import Foundation
import Testing
import TokiModels
@testable import TokiLimits

private func snapshot(
    _ utilization: Double,
    at date: Date = Date(),
    account: UsageAccount? = nil,
    resets: Int? = nil,
    supplementalRateLimit: SupplementalRateLimit? = nil
) -> UsageLimits {
    UsageLimits(windows: [RateLimitWindow(
        id: "session", title: "5-hour", utilization: utilization,
        resetsAt: nil, isAvailable: true
    )], extra: nil, fetchedAt: date, account: account, bankedResets: nil,
    claudeResets: resets.map {
        ClaudeResetStatus(
            eligible: true,
            grants: [ClaudeResetGrant(id: "grant", resetsLeft: $0)]
        )
    }, supplementalRateLimit: supplementalRateLimit)
}

/// The transport deliberately ignores cancellation, like an already completed IPC reply.
private actor Replies {
    var requests: [CheckedContinuation<UsageLimits, Error>] = []
    var started: [Int: CheckedContinuation<Void, Never>] = [:]

    func fetch() async throws -> UsageLimits {
        try await withCheckedThrowingContinuation { reply in
            requests.append(reply)
            started.removeValue(forKey: requests.count)?.resume()
        }
    }

    func waitFor(_ count: Int) async {
        if requests.count >= count { return }
        await withCheckedContinuation { started[count] = $0 }
    }

    func finish(_ index: Int, with result: Result<UsageLimits, Error>) {
        requests[index].resume(with: result)
    }
}

@Suite("Live usage publication")
@MainActor
struct LiveUsageFeedTests {
    @Test("access recovery retains the previous account snapshot while cadence defers a fetch")
    func recoveryRetainsSnapshotDuringCooldown() async {
        let account = UsageAccount(accountUuid: "same", organizationUuid: "org")
        let previous = snapshot(0.42, account: account, resets: 1)
        let feed = LiveUsageFeed { _ in throw UsageRefreshDeferred() }
        feed.limits = previous
        feed.state = .needsAccess

        feed.invalidate(preservingSnapshot: true)
        await feed.refresh()

        #expect(feed.limits?.claudeResets?.totalResets == 1)
        #expect(feed.limits?.fetchedAt == previous.fetchedAt)
        #expect(feed.state == .stale(previous.fetchedAt))
    }

    @Test("a forced refresh supersedes an ordinary request already in flight")
    func forcedRefreshIsNotLost() async {
        let replies = Replies()
        let feed = LiveUsageFeed { force in
            if force { return snapshot(0.15) }
            return try await replies.fetch()
        }
        let ordinary = Task { await feed.refresh() }
        await replies.waitFor(1)
        let finish = Task { await replies.finish(0, with: .success(snapshot(0.99))) }
        await feed.refresh(forceCredentialRefresh: true)
        await ordinary.value
        await finish.value
        #expect(feed.limits?.fiveHour?.utilization == 0.15)
    }

