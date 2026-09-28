/// Keychain persistence for account slots and quarantined credentials.
import Foundation
import Security
import LocalAuthentication
import TokiKeychain
import TokiLogging

private let log = TokiLog.logger("accounts")

public protocol SlotStoring: Sendable {
    func loadAll() throws -> [AccountSlot]
    /// One slot by uuid — an exact Keychain read, without `loadAll`'s repair enumeration.
    /// Callers that already know which account they want must use this: re-reading every
    /// slot to find one turns a per-account loop into O(N) whole-keychain scans.
    func load(accountUuid: String) throws -> AccountSlot?
    func save(_ slot: AccountSlot) throws
    func delete(accountUuid: String) throws
    func loadQuarantine() throws -> [QuarantineEntry]
    func saveQuarantine(_ entry: QuarantineEntry, now: Date) throws
    func deleteQuarantine(id: String) throws
}

public enum SlotStoreError: Error, Equatable {
    case keychainFailure(OSStatus)
    /// Quarantine is at `KeychainSlotStore.quarantineCap`. Per design decision D3 the cap
    /// refuses new entries rather than evicting an old one — quarantined bytes may be the
    /// only surviving copy of an account's refresh token.
    case quarantineFull(cap: Int)
}

/// Seam over the four Security-framework calls this store makes, so tests can inject a
/// genuine Keychain failure (as opposed to `errSecItemNotFound`) without needing to coerce
/// the real Keychain into an error state.
protocol KeychainPrimitives: Sendable {
    func copyMatching(_ query: [CFString: Any]) -> (status: OSStatus, result: CFTypeRef?)
    func update(_ query: [CFString: Any], attributes: [CFString: Any]) -> OSStatus
    func add(_ attributes: [CFString: Any]) -> OSStatus
    func delete(_ query: [CFString: Any]) -> OSStatus
}

struct RealKeychainPrimitives: KeychainPrimitives {
    func copyMatching(_ query: [CFString: Any]) -> (status: OSStatus, result: CFTypeRef?) {
        KeychainInteractionGuard.performNoninteractive {
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            return (status, result)
        } ?? (errSecInteractionNotAllowed, nil)
    }

    func update(_ query: [CFString: Any], attributes: [CFString: Any]) -> OSStatus {
        KeychainInteractionGuard.performNoninteractive {
            SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        } ?? errSecInteractionNotAllowed
    }

    func add(_ attributes: [CFString: Any]) -> OSStatus {
        KeychainInteractionGuard.performNoninteractive {
            SecItemAdd(attributes as CFDictionary, nil)
        } ?? errSecInteractionNotAllowed
    }

    func delete(_ query: [CFString: Any]) -> OSStatus {
        KeychainInteractionGuard.performNoninteractive {
            SecItemDelete(query as CFDictionary)
        } ?? errSecInteractionNotAllowed
    }
}

/// One Keychain item per slot, service `<prefix><accountUuid>`. There is deliberately
/// an index of account uuids, because broad enumeration alone is not trustworthy:
/// measured on this machine, a `kSecMatchLimitAll` enumeration missed a just-written
/// item in 30 of 60 rounds while a `security` subprocess was concurrently mutating the
/// Keychain, and returned an empty list outright in some of them — whereas an exact
/// service+account query missed 0 of 60. Toki spawns `security` itself (credential
/// reads, and a swap's credential write), so relying on enumeration would make the whole
/// account list vanish at exactly the moment a swap happens. The index is read and each
/// slot fetched by exact query; enumeration is demoted to repair duty, adopting any slot
/// the index does not know about, so a lost index still heals itself.
public struct KeychainSlotStore: SlotStoring {
    public static let quarantineCap = 3
    public static let quarantineTTL: TimeInterval = 30 * 24 * 3600

    private let servicePrefix: String
    private let quarantinePrefix: String
    private let indexService: String
    private let account: String
    private let primitives: KeychainPrimitives

    /// Debug builds keep their slot, index and quarantine items in a separate namespace:
    /// a differently signed Debug binary must not contend for the release items' ACLs, or
    /// reading an item the other build created prompts for the Keychain password — the same
    /// reason `KeychainVaultStore` splits its item. The Debug names are prefixed with
    /// `debug.` (rather than suffixed) so that neither build's `servicePrefix` is a prefix
    /// of the other's — the repair enumeration in `loadAll` matches by prefix and would
    /// otherwise adopt the other build's slots.
    public static let defaultServicePrefix = servicePrefix(build: "account.")
    public static let defaultQuarantinePrefix = servicePrefix(build: "quarantine.")
    public static let defaultIndexService = servicePrefix(build: "accounts.index")

