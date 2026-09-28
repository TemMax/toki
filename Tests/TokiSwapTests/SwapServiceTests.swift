import Testing
import Foundation
import TokiAccounts
import TokiKeychain
import TokiModels
@testable import TokiSwap

private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
private let liveRef = KeychainItemRef(service: "Claude Code-credentials", account: "u", modifiedAt: 1)

private func credential(refresh: String) -> Data {
    Data(#"{"claudeAiOauth":{"accessToken":"a-\#(refresh)","refreshToken":"\#(refresh)"}}"#.utf8)
}

private func slot(_ uuid: String, refresh: String) -> AccountSlot {
    AccountSlot(
        identity: AccountIdentity(
            accountUuid: uuid, email: "\(uuid)@x.y", displayName: nil,
            organizationName: nil, organizationUuid: nil
        ),
        alias: nil, credentialJSON: credential(refresh: refresh), previousCredentialJSON: nil,
        lineage: Lineage.fingerprint(refreshToken: refresh),
        addedAt: t0, lastActiveAt: nil, lastRefreshAt: nil, health: .ok
    )
}

private enum FakeStoreError: Error, Equatable { case injected }

private final class FakeStore: SlotStoring, @unchecked Sendable {
    var slots: [String: AccountSlot] = [:]
    var quarantine: [QuarantineEntry] = []
    /// Injected failures. Without them every `try?` in the swap transaction was asserted
    /// against a store that could not fail, which is exactly why the missing abort on a
    /// failed sync-back went unnoticed.
    var saveError: FakeStoreError?
    var quarantineError: FakeStoreError?

    func loadAll() throws -> [AccountSlot] { slots.values.sorted { $0.addedAt < $1.addedAt } }
    func load(accountUuid: String) throws -> AccountSlot? { slots[accountUuid] }
    func save(_ slot: AccountSlot) throws {
        if let saveError { throw saveError }
        slots[slot.identity.accountUuid] = slot
    }
    func delete(accountUuid: String) throws { slots[accountUuid] = nil }
    func loadQuarantine() throws -> [QuarantineEntry] { quarantine }
    func saveQuarantine(_ entry: QuarantineEntry, now: Date) throws {
        if let quarantineError { throw quarantineError }
        quarantine.append(entry)
    }
    func deleteQuarantine(id: String) throws { quarantine.removeAll { $0.id == id } }
}

private final class FakeLive: LiveCredentialAccess, @unchecked Sendable {
    var json: Data
    /// Models a machine that has just run `/logout`: nothing readable is live, yet a
    /// stored account must still be restorable.
    var isReadable = true
    init(json: Data) { self.json = json }
    func readLive() async -> (json: Data, ref: KeychainItemRef)? {
        isReadable ? (json, liveRef) : nil
    }
}

private final class FakeRunner: SubprocessRunning, @unchecked Sendable {
    let live: FakeLive
    var outcome: SubprocessOutcome = .success(Data(), duration: 0.05)
    /// Per-call outcomes consumed in order, falling back to `outcome`. Needed to fail only
    /// the rollback write, leaving the first one to succeed.
    var queuedOutcomes: [SubprocessOutcome] = []
    private(set) var writes = 0
    init(live: FakeLive) { self.live = live }
    func run(arguments: [String], timeout: TimeInterval) async -> SubprocessOutcome {
        writes += 1
        let result = queuedOutcomes.isEmpty ? outcome : queuedOutcomes.removeFirst()
        // Mimic the real writer: unless `security` itself refused, the item now holds what
        // was written — which is why a timeout or a verification mismatch still needs a
        // rollback.
        if case .failure = result { return result }
        if let hexIndex = arguments.firstIndex(of: "-X"), hexIndex + 1 < arguments.count {
            let hex = arguments[hexIndex + 1]
            var bytes = [UInt8]()
            var i = hex.startIndex
            while i < hex.endIndex {
                let j = hex.index(i, offsetBy: 2)
                bytes.append(UInt8(hex[i..<j], radix: 16) ?? 0)
                i = j
            }
            live.json = Data(bytes)
        }
        return result
    }
}

private final class VaultInvalidations: @unchecked Sendable {
    var count = 0
}

/// Records, from inside the profile lookup, which Claude Code lock directories existed
/// at that instant — the evidence for "no network call while a lock is held".
private final class LockProbe: @unchecked Sendable {
    var calls = 0
    var locksHeldAtLookup: [String] = []
}

private struct FakeOracle: ProfileLookup {
    var identity: AccountIdentity?
    var probe: LockProbe?
    /// Injected by the harness, which owns the temp config directory.
    var configDir: URL?

    func owner(ofToken token: String) async throws -> AccountIdentity {
        if let probe {
            probe.calls += 1
            if let configDir {
                probe.locksHeldAtLookup += [
                    ClaudeLocks.tokiSwap(configDir: configDir),
                    ClaudeLocks.oauthRefresh(configDir: configDir),
                    ClaudeLocks.storageWrite(configDir: configDir),
                ]
                .filter { FileManager.default.fileExists(atPath: $0.path.path) }
                .map { $0.path.lastPathComponent }
            }
        }
        guard let identity else { throw TokiError.httpError(500) }
        return identity
    }
}

private struct Harness {
    let service: SwapService
    let store: FakeStore
    let live: FakeLive
    let runner: FakeRunner
    let invalidations: VaultInvalidations
    let dir: URL

    var configURL: URL { dir.appendingPathComponent(".claude.json") }
    var fallbackURL: URL { dir.appendingPathComponent(".credentials.json") }
    var lockPaths: [URL] {
        [
            ClaudeLocks.tokiSwap(configDir: dir),
            ClaudeLocks.oauthRefresh(configDir: dir),
            ClaudeLocks.storageWrite(configDir: dir),
        ].map { $0.path }
    }
}

private func makeHarness(
    live liveRefresh: String,
    slots: [AccountSlot],
    oracle: FakeOracle = FakeOracle(identity: nil),
    configAccountUuid: String = "start",
    credentialItemRef: @escaping @Sendable () -> KeychainItemRef? = { liveRef },
    freshen: @escaping @Sendable (AccountSlot, String?) async -> RefreshOutcome = { _, _ in .skipped }
) throws -> Harness {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("toki-swap-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let configURL = dir.appendingPathComponent(".claude.json")
    try #"{"oauthAccount": {"accountUuid": "\#(configAccountUuid)"}, "keep": 1}"#
        .write(to: configURL, atomically: true, encoding: .utf8)

    let store = FakeStore()
    for s in slots { try store.save(s) }
    let live = FakeLive(json: credential(refresh: liveRefresh))
    let runner = FakeRunner(live: live)
    let writer = CredentialWriter(runner: runner, readBack: { _ in live.json })
    let invalidations = VaultInvalidations()

    var oracle = oracle
    oracle.configDir = dir

    let service = SwapService(dependencies: SwapDependencies(
        store: store, live: live, writer: writer,
        config: ClaudeConfigEditor(configURL: configURL),
        oracle: oracle, locks: LockBroker(), configDir: dir,
        fallbackFileURL: dir.appendingPathComponent(".credentials.json"),
        // Never `KeychainItemRef.selectClaudeItem()`: that would read the user's real
        // Claude Code login item.
        credentialItemRef: credentialItemRef,
        now: { t0 }, onVaultInvalidated: { invalidations.count += 1 },
        freshen: freshen
    ))
    return Harness(
        service: service, store: store, live: live, runner: runner,
        invalidations: invalidations, dir: dir
    )
}

@Suite("SwapService", .serialized)
struct SwapServiceTests {

    @Test("swapping writes the target credential and records the outgoing one")
    func happyPath() async throws {
        let h = try makeHarness(
            live: "r-a", slots: [slot("a", refresh: "r-a"), slot("b", refresh: "r-b")]
        )
        defer { try? FileManager.default.removeItem(at: h.dir) }

        let outcome = try await h.service.swap(to: "b")

        #expect(outcome == SwapOutcome(from: "a", to: "b", quarantined: false))
        #expect(h.live.json == credential(refresh: "r-b"))
        #expect(h.store.slots["a"]?.lastActiveAt == t0)
    }

    @Test("the config's oauthAccount is spliced to the target account")
    func splicesConfig() async throws {
        let h = try makeHarness(
            live: "r-a", slots: [slot("a", refresh: "r-a"), slot("b", refresh: "r-b")]
        )
        defer { try? FileManager.default.removeItem(at: h.dir) }

        _ = try await h.service.swap(to: "b")

        let text = try String(contentsOf: h.configURL, encoding: .utf8)
        #expect(text.contains("\"b\""))
        #expect(text.contains("\"keep\": 1"), "unrelated config keys must survive")
    }

    @Test("a foreign live credential is quarantined instead of overwriting the slot")
    func foreignCredentialIsQuarantined() async throws {
        // Someone logged into a third account outside Toki. Writing those bytes into
        // slot "a" would destroy the only copy of a's refresh token.
        let h = try makeHarness(
            live: "r-stranger",
            slots: [slot("a", refresh: "r-a"), slot("b", refresh: "r-b")],
            oracle: FakeOracle(identity: AccountIdentity(
                accountUuid: "uuid-stranger", email: nil, displayName: nil,
                organizationName: nil, organizationUuid: nil
            ))
        )
        defer { try? FileManager.default.removeItem(at: h.dir) }

        let outcome = try await h.service.swap(to: "b")

        #expect(outcome.quarantined)
        #expect(outcome.from == nil)
        #expect(h.store.slots["a"]?.credentialJSON == credential(refresh: "r-a"))
        #expect(h.store.quarantine.count == 1)
    }

    @Test("the fallback credentials file is updated only when it already exists")
    func fallbackFileIsNotCreated() async throws {
        let h = try makeHarness(
            live: "r-a", slots: [slot("a", refresh: "r-a"), slot("b", refresh: "r-b")]
        )
        defer { try? FileManager.default.removeItem(at: h.dir) }
        let fallback = h.fallbackURL

        _ = try await h.service.swap(to: "b")
        #expect(!FileManager.default.fileExists(atPath: fallback.path))

        try Data("{}".utf8).write(to: fallback)
        _ = try await h.service.swap(to: "a")
        #expect(try Data(contentsOf: fallback) == credential(refresh: "r-a"))
    }

    @Test("a swap while Claude Code holds its write lock aborts cleanly")
    func abortsWhenClaudeCodeIsBusy() async throws {
        let h = try makeHarness(
            live: "r-a", slots: [slot("a", refresh: "r-a"), slot("b", refresh: "r-b")]
        )
        defer { try? FileManager.default.removeItem(at: h.dir) }
        try FileManager.default.createDirectory(
            at: ClaudeLocks.storageWrite(configDir: h.dir).path, withIntermediateDirectories: false
        )

        await #expect(throws: SwapError.claudeBusy) { _ = try await h.service.swap(to: "b") }
        #expect(h.live.json == credential(refresh: "r-a"), "no partial mutation")
    }

    @Test("swapping to an unknown account is refused")
    func unknownAccountIsRefused() async throws {
        let h = try makeHarness(live: "r-a", slots: [slot("a", refresh: "r-a")])
        defer { try? FileManager.default.removeItem(at: h.dir) }
        await #expect(throws: SwapError.unknownAccount) { _ = try await h.service.swap(to: "zzz") }
    }

    @Test("the ownership network call happens before any Claude Code lock is taken")
    func ownershipLookupRunsOutsideEveryLock() async throws {
        // A profile lookup made while `.storage-write` is held would stall Claude Code's
        // own credential writes for the length of an HTTP round trip.
        let probe = LockProbe()
        let h = try makeHarness(
            live: "r-stranger",
            slots: [slot("a", refresh: "r-a"), slot("b", refresh: "r-b")],
            oracle: FakeOracle(
                identity: AccountIdentity(
                    accountUuid: "uuid-stranger", email: nil, displayName: nil,
                    organizationName: nil, organizationUuid: nil
                ),
                probe: probe
            )
        )
        defer { try? FileManager.default.removeItem(at: h.dir) }

        _ = try await h.service.swap(to: "b")

        // Without this the assertion below would pass vacuously on a swap that never
        // consulted the oracle at all.
        #expect(probe.calls > 0)
        #expect(probe.locksHeldAtLookup.isEmpty)
    }

    // MARK: F13 — a failed credential write is rolled back

    @Test("a write that times out is rolled back to the outgoing credential")
    func timedOutWriteIsRolledBack() async throws {
        // `timedOut` and `verificationMismatch` both mean the bytes may already be in the
        // Keychain. Without a rollback Claude Code keeps the target's credential while the
        // config still names the outgoing account, and every gauge is misattributed.
        let h = try makeHarness(
            live: "r-a", slots: [slot("a", refresh: "r-a"), slot("b", refresh: "r-b")]
        )
        defer { try? FileManager.default.removeItem(at: h.dir) }
        h.runner.queuedOutcomes = [.timedOut, .success(Data(), duration: 0.01)]

        await #expect(throws: SwapError.writeFailed) { _ = try await h.service.swap(to: "b") }

        #expect(h.live.json == credential(refresh: "r-a"), "the live credential must survive")
        #expect(h.runner.writes == 2, "the rollback write must actually be issued")
        #expect(h.invalidations.count == 1, "the cached token may have changed")
    }

    @Test("failed write with failed rollback reports recovery failure distinctly")
    func failedWriteAndRollback() async throws {
        let h = try makeHarness(
            live: "r-a", slots: [slot("a", refresh: "r-a"), slot("b", refresh: "r-b")]
        )
        defer { try? FileManager.default.removeItem(at: h.dir) }
        h.runner.queuedOutcomes = [.timedOut, .failure(exitCode: 45)]
        await #expect(throws: SwapError.rollbackFailed) { _ = try await h.service.swap(to: "b") }
        #expect(h.invalidations.count == 1)
        #expect(h.live.json == credential(refresh: "r-b"))
    }

    // MARK: F14 — preserving the outgoing credential is a precondition (D2)

    @Test("a store that cannot save the outgoing slot aborts before any write")
    func failedSyncBackAbortsTheSwap() async throws {
        let h = try makeHarness(
            live: "r-a", slots: [slot("a", refresh: "r-a"), slot("b", refresh: "r-b")]
        )
        defer { try? FileManager.default.removeItem(at: h.dir) }
        h.store.saveError = .injected

        await #expect(throws: SwapError.preservationFailed) {
            _ = try await h.service.swap(to: "b")
        }

        #expect(h.runner.writes == 0, "nothing may be written before the outgoing bytes are safe")
        #expect(h.live.json == credential(refresh: "r-a"))
    }

    @Test("a quarantine that cannot be written aborts before any write")
    func failedQuarantineAbortsTheSwap() async throws {
        // The quarantine cap and a Keychain failure both surface here, and the quarantined
        // bytes may be the only copy of that account's refresh token.
        let h = try makeHarness(
            live: "r-stranger",
            slots: [slot("a", refresh: "r-a"), slot("b", refresh: "r-b")],
            oracle: FakeOracle(identity: AccountIdentity(
                accountUuid: "uuid-stranger", email: nil, displayName: nil,
                organizationName: nil, organizationUuid: nil
            ))
        )
        defer { try? FileManager.default.removeItem(at: h.dir) }
        h.store.quarantineError = .injected

        await #expect(throws: SwapError.preservationFailed) {
            _ = try await h.service.swap(to: "b")
        }

        #expect(h.runner.writes == 0)
        #expect(h.live.json == credential(refresh: "r-stranger"))
    }

    // MARK: F15 — the step-3 rollback is verified and invalidates the vault

    @Test("a config failure rolls the credential back and drops the cached token")
    func configFailureRollsBack() async throws {
        let h = try makeHarness(
            live: "r-a", slots: [slot("a", refresh: "r-a"), slot("b", refresh: "r-b")]
        )
        defer { try? FileManager.default.removeItem(at: h.dir) }
        try FileManager.default.removeItem(at: h.configURL)

        await #expect(throws: SwapError.configFailed) { _ = try await h.service.swap(to: "b") }

        #expect(h.live.json == credential(refresh: "r-a"))
        #expect(h.invalidations.count == 1, "the live credential changed twice; the cache is stale")
    }

    @Test("a rollback that itself fails is reported rather than swallowed")
    func failedRollbackIsReported() async throws {
        let h = try makeHarness(
            live: "r-a", slots: [slot("a", refresh: "r-a"), slot("b", refresh: "r-b")]
        )
        defer { try? FileManager.default.removeItem(at: h.dir) }
        try FileManager.default.removeItem(at: h.configURL)
        // The target write lands; only the restore is refused.
        h.runner.queuedOutcomes = [.success(Data(), duration: 0.01), .failure(exitCode: 1)]

        await #expect(throws: SwapError.rollbackFailed) { _ = try await h.service.swap(to: "b") }

        #expect(
            h.live.json == credential(refresh: "r-b"),
            "the mismatch the user must be told about: Keychain holds b, the config does not"
        )
    }

    // MARK: F16 — locks are released before the call returns

    @Test("every Claude Code lock is gone by the time a successful swap returns")
    func locksAreReleasedOnSuccess() async throws {
        // `defer { Task { await release } }` only schedules the release, so the lock
        // directories outlive the call and the next swap sees Claude Code as busy.
        let h = try makeHarness(
            live: "r-a", slots: [slot("a", refresh: "r-a"), slot("b", refresh: "r-b")]
        )
        defer { try? FileManager.default.removeItem(at: h.dir) }

        _ = try await h.service.swap(to: "b")

        for path in h.lockPaths {
            #expect(
                !FileManager.default.fileExists(atPath: path.path),
                "\(path.lastPathComponent) still held after swap returned"
            )
        }
    }

    @Test("every Claude Code lock is gone after a swap that throws")
    func locksAreReleasedOnThrow() async throws {
        let h = try makeHarness(
            live: "r-a", slots: [slot("a", refresh: "r-a"), slot("b", refresh: "r-b")]
        )
        defer { try? FileManager.default.removeItem(at: h.dir) }
        h.store.saveError = .injected

        await #expect(throws: SwapError.preservationFailed) {
            _ = try await h.service.swap(to: "b")
        }

        for path in h.lockPaths {
            #expect(
                !FileManager.default.fileExists(atPath: path.path),
                "\(path.lastPathComponent) still held after swap threw"
            )
        }
    }

    // MARK: F17 — swapping to the account already signed in (D1)

    @Test("swapping to the account whose lineage is live does nothing")
    func selfSwapByLineageIsANoOp() async throws {
        let h = try makeHarness(
            live: "r-a", slots: [slot("a", refresh: "r-a"), slot("b", refresh: "r-b")]
        )
        defer { try? FileManager.default.removeItem(at: h.dir) }

        let outcome = try await h.service.swap(to: "a")

        #expect(outcome == SwapOutcome(from: "a", to: "a", quarantined: false, alreadyActive: true))
        #expect(h.runner.writes == 0)
        #expect(h.live.json == credential(refresh: "r-a"))
    }

    @Test("swapping to the account the config names, after Claude Code rotated, does nothing")
    func selfSwapByConfigIdentityIsANoOp() async throws {
        // Claude Code refreshed on its own schedule, so the live credential is a
        // descendant of what slot "a" stores and resolves by lineage to `.unknown`.
        // Writing the slot's copy would hand Claude Code a refresh token it has already
        // spent, and quarantine the only working one.
        let h = try makeHarness(
            live: "r-a-rotated",
            slots: [slot("a", refresh: "r-a"), slot("b", refresh: "r-b")],
            configAccountUuid: "a"
        )
        defer { try? FileManager.default.removeItem(at: h.dir) }

        let outcome = try await h.service.swap(to: "a")

        #expect(outcome.alreadyActive)
        #expect(h.runner.writes == 0)
        #expect(h.live.json == credential(refresh: "r-a-rotated"), "the working credential survives")
        #expect(h.store.quarantine.isEmpty, "the live credential must not be quarantined")
    }

    // MARK: F19 — the fallback file is never briefly world-readable

    @Test("the fallback file is narrowed to 0600 before the credential is published")
    func fallbackFileIsNarrowedBeforeTheWrite() async throws {
        let h = try makeHarness(
            live: "r-a", slots: [slot("a", refresh: "r-a"), slot("b", refresh: "r-b")]
        )
        defer { try? FileManager.default.removeItem(at: h.dir) }
        try Data("{}".utf8).write(to: h.fallbackURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: h.fallbackURL.path
        )
        // `Data.write(.atomic)` publishes a NEW inode that inherits the destination's mode,
        // so this hard link keeps the inode the credential replaced. Its mode is the
        // evidence of whether the destination was narrowed BEFORE the secret was published
        // or only chmodded afterwards.
        let witness = h.dir.appendingPathComponent("witness")
        #expect(link(h.fallbackURL.path, witness.path) == 0)

        _ = try await h.service.swap(to: "b")

        #expect(try mode(of: h.fallbackURL) == 0o600)
        #expect(try mode(of: witness) == 0o600, "the destination was still 0644 when replaced")
    }

    // MARK: F20 — restoring an account after `/logout`

    @Test("a stored account can be restored when no credential is readable")
    func restoresWhenNothingIsLive() async throws {
        let h = try makeHarness(
            live: "r-a", slots: [slot("a", refresh: "r-a"), slot("b", refresh: "r-b")]
        )
        defer { try? FileManager.default.removeItem(at: h.dir) }
        h.live.isReadable = false

        let outcome = try await h.service.swap(to: "b")

        #expect(outcome == SwapOutcome(from: nil, to: "b", quarantined: false))
        #expect(h.live.json == credential(refresh: "r-b"))
    }

    // MARK: F46 — a provisional adopted slot never fabricates a config accountUuid

    @Test("swapping to a provisional adopted slot keeps the config's own accountUuid")
    func provisionalSlotDoesNotFabricateConfigAccountUuid() async throws {
        // A quarantined credential adopted with no confirmed identity is keyed on its
        // lineage-fingerprint prefix, not an id Anthropic issued. Writing that prefix into
        // `~/.claude.json`'s oauthAccount.accountUuid would plant a fabricated account id in
        // Claude Code's own config.
        let provLineage = Lineage.fingerprint(refreshToken: "r-prov")
        let provUuid = String(provLineage.prefix(16))
        let provisional = slot(provUuid, refresh: "r-prov")

        let h = try makeHarness(
            live: "r-a",
            slots: [slot("a", refresh: "r-a"), provisional],
            configAccountUuid: "a"
        )
        defer { try? FileManager.default.removeItem(at: h.dir) }

        _ = try await h.service.swap(to: provUuid)

        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: h.configURL))
            as? [String: Any]
        let oauth = root?["oauthAccount"] as? [String: Any]
        #expect(
            oauth?["accountUuid"] as? String != provUuid,
            "the fabricated provisional id must never reach Claude Code's config"
        )
        #expect(
            oauth?["accountUuid"] as? String == "a",
            "Claude Code keeps whatever accountUuid it already had until the first refresh"
        )
    }

    @Test("an unlocatable credential item is reported distinctly")
    func unlocatableItemIsReported() async throws {
        let h = try makeHarness(
            live: "r-a", slots: [slot("a", refresh: "r-a"), slot("b", refresh: "r-b")],
            credentialItemRef: { nil }
        )
        defer { try? FileManager.default.removeItem(at: h.dir) }
        h.live.isReadable = false

        await #expect(throws: SwapError.noCredentialItem) { _ = try await h.service.swap(to: "b") }
    }
}