    @Test("usage stays visible as stale if no replacement response arrives")
    func hungPollingMarksUsageStale() async throws {
        let feed = LiveUsageFeed(maximumAge: 0.05) { _ in snapshot(0.98) }
        await feed.refresh()
        #expect(feed.limits != nil)
        try await Task.sleep(for: .milliseconds(100))
        #expect(feed.limits?.fiveHour?.utilization == 0.98)
        if let limits = feed.limits { #expect(feed.state == .stale(limits.fetchedAt)) }
    }

    @Test("a failed refresh retains the previously displayed percentages")
    func failedRefreshRetainsUsage() async {
        let replies = Replies()
        let feed = LiveUsageFeed { _ in try await replies.fetch() }
        let first = Task { await feed.refresh() }
        await replies.waitFor(1)
        await replies.finish(0, with: .success(snapshot(0.98)))
        await first.value
        #expect(feed.limits?.fiveHour?.utilization == 0.98)

        let second = Task { await feed.refresh() }
        await replies.waitFor(2)
        await replies.finish(1, with: .failure(URLError(.notConnectedToInternet)))
        await second.value
        #expect(feed.limits?.fiveHour?.utilization == 0.98)
        if let limits = feed.limits { #expect(feed.state == .stale(limits.fetchedAt)) }
        #expect(feed.failure == .network)
    }

    @Test("refresh failures retain the snapshot until recovery or account invalidation",
          arguments: [TokiError.tokenExpired, .rateLimited(retryAfter: 60), .keychainLocked])
    func retainsUntilRecovery(error: TokiError) async {
        let replies = Replies()
        let feed = LiveUsageFeed { _ in try await replies.fetch() }
        let original = snapshot(0.75)
        feed.limits = original
        feed.state = .ok
        let failed = Task { await feed.refresh() }
        await replies.waitFor(1)
        await replies.finish(0, with: .failure(error))
        await failed.value
        #expect(feed.limits?.fiveHour?.utilization == 0.75)
        #expect(feed.limits?.fetchedAt == original.fetchedAt)
        #expect(feed.state == .stale(original.fetchedAt))
        let recovered = Task { await feed.refresh() }
        await replies.waitFor(2)
        await replies.finish(1, with: .success(snapshot(0.25)))
        await recovered.value
        #expect(feed.limits?.fiveHour?.utilization == 0.25)
        #expect(feed.state == .ok)
        #expect(feed.failure == nil)
        feed.invalidate()
        #expect(feed.limits == nil)
    }

    @Test("supplemental rate limiting publishes fresh usage and keeps the same account's resets through main 429")
    func supplementalRateLimitRetainsSameAccountSnapshot() async {
        let replies = Replies()
        let feed = LiveUsageFeed { _ in try await replies.fetch() }
        let account = UsageAccount(accountUuid: "account-a", organizationUuid: "org-a")
        let originalDate = Date(timeIntervalSince1970: 1_750_000_000)
        feed.limits = snapshot(0.25, at: originalDate, account: account, resets: 2)
        feed.state = .ok

        let partial = Task { await feed.refresh() }
        await replies.waitFor(1)
        await replies.finish(0, with: .success(snapshot(
            0.35,
            account: account,
            supplementalRateLimit: SupplementalRateLimit(retryAfter: 180)
        )))
        await partial.value

        // The gauges are the fresh reply's; only the resets come from before.
        #expect(feed.limits?.fiveHour?.utilization == 0.35)
        #expect(feed.limits?.claudeResets?.totalResets == 2)
        let partialDate = feed.limits?.fetchedAt
        #expect(partialDate != originalDate)
        if let partialDate { #expect(feed.state == .stale(partialDate)) }
        #expect(feed.failure == .rateLimited)

        let mainRateLimit = Task { await feed.refresh() }
        await replies.waitFor(2)
        await replies.finish(1, with: .failure(TokiError.rateLimited(retryAfter: 360)))
        await mainRateLimit.value
        #expect(feed.limits?.claudeResets?.totalResets == 2)
        #expect(feed.limits?.fiveHour?.utilization == 0.35)
        #expect(feed.limits?.fetchedAt == partialDate)

        let recovery = Task { await feed.refresh() }
        await replies.waitFor(3)
        await replies.finish(2, with: .success(snapshot(0.45, account: account, resets: 5)))
        await recovery.value
        #expect(feed.limits?.fiveHour?.utilization == 0.45)
        #expect(feed.limits?.claudeResets?.totalResets == 5)
        #expect(feed.limits?.fetchedAt != originalDate)
        #expect(feed.state == .ok)
    }

    @Test("first or foreign-account supplemental 429 keeps only returned ordinary usage")
    func partialRateLimitDoesNotInventOrCrossAccounts() async {
        let accountA = UsageAccount(accountUuid: "account-a", organizationUuid: nil)
        let accountB = UsageAccount(accountUuid: "account-b", organizationUuid: nil)
        let partial = snapshot(
            0.65,
            account: accountB,
            supplementalRateLimit: SupplementalRateLimit(retryAfter: 180)
        )

        let first = LiveUsageFeed { _ in partial }
        await first.refresh()
        #expect(first.limits?.fiveHour?.utilization == 0.65)
        #expect(first.limits?.claudeResets == nil)
        if let limits = first.limits { #expect(first.state == .stale(limits.fetchedAt)) }
        #expect(first.failure == .rateLimited)

        let foreign = LiveUsageFeed { _ in partial }
        foreign.limits = snapshot(0.25, account: accountA, resets: 9)
        foreign.state = .ok
        await foreign.refresh()
        #expect(foreign.limits?.account == accountB)
        #expect(foreign.limits?.fiveHour?.utilization == 0.65)
        #expect(foreign.limits?.claudeResets == nil)
        #expect(foreign.failure == .rateLimited)
    }

    @Test("a late response from the previous account cannot overwrite the new account")
    func accountChangeDiscardsOldResponse() async {
        let replies = Replies()
        let feed = LiveUsageFeed { _ in try await replies.fetch() }
        let old = Task { await feed.refresh() }
        await replies.waitFor(1)
        feed.invalidate()
        #expect(feed.limits == nil)
        let current = Task { await feed.refresh() }
        await replies.waitFor(2)
        await replies.finish(1, with: .success(snapshot(0.15)))
        await current.value
        await replies.finish(0, with: .success(snapshot(0.99)))
        await old.value
        #expect(feed.limits?.fiveHour?.utilization == 0.15)
        #expect(feed.state == .ok)
    }

    @Test("an old request error cannot clear a successful new account response")
    func oldFailureIsIgnored() async {
        let replies = Replies()
        let feed = LiveUsageFeed { _ in try await replies.fetch() }
        let old = Task { await feed.refresh() }
        await replies.waitFor(1)
        feed.invalidate()
        let current = Task { await feed.refresh() }
        await replies.waitFor(2)
        await replies.finish(1, with: .success(snapshot(0.15)))
        await current.value
        await replies.finish(0, with: .failure(TokiError.tokenExpired))
        await old.value
        #expect(feed.limits?.fiveHour?.utilization == 0.15)
        #expect(feed.state == .ok)
    }

    @Test("concurrent refresh callers share the current request")
    func coalescesRefreshes() async {
        let replies = Replies()
        let feed = LiveUsageFeed { _ in try await replies.fetch() }
        let first = Task { await feed.refresh() }
        await replies.waitFor(1)
        let second = Task { await feed.refresh() }
        // Let the second caller enter while the transport is suspended.
        await Task.yield()
        await replies.finish(0, with: .success(snapshot(0.15)))
        await first.value
        await second.value
        #expect(await replies.requests.count == 1)
        #expect(feed.state == .ok)
    }

    @Test("a historical snapshot is never published as current")
    func refusesHistoricalData() async {
        let feed = LiveUsageFeed { _ in snapshot(0.98, at: Date().addingTimeInterval(-600)) }
        await feed.refresh()
        #expect(feed.limits == nil)
        #expect(feed.state != .ok)
    }

    @Test("authorization failures clear usage and show a reconnect state")
    func missingCredentials() async {
        let feed = LiveUsageFeed { _ in throw TokiError.credentialsNotFound }
        await feed.refresh()
        #expect(feed.limits == nil)
        #expect(feed.state == .notLoggedIn)
    }

    @Test("Keychain access failure retains the snapshot and records authorization failure")
    func keychainAccessIsDistinctFromMissingLogin() async {
        let feed = LiveUsageFeed { _ in throw TokiError.keychainDenied }
        feed.limits = snapshot(0.75)
        feed.state = .ok
        await feed.refresh()
        #expect(feed.limits?.fiveHour?.utilization == 0.75)
        if let limits = feed.limits { #expect(feed.state == .stale(limits.fetchedAt)) }
        #expect(feed.failure == .authorization)
    }

    // MARK: Status line samples

    private static func weekly(_ utilization: Double, at date: Date, account: UsageAccount) -> UsageLimits {
        UsageLimits(windows: [
            RateLimitWindow(id: "session", title: "5-hour", utilization: 0.1,
                            resetsAt: Date(timeIntervalSince1970: 1_000_000), isAvailable: true),
            RateLimitWindow(id: "weekly_all", title: "7-day", utilization: utilization,
                            resetsAt: Date(timeIntervalSince1970: 2_000_000), isAvailable: true),
        ], extra: nil, fetchedAt: date, account: account, bankedResets: nil)
    }

    private static func sample(_ session: Double, week: Double, at date: Date) -> StatuslineRateLimits {
        StatuslineRateLimits(
            fiveHour: .init(utilization: session, resetsAt: Date(timeIntervalSince1970: 1_000_000)),
            sevenDay: .init(utilization: week, resetsAt: Date(timeIntervalSince1970: 2_000_000)),
            observedAt: date
        )
    }

    @Test("a status line sample refreshes a stale snapshot and makes it current")
    func statuslineSampleRefreshesStaleSnapshot() {
        let account = UsageAccount(accountUuid: "a", organizationUuid: nil)
        let feed = LiveUsageFeed { _ in throw TokiError.keychainDenied }
        let polled = Date().addingTimeInterval(-3600)
        feed.limits = Self.weekly(0.2, at: polled, account: account)
        feed.state = .stale(polled)

        let now = Date()
        #expect(feed.ingest(Self.sample(0.35, week: 0.4, at: now)))

        #expect(feed.limits?.fiveHour?.utilization == 0.35)
        #expect(feed.limits?.sevenDay?.utilization == 0.4)
        #expect(feed.limits?.fetchedAt == now)
        #expect(feed.state == .ok)
        #expect(feed.failure == nil)
    }

    @Test("an old status line sample updates the numbers but stays marked stale")
    func oldSampleStaysStale() {
        let account = UsageAccount(accountUuid: "a", organizationUuid: nil)
        let feed = LiveUsageFeed { _ in throw TokiError.keychainDenied }
        feed.limits = Self.weekly(0.2, at: Date().addingTimeInterval(-7200), account: account)
        let observed = Date().addingTimeInterval(-1800)

        #expect(feed.ingest(Self.sample(0.3, week: 0.3, at: observed)))
        #expect(feed.limits?.sevenDay?.utilization == 0.3)
        #expect(feed.state == .stale(observed))
    }

    @Test("with nothing to bind to — no snapshot, or one without an account — samples are ignored")
    func unboundSampleIgnored() {
        let feed = LiveUsageFeed { _ in throw TokiError.keychainDenied }
        #expect(!feed.ingest(Self.sample(0.3, week: 0.3, at: Date())))
        #expect(feed.limits == nil)

        let anonymous = Self.weekly(0.2, at: Date().addingTimeInterval(-60), account: UsageAccount(accountUuid: "", organizationUuid: nil))
        feed.limits = UsageLimits(windows: anonymous.windows, extra: nil, fetchedAt: anonymous.fetchedAt, bankedResets: nil)
        #expect(!feed.ingest(Self.sample(0.3, week: 0.3, at: Date())))
        #expect(feed.limits?.sevenDay?.utilization == 0.2)
    }

    @Test("invalidating for an account change drops the snapshot, so samples wait for the new account's poll")
    func invalidateBlocksSamples() {
        let feed = LiveUsageFeed { _ in throw TokiError.keychainDenied }
        feed.limits = Self.weekly(0.2, at: Date().addingTimeInterval(-60),
                                  account: UsageAccount(accountUuid: "a", organizationUuid: nil))
        feed.invalidate()
        #expect(!feed.ingest(Self.sample(0.3, week: 0.3, at: Date())))
        #expect(feed.state == .loading)
    }

    // MARK: Restoring the cache at launch

    // A relaunch within the 90-second cadence finds its first poll deferred: the previous
    // process fetched moments ago. That snapshot is current, not "could not be updated".
    @Test("a cached snapshot inside the freshness ceiling is restored as current")
    func freshCacheRestoresAsCurrent() {
        let feed = LiveUsageFeed { _ in throw UsageRefreshDeferred() }
        let cached = snapshot(0.3, at: Date().addingTimeInterval(-40),
                              account: UsageAccount(accountUuid: "a", organizationUuid: nil))
        feed.restore(cached)
        #expect(feed.state == .ok)
        #expect(feed.failure == nil)
        #expect(feed.limits?.fetchedAt == cached.fetchedAt)
    }

    @Test("an older cached snapshot is restored as stale")
    func oldCacheRestoresAsStale() {
        let feed = LiveUsageFeed { _ in throw UsageRefreshDeferred() }
        let cached = snapshot(0.3, at: Date().addingTimeInterval(-3600),
                              account: UsageAccount(accountUuid: "a", organizationUuid: nil))
        feed.restore(cached)
        #expect(feed.state == .stale(cached.fetchedAt))
        #expect(feed.limits?.fetchedAt == cached.fetchedAt)
    }

    @Test("a restored current snapshot still goes stale at the ceiling")
    func restoredSnapshotExpires() async throws {
        let feed = LiveUsageFeed(maximumAge: 0.2) { _ in throw UsageRefreshDeferred() }
        let cached = snapshot(0.3, at: Date(), account: UsageAccount(accountUuid: "a", organizationUuid: nil))
        feed.restore(cached)
        #expect(feed.state == .ok)
        try await Task.sleep(for: .milliseconds(400))
        #expect(feed.state == .stale(cached.fetchedAt))
    }
}
