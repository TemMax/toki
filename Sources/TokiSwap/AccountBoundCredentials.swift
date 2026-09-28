import TokiAccounts
import TokiModels
import TokiLogging

/// Refuses to expose a credential until Anthropic confirms that it belongs to the
/// account currently named by Claude Code's configuration.
public actor AccountBoundCredentials: CredentialProviding {
    private struct Binding: Equatable, Sendable {
        let accountUuid: String
        let organizationUuid: String?

        init(_ identity: AccountIdentity) {
            accountUuid = identity.accountUuid
            organizationUuid = identity.organizationUuid
        }
    }

    private let credentials: any CredentialProviding
    private let oracle: any ProfileLookup
    private let signedInIdentity: @Sendable () -> AccountIdentity?
    private var provenBindings: [String: Binding] = [:]
    private var invalidationGeneration: UInt = 0
    private let log = TokiLog.logger("limits")

    public init(
        credentials: any CredentialProviding,
        oracle: any ProfileLookup,
        signedInIdentity: @escaping @Sendable () -> AccountIdentity?
    ) {
        self.credentials = credentials
        self.oracle = oracle
        self.signedInIdentity = signedInIdentity
    }

    public func currentCredential() async throws -> OAuthCredential {
        try await currentCredential(userInitiated: false, forceRefresh: false)
    }

    public func currentCredential(userInitiated: Bool) async throws -> OAuthCredential {
        try await currentCredential(userInitiated: userInitiated, forceRefresh: false)
    }

    public func currentCredential(
        userInitiated: Bool,
        forceRefresh: Bool
    ) async throws -> OAuthCredential {
        let expected = try currentBinding()
        let generation = invalidationGeneration
        let credential = try await credentials.currentCredential(
            userInitiated: userInitiated,
            forceRefresh: forceRefresh
        )
        guard invalidationGeneration == generation else { throw TokiError.keychainDenied }
        try ensureConfigurationStillMatches(expected)
        try await prove(credential, belongsTo: expected)
        return OAuthCredential(
            accessToken: credential.accessToken,
            refreshToken: credential.refreshToken,
            expiresAt: credential.expiresAt,
            source: credential.source,
            account: UsageAccount(
                accountUuid: expected.accountUuid,
                organizationUuid: expected.organizationUuid
            )
        )
    }

    /// Called after the usage response so a configuration switch that landed while the
    /// request was in flight cannot let the old account's response enter the cache.
    public func validateCredential(_ credential: OAuthCredential) async throws {
        let expected = try currentBinding()
        if let account = credential.account {
            guard account.accountUuid == expected.accountUuid,
                  account.organizationUuid == expected.organizationUuid
            else { throw TokiError.keychainDenied }
        }
        try await prove(credential, belongsTo: expected)
    }

    public func markCredentialRejected(_ credential: OAuthCredential) async {
        provenBindings[credential.accessToken] = nil
        invalidationGeneration &+= 1
        await credentials.markCredentialRejected(credential)
    }

    public func invalidateCache() async {
        provenBindings.removeAll()
        invalidationGeneration &+= 1
        await credentials.invalidateCache()
    }

    private func prove(_ credential: OAuthCredential, belongsTo expected: Binding) async throws {
        if let proven = provenBindings[credential.accessToken] {
            guard proven == expected else {
                log.notice("usage credential refused: cached owner differs from current account or organization")
                throw TokiError.keychainDenied
            }
            return
        }

        let generation = invalidationGeneration
        let owner = try await oracle.owner(ofToken: credential.accessToken)
        guard invalidationGeneration == generation else { throw TokiError.keychainDenied }
        try ensureConfigurationStillMatches(expected)
        guard Binding(owner) == expected else {
            log.notice("usage credential refused: profile owner differs from current account or organization")
            throw TokiError.keychainDenied
        }
        provenBindings[credential.accessToken] = expected
    }

    private func currentBinding() throws -> Binding {
        guard let identity = signedInIdentity() else { throw TokiError.notLoggedIn }
        return Binding(identity)
    }

    private func ensureConfigurationStillMatches(_ expected: Binding) throws {
        guard let identity = signedInIdentity() else { throw TokiError.notLoggedIn }
        guard Binding(identity) == expected else { throw TokiError.keychainDenied }
    }
}
