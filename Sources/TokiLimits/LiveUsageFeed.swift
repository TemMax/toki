import Foundation
import Observation
import TokiLogging
import TokiModels

/// Owns the publishable Claude snapshot. Request cancellation is only an optimization:
/// a generation check also rejects replies already in flight when the account changes.
@Observable
@MainActor
public final class LiveUsageFeed {
    public enum State: Sendable, Equatable {
        case loading
        case ok
        case stale(Date)
        case notLoggedIn
        case needsAccess
        case error(String)
    }

    public enum Failure: Sendable, Equatable {
        case authorization, rateLimited, network
    }

    public var limits: UsageLimits?
    public var state: State = .loading
    public private(set) var failure: Failure?
    public private(set) var refreshResultRevision: UInt64 = 0
    private let fetch: @Sendable (Bool) async throws -> UsageLimits
    private let maximumAge: TimeInterval
    private var generation: UInt64 = 0
    private var request: (id: UUID, forced: Bool, task: Task<Void, Never>)?
    private var expiryTask: Task<Void, Never>?
    private let log = TokiLog.logger("limits")

    public init(
        // Freshness ceiling, independent of the normal polling interval.
        maximumAge: TimeInterval = 210,
        fetch: @escaping @Sendable (Bool) async throws -> UsageLimits
    ) {
        self.maximumAge = maximumAge
        self.fetch = fetch
    }

    /// Revokes the old account's data immediately, including replies not yet delivered.
    public func invalidate(preservingSnapshot: Bool = false) {
        let previous = preservingSnapshot ? limits : nil
        generation &+= 1
        request?.task.cancel()
        request = nil
        expiryTask?.cancel()
        expiryTask = nil
        limits = previous
        state = previous.map { .stale($0.fetchedAt) } ?? .loading
        failure = nil
        log.info("live usage invalidated generation=\(Int(generation))")
    }

    @discardableResult
    public func refresh(forceCredentialRefresh: Bool = false) async -> Bool {
        if let request {
            if forceCredentialRefresh && !request.forced {
                invalidate()
            } else {
                let joinedGeneration = generation
                await request.task.value
                return generation == joinedGeneration
            }
        }
        let id = UUID()
        let startedGeneration = generation
        let fetch = self.fetch
        let task = Task { [weak self] in
            defer {
                if let self, self.request?.id == id { self.request = nil }
            }
            do {
                let result = try await fetch(forceCredentialRefresh)
                guard let self, self.generation == startedGeneration, !Task.isCancelled else { return }
                self.refreshResultRevision &+= 1
                self.publish(result, generation: startedGeneration)
            } catch is UsageRefreshDeferred {
                // Another surface or the background loop already owns this account's
                // collection window. Keep the last snapshot and its freshness unchanged.
                self?.log.debug("usage refresh deferred by the shared cadence")
            } catch {
                // no-log: fail(_:) logs current-request failures; superseded replies are discarded.
                guard let self, self.generation == startedGeneration, !Task.isCancelled else { return }
                self.refreshResultRevision &+= 1
                self.fail(error)
            }
        }
        request = (id, forceCredentialRefresh, task)
        await task.value
        return generation == startedGeneration
    }

    private func publish(_ result: UsageLimits, generation: UInt64) {
        if let partialRateLimit = result.supplementalRateLimit {
            // Only the reset request was rate limited: the usage windows in `result` are
            // fresh. Publish them, carrying over the resets of the previous snapshot when it
            // is the same account's (never inventing them, never crossing accounts). Keeping
            // the whole previous snapshot instead would pin the gauges to whatever it was —
            // after a launch, a snapshot restored from disk that can be hours old.
            let previousResets = result.account.flatMap { account in
                limits?.account == account ? limits?.claudeResets : nil
            }
            limits = UsageLimits(
                windows: result.windows,
                extra: result.extra,
                fetchedAt: result.fetchedAt,
                account: result.account,
                bankedResets: result.bankedResets,
                claudeResets: result.claudeResets ?? previousResets,
                supplementalRateLimit: partialRateLimit
            )
            fail(TokiError.rateLimited(retryAfter: partialRateLimit.retryAfter))
            return
        }
        guard showCurrent(result) else {
            fail(TokiError.httpError(-1))
            return
        }
        log.debug("live usage published generation=\(Int(generation))")
    }

    /// Shows a snapshot saved by an earlier launch. One still inside the freshness ceiling is
    /// current: a relaunch within the 90-second cadence has its first poll deferred because
    /// the previous process has only just fetched, and calling that snapshot outdated would
    /// put up a "could not be updated" banner over data seconds old.
    public func restore(_ cached: UsageLimits) {
        if !showCurrent(cached) {
            limits = cached
            state = .stale(cached.fetchedAt)
        }
        log.debug("live usage restored from cache generation=\(Int(generation))")
    }

    public func restorePresentation(limits: UsageLimits?, state: State, failure: Failure?) {
        invalidate()
        self.limits = limits
        switch state {
        case .needsAccess, .notLoggedIn:
            self.state = state
        default:
            self.state = limits.map { .stale($0.fetchedAt) } ?? state
        }
        self.failure = failure
    }

    /// Folds in the usage Claude Code gave its status line. Only the snapshot on screen can
    /// accept it — it must belong to an account and be the same week's (see
    /// `StatuslineRateLimits.merged(into:)`) — so after an account change nothing is taken
    /// until that account's first poll lands. Returns whether the sample was applied.
    @discardableResult
    public func ingest(_ sample: StatuslineRateLimits) -> Bool {
        guard sample.observedAt <= Date(),
              let current = limits, current.account.map({ !$0.accountUuid.isEmpty }) == true,
              let merged = sample.merged(into: current) else { return false }
        if !showCurrent(merged) {
            // Newer than what was shown, but past the freshness ceiling: keep the numbers,
            // keep saying they are old.
            limits = merged
            state = .stale(merged.fetchedAt)
        }
        log.debug("live usage updated from the status line generation=\(Int(generation))")
        return true
    }

    /// Shows `result` as current until it outlives `maximumAge`. False, touching nothing,
    /// when it already has.
    private func showCurrent(_ result: UsageLimits) -> Bool {
        let remaining = maximumAge - Date().timeIntervalSince(result.fetchedAt)
        guard remaining > 0 else { return false }
        let generation = self.generation
        limits = result
        state = .ok
        failure = nil
        expiryTask?.cancel()
        expiryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(remaining)) } catch {
                self?.log.debug("live usage expiry timer cancelled")
                return
            }
            guard let self, self.generation == generation else { return }
            self.state = .stale(result.fetchedAt)
            self.failure = .network
        }
        return true
    }

    private func fail(_ error: Error) {
        expiryTask?.cancel()
        expiryTask = nil
        switch error {
        case TokiError.keychainDenied, TokiError.keychainLocked:
            state = .needsAccess
            failure = .authorization
        case TokiError.notLoggedIn, TokiError.tokenExpired, TokiError.credentialsNotFound:
            state = .notLoggedIn
            failure = .authorization
        case TokiError.rateLimited:
            state = .error("Usage is temporarily rate limited")
            failure = .rateLimited
        default:
            state = .error("Couldn't reach Anthropic")
            failure = .network
        }
        if let limits { state = .stale(limits.fetchedAt) }
        log.notice("live usage unavailable \(error: error)")
    }
}
