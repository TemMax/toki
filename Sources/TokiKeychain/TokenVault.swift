/// Toki' own cached copy of the Claude Code access token.
import Foundation
import CryptoKit
import TokiModels

/// Persistence backend for the vault payload. Abstracted so tests never touch the
/// real Keychain.
protocol VaultStoring: Sendable {
    func load() throws -> VaultPayload?
    func save(_ payload: VaultPayload) throws
    func clear() throws
}

/// Serializes every read, write and dead-mark of the cached token.
///
/// Reading Toki' own Keychain item never prompts (we created it), so this is the hot
/// path: Claude Code's item is touched only when this vault has nothing live.
actor TokenVault {
    private let store: any VaultStoring
    /// SHA-256 of a token that returned 401. In-memory only: the cost of forgetting it
    /// across launches is one wasted request, whereas a persisted flag can outlive the
    /// token it describes and permanently suppress a healthy credential.
    private var deadTokenDigest: String?
    private var invalidated = false
    private var invalidationGeneration: UInt64 = 0
    /// Persistence is an optimization; a fresh token remains usable if a vault write fails.
    private var memoryPayload: VaultPayload?

    init(store: any VaultStoring) {
        self.store = store
    }

    /// The cached payload when it is present, unexpired and not dead-marked.
    func livePayload(now: Date) -> VaultPayload? {
        // no-log: `store.load()`'s outcome, including the OSStatus on any real failure, is
        // already logged inside `KeychainVaultStore.load()`. This call site has no further
        // context to add (no account/service is available here), so logging again would
        // just duplicate that one Keychain read event.
        guard !invalidated,
              let payload = memoryPayload ?? persistedPayload(), payload.isLive(now: now) else { return nil }
        guard Self.digest(payload.accessToken) != deadTokenDigest else { return nil }
        return payload
    }

    /// Identity (service/account/`mdat`) of the Claude Code item the cached token came
    /// from, for prompt-free change detection.
    func storedSource() -> KeychainItemRef? {
        // no-log: same read path as `livePayload`; outcome already logged in
        // `KeychainVaultStore.load()`.
        guard !invalidated else { return nil }
        return (memoryPayload ?? persistedPayload())?.source
    }

    /// Whether an earlier keychain-backed credential means lower-precedence sources are
    /// no longer safe to use without re-establishing provenance.
    func blocksUnconfirmedFallback() -> Bool {
        invalidated || memoryPayload != nil || persistedPayload() != nil
    }

    func generation() -> UInt64 { invalidationGeneration }

    func accepts(token: String, expiresAt: Date?, now: Date) -> Bool {
        if let expiresAt, now >= expiresAt.addingTimeInterval(-VaultPayload.expiryGuard) {
            return false
        }
        return Self.digest(token) != deadTokenDigest
    }

    @discardableResult
    func capture(
        accessToken: String, expiresAt: Date?, source: KeychainItemRef, now: Date,
        expectedGeneration: UInt64? = nil
    ) -> Bool {
        if let expectedGeneration, expectedGeneration != invalidationGeneration { return false }
        // Recheck in the same actor turn as acceptance: a 401 can arrive between the
        // resolver's earlier check and this call.
        guard accepts(token: accessToken, expiresAt: expiresAt, now: now) else { return false }
        let payload = VaultPayload(
            accessToken: accessToken, expiresAt: expiresAt, source: source, capturedAt: now
        )
        // no-log: the write outcome, including the OSStatus on any real failure, is already
        // logged inside `KeychainVaultStore.save()`.
        memoryPayload = payload
        invalidated = false
        // no-log: KeychainVaultStore.save logs the OSStatus; the memory copy remains usable.
        try? store.save(payload)
        // A newly captured token is alive by definition; drop any stale dead mark.
        if deadTokenDigest != nil, deadTokenDigest != Self.digest(accessToken) {
            deadTokenDigest = nil
        }
        return true
    }

    /// Drops the cached credential entirely. Used after an account swap: the cached token
    /// belongs to the account we just switched away from.
    func clear() {
        // no-log: the clear outcome, including the OSStatus on any real failure, is already
        // logged inside `KeychainVaultStore.clear()`.
        invalidated = true
        invalidationGeneration &+= 1
        memoryPayload = nil
        // no-log: KeychainVaultStore.clear logs its OSStatus; invalidation survives failure.
        try? store.clear()
        deadTokenDigest = nil
    }

    /// Records that `token` was rejected with a 401 — but only if it is still the token
    /// we hold, so a late 401 cannot kill a concurrently captured fresh token.
    func markDead(token: String) {
        // no-log: same read path as `livePayload`; outcome already logged in
        // `KeychainVaultStore.load()`.
        guard !invalidated,
              let current = memoryPayload ?? persistedPayload(), current.accessToken == token else { return }
        deadTokenDigest = Self.digest(token)
    }

    private func persistedPayload() -> VaultPayload? {
        // no-log: KeychainVaultStore.load logs the read outcome and OSStatus.
        try? store.load()
    }

    private static func digest(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
