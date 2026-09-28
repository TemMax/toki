import Foundation
import Testing
import TokiAccounts
import TokiModels
@testable import TokiSwap

private let accountA = AccountIdentity(
    accountUuid: "account-a", email: "a@example.com", displayName: "A",
    organizationName: "Acme", organizationUuid: "org-a"
)
private let accountB = AccountIdentity(
    accountUuid: "account-b", email: "b@example.com", displayName: "B",
    organizationName: "Acme", organizationUuid: "org-a"
)

private final class IdentityBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: AccountIdentity?

    init(_ value: AccountIdentity?) { self.value = value }

    func get() -> AccountIdentity? {
        lock.withLock { value }
    }

    func set(_ value: AccountIdentity?) {
        lock.withLock { self.value = value }
    }
}

private actor CredentialStub: CredentialProviding {
    let credential: OAuthCredential
    private(set) var rejected: [String] = []
    private(set) var invalidations = 0
    private(set) var requests: [(userInitiated: Bool, forceRefresh: Bool)] = []

    init(
        token: String,
        refreshToken: String? = nil,
        expiresAt: Date? = nil,
        source: CredentialSource = .claudeKeychain
    ) {
        credential = OAuthCredential(
            accessToken: token,
            refreshToken: refreshToken,
            expiresAt: expiresAt,
            source: source
        )
    }

    func currentCredential() async throws -> OAuthCredential { credential }

    func currentCredential(
        userInitiated: Bool, forceRefresh: Bool
    ) async throws -> OAuthCredential {
        requests.append((userInitiated, forceRefresh))
        return credential
    }

    func markCredentialRejected(_ credential: OAuthCredential) async {
        rejected.append(credential.accessToken)
    }

    func invalidateCache() async { invalidations += 1 }
}

private actor OracleStub: ProfileLookup {
    private var owners: [String: AccountIdentity]
    private(set) var calls: [String] = []

    init(owners: [String: AccountIdentity]) { self.owners = owners }

    func owner(ofToken token: String) async throws -> AccountIdentity {
        calls.append(token)
        guard let owner = owners[token] else { throw TokiError.credentialsNotFound }
        return owner
    }

    func callCount() -> Int { calls.count }
}

