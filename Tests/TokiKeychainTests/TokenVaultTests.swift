import Testing
import Foundation
import TokiModels
@testable import TokiKeychain

private let ref = KeychainItemRef(service: "Claude Code-credentials", account: "u", modifiedAt: 100)
private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

/// In-memory `VaultStoring` used by every unit test (never touches the real Keychain).
final class FakeVaultStore: VaultStoring, @unchecked Sendable {
    var payload: VaultPayload?
    var clearError: Error?
    var saveError: Error?
    private(set) var saveCount = 0
    func load() throws -> VaultPayload? { payload }
    func save(_ p: VaultPayload) throws {
        if let saveError { throw saveError }
        payload = p
        saveCount += 1
    }
    func clear() throws {
        if let clearError { throw clearError }
        payload = nil
    }
}

@Suite("TokenVault")
struct TokenVaultTests {
    @Test("a cache write failure does not make a freshly read token unusable")
    func persistenceIsOptional() async {
        let store = FakeVaultStore()
        store.saveError = TokiError.keychainDenied
        let vault = TokenVault(store: store)
        #expect(await vault.capture(accessToken: "fresh", expiresAt: nil, source: ref, now: t0))
        #expect(await vault.livePayload(now: t0)?.accessToken == "fresh")
        await vault.markDead(token: "fresh")
        #expect(await vault.livePayload(now: t0) == nil)
    }

    @Test("a rejection arriving after preliminary validation still blocks capture")
    func captureRechecksRejectionAtomically() async {
        let vault = TokenVault(store: FakeVaultStore())
        await vault.capture(accessToken: "token", expiresAt: nil, source: ref, now: t0)
        #expect(await vault.accepts(token: "token", expiresAt: nil, now: t0))
        await vault.markDead(token: "token")
        #expect(await vault.capture(accessToken: "token", expiresAt: nil, source: ref, now: t0) == false)
    }

    @Test("captures a token and serves it back as a live payload")
    func captureThenServe() async {
        let store = FakeVaultStore()
        let vault = TokenVault(store: store)
        await vault.capture(
            accessToken: "tok", expiresAt: t0.addingTimeInterval(3600), source: ref, now: t0
        )
        let live = await vault.livePayload(now: t0)
        #expect(live?.accessToken == "tok")
        #expect(await vault.storedSource() == ref)
        #expect(store.saveCount == 1)
    }

    @Test("does not serve an expired payload")
    func expiredPayloadIsWithheld() async {
        let store = FakeVaultStore()
        let vault = TokenVault(store: store)
        await vault.capture(
            accessToken: "tok", expiresAt: t0.addingTimeInterval(60), source: ref, now: t0
        )
        #expect(await vault.livePayload(now: t0.addingTimeInterval(3600)) == nil)
    }

    @Test("a dead-marked token is withheld even while unexpired")
    func deadMarkedTokenIsWithheld() async {
        let store = FakeVaultStore()
        let vault = TokenVault(store: store)
        await vault.capture(
            accessToken: "tok", expiresAt: t0.addingTimeInterval(3600), source: ref, now: t0
        )
        await vault.markDead(token: "tok")
        #expect(await vault.livePayload(now: t0) == nil)
    }

    @Test("capturing a different token clears the dead mark")
    func captureClearsDeadMark() async {
        let store = FakeVaultStore()
        let vault = TokenVault(store: store)
        await vault.capture(accessToken: "old", expiresAt: nil, source: ref, now: t0)
        await vault.markDead(token: "old")
        await vault.capture(accessToken: "new", expiresAt: nil, source: ref, now: t0)
        #expect(await vault.livePayload(now: t0)?.accessToken == "new")
    }

    @Test("dead-marking a token the vault no longer holds is a no-op")
    func staleDeadMarkIsIgnored() async {
        let store = FakeVaultStore()
        let vault = TokenVault(store: store)
        await vault.capture(accessToken: "fresh", expiresAt: nil, source: ref, now: t0)
        // A slow 401 for the previous token arrives after a concurrent capture.
        await vault.markDead(token: "stale")
        #expect(await vault.livePayload(now: t0)?.accessToken == "fresh")
    }

    @Test("an unreadable store still allows freshly acquired in-memory credentials")
    func brokenStoreDegrades() async {
        struct ThrowingStore: VaultStoring {
            func load() throws -> VaultPayload? { throw TokiError.credentialsNotFound }
            func save(_ payload: VaultPayload) throws { throw TokiError.credentialsNotFound }
            func clear() throws {}
        }
        let vault = TokenVault(store: ThrowingStore())
        #expect(await vault.livePayload(now: t0) == nil)
        await vault.capture(accessToken: "tok", expiresAt: nil, source: ref, now: t0)
        #expect(await vault.livePayload(now: t0)?.accessToken == "tok")
    }
}