    private static func servicePrefix(build tail: String) -> String {
        #if DEBUG
        return KeychainNamespace.prefix + "debug." + tail
        #else
        return KeychainNamespace.prefix + tail
        #endif
    }

    public init(
        servicePrefix: String = KeychainSlotStore.defaultServicePrefix,
        quarantinePrefix: String = KeychainSlotStore.defaultQuarantinePrefix,
        indexService: String = KeychainSlotStore.defaultIndexService,
        account: String = NSUserName()
    ) {
        self.init(
            servicePrefix: servicePrefix, quarantinePrefix: quarantinePrefix,
            indexService: indexService, account: account, primitives: RealKeychainPrimitives()
        )
    }

    /// Test-only seam (see `KeychainPrimitives`); not part of the public API.
    init(
        servicePrefix: String, quarantinePrefix: String, indexService: String,
        account: String, primitives: KeychainPrimitives
    ) {
        self.servicePrefix = servicePrefix
        self.quarantinePrefix = quarantinePrefix
        self.indexService = indexService
        self.account = account
        self.primitives = primitives
    }

    // MARK: Slots

    public func loadAll() throws -> [AccountSlot] {
        var uuids = indexedUUIDs()

        // Repair duty only: anything enumeration finds that the index missed is adopted,
        // so a slot written by an older build (or an index lost to a failed write) still
        // shows up. A truncated enumeration can only ever under-report here, never remove
        // an indexed slot.
        //
        // Rate-limited because it is not cheap: the scan walks every generic-password item
        // in the login keychain (535 on the machine this was measured on) and `loadAll` sits
        // on the account list's refresh path. An empty index always scans — that is the case
        // repair exists for — and otherwise it runs at most once a minute, so a slot the
        // index never learned about still surfaces promptly without a whole-keychain scan
        // behind every refresh.
        if uuids.isEmpty || RepairClock.shared.shouldScan(now: Date()) {
            let discovered = KeychainEnumerator.items(servicePrefix: servicePrefix)
                .map { String($0.service.dropFirst(servicePrefix.count)) }
            let unindexed = discovered.filter { !uuids.contains($0) }
            uuids.formUnion(unindexed)
            if !unindexed.isEmpty {
                do {
                    try writeIndex(uuids)
                } catch {
                    // Best-effort: `uuids` already carries the repaired set for this call's
                    // return value, so a failed write only means the NEXT `loadAll` has to
                    // repair again rather than reading the healed index.
                    log.error("loadAll: failed to persist the repaired index after discovering \(unindexed.count) unindexed slot(s): \(error: error)")
                }
            }
        }

        // `try`, not `try?`: `read` already tells a missing item (silent, `nil`) apart from
        // a genuine Keychain failure (thrown). Swallowing that distinction here would drop
        // an account whose read merely glitched and route its live credential to quarantine.
        return try uuids
            .compactMap { try read(AccountSlot.self, service: servicePrefix + $0) }
            .sorted { $0.addedAt < $1.addedAt }
    }

    public func load(accountUuid: String) throws -> AccountSlot? {
        try read(AccountSlot.self, service: servicePrefix + accountUuid)
    }

    public func save(_ slot: AccountSlot) throws {
        // Index first, then the slot: if the index write fails, the save must fail before
        // the slot is written, or the slot becomes an item `loadAll` can never find again
        // without a lucky enumeration repair.
        var uuids = indexedUUIDs()
        if uuids.insert(slot.identity.accountUuid).inserted {
            try writeIndex(uuids)
        }
        try write(slot, service: servicePrefix + slot.identity.accountUuid)
    }

    public func delete(accountUuid: String) throws {
        try remove(service: servicePrefix + accountUuid)
        var uuids = indexedUUIDs()
        if uuids.remove(accountUuid) != nil {
            try writeIndex(uuids)
        }
    }

    /// The uuids the index knows about. A missing or unreadable index is an empty set,
    /// not an error: `loadAll` rebuilds it from enumeration.
    private func indexedUUIDs() -> Set<String> {
        do {
            return Set(try read([String].self, service: indexService) ?? [])
        } catch {
            // A missing item returns nil from `read` without throwing (see below); reaching
            // this catch means a genuine Keychain failure, tolerated the same way — the
            // caller rebuilds from enumeration — but worth a diagnostic trail of its own.
            log.error("indexedUUIDs: index unreadable, treating as empty (repair enumeration will rebuild it): \(error: error)")
            return []
        }
    }

    private func writeIndex(_ uuids: Set<String>) throws {
        try write(uuids.sorted(), service: indexService)
    }

    // MARK: Quarantine