private actor SuspendedOracle: ProfileLookup {
    private let ownerIdentity: AccountIdentity
    private var continuation: CheckedContinuation<Void, Never>?
    private var started = false

    init(owner: AccountIdentity) { ownerIdentity = owner }

    func owner(ofToken token: String) async throws -> AccountIdentity {
        started = true
        await withCheckedContinuation { continuation = $0 }
        return ownerIdentity
    }

    func waitUntilStarted() async {
        while !started { await Task.yield() }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

@Suite("AccountBoundCredentials")
struct AccountBoundCredentialsTests {
    @Test("a verified credential carries its account binding without changing credential metadata")
    func attachesVerifiedIdentityAndPreservesCredentialFields() async throws {
        let expiry = Date(timeIntervalSince1970: 1_900_000_000)
        let credentials = CredentialStub(
            token: "token-a",
            refreshToken: "refresh-a",
            expiresAt: expiry,
            source: .file
        )
        let subject = AccountBoundCredentials(
            credentials: credentials,
            oracle: OracleStub(owners: ["token-a": accountA]),
            signedInIdentity: { accountA }
        )

        let verified = try await subject.currentCredential(
            userInitiated: false, forceRefresh: false
        )

        #expect(verified.accessToken == "token-a")
        #expect(verified.refreshToken == "refresh-a")
        #expect(verified.expiresAt == expiry)
        #expect(verified.source == .file)
        #expect(verified.account == UsageAccount(
            accountUuid: "account-a", organizationUuid: "org-a"
        ))
    }

    @Test("a proof for an old configuration cannot authorize the same token after an account switch")
    func oldTokenCannotAuthorizeNewConfiguration() async throws {
        let identity = IdentityBox(accountA)
        let credentials = CredentialStub(token: "token-a")
        let oracle = OracleStub(owners: ["token-a": accountA])
        let subject = AccountBoundCredentials(
            credentials: credentials, oracle: oracle, signedInIdentity: identity.get
        )

        _ = try await subject.currentCredential(userInitiated: false, forceRefresh: false)
        identity.set(accountB)

        await #expect(throws: TokiError.keychainDenied) {
            try await subject.currentCredential(userInitiated: false, forceRefresh: false)
        }
    }

    @Test("an organization mismatch rejects a token even when the account UUID matches")
    func rejectsOrganizationMismatch() async {
        let configured = accountA
        let owner = AccountIdentity(
            accountUuid: accountA.accountUuid, email: nil, displayName: nil,
            organizationName: "Other", organizationUuid: "org-b"
        )
        let subject = AccountBoundCredentials(
            credentials: CredentialStub(token: "token-a"),
            oracle: OracleStub(owners: ["token-a": owner]),
            signedInIdentity: { configured }
        )

        await #expect(throws: TokiError.keychainDenied) {
            try await subject.currentCredential(userInitiated: false, forceRefresh: false)
        }
    }

    @Test("a configuration change while the profile request is in flight fails closed")
    func rejectsConfigurationChangeDuringLookup() async {
        let identity = IdentityBox(accountA)
        let oracle = SuspendedOracle(owner: accountA)
        let subject = AccountBoundCredentials(
            credentials: CredentialStub(token: "token-a"),
            oracle: oracle,
            signedInIdentity: identity.get
        )

        let request = Task {
            try await subject.currentCredential(userInitiated: false, forceRefresh: false)
        }
        await oracle.waitUntilStarted()
        identity.set(accountB)
        await oracle.resume()

        await #expect(throws: TokiError.keychainDenied) { try await request.value }
    }

    @Test("a successful proof is reused while token and configuration remain unchanged")
    func reusesSuccessfulProof() async throws {
        let oracle = OracleStub(owners: ["token-a": accountA])
        let subject = AccountBoundCredentials(
            credentials: CredentialStub(token: "token-a"),
            oracle: oracle,
            signedInIdentity: { accountA }
        )

        _ = try await subject.currentCredential(userInitiated: false, forceRefresh: false)
        _ = try await subject.currentCredential(userInitiated: false, forceRefresh: false)

        #expect(await oracle.callCount() == 1)
    }

    @Test("a missing signed-in identity fails before any token is returned")
    func rejectsMissingIdentity() async {
        let oracle = OracleStub(owners: ["token-a": accountA])
        let subject = AccountBoundCredentials(
            credentials: CredentialStub(token: "token-a"),
            oracle: oracle,
            signedInIdentity: { nil }
        )

        await #expect(throws: TokiError.notLoggedIn) {
            try await subject.currentCredential(userInitiated: false, forceRefresh: false)
        }
        #expect(await oracle.callCount() == 0)
    }

    @Test("validation rechecks the current configuration after the usage request")
    func validationRejectsAConfigurationChangedAfterCredentialResolution() async throws {
        let identity = IdentityBox(accountA)
        let credential = OAuthCredential(accessToken: "token-a", refreshToken: nil, expiresAt: nil)
        let subject = AccountBoundCredentials(
            credentials: CredentialStub(token: "token-a"),
            oracle: OracleStub(owners: ["token-a": accountA]),
            signedInIdentity: identity.get
        )

        _ = try await subject.currentCredential(userInitiated: false, forceRefresh: false)
        identity.set(accountB)

        await #expect(throws: TokiError.keychainDenied) {
            try await subject.validateCredential(credential)
        }
    }

    @Test("validation rejects a credential carrying another account binding")
    func validationRejectsConflictingCarriedBinding() async {
        let credential = OAuthCredential(
            accessToken: "token-a",
            refreshToken: nil,
            expiresAt: nil,
            account: UsageAccount(accountUuid: "account-b", organizationUuid: "org-a")
        )
        let subject = AccountBoundCredentials(
            credentials: CredentialStub(token: "token-a"),
            oracle: OracleStub(owners: ["token-a": accountA]),
            signedInIdentity: { accountA }
        )

        await #expect(throws: TokiError.keychainDenied) {
            try await subject.validateCredential(credential)
        }
    }

    @Test("rejecting a credential discards its proof and forwards the rejection")
    func rejectionInvalidatesProofAndForwards() async throws {
        let credentials = CredentialStub(token: "token-a")
        let oracle = OracleStub(owners: ["token-a": accountA])
        let subject = AccountBoundCredentials(
            credentials: credentials, oracle: oracle, signedInIdentity: { accountA }
        )
        let credential = try await subject.currentCredential(
            userInitiated: false, forceRefresh: false
        )

        await subject.markCredentialRejected(credential)
        _ = try await subject.currentCredential(userInitiated: false, forceRefresh: false)

        #expect(await oracle.callCount() == 2)
        #expect(await credentials.rejected == ["token-a"])
    }

    @Test("a delayed profile response cannot restore a proof after rejection")
    func rejectionDuringLookupPreventsDelayedProof() async {
        let credentials = CredentialStub(token: "token-a")
        let oracle = SuspendedOracle(owner: accountA)
        let subject = AccountBoundCredentials(
            credentials: credentials, oracle: oracle, signedInIdentity: { accountA }
        )
        let credential = OAuthCredential(accessToken: "token-a", refreshToken: nil, expiresAt: nil)
        let request = Task {
            try await subject.currentCredential(userInitiated: false, forceRefresh: false)
        }
        await oracle.waitUntilStarted()

        await subject.markCredentialRejected(credential)
        await oracle.resume()

        await #expect(throws: TokiError.keychainDenied) { try await request.value }
    }

    @Test("resolution forwards interaction and refresh policy to the underlying provider")
    func forwardsResolutionPolicy() async throws {
        let credentials = CredentialStub(token: "token-a")
        let subject = AccountBoundCredentials(
            credentials: credentials,
            oracle: OracleStub(owners: ["token-a": accountA]),
            signedInIdentity: { accountA }
        )

        _ = try await subject.currentCredential(userInitiated: true, forceRefresh: true)

        let requests = await credentials.requests
        #expect(requests.count == 1)
        #expect(requests.first?.userInitiated == true)
        #expect(requests.first?.forceRefresh == true)
    }

    @Test("invalidating caches forwards and discards all ownership proofs")
    func invalidationForwardsAndDiscardsProofs() async throws {
        let credentials = CredentialStub(token: "token-a")
        let oracle = OracleStub(owners: ["token-a": accountA])
        let subject = AccountBoundCredentials(
            credentials: credentials, oracle: oracle, signedInIdentity: { accountA }
        )
        _ = try await subject.currentCredential(userInitiated: false, forceRefresh: false)

        await subject.invalidateCache()
        _ = try await subject.currentCredential(userInitiated: false, forceRefresh: false)

        #expect(await credentials.invalidations == 1)
        #expect(await oracle.callCount() == 2)
    }
}