/// Unique per process run — see the note in SlotStoreTests: re-reading an item written by a
/// previous, differently-signed test binary raises the Keychain dialog.
private let testRunID = UUID().uuidString.prefix(8)
private let vaultIntegrationEnabled =
    ProcessInfo.processInfo.environment["TOKI_RUN_REAL_KEYCHAIN_TESTS"] == "1"

@Suite("KeychainVaultStore", .serialized, .enabled(if: vaultIntegrationEnabled))
struct KeychainVaultStoreTests {

    @Test("round-trips a payload through the real login keychain")
    func realRoundTrip() throws {
        let store = KeychainVaultStore(service: "dev.komar.toki.credentials.test.\(testRunID)")
        // A bare `try? store.clear()` swallows a genuine failure (a transient one on the
        // shared login Keychain, or a real permission problem) exactly the same way — leaving
        // this test's own item behind with nothing surfaced to say so. Retrying, and asserting
        // the retries eventually succeed, turns a silent leak into a visible test failure
        // instead. (`dev.komar.toki.credentials.test.*` residue has been observed on real
        // machines — see `KeychainNamespaceTests.foreignItemsAreSkipped` — which is exactly
        // the kind of leftover a swallowed cleanup failure produces.)
        defer { #expect(clearRetrying(store)) }
        try store.clear()

        let payload = VaultPayload(
            accessToken: "tok-real", expiresAt: t0, source: ref, capturedAt: t0
        )
        try store.save(payload)
        #expect(try store.load() == payload)

        // Overwriting must update in place (preserving our own ACL), not recreate.
        let updated = VaultPayload(accessToken: "tok-2", expiresAt: t0, source: ref, capturedAt: t0)
        try store.save(updated)
        #expect(try store.load()?.accessToken == "tok-2")

        try store.clear()
        #expect(try store.load() == nil)
    }

    /// Retries `store.clear()` until it succeeds, instead of firing once and swallowing
    /// whatever it returns — the same defensiveness `KeychainEnumeratorTests.deleteRetrying`
    /// applies against the same shared, occasionally slow-to-settle login Keychain. Returns
    /// whether it is confirmed cleared.
    private func clearRetrying(_ store: KeychainVaultStore) -> Bool {
        for _ in 0..<20 {
            if (try? store.clear()) != nil { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }
}

@Suite("TokenVault clearing")
struct TokenVaultClearingTests {

    @Test("an in-flight capture cannot cross an invalidation generation")
    func staleGenerationCannotCapture() async {
        let vault = TokenVault(store: FakeVaultStore())
        let generation = await vault.generation()

        await vault.clear()
        let accepted = await vault.capture(
            accessToken: "late", expiresAt: t0.addingTimeInterval(3600),
            source: ref, now: t0, expectedGeneration: generation
        )

        #expect(!accepted)
        #expect(await vault.livePayload(now: t0) == nil)
    }

    @Test("failed persistence deletion still invalidates every in-process read path")
    func failedClearRemainsInvalidatedInMemory() async {
        let store = FakeVaultStore()
        store.payload = VaultPayload(
            accessToken: "previous-account", expiresAt: t0.addingTimeInterval(3600),
            source: ref, capturedAt: t0
        )
        store.clearError = TokiError.credentialsNotFound
        let vault = TokenVault(store: store)

        await vault.clear()

        #expect(await vault.livePayload(now: t0) == nil)
        #expect(await vault.storedSource() == nil)
    }

    @Test("clearing removes the token from every read path")
    func clearEmptiesEveryPath() async {
        // After a swap the cached token belongs to the account we just left.
        let store = FakeVaultStore()
        let vault = TokenVault(store: store)
        await vault.capture(
            accessToken: "previous-account", expiresAt: t0.addingTimeInterval(3600),
            source: ref, now: t0
        )
        #expect(await vault.livePayload(now: t0) != nil)

        await vault.clear()

        #expect(await vault.livePayload(now: t0) == nil)
        #expect(await vault.storedSource() == nil)
    }

    @Test("a cleared vault accepts a fresh capture immediately")
    func clearDoesNotPoisonLaterCaptures() async {
        let vault = TokenVault(store: FakeVaultStore())
        await vault.capture(accessToken: "old", expiresAt: nil, source: ref, now: t0)
        await vault.markDead(token: "old")
        await vault.clear()
        await vault.capture(accessToken: "new", expiresAt: nil, source: ref, now: t0)
        #expect(await vault.livePayload(now: t0)?.accessToken == "new")
    }
}