private func mode(of url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
}

// MARK: - Freshen before activate

/// claude-swap freshens a target's token *before* activating it and quarantines a target
/// whose refresh token is dead, rather than handing Claude Code a credential it cannot use
/// ("OAuth session expired and could not be refreshed"). These cover that contract.
@Suite("SwapService freshen-before-activate", .serialized)
struct SwapServiceFreshenTests {

    @Test("a target whose grant is dead is never activated")
    func deadGrantIsNotActivated() async throws {
        let target = slot("b", refresh: "r-b")
        let dead: AccountSlot = {
            var s = target
            s.health = .needsReauth
            return s
        }()
        let h = try makeHarness(
            live: "r-a",
            slots: [slot("a", refresh: "r-a"), target],
            freshen: { _, _ in .deadLineage(dead) }
        )

        await #expect(throws: SwapError.targetNeedsReauth) {
            _ = try await h.service.swap(to: "b")
        }
        // The live credential must be untouched: nothing was written over it.
        #expect(h.runner.writes == 0)
    }

    @Test("a transient freshen failure aborts instead of activating a stale credential")
    func transientFailureAborts() async throws {
        let h = try makeHarness(
            live: "r-a",
            slots: [slot("a", refresh: "r-a"), slot("b", refresh: "r-b")],
            freshen: { _, _ in .transientFailure }
        )

        await #expect(throws: SwapError.freshenFailed) {
            _ = try await h.service.swap(to: "b")
        }
        #expect(h.runner.writes == 0)
    }

    @Test("a freshened target activates with the NEW credential, not the stored one")
    func activatesRefreshedBytes() async throws {
        let target = slot("b", refresh: "r-b")
        let refreshed: AccountSlot = {
            var s = target
            s.credentialJSON = credential(refresh: "r-b-successor")
            return s
        }()
        let h = try makeHarness(
            live: "r-a",
            slots: [slot("a", refresh: "r-a"), target],
            freshen: { _, _ in .refreshed(refreshed) }
        )

        _ = try await h.service.swap(to: "b")

        let written = try #require(String(data: h.live.json, encoding: .utf8))
        #expect(written.contains("r-b-successor"))
    }

    @Test("a target that is not near expiry activates unchanged")
    func skippedFreshenActivatesStoredBytes() async throws {
        let h = try makeHarness(
            live: "r-a",
            slots: [slot("a", refresh: "r-a"), slot("b", refresh: "r-b")],
            freshen: { _, _ in .skipped }
        )

        _ = try await h.service.swap(to: "b")

        let written = try #require(String(data: h.live.json, encoding: .utf8))
        #expect(written.contains("r-b"))
    }

    @Test("the freshener is told which lineage is live, so it never refreshes the live one")
    func freshenReceivesActiveLineage() async throws {
        let seen = LineageProbe()
        let h = try makeHarness(
            live: "r-a",
            slots: [slot("a", refresh: "r-a"), slot("b", refresh: "r-b")],
            freshen: { _, lineage in seen.value = lineage; return .skipped }
        )

        _ = try await h.service.swap(to: "b")

        #expect(seen.value == Lineage.fingerprint(credentialJSON: credential(refresh: "r-a")))
    }
}

private final class LineageProbe: @unchecked Sendable {
    var value: String?
}
