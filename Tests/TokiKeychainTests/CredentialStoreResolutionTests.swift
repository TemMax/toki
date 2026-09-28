import Testing
import Foundation
import TokiModels
@testable import TokiKeychain

private let ref = KeychainItemRef(service: "Claude Code-credentials", account: "u", modifiedAt: 100)
private let now = Date(timeIntervalSince1970: 1_700_000_000)

/// Minimal call counter for the "the ladder was not run" assertions.
private final class Counter: @unchecked Sendable {
    private(set) var value = 0
    func bump() { value += 1 }
}

/// Builds a store whose every external dependency is injected.
private func makeStore(
    env: String? = nil,
    file: OAuthCredential? = nil,
    vaultStore: FakeVaultStore = FakeVaultStore(),
    ladderResult: LadderResult = .blocked,
    onLadderRun: (@Sendable (LadderContext, Bool) -> Void)? = nil,
    interactive: OAuthCredential? = nil,
    rawResult: RawCredentialResult = .blocked,
    interactiveRaw: Data? = nil
) -> CredentialStore {
    CredentialStore(
        envProvider: { env },
        fileProvider: { file },
        vault: TokenVault(store: vaultStore),
        ladderRunner: { context, force in
            onLadderRun?(context, force)
            return ladderResult
        },
        ladderSource: { ref },
        interactiveRead: { interactive },
        rawLadderRunner: { _, _ in rawResult },
        interactiveRawRead: { interactiveRaw },
        now: { now }
    )
}

@Suite("CredentialStore resolution")
struct CredentialStoreResolutionTests {

