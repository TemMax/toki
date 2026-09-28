import Testing
import Foundation
import Security
import LocalAuthentication
import TokiKeychain
@testable import TokiAccounts

private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

private func makeSlot(uuid: String, refresh: String, addedAt: Date = t0) -> AccountSlot {
    let json = Data(#"{"claudeAiOauth":{"accessToken":"a","refreshToken":"\#(refresh)"}}"#.utf8)
    return AccountSlot(
        identity: AccountIdentity(
            accountUuid: uuid, email: "\(uuid)@x.y", displayName: nil,
            organizationName: nil, organizationUuid: nil
        ),
        alias: nil, credentialJSON: json, previousCredentialJSON: nil,
        lineage: Lineage.fingerprint(refreshToken: refresh),
        addedAt: addedAt, lastActiveAt: nil, lastRefreshAt: nil, health: .ok
    )
}

/// Unique per process run: the test bundle is rebuilt and re-signed on every `swift test`,
/// so items written by a previous build are no longer covered by their own Keychain ACL and
/// reading them raises the macOS authorization dialog. A fresh prefix each run means the
/// suite only ever reads items this binary wrote — no dialogs, and no `errSecUserCanceled`
/// masquerading as a missing account.
private let testRunID = UUID().uuidString.prefix(8)

/// Uses a test-only service prefix so the suite can never disturb real slots.
private func makeStore() -> KeychainSlotStore {
    KeychainSlotStore(
        servicePrefix: "dev.komar.toki.test.account.\(testRunID).",
        quarantinePrefix: "dev.komar.toki.test.quarantine.\(testRunID).",
        indexService: "dev.komar.toki.test.index.\(testRunID)"
    )
}

/// In-memory stand-in for `KeychainPrimitives`, keyed the way the real Keychain queries
/// are keyed (service + account). Lets F7/F8 tests force a specific failure — the real
/// Keychain has no reliable, deterministic way to produce one.
private final class FakeKeychainPrimitives: KeychainPrimitives, @unchecked Sendable {
    private var storage: [String: Data] = [:]
    var failingWriteServices: Set<String> = []
    var failingReadServices: Set<String> = []
    var failureStatus: OSStatus = errSecIO

    /// Every query/attributes dictionary handed to a primitive call, in order — lets tests
    /// assert on what `baseQuery` actually put in the dictionary (e.g. the auth context).
    var recordedQueries: [[CFString: Any]] = []

    private func key(service: String, account: String) -> String { "\(service)|\(account)" }

    private func service(of query: [CFString: Any]) -> String { (query[kSecAttrService] as? String) ?? "" }
    private func account(of query: [CFString: Any]) -> String { (query[kSecAttrAccount] as? String) ?? "" }

    /// True once a value has actually been stored under this key — matches the real
    /// Keychain's item-exists check that decides update vs. add.
    func contains(service: String, account: String) -> Bool {
        storage[key(service: service, account: account)] != nil
    }

    func copyMatching(_ query: [CFString: Any]) -> (status: OSStatus, result: CFTypeRef?) {
        recordedQueries.append(query)
        let svc = service(of: query)
        if failingReadServices.contains(svc) { return (failureStatus, nil) }
        guard let data = storage[key(service: svc, account: account(of: query))] else {
            return (errSecItemNotFound, nil)
        }
        return (errSecSuccess, data as CFTypeRef)
    }

    func update(_ query: [CFString: Any], attributes: [CFString: Any]) -> OSStatus {
        recordedQueries.append(query)
        let svc = service(of: query)
        if failingWriteServices.contains(svc) { return failureStatus }
        let k = key(service: svc, account: account(of: query))
        guard storage[k] != nil else { return errSecItemNotFound }
        storage[k] = attributes[kSecValueData] as? Data
        return errSecSuccess
    }

    func add(_ attributes: [CFString: Any]) -> OSStatus {
        recordedQueries.append(attributes)
        let svc = service(of: attributes)
        if failingWriteServices.contains(svc) { return failureStatus }
        storage[key(service: svc, account: account(of: attributes))] = attributes[kSecValueData] as? Data
        return errSecSuccess
    }

    func delete(_ query: [CFString: Any]) -> OSStatus {
        recordedQueries.append(query)
        let k = key(service: service(of: query), account: account(of: query))
        guard storage.removeValue(forKey: k) != nil else { return errSecItemNotFound }
        return errSecSuccess
    }
}

/// A store wired to the fake backing, for tests that need to inject a Keychain failure
/// rather than exercise the real Keychain.
private func makeFakeBackedStore(primitives: FakeKeychainPrimitives) -> KeychainSlotStore {
    KeychainSlotStore(
        servicePrefix: "svc.", quarantinePrefix: "qua.", indexService: "idx",
        account: "test-account", primitives: primitives
    )
}

/// `indexService` must be the exact index service the given `store` was built with — the
/// store has no API for dropping its own index, so this has to know it directly rather than
/// guess. Passing it explicitly (instead of hardcoding the file-scope `testRunID`-based
/// service every `makeStore()` uses) is the fix for a real leak: `SlotStoreExactReadTests`
/// builds its OWN store with its own locally-generated id specifically so parallel suites
/// don't race each other's wipes (see its own comment), but calling this with the wrong,
/// unrelated index service silently deleted nothing for that store's actual index — leaving
/// one `dev.komar.toki.test.exact.index.*` item behind per run. Every call site below must
/// pass the same index service string its store was constructed with.
private func wipe(_ store: KeychainSlotStore, indexService: String) {
    for slot in (try? store.loadAll()) ?? [] {
        try? store.delete(accountUuid: slot.identity.accountUuid)
    }
    for entry in (try? store.loadQuarantine()) ?? [] {
        try? store.deleteQuarantine(id: entry.id)
    }
    // Leaving one behind per run would slowly litter the developer's Keychain.
    SecItemDelete([
        kSecClass: kSecClassGenericPassword,
        kSecAttrService: indexService,
        kSecAttrAccount: NSUserName(),
    ] as CFDictionary)
}

/// The index service `makeStore()` builds its `KeychainSlotStore`s with — the default
/// `wipe(_:indexService:)` argument for every test in this file that uses `makeStore()`.
private let defaultIndexService = "dev.komar.toki.test.index.\(testRunID)"

@Suite("SlotStore", .serialized)
struct SlotStoreTests {

    @Test("Debug and release namespaces are disjoint — neither prefix contains the other")
    func buildNamespacesAreDisjoint() {
        // Both builds' default names coexist in the same login keychain. If either build's
        // slot prefix were a prefix of the other's, the repair enumeration in `loadAll`
        // (which matches by prefix) would adopt the other build's slots, and each build
        // would read an item whose ACL names a differently signed binary — a password
        // prompt per item. Whichever configuration this test binary was compiled in gives
        // us one side; assert it can't collide with the other regardless.
        let account = KeychainSlotStore.defaultServicePrefix
        let quarantine = KeychainSlotStore.defaultQuarantinePrefix
        let index = KeychainSlotStore.defaultIndexService
        let releaseAccount = KeychainNamespace.prefix + "account."
        let debugAccount = KeychainNamespace.prefix + "debug.account."

        #expect(account == releaseAccount || account == debugAccount)
        #expect(!releaseAccount.hasPrefix(debugAccount))
        #expect(!debugAccount.hasPrefix(releaseAccount))
        // The index must not sit under the slot prefix, or a slot enumeration would try to
        // decode the index blob as a slot.
        #expect(!index.hasPrefix(account))
        #expect(!quarantine.hasPrefix(account))
        #expect(!account.hasPrefix(quarantine))
    }

    @Test("saves and lists slots, ordered by when they were added")
    func saveAndList() throws {
        let store = makeStore()
        wipe(store, indexService: defaultIndexService); defer { wipe(store, indexService: defaultIndexService) }

        try store.save(makeSlot(uuid: "b", refresh: "r-b", addedAt: t0.addingTimeInterval(60)))
        try store.save(makeSlot(uuid: "a", refresh: "r-a", addedAt: t0))

        let all = try store.loadAll()
        #expect(all.map(\.identity.accountUuid) == ["a", "b"])
        #expect(all.first?.credentialJSON.isEmpty == false)
    }

    @Test("saving the same account twice updates rather than duplicates")
    func saveIsIdempotent() throws {
        let store = makeStore()
        wipe(store, indexService: defaultIndexService); defer { wipe(store, indexService: defaultIndexService) }

        try store.save(makeSlot(uuid: "a", refresh: "r1"))
        try store.save(makeSlot(uuid: "a", refresh: "r2"))

        let all = try store.loadAll()
        #expect(all.count == 1)
        #expect(all.first?.lineage == Lineage.fingerprint(refreshToken: "r2"))
    }

    @Test("delete removes exactly one slot")
    func deleteRemovesOne() throws {
        let store = makeStore()
        wipe(store, indexService: defaultIndexService); defer { wipe(store, indexService: defaultIndexService) }

        try store.save(makeSlot(uuid: "a", refresh: "r-a"))
        try store.save(makeSlot(uuid: "b", refresh: "r-b"))
        try store.delete(accountUuid: "a")

        #expect(try store.loadAll().map(\.identity.accountUuid) == ["b"])
    }

    @Test("the slot list survives without any index — it is rebuilt by enumeration")
    func listNeedsNoIndex() throws {
        let store = makeStore()
        wipe(store, indexService: defaultIndexService); defer { wipe(store, indexService: defaultIndexService) }
        try store.save(makeSlot(uuid: "a", refresh: "r-a"))

        // A brand-new store instance shares no in-memory state with the one that wrote.
        let fresh = makeStore()
        #expect(try fresh.loadAll().count == 1)
    }

    // Rewritten for F6/D3: quarantined bytes may be the only surviving copy of an
    // account's refresh token, so the cap must never evict to make room for a new
    // entry — it refuses the write instead. This replaces the old assertion that
    // pinned eviction as correct behaviour.
    @Test("quarantine at the cap refuses a new entry rather than evicting an old one")
    func quarantineIsCapped() throws {
        let store = makeStore()
        wipe(store, indexService: defaultIndexService); defer { wipe(store, indexService: defaultIndexService) }

        for i in 0..<KeychainSlotStore.quarantineCap {
            try store.saveQuarantine(
                QuarantineEntry(
                    id: "q\(i)", credentialJSON: Data("c\(i)".utf8),
                    foundAt: t0.addingTimeInterval(Double(i)), ownerLabel: nil
                ),
                now: t0.addingTimeInterval(Double(i))
            )
        }

        #expect(throws: SlotStoreError.quarantineFull(cap: KeychainSlotStore.quarantineCap)) {
            try store.saveQuarantine(
                QuarantineEntry(
                    id: "overflow", credentialJSON: Data("overflow".utf8),
                    foundAt: t0.addingTimeInterval(99), ownerLabel: nil
                ),
                now: t0.addingTimeInterval(99)
            )
        }

        // The refused write must not have disturbed what was already there.
        let entries = try store.loadQuarantine().sorted { $0.foundAt < $1.foundAt }
        #expect(entries.map(\.id) == ["q0", "q1", "q2"])
    }

    @Test("re-quarantining an id already present at the cap still updates it")
    func quarantineUpdateAtCapIsNotBlocked() throws {
        let store = makeStore()
        wipe(store, indexService: defaultIndexService); defer { wipe(store, indexService: defaultIndexService) }

        for i in 0..<KeychainSlotStore.quarantineCap {
            try store.saveQuarantine(
                QuarantineEntry(
                    id: "q\(i)", credentialJSON: Data("c\(i)".utf8),
                    foundAt: t0.addingTimeInterval(Double(i)), ownerLabel: nil
                ),
                now: t0.addingTimeInterval(Double(i))
            )
        }

        try store.saveQuarantine(
            QuarantineEntry(id: "q0", credentialJSON: Data("updated".utf8), foundAt: t0, ownerLabel: "owner"),
            now: t0
        )

        let entries = try store.loadQuarantine()
        #expect(entries.count == KeychainSlotStore.quarantineCap)
        #expect(entries.first { $0.id == "q0" }?.ownerLabel == "owner")
    }

    // F7: a failed index write must abort the save before the slot itself is written —
    // otherwise the slot becomes an item the index (and so `loadAll`) doesn't know about.
    @Test("save fails atomically when the index write fails")
    func saveFailsWhenIndexWriteFails() throws {
        let fake = FakeKeychainPrimitives()
        let store = makeFakeBackedStore(primitives: fake)
        fake.failingWriteServices.insert("idx")

        #expect(throws: SlotStoreError.self) {
            try store.save(makeSlot(uuid: "a", refresh: "r-a"))
        }
        #expect(fake.contains(service: "svc.a", account: "test-account") == false)
    }

    // F8: `read` already tells "item missing" apart from a genuine Keychain failure;
    // `loadAll` must propagate the latter instead of silently dropping the account.
    @Test("loadAll propagates a genuine Keychain failure instead of dropping the slot")
    func loadAllPropagatesGenuineFailure() throws {
        let fake = FakeKeychainPrimitives()
        let store = makeFakeBackedStore(primitives: fake)
        try store.save(makeSlot(uuid: "a", refresh: "r-a"))

        fake.failingReadServices.insert("svc.a")

        #expect(throws: SlotStoreError.self) {
            try store.loadAll()
        }
    }

    // Background poll loops must never be able to raise a Keychain consent dialog: every
    // query the store issues has to carry a no-interaction auth context.
    @Test("every read and write query carries a no-interaction auth context")
    func queriesCarryNoInteractionContext() throws {
        let fake = FakeKeychainPrimitives()
        let store = makeFakeBackedStore(primitives: fake)

        try store.save(makeSlot(uuid: "a", refresh: "r-a"))
        _ = try store.load(accountUuid: "a")

        #expect(!fake.recordedQueries.isEmpty)
        for query in fake.recordedQueries {
            guard let context = query[kSecUseAuthenticationContext] as? LAContext else {
                Issue.record("query missing kSecUseAuthenticationContext: \(query)")
                continue
            }
            #expect(context.interactionNotAllowed)
        }
    }

    @Test("quarantine entries older than the refresh-token lifetime are dropped")
    func quarantineExpires() throws {
        let store = makeStore()
        wipe(store, indexService: defaultIndexService); defer { wipe(store, indexService: defaultIndexService) }

        try store.saveQuarantine(
            QuarantineEntry(id: "old", credentialJSON: Data("x".utf8), foundAt: t0, ownerLabel: nil),
            now: t0
        )
        // A later write triggers the sweep; 31 days is past a refresh token's ~28-day life,
        // so nothing recoverable is discarded early.
        try store.saveQuarantine(
            QuarantineEntry(
                id: "new", credentialJSON: Data("y".utf8),
                foundAt: t0.addingTimeInterval(31 * 24 * 3600), ownerLabel: nil
            ),
            now: t0.addingTimeInterval(31 * 24 * 3600)
        )
        #expect(try store.loadQuarantine().map(\.id) == ["new"])
    }
}

