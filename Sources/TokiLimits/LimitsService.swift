/// LimitsService — polls the Anthropic OAuth usage endpoint for live rate-limit data.
import Foundation
import TokiLogging
import TokiModels

// MARK: - LimitsService

/// Fetches the live rate-limit snapshot from `GET https://api.anthropic.com/api/oauth/usage`.
///
/// `UsageRefreshController` owns the 90-second minimum and 429 backoff. Failures are propagated; callers
/// must not substitute historical percentages for a current response.
public actor LimitsService: LimitsProviding {
    private let credentials: any CredentialProviding
    private let client: OAuthUsageClient
    private let cache: LimitsCache
    private let refreshController: UsageRefreshController
    private let log = TokiLog.logger("limits")
    private var accountGeneration: UInt64 = 0

    /// Saved-reset metadata costs a second request against the same rate limit as the
    /// usage itself and rarely changes, so it is asked for on this slower cadence. Between
    /// requests — and after the reset request alone is rate limited — the account's last
    /// known resets ride along with every fresh usage response.
    public static let defaultResetsRefreshInterval: TimeInterval = 600
    private let resetsRefreshInterval: TimeInterval
    private let now: @Sendable () -> Date
    private var resetsNextRequestAt: [UsageRefreshKey: Date] = [:]
    private var lastResets: [UsageRefreshKey: ClaudeResetStatus] = [:]

    public init(
        credentials: any CredentialProviding,
        userAgent: String = OAuthUsageClient.defaultUserAgent,
        session: URLSession = .shared,
        cache: LimitsCache = LimitsCache(),
        refreshController: UsageRefreshController,
        resetsRefreshInterval: TimeInterval = LimitsService.defaultResetsRefreshInterval,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.credentials = credentials
        self.client = OAuthUsageClient(userAgent: userAgent, session: session)
        self.cache = cache
        self.refreshController = refreshController
        self.resetsRefreshInterval = resetsRefreshInterval
        self.now = now
    }

    /// Returns the last cached `UsageLimits` from disk, or nil if no cache exists.
    public func cachedLimits() -> UsageLimits? {
        cache.load()
    }

    // MARK: LimitsProviding

    /// Force a credential re-check after source changes without permitting authentication
    /// UI. Ordinary menu refreshes use fetchLimits() and retain a validated live token.
    public func refreshLimitsFreshCredential() async throws -> UsageLimits {
        try await fetchLimits(forceCredentialRefresh: true)
    }

    public func fetchLimits() async throws -> UsageLimits {
        try await fetchLimits(forceCredentialRefresh: false)
    }

    public func accountDidChange() async {
        accountGeneration &+= 1
        cache.remove()
        await credentials.invalidateCache()
    }

    private func fetchLimits(forceCredentialRefresh: Bool) async throws -> UsageLimits {
        let generation = accountGeneration
        log.debug("usage request: interactive=false forceCredentialRefresh=\(forceCredentialRefresh) generation=\(Int(generation))")
        let credential = try await credentials.currentCredential(
            userInitiated: false, forceRefresh: forceCredentialRefresh
        )
        guard generation == accountGeneration else { throw CancellationError() }

        let key = UsageRefreshKey(
            provider: .claude,
            accountID: credential.account?.accountUuid ?? "live-unknown",
            organizationID: credential.account?.organizationUuid
        )
        guard let permit = await refreshController.begin(key) else {
            throw UsageRefreshDeferred()
        }

        do {
            let limits = try await fetchWithCredentialRetry(
                credential, generation: generation, key: key, forceResets: forceCredentialRefresh
            )
            await refreshController.finish(permit, outcome: .response(limits))
            return limits
        } catch {
            await refreshController.finish(permit, outcome: .error(error))
            if case TokiError.rateLimited(let retryAfter) = error {
                log.notice("rate limited; retryAfter=\(retryAfter)")
            }
            throw error
        }
    }

    private func fetchWithCredentialRetry(
        _ credential: OAuthCredential, generation: UInt64, key: UsageRefreshKey, forceResets: Bool
    ) async throws -> UsageLimits {
        do {
            return try await succeed(with: credential, generation: generation, key: key, forceResets: forceResets)
        } catch TokiError.tokenExpired {
            // Expected, not a fault: the access token expired and Claude Code has not
            // rotated it yet.
            log.notice("token expired; marking credential rejected and re-resolving")

            // Tell the credential layer this token is dead, then re-resolve. Claude Code
            // rotates its own token; Toki must never call the refresh endpoint itself,
            // because Anthropic's refresh tokens are single-use and rotating one out from
            // under the CLI would force the user to log in again.
            await credentials.markCredentialRejected(credential)
            let fresh = try await credentials.currentCredential(userInitiated: false, forceRefresh: true)
            // The permit belongs to the original account. A config switch can race
            // credential re-resolution before its watcher invalidates this feed.
            guard fresh.account == credential.account else { throw CancellationError() }

            // Claude Code has not refreshed yet (it may not even be running). Retrying with
            // the identical token would just burn one more request on every poll, forever.
            guard fresh.accessToken != credential.accessToken else {
                log.notice("re-resolved credential is still the expired one; giving up on this poll")
                throw TokiError.tokenExpired
            }
            return try await succeed(with: fresh, generation: generation, key: key, forceResets: forceResets)
        }
    }

    private func succeed(
        with credential: OAuthCredential, generation: UInt64, key: UsageRefreshKey, forceResets: Bool
    ) async throws -> UsageLimits {
        guard generation == accountGeneration else { throw CancellationError() }
        let wantsResets = forceResets || now() >= (resetsNextRequestAt[key] ?? .distantPast)
        let response = try await client.fetchUsage(
            token: credential.accessToken, includeSupplemental: wantsResets
        )
        try await credentials.validateCredential(credential)
        guard generation == accountGeneration else { throw CancellationError() }

        let resets: ClaudeResetStatus?
        if let fresh = response.claudeResets {
            lastResets[key] = fresh
            resetsNextRequestAt[key] = now().addingTimeInterval(resetsRefreshInterval)
            resets = fresh
        } else if let partial = response.supplementalRateLimit {
            // Only the optional reset request was refused. The usage above is fresh and is
            // published as such, with the last known resets; the reset request alone waits
            // out the back-off.
            log.notice("supplemental reset request rate limited; retryAfter=\(partial.retryAfter)")
            resetsNextRequestAt[key] = now().addingTimeInterval(
                max(resetsRefreshInterval, partial.retryAfter)
            )
            resets = lastResets[key] ?? cachedResets(for: credential.account)
        } else if !wantsResets {
            resets = lastResets[key] ?? cachedResets(for: credential.account)
        } else {
            // Asked and got no answer we can trust: an old balance must not come back as
            // current. The next poll asks again.
            lastResets[key] = nil
            resets = nil
        }

        let limits = UsageLimits(
            windows: response.windows, extra: response.extra, fetchedAt: response.fetchedAt,
            account: credential.account,
            bankedResets: response.bankedResets,
            claudeResets: resets
        )
        cache.save(limits)
        return limits
    }

    /// The resets saved with this account's last cached snapshot — what a fresh launch
    /// shows until the reset request next succeeds. Never another account's.
    private func cachedResets(for account: UsageAccount?) -> ClaudeResetStatus? {
        guard let account, let cached = cache.load(), cached.account == account else { return nil }
        return cached.claudeResets
    }
}