    @Test("an unreadable credential is an access failure, not a missing login")
    func blockedCredentialNeedsAccess() async {
        let store = makeStore(ladderResult: .blocked)
        await #expect(throws: TokiError.keychainDenied) {
            _ = try await store.currentCredential()
        }
        await #expect(throws: TokiError.keychainDenied) {
            _ = try await store.readRawCredential()
        }
    }

    @Test("raw credential access preserves the complete JSON")
    func rawCredentialPreservesJSON() async throws {
        let raw = Data(#"{"claudeAiOauth":{"accessToken":"token","refreshToken":"refresh"},"extra":{"kept":true}}"#.utf8)
        let store = makeStore(rawResult: .harvested(data: raw, from: ref))

        let result = try await store.readRawCredential()
        #expect(result.json == raw)
        #expect(result.ref == ref)
    }

    @Test("raw credential access is noninteractive unless explicitly user initiated")
    func rawCredentialDefaultsToNoninteractive() async throws {
        let raw = Data(#"{"claudeAiOauth":{"accessToken":"token","refreshToken":"refresh"}}"#.utf8)
        let store = makeStore(rawResult: .blocked, interactiveRaw: raw)

        await #expect(throws: TokiError.keychainDenied) {
            _ = try await store.readRawCredential()
        }
        #expect(try await store.readRawCredential(userInitiated: true).json == raw)
    }

    @Test("raw credential access rejects a read when the selected source changes")
    func rawCredentialRejectsChangedSource() async {
        let raw = Data(#"{"claudeAiOauth":{"accessToken":"token","refreshToken":"refresh"}}"#.utf8)
        let changed = KeychainItemRef(
            service: ref.service, account: ref.account, modifiedAt: ref.modifiedAt + 1
        )
        let store = CredentialStore(
            envProvider: { nil }, fileProvider: { nil },
            vault: TokenVault(store: FakeVaultStore()),
            ladderRunner: { _, _ in .blocked }, ladderSource: { changed },
            interactiveRead: { nil },
            rawLadderRunner: { _, _ in .harvested(data: raw, from: ref) },
            interactiveRawRead: { nil }, now: { now }
        )

        await #expect(throws: TokiError.credentialsNotFound) {
            _ = try await store.readRawCredential()
        }
    }

    @Test("environment variable wins and is tagged as such")
    func envWins() async throws {
        let cred = try await makeStore(env: "env-token").currentCredential()
        #expect(cred.accessToken == "env-token")
        #expect(cred.source == .environment)
    }

    @Test("an environment token short-circuits every other source")
    func envConsultsNothingElse() async throws {
        let store = CredentialStore(
            envProvider: { "env-token" },
            fileProvider: {
                Issue.record("File must not be read when the env var is set")
                return nil
            },
            vault: TokenVault(store: FakeVaultStore()),
            ladderRunner: { _, _ in
                Issue.record("The ladder must not run when the env var is set")
                return .blocked
            },
            ladderSource: { ref },
            interactiveRead: {
                Issue.record("The prompting read must not run when the env var is set")
                return nil
            },
            now: { now }
        )
        let cred = try await store.currentCredential()
        #expect(cred.accessToken == "env-token")
        #expect(cred.refreshToken == nil)
        #expect(cred.expiresAt == nil)
        #expect(!cred.isExpired)
    }

    @Test("devSkip reports available without consulting any source")
    func devSkipShortCircuitsAccessState() async {
        let store = CredentialStore(
            envProvider: { nil },
            fileProvider: {
                Issue.record("File must not be read when devSkip is set")
                return nil
            },
            vault: TokenVault(store: FakeVaultStore()),
            ladderRunner: { _, _ in
                Issue.record("The ladder must not run when devSkip is set")
                return .blocked
            },
            ladderSource: { ref },
            interactiveRead: { nil },
            now: { now },
            devSkip: { true }
        )
        #expect(await store.accessState() == .available)
    }

    @Test("the vault beats the credentials file, mirroring Claude Code's own precedence")
    func vaultBeatsFile() async throws {
        // Verified against Claude Code 2.1.223: the Keychain is primary and
        // ~/.claude/.credentials.json is only a fallback. A leftover file holds the
        // PREVIOUS account's still-unexpired token once accounts can be swapped, so
        // preferring it would report the wrong account's usage.
        let vaultStore = FakeVaultStore()
        vaultStore.payload = VaultPayload(
            accessToken: "vault-token", expiresAt: now.addingTimeInterval(3600),
            source: ref, capturedAt: now
        )
        let file = OAuthCredential(
            accessToken: "file-token", refreshToken: nil,
            expiresAt: now.addingTimeInterval(3600), source: .file
        )
        let cred = try await makeStore(file: file, vaultStore: vaultStore).currentCredential()
        #expect(cred.accessToken == "vault-token")
        #expect(cred.source == .vault)
    }

    @Test("the credentials file is still used when no keychain-derived token exists")
    func fileIsTheFallback() async throws {
        let file = OAuthCredential(
            accessToken: "file-token", refreshToken: nil,
            expiresAt: now.addingTimeInterval(3600), source: .file
        )
        let cred = try await makeStore(file: file, ladderResult: .notFound).currentCredential()
        #expect(cred.accessToken == "file-token")
        #expect(cred.source == .file)
    }

    @Test("a vault token is abandoned once Claude Code rewrites its item")
    func vaultIsAbandonedWhenSourceChanges() async throws {
        // Signing into a different account rewrites Claude Code's item, which bumps its
        // modification date. The cached token stays valid for ~8 h, so without this check
        // the gauges would keep reporting the PREVIOUS account's usage for hours — the
        // bug this test exists to prevent.
        let vaultStore = FakeVaultStore()
        vaultStore.payload = VaultPayload(
            accessToken: "previous-account", expiresAt: now.addingTimeInterval(3600),
            source: ref, capturedAt: now
        )
        let rewritten = KeychainItemRef(
            service: ref.service, account: ref.account, modifiedAt: ref.modifiedAt + 1
        )
        let store = CredentialStore(
            envProvider: { nil },
            fileProvider: { nil },
            vault: TokenVault(store: vaultStore),
            ladderRunner: { _, _ in
                .harvested(token: "new-account", expiresAt: now.addingTimeInterval(3600), from: rewritten)
            },
            ladderSource: { rewritten },
            interactiveRead: { nil },
            now: { now }
        )

        let cred = try await store.currentCredential()
        #expect(cred.accessToken == "new-account")
        #expect(vaultStore.payload?.accessToken == "new-account")
    }

    @Test("a blocked ladder after a source change cannot fall back to a file credential")
    func changedSourceBlocksFileFallback() async {
        let vaultStore = FakeVaultStore()
        vaultStore.payload = VaultPayload(
            accessToken: "previous-account", expiresAt: now.addingTimeInterval(3600),
            source: ref, capturedAt: now
        )
        let rewritten = KeychainItemRef(
            service: ref.service, account: ref.account, modifiedAt: ref.modifiedAt + 1
        )
        let file = OAuthCredential(
            accessToken: "unconfirmed-file", refreshToken: "refresh",
            expiresAt: now.addingTimeInterval(3600), source: .file
        )
        let store = CredentialStore(
            envProvider: { nil }, fileProvider: { file }, vault: TokenVault(store: vaultStore),
            ladderRunner: { _, _ in .blocked }, ladderSource: { rewritten },
            interactiveRead: { nil }, now: { now }
        )

        await #expect(throws: TokiError.keychainDenied) {
            _ = try await store.currentCredential()
        }
    }

    @Test("accessState also stops trusting a vault token whose source changed")
    func accessStateAbandonsChangedSource() async {
        let vaultStore = FakeVaultStore()
        vaultStore.payload = VaultPayload(
            accessToken: "previous-account", expiresAt: now.addingTimeInterval(3600),
            source: ref, capturedAt: now
        )
        let rewritten = KeychainItemRef(
            service: ref.service, account: ref.account, modifiedAt: ref.modifiedAt + 1
        )
        let store = CredentialStore(
            envProvider: { nil },
            fileProvider: { nil },
            vault: TokenVault(store: vaultStore),
            ladderRunner: { _, _ in .notFound },
            ladderSource: { rewritten },
            interactiveRead: { nil },
            now: { now }
        )
        // The cached token must not keep reporting "available" for an account that is no
        // longer signed in.
        #expect(await store.accessState() == .notFound)
    }

    @Test("accessState does not trust a file after a keychain source change")
    func accessStateBlocksUnconfirmedFileFallback() async {
        let vaultStore = FakeVaultStore()
        vaultStore.payload = VaultPayload(
            accessToken: "previous-account", expiresAt: now.addingTimeInterval(3600),
            source: ref, capturedAt: now
        )
        let rewritten = KeychainItemRef(
            service: ref.service, account: ref.account, modifiedAt: ref.modifiedAt + 1
        )
        let file = OAuthCredential(
            accessToken: "unconfirmed", refreshToken: nil,
            expiresAt: now.addingTimeInterval(3600), source: .file
        )
        let store = CredentialStore(
            envProvider: { nil }, fileProvider: { file }, vault: TokenVault(store: vaultStore),
            ladderRunner: { _, _ in .notFound }, ladderSource: { rewritten },
            interactiveRead: { nil }, now: { now }
        )

        #expect(await store.accessState() == .notFound)
    }

    @Test("an unlocatable source fails closed instead of serving the cached token")
    func missingSourceRejectsCachedToken() async {
        let vaultStore = FakeVaultStore()
        vaultStore.payload = VaultPayload(
            accessToken: "cached", expiresAt: now.addingTimeInterval(3600),
            source: ref, capturedAt: now
        )
        let store = CredentialStore(
            envProvider: { nil },
            fileProvider: { nil },
            vault: TokenVault(store: vaultStore),
            ladderRunner: { _, _ in .blocked },
            ladderSource: { nil },
            interactiveRead: { nil },
            now: { now }
        )
        await #expect(throws: TokiError.credentialsNotFound) {
            _ = try await store.currentCredential()
        }
    }

    @Test("a live vault token is served without running the ladder")
    func liveVaultSkipsLadder() async throws {
        let vaultStore = FakeVaultStore()
        vaultStore.payload = VaultPayload(
            accessToken: "vault-token", expiresAt: now.addingTimeInterval(3600),
            source: ref, capturedAt: now
        )
        let calls = Counter()
        let store = makeStore(vaultStore: vaultStore, onLadderRun: { _, _ in calls.bump() })
        _ = try await store.currentCredential()
        #expect(calls.value == 0)
    }

    @Test("cache invalidation clears the vault and forces a new ladder read")
    func invalidationForcesNewRead() async throws {
        let vaultStore = FakeVaultStore()
        vaultStore.payload = VaultPayload(
            accessToken: "cached", expiresAt: now.addingTimeInterval(3600),
            source: ref, capturedAt: now
        )
        let calls = Counter()
        let store = makeStore(
            vaultStore: vaultStore,
            ladderResult: .harvested(token: "fresh", expiresAt: nil, from: ref),
            onLadderRun: { _, _ in calls.bump() }
        )

        await store.invalidateCache()
        let credential = try await store.currentCredential()

        #expect(credential.accessToken == "fresh")
        #expect(calls.value == 1)
    }

    @Test("a harvested token is captured into the vault for later polls")
    func harvestPopulatesVault() async throws {
        let vaultStore = FakeVaultStore()
        let store = makeStore(
            vaultStore: vaultStore,
            ladderResult: .harvested(
                token: "fresh", expiresAt: now.addingTimeInterval(3600), from: ref
            )
        )
        let cred = try await store.currentCredential()
        #expect(cred.accessToken == "fresh")
        #expect(cred.source == .claudeKeychain)
        #expect(vaultStore.payload?.accessToken == "fresh")
        #expect(vaultStore.payload?.source == ref)
    }

    @Test("an expired ladder harvest is rejected")
    func expiredHarvestIsRejected() async {
        let store = makeStore(
            ladderResult: .harvested(
                token: "expired", expiresAt: now.addingTimeInterval(-1), from: ref
            )
        )
        await #expect(throws: TokiError.credentialsNotFound) {
            _ = try await store.currentCredential()
        }
    }

    @Test("a ladder result is rejected when its source changed during the read")
    func harvestedSourceChangeIsRejected() async {
        let changed = KeychainItemRef(
            service: ref.service, account: ref.account, modifiedAt: ref.modifiedAt + 1
        )
        let store = CredentialStore(
            envProvider: { nil }, fileProvider: { nil }, vault: TokenVault(store: FakeVaultStore()),
            ladderRunner: { _, _ in
                .harvested(token: "wrong-account", expiresAt: now.addingTimeInterval(3600), from: ref)
            },
            ladderSource: { changed }, interactiveRead: { nil }, now: { now }
        )
        await #expect(throws: TokiError.credentialsNotFound) {
            _ = try await store.currentCredential()
        }
    }

    @Test("an expired vault token is rejected instead of being served as a fallback")
    func expiredVaultIsRejected() async {
        let vaultStore = FakeVaultStore()
        vaultStore.payload = VaultPayload(
            accessToken: "old", expiresAt: now.addingTimeInterval(-10), source: ref, capturedAt: now
        )
        await #expect(throws: TokiError.keychainDenied) {
            _ = try await makeStore(vaultStore: vaultStore).currentCredential()
        }
    }

    @Test("background resolution never performs the interactive read")
    func backgroundNeverPrompts() async {
        let interactive = OAuthCredential(
            accessToken: "prompted", refreshToken: nil, expiresAt: nil, source: .claudeKeychain
        )
        let store = makeStore(ladderResult: .blocked, interactive: interactive)
        await #expect(throws: TokiError.keychainDenied) {
            _ = try await store.currentCredential()
        }
    }

    @Test("a user-initiated resolution may perform the interactive read and caches it")
    func userInitiatedMayPrompt() async throws {
        let vaultStore = FakeVaultStore()
        let interactive = OAuthCredential(
            accessToken: "prompted", refreshToken: nil,
            expiresAt: now.addingTimeInterval(3600), source: .claudeKeychain
        )
        let store = makeStore(
            vaultStore: vaultStore, ladderResult: .blocked, interactive: interactive
        )
        let cred = try await store.currentCredential(userInitiated: true)
        #expect(cred.accessToken == "prompted")
        #expect(vaultStore.payload?.accessToken == "prompted")
    }

    @Test("an interactive result is rejected when the source changes during the read")
    func interactiveSourceChangeIsRejected() async {
        let source = SequencedSource([
            ref,
            KeychainItemRef(service: ref.service, account: ref.account, modifiedAt: ref.modifiedAt + 1),
        ])
        let interactive = OAuthCredential(
            accessToken: "wrong-account", refreshToken: nil,
            expiresAt: now.addingTimeInterval(3600), source: .claudeKeychain
        )
        let store = CredentialStore(
            envProvider: { nil }, fileProvider: { nil }, vault: TokenVault(store: FakeVaultStore()),
            ladderRunner: { _, _ in .blocked }, ladderSource: { source.next() },
            interactiveRead: { interactive }, now: { now }
        )
        await #expect(throws: TokiError.credentialsNotFound) {
            _ = try await store.currentCredential(userInitiated: true)
        }
    }

    @Test("interaction permission does not implicitly force the ladder past its memo")
    func userInitiatedDoesNotForceLadder() async throws {
        let seen = ForceRecorder()
        let store = makeStore(
            ladderResult: .harvested(token: "fresh", expiresAt: nil, from: ref),
            onLadderRun: { context, force in seen.record(context: context, force: force) }
        )
        _ = try await store.currentCredential(userInitiated: true)
        #expect(seen.lastForce == false)
        #expect(seen.lastWasUserInitiated == true)
    }

    @Test("force refresh is independent of interaction permission")
    func forceRefreshIsIndependent() async throws {
        let seen = ForceRecorder()
        let vaultStore = FakeVaultStore()
        vaultStore.payload = VaultPayload(
            accessToken: "cached", expiresAt: now.addingTimeInterval(3600),
            source: ref, capturedAt: now
        )
        let store = makeStore(
            vaultStore: vaultStore,
            ladderResult: .harvested(token: "fresh", expiresAt: nil, from: ref),
            onLadderRun: { context, force in seen.record(context: context, force: force) }
        )
        let credential = try await store.currentCredential(
            userInitiated: false, forceRefresh: true
        )
        #expect(credential.accessToken == "fresh")
        #expect(seen.lastForce == true)
        #expect(seen.lastWasUserInitiated == false)
    }

    @Test("a background resolution lets the ladder answer from its memo")
    func backgroundDoesNotForceLadder() async throws {
        let seen = ForceRecorder()
        let store = makeStore(
            ladderResult: .harvested(token: "fresh", expiresAt: nil, from: ref),
            onLadderRun: { context, force in seen.record(context: context, force: force) }
        )
        _ = try await store.currentCredential()
        #expect(seen.lastForce == false)
        #expect(seen.lastWasUserInitiated == false)
    }

    @Test("accessState reports available when a live vault token exists")
    func accessStateSeesVault() async {
        let vaultStore = FakeVaultStore()
        vaultStore.payload = VaultPayload(
            accessToken: "vault-token", expiresAt: now.addingTimeInterval(3600),
            source: ref, capturedAt: now
        )
        #expect(await makeStore(vaultStore: vaultStore).accessState() == .available)
    }

    @Test("accessState bootstraps the vault from a silent harvest")
    func accessStateBootstrapsVault() async {
        let vaultStore = FakeVaultStore()
        let store = makeStore(
            vaultStore: vaultStore,
            ladderResult: .harvested(
                token: "bootstrapped", expiresAt: now.addingTimeInterval(3600), from: ref
            )
        )
        #expect(await store.accessState() == .available)
        #expect(vaultStore.payload?.accessToken == "bootstrapped")
    }

    @Test("accessState surfaces the unsupported Claude Code layout")
    func accessStateSurfacesUnsupportedLayout() async {
        #expect(await makeStore(ladderResult: .unsupportedLayout).accessState() == .unsupportedLayout)
    }

    @Test("accessState reports needsAuthorization when the ladder is blocked")
    func accessStateBlockedNeedsAuthorization() async {
        #expect(await makeStore(ladderResult: .blocked).accessState() == .needsAuthorization)
    }

    @Test("accessState never runs the ladder in a user-initiated context")
    func accessStateStaysSilent() async {
        let seen = ForceRecorder()
        let store = makeStore(
            ladderResult: .blocked,
            onLadderRun: { context, force in seen.record(context: context, force: force) }
        )
        _ = await store.accessState()
        #expect(seen.lastWasUserInitiated == false)
        #expect(seen.lastForce == false)
    }

    @Test("rejecting an environment token leaves the vault untouched")
    func rejectionIsSourceAware() async throws {
        let vaultStore = FakeVaultStore()
        vaultStore.payload = VaultPayload(
            accessToken: "vault-token", expiresAt: now.addingTimeInterval(3600),
            source: ref, capturedAt: now
        )
        let store = makeStore(vaultStore: vaultStore)
        await store.markCredentialRejected(
            OAuthCredential(
                accessToken: "vault-token", refreshToken: nil, expiresAt: nil, source: .environment
            )
        )
        #expect(try await store.currentCredential().accessToken == "vault-token")
    }

    @Test("rejecting the vault token withholds it from the next resolution")
    func rejectionWithholdsVaultToken() async throws {
        let vaultStore = FakeVaultStore()
        vaultStore.payload = VaultPayload(
            accessToken: "vault-token", expiresAt: now.addingTimeInterval(3600),
            source: ref, capturedAt: now
        )
        let store = makeStore(
            vaultStore: vaultStore,
            ladderResult: .harvested(
                token: "rotated", expiresAt: now.addingTimeInterval(3600), from: ref
            )
        )
        await store.markCredentialRejected(
            OAuthCredential(
                accessToken: "vault-token", refreshToken: nil, expiresAt: nil, source: .vault
            )
        )
        #expect(try await store.currentCredential().accessToken == "rotated")
    }

    @Test("a rejected vault token is never returned when rereading is blocked")
    func rejectionHasNoDeadTokenFallback() async {
        let vaultStore = FakeVaultStore()
        vaultStore.payload = VaultPayload(
            accessToken: "dead", expiresAt: now.addingTimeInterval(3600),
            source: ref, capturedAt: now
        )
        let store = makeStore(
            vaultStore: vaultStore,
            ladderResult: .harvested(
                token: "dead", expiresAt: now.addingTimeInterval(3600), from: ref
            )
        )
        await store.markCredentialRejected(
            OAuthCredential(
                accessToken: "dead", refreshToken: nil, expiresAt: nil, source: .vault
            )
        )

        await #expect(throws: TokiError.credentialsNotFound) {
            _ = try await store.currentCredential()
        }
    }
}

private final class SequencedSource: @unchecked Sendable {
    private let lock = NSLock()
    private var sources: [KeychainItemRef?]

    init(_ sources: [KeychainItemRef?]) { self.sources = sources }

    func next() -> KeychainItemRef? {
        lock.withLock {
            if sources.count > 1 { return sources.removeFirst() }
            return sources.first ?? nil
        }
    }
}

/// Records how the ladder was invoked, so tests can assert the context/force flags.
private final class ForceRecorder: @unchecked Sendable {
    private(set) var lastForce: Bool?
    private(set) var lastWasUserInitiated: Bool?

    func record(context: LadderContext, force: Bool) {
        lastForce = force
        lastWasUserInitiated = {
            if case .userInitiated = context { return true }
            return false
        }()
    }
}