// MARK: - Repair-scan rate limiting

/// `loadAll` sits on the account list's refresh path, and its repair enumeration walks
/// every generic-password item in the login keychain (535 on the machine this was measured
/// on). These cover the gate that keeps that scan off the hot path without losing the
/// self-healing it exists for.
@Suite("SlotStore repair clock")
struct RepairClockTests {

    @Test("an empty index always scans — that is the case repair exists for")
    func emptyIndexAlwaysScans() {
        let clock = RepairClock()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(clock.shouldScan(now: t0))
    }

    @Test("a second scan inside the window is refused, and allowed again after it")
    func scanIsRateLimited() {
        let clock = RepairClock()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)

        #expect(clock.shouldScan(now: t0))
        #expect(!clock.shouldScan(now: t0.addingTimeInterval(1)))
        #expect(!clock.shouldScan(now: t0.addingTimeInterval(RepairClock.interval - 0.1)))
        #expect(clock.shouldScan(now: t0.addingTimeInterval(RepairClock.interval)))
    }

    @Test("the gate is claimed by the first caller, so concurrent refreshes scan once")
    func gateIsClaimedOnce() {
        let clock = RepairClock()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let granted = (0..<8).filter { _ in clock.shouldScan(now: t0) }.count
        #expect(granted == 1)
    }
}