    public func loadQuarantine() throws -> [QuarantineEntry] {
        KeychainEnumerator.items(servicePrefix: quarantinePrefix)
            .compactMap { item -> QuarantineEntry? in
                do {
                    return try read(QuarantineEntry.self, service: item.service)
                } catch {
                    // A quarantined credential may be the only surviving copy of an
                    // account's refresh token (D3); silently dropping one that fails to
                    // read would be exactly the loss this store exists to prevent.
                    log.error("loadQuarantine: failed to read a quarantined entry, skipping it: \(error: error)")
                    return nil
                }
            }
            .sorted { $0.foundAt < $1.foundAt }
    }

    /// Per D3, the cap never evicts — a quarantined credential may be the only surviving
    /// copy of an account's refresh token. The TTL sweep (below) is the only thing that
    /// removes an entry; a write that would push the count past the cap is refused instead.
    public func saveQuarantine(_ entry: QuarantineEntry, now: Date) throws {
        var kept = try loadQuarantine()
        for stale in kept where now.timeIntervalSince(stale.foundAt) > Self.quarantineTTL {
            do {
                try deleteQuarantine(id: stale.id)
            } catch {
                // Best-effort sweep: a failed delete just means this entry survives to be
                // retried on the next save, not that the save below should be blocked on it.
                log.error("saveQuarantine: failed to sweep a TTL-expired quarantine entry: \(error: error)")
            }
        }
        kept = try loadQuarantine()

        // Re-quarantining the same credential (same id) is an update, not growth, and must
        // not be blocked by a cap that's already counting it.
        let isUpdate = kept.contains { $0.id == entry.id }
        guard isUpdate || kept.count < Self.quarantineCap else {
            throw SlotStoreError.quarantineFull(cap: Self.quarantineCap)
        }
        try write(entry, service: quarantinePrefix + entry.id)
    }

    public func deleteQuarantine(id: String) throws {
        try remove(service: quarantinePrefix + id)
    }

    // MARK: Keychain primitives

    /// Barred from raising a consent dialog: this store sits on background poll
    /// loops, and its items' ACLs name Toki, so a dialog can only mean a foreign
    /// ACL or a locked keychain — cases where failing is correct and prompting
    /// from nowhere is not.
    private var noInteraction: LAContext {
        let context = LAContext()
        context.interactionNotAllowed = true
        return context
    }

    private func baseQuery(_ service: String) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
            kSecUseAuthenticationContext: noInteraction,
        ]
    }

    private func read<T: Decodable>(_ type: T.Type, service: String) throws -> T? {
        var query = baseQuery(service)
        query[kSecMatchLimit] = kSecMatchLimitOne
        query[kSecReturnData] = true

        let (status, result) = primitives.copyMatching(query)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return nil }
            do {
                return try decoder.decode(T.self, from: data)
            } catch {
                // Corrupt payload → treat as absent, same as `errSecItemNotFound` below; the
                // type name alone (never the service, which embeds the account uuid) is safe
                // to log and is the only thing worth knowing here.
                log.error("read: stored \(String(describing: T.self), privacy: .public) payload failed to decode, treating as absent: \(error: error)")
                return nil
            }
        case errSecItemNotFound:
            return nil
        default:
            throw SlotStoreError.keychainFailure(status)
        }
    }

    /// Update in place when the item exists — recreating it would reset the ACL Toki
    /// relies on for silent reads, the same mistake that makes Claude Code's item
    /// re-prompt after every token refresh.
    private func write<T: Encodable>(_ value: T, service: String) throws {
        let data = try encoder.encode(value)
        let update = primitives.update(baseQuery(service), attributes: [kSecValueData: data])
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw SlotStoreError.keychainFailure(update) }

        var add = baseQuery(service)
        add[kSecValueData] = data
        add[kSecAttrSynchronizable] = false
        add[kSecAttrLabel] = "Toki — stored Claude account"
        let status = primitives.add(add)
        guard status == errSecSuccess else { throw SlotStoreError.keychainFailure(status) }
    }

    private func remove(service: String) throws {
        let status = primitives.delete(baseQuery(service))
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SlotStoreError.keychainFailure(status)
        }
    }

    private var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }

    private var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }
}


/// Process-wide gate for `loadAll`'s repair enumeration. A value type cannot hold the last
/// scan time, and the cost being avoided is process-wide anyway.
final class RepairClock: @unchecked Sendable {
    static let shared = RepairClock()
    static let interval: TimeInterval = 60

    private let lock = NSLock()
    private var lastScan: Date?

    /// True at most once per `interval`; claims the slot so concurrent callers do not all
    /// scan at once.
    func shouldScan(now: Date) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let lastScan, now.timeIntervalSince(lastScan) < Self.interval { return false }
        lastScan = now
        return true
    }

    /// Test hook: forget the last scan so the next call scans.
    func reset() {
        lock.lock()
        lastScan = nil
        lock.unlock()
    }
}
