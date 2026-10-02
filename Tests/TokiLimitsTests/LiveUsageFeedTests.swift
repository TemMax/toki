import Foundation
import Observation
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
    private var finishedRequests: Set<Int> = []
    private let automaticallyRespondFrom: Int?

    init(automaticallyRespondFrom: Int? = nil) {
        self.automaticallyRespondFrom = automaticallyRespondFrom
    }

    func fetch() async throws -> UsageLimits {
        try await withCheckedThrowingContinuation { reply in
            let index = requests.count
            requests.append(reply)
            started.removeValue(forKey: requests.count)?.resume()
            if let automaticallyRespondFrom, requests.count >= automaticallyRespondFrom {
                finishedRequests.insert(index)
                reply.resume(returning: snapshot(0.3))
            }
        }
    }

    func waitFor(_ count: Int) async {
        if requests.count >= count { return }
        await withCheckedContinuation { started[count] = $0 }
    }

    func finish(_ index: Int, with result: Result<UsageLimits, Error>) {
        guard !finishedRequests.contains(index) else { return }
        finishedRequests.insert(index)
        requests[index].resume(with: result)
    }

    var requestCount: Int { requests.count }

    func waitForBounded(_ count: Int) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while requests.count < count {
            guard clock.now < deadline else { throw CoordinationTimeout.requestCount(count) }
            await Task.yield()
        }
    }

    func releasePending() {
        for index in requests.indices where !finishedRequests.contains(index) {
            finishedRequests.insert(index)
            requests[index].resume(throwing: UsageRefreshDeferred())
        }
        for continuation in started.values {
            continuation.resume()
        }
        started.removeAll()
    }
}

private enum CoordinationTimeout: Error {
    case requestCount(Int)
    case callerEntry
}

private actor FailureThenDeferredFetch {
    private var invocationCount = 0

    func fetch() throws -> UsageLimits {
        invocationCount += 1
        if invocationCount == 1 { throw TokiError.keychainDenied }
        throw UsageRefreshDeferred()
    }
}

@MainActor
private final class ImmediateUsageSource {
    private(set) var invocationCount = 0
    private let account = UsageAccount(accountUuid: "immediate-probe", organizationUuid: "org")

    func nextSnapshot() -> UsageLimits {
        invocationCount += 1
        return snapshot(Double(invocationCount) / 10, account: account)
    }
}

@MainActor
private final class ObservedRefreshResult {
    var observedCurrentState = false
    var utilization: Double?
    var followupCompleted = false
}