@Suite("SlotStore exact reads", .serialized)
struct SlotStoreExactReadTests {

    @Test("load(accountUuid:) returns just that slot, and nil for an unknown one")
    func exactReadFindsOneSlot() throws {
        // Its own prefix, not `makeStore()`'s: suites run in parallel with each other, and
        // sharing a prefix means one suite's wipe races the other's saves.
        let id = UUID().uuidString.prefix(8)
        // This store's OWN index service, not `defaultIndexService` (`makeStore()`'s) — this
        // was the actual leak: passing the wrong index service to `wipe` silently deleted
        // nothing for this store, leaving one `dev.komar.toki.test.exact.index.*` item behind
        // per run.
        let exactIndexService = "dev.komar.toki.test.exact.index.\(id)"
        let store = KeychainSlotStore(
            servicePrefix: "dev.komar.toki.test.exact.account.\(id).",
            quarantinePrefix: "dev.komar.toki.test.exact.quarantine.\(id).",
            indexService: exactIndexService
        )
        wipe(store, indexService: exactIndexService); defer { wipe(store, indexService: exactIndexService) }

        try store.save(makeSlot(uuid: "exact-x", refresh: "r-x"))
        try store.save(makeSlot(uuid: "exact-y", refresh: "r-y"))

        #expect(try store.load(accountUuid: "exact-y")?.identity.accountUuid == "exact-y")
        #expect(try store.load(accountUuid: "exact-missing") == nil)
    }
}