@MainActor
private func waitForCallerEntry(_ condition: @MainActor () -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while !condition() {
        guard clock.now < deadline else { throw CoordinationTimeout.callerEntry }
        await Task.yield()
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
        _ = await feed.refresh()

        #expect(feed.limits?.claudeResets?.totalResets == 1)
        #expect(feed.limits?.fetchedAt == previous.fetchedAt)
        #expect(feed.state == .stale(previous.fetchedAt))
    }

    @Test("forced supersession reports the accepted forced result and rejects the ordinary result")
    func forcedSupersessionReportsLifecycleValidity() async {
        let replies = Replies()
        let feed = LiveUsageFeed { force in
            if force { return snapshot(0.15) }
            return try await replies.fetch()
        }
        let ordinary = Task { await feed.refresh() }
        await replies.waitFor(1)
        let forcedIsCurrent = await feed.refresh(forceCredentialRefresh: true)
        await replies.finish(0, with: .success(snapshot(0.99)))
        let ordinaryIsCurrent = await ordinary.value
        #expect(forcedIsCurrent)
        #expect(!ordinaryIsCurrent)
        #expect(feed.limits?.fiveHour?.utilization == 0.15)
        #expect(feed.refreshResultRevision == 1)
    }

    @Test("usage stays visible as stale if no replacement response arrives")
    func hungPollingMarksUsageStale() async throws {
        let feed = LiveUsageFeed(maximumAge: 0.05) { _ in snapshot(0.98) }
        _ = await feed.refresh()
        #expect(feed.limits != nil)
        try await Task.sleep(for: .milliseconds(100))
        #expect(feed.limits?.fiveHour?.utilization == 0.98)
        if let limits = feed.limits { #expect(feed.state == .stale(limits.fetchedAt)) }
    }

    @Test("a failed refresh retains the previously displayed percentages")
    func failedRefreshRetainsUsage() async {
        let replies = Replies()
        let feed = LiveUsageFeed { _ in try await replies.fetch() }
        let first = Task { _ = await feed.refresh() }
        await replies.waitFor(1)
        await replies.finish(0, with: .success(snapshot(0.98)))
        _ = await first.value
        #expect(feed.limits?.fiveHour?.utilization == 0.98)

        let second = Task { _ = await feed.refresh() }
        await replies.waitFor(2)
        await replies.finish(1, with: .failure(URLError(.notConnectedToInternet)))
        _ = await second.value
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
        let failed = Task { _ = await feed.refresh() }
        await replies.waitFor(1)
        await replies.finish(0, with: .failure(error))
        _ = await failed.value
        #expect(feed.limits?.fiveHour?.utilization == 0.75)
        #expect(feed.limits?.fetchedAt == original.fetchedAt)
        #expect(feed.state == .stale(original.fetchedAt))
        let recovered = Task { _ = await feed.refresh() }
        await replies.waitFor(2)
        await replies.finish(1, with: .success(snapshot(0.25)))
        _ = await recovered.value
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

        let partial = Task { _ = await feed.refresh() }
        await replies.waitFor(1)
        await replies.finish(0, with: .success(snapshot(
            0.35,
            account: account,
            supplementalRateLimit: SupplementalRateLimit(retryAfter: 180)
        )))
        _ = await partial.value

        // The gauges are the fresh reply's; only the resets come from before.
        #expect(feed.limits?.fiveHour?.utilization == 0.35)
        #expect(feed.limits?.claudeResets?.totalResets == 2)
        let partialDate = feed.limits?.fetchedAt
        #expect(partialDate != originalDate)
        if let partialDate { #expect(feed.state == .stale(partialDate)) }
        #expect(feed.failure == .rateLimited)

        let mainRateLimit = Task { _ = await feed.refresh() }
        await replies.waitFor(2)
        await replies.finish(1, with: .failure(TokiError.rateLimited(retryAfter: 360)))
        _ = await mainRateLimit.value
        #expect(feed.limits?.claudeResets?.totalResets == 2)
        #expect(feed.limits?.fiveHour?.utilization == 0.35)
        #expect(feed.limits?.fetchedAt == partialDate)

        let recovery = Task { _ = await feed.refresh() }
        await replies.waitFor(3)
        await replies.finish(2, with: .success(snapshot(0.45, account: account, resets: 5)))
        _ = await recovery.value
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
        _ = await first.refresh()
        #expect(first.limits?.fiveHour?.utilization == 0.65)
        #expect(first.limits?.claudeResets == nil)
        if let limits = first.limits { #expect(first.state == .stale(limits.fetchedAt)) }
        #expect(first.failure == .rateLimited)

        let foreign = LiveUsageFeed { _ in partial }
        foreign.limits = snapshot(0.25, account: accountA, resets: 9)
        foreign.state = .ok
        _ = await foreign.refresh()
        #expect(foreign.limits?.account == accountB)
        #expect(foreign.limits?.fiveHour?.utilization == 0.65)
        #expect(foreign.limits?.claudeResets == nil)
        #expect(foreign.failure == .rateLimited)
    }

    @Test("a late response from the previous account cannot overwrite the new account")
    func accountChangeDiscardsOldResponse() async {
        let replies = Replies()
        let feed = LiveUsageFeed { _ in try await replies.fetch() }
        let old = Task { _ = await feed.refresh() }
        await replies.waitFor(1)
        feed.invalidate()
        #expect(feed.limits == nil)
        let current = Task { _ = await feed.refresh() }
        await replies.waitFor(2)
        await replies.finish(1, with: .success(snapshot(0.15)))
        _ = await current.value
        await replies.finish(0, with: .success(snapshot(0.99)))
        _ = await old.value
        #expect(feed.limits?.fiveHour?.utilization == 0.15)
        #expect(feed.state == .ok)
    }

    @Test("an old request error cannot clear a successful new account response")
    func oldFailureIsIgnored() async {
        let replies = Replies()
        let feed = LiveUsageFeed { _ in try await replies.fetch() }
        let old = Task { _ = await feed.refresh() }
        await replies.waitFor(1)
        feed.invalidate()
        let current = Task { _ = await feed.refresh() }
        await replies.waitFor(2)
        await replies.finish(1, with: .success(snapshot(0.15)))
        _ = await current.value
        await replies.finish(0, with: .failure(TokiError.tokenExpired))
        _ = await old.value
        #expect(feed.limits?.fiveHour?.utilization == 0.15)
        #expect(feed.state == .ok)
    }

    @Test("concurrent refresh callers share the current request")
    func coalescesRefreshes() async throws {
        let replies = Replies(automaticallyRespondFrom: 2)
        defer { Task { await replies.releasePending() } }
        let feed = LiveUsageFeed { _ in try await replies.fetch() }
        let first = Task { await feed.refresh() }
        try await replies.waitForBounded(1)
        var secondCallerEntered = false
        let second = Task { @MainActor in
            secondCallerEntered = true
            return await feed.refresh()
        }
        try await waitForCallerEntry { secondCallerEntered }
        await replies.finish(0, with: .success(snapshot(0.15)))
        let firstIsCurrent = await first.value
        let secondIsCurrent = await second.value
        #expect(firstIsCurrent)
        #expect(secondIsCurrent)
        #expect(await replies.requestCount == 1)
        #expect(feed.limits?.fiveHour?.utilization == 0.15)
        #expect(feed.state == .ok)
        #expect(feed.refreshResultRevision == 1)
    }

    @Test("coalesced failed refresh callers share one accepted result revision")
    func coalescedFailureAdvancesRefreshResultRevisionOnce() async throws {
        let replies = Replies()
        defer { Task { await replies.releasePending() } }
        let feed = LiveUsageFeed { _ in try await replies.fetch() }
        let first = Task { await feed.refresh() }
        try await replies.waitForBounded(1)
        var secondCallerEntered = false
        let second = Task { @MainActor in
            secondCallerEntered = true
            return await feed.refresh()
        }
        try await waitForCallerEntry { secondCallerEntered }
        await replies.finish(0, with: .failure(URLError(.notConnectedToInternet)))

        let firstIsCurrent = await first.value
        let secondIsCurrent = await second.value
        #expect(firstIsCurrent)
        #expect(secondIsCurrent)
        #expect(await replies.requestCount == 1)
        #expect(feed.failure == .network)
        #expect(feed.refreshResultRevision == 1)
    }

    @Test("a deferred refresh preserves the previous failure without advancing its result revision")
    func deferredRefreshPreservesFailureRevision() async {
        let fetcher = FailureThenDeferredFetch()
        let feed = LiveUsageFeed { _ in try await fetcher.fetch() }
        _ = await feed.refresh()
        let revisionAfterFailure = feed.refreshResultRevision
        let failureAfterFailure = feed.failure
        let stateAfterFailure = feed.state

        _ = await feed.refresh()

        #expect(revisionAfterFailure == 1)
        #expect(feed.refreshResultRevision == revisionAfterFailure)
        #expect(feed.failure == failureAfterFailure)
        #expect(feed.state == stateAfterFailure)
    }

    @Test("a published refresh can immediately start a new request")
    func publishedRequestCanBeRefreshedImmediately() async throws {
        let source = ImmediateUsageSource()
        let feed = LiveUsageFeed { _ in await source.nextSnapshot() }
        let observer = ObservedRefreshResult()

        withObservationTracking {
            _ = feed.state
        } onChange: {
            Task(priority: .high) { @MainActor in
                observer.observedCurrentState = feed.state == .ok
                _ = await feed.refresh()
                observer.utilization = feed.limits?.fiveHour?.utilization
                observer.followupCompleted = true
            }
        }

        let initial = Task(priority: .background) { @MainActor in
            _ = await feed.refresh()
        }
        try await waitForCallerEntry { observer.followupCompleted }
        await initial.value

        #expect(observer.observedCurrentState)
        #expect(source.invocationCount == 2)
        #expect(observer.utilization == 0.2)
        #expect(feed.limits?.fiveHour?.utilization == 0.2)
        #expect(feed.state == .ok)
    }

    @Test("a cancelled old request cannot erase a forced replacement slot")
    func cancelledRequestCannotEraseForcedReplacement() async throws {
        let replies = Replies(automaticallyRespondFrom: 3)
        defer { Task { await replies.releasePending() } }
        let feed = LiveUsageFeed { _ in try await replies.fetch() }
        let ordinary = Task { await feed.refresh() }
        try await replies.waitForBounded(1)

        let forced = Task { @MainActor in
            await feed.refresh(forceCredentialRefresh: true)
        }
        try await replies.waitForBounded(2)
        await replies.finish(0, with: .success(snapshot(0.99)))
        let ordinaryIsCurrent = await ordinary.value
        #expect(!ordinaryIsCurrent)

        var joiningCallerEntered = false
        let joining = Task { @MainActor in
            joiningCallerEntered = true
            return await feed.refresh()
        }
        try await waitForCallerEntry { joiningCallerEntered }

        await replies.finish(1, with: .success(snapshot(0.2)))
        let forcedIsCurrent = await forced.value
        let joiningIsCurrent = await joining.value
        #expect(forcedIsCurrent)
        #expect(joiningIsCurrent)
        #expect(await replies.requestCount == 2)
        #expect(feed.limits?.fiveHour?.utilization == 0.2)
    }

    @Test("a historical snapshot is never published as current")
    func refusesHistoricalData() async {
        let feed = LiveUsageFeed { _ in snapshot(0.98, at: Date().addingTimeInterval(-600)) }
        _ = await feed.refresh()
        #expect(feed.limits == nil)
        #expect(feed.state != .ok)
    }

    @Test("authorization failures clear usage and show a reconnect state")
    func missingCredentials() async {
        let feed = LiveUsageFeed { _ in throw TokiError.credentialsNotFound }
        _ = await feed.refresh()
        #expect(feed.limits == nil)
        #expect(feed.state == .notLoggedIn)
    }

    @Test("Keychain access failure retains the snapshot and records authorization failure")
    func keychainAccessIsDistinctFromMissingLogin() async {
        let feed = LiveUsageFeed { _ in throw TokiError.keychainDenied }
        feed.limits = snapshot(0.75)
        feed.state = .ok
        _ = await feed.refresh()
        #expect(feed.limits?.fiveHour?.utilization == 0.75)
        if let limits = feed.limits { #expect(feed.state == .stale(limits.fetchedAt)) }
        #expect(feed.failure == .authorization)
    }

    @Test("restoring a suspended authorization presentation keeps the failure and ages the snapshot")
    func restoresAuthorizationPresentation() async throws {
        let feed = LiveUsageFeed(maximumAge: 0.05) { _ in throw TokiError.keychainDenied }
        let cached = snapshot(0.75)
        feed.limits = cached
        _ = await feed.refresh()
        feed.restorePresentation(limits: feed.limits, state: feed.state, failure: feed.failure)
        #expect(feed.failure == .authorization)
        #expect(feed.state == .stale(cached.fetchedAt))
        try await Task.sleep(for: .milliseconds(100))
        #expect(feed.failure == .authorization)
        #expect(feed.state == .stale(cached.fetchedAt))
    }

    @Test("restoring a suspended credential gate preserves it with and without a snapshot")
    func restoresCredentialGates() async throws {
        for gate in [LiveUsageFeed.State.needsAccess, .notLoggedIn] {
            for cached in [UsageLimits?.none, snapshot(0.75)] {
                let feed = LiveUsageFeed(maximumAge: 0.03) { _ in throw UsageRefreshDeferred() }
                feed.restorePresentation(limits: cached, state: gate, failure: .authorization)
                try await Task.sleep(for: .milliseconds(70))
                #expect(feed.failure == .authorization)
                #expect(feed.state == gate)
                #expect(feed.limits?.fetchedAt == cached?.fetchedAt)
            }
        }
    }

    @Test("restoring a presentation invalidates pending requests and expiry timers")
    func restoredPresentationRejectsOldWork() async throws {
        let replies = Replies()
        let feed = LiveUsageFeed(maximumAge: 0.05) { _ in try await replies.fetch() }
        let initial = snapshot(0.2)
        feed.restore(initial)
        let request = Task { _ = await feed.refresh() }
        await replies.waitFor(1)
        let restored = snapshot(0.7)
        feed.restorePresentation(limits: restored, state: .needsAccess, failure: .authorization)
        await replies.finish(0, with: .success(snapshot(0.99)))
        _ = await request.value
        try await Task.sleep(for: .milliseconds(100))
        #expect(feed.limits?.fiveHour?.utilization == 0.7)
        #expect(feed.state == .needsAccess)
        #expect(feed.failure == .authorization)
    }

    @Test("presentation restoration invalidates initial and joined refresh waiters")
    func restoredPresentationMakesRefreshWaitersOutdated() async {
        let replies = Replies()
        let feed = LiveUsageFeed { _ in try await replies.fetch() }
        let initial = Task { await feed.refresh() }
        await replies.waitFor(1)
        var joinedTaskEntered = false
        let joined = Task { @MainActor in
            joinedTaskEntered = true
            return await feed.refresh()
        }
        while !joinedTaskEntered {
            await Task.yield()
        }

        let restored = snapshot(0.7, resets: 2)
        feed.restorePresentation(limits: restored, state: .needsAccess, failure: .authorization)
        await replies.finish(0, with: .success(snapshot(0.99)))

        let initialIsCurrent = await initial.value
        let joinedIsCurrent = await joined.value
        #expect(!initialIsCurrent)
        #expect(!joinedIsCurrent)
        #expect(feed.limits?.fiveHour?.utilization == 0.7)
        #expect(feed.state == .needsAccess)
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

    @Test("a future-dated status line sample cannot make usage current")
    func futureSampleIsIgnored() {
        let account = UsageAccount(accountUuid: "a", organizationUuid: nil)
        let feed = LiveUsageFeed { _ in throw UsageRefreshDeferred() }
        let original = Self.weekly(0.2, at: Date().addingTimeInterval(-600), account: account)
        feed.limits = original
        feed.state = .stale(original.fetchedAt)

        #expect(!feed.ingest(Self.sample(0.9, week: 0.9, at: Date().addingTimeInterval(3600))))
        #expect(feed.limits?.sevenDay?.utilization == 0.2)
        #expect(feed.limits?.fetchedAt == original.fetchedAt)
        #expect(feed.state == .stale(original.fetchedAt))
    }

    @Test("passive updates do not fetch usage or prevent the next regular refresh")
    func statuslineDoesNotReplacePolling() async {
        let account = UsageAccount(accountUuid: "a", organizationUuid: nil)
        let replies = Replies()
        let feed = LiveUsageFeed { _ in try await replies.fetch() }
        feed.limits = Self.weekly(0.2, at: Date().addingTimeInterval(-60), account: account)

        #expect(feed.ingest(Self.sample(0.35, week: 0.4, at: Date())))
        #expect(await replies.requests.isEmpty)

        let refresh = Task { _ = await feed.refresh() }
        await replies.waitFor(1)
        await replies.finish(0, with: .success(Self.weekly(0.5, at: Date(), account: account)))
        _ = await refresh.value

        #expect(await replies.requests.count == 1)
        #expect(feed.limits?.sevenDay?.utilization == 0.5)
        #expect(feed.state == .ok)
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
