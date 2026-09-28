import Foundation
import Observation
import TokiAlerts
import TokiCore
import TokiAutoSwap

private let log = TokiLog.logger("autoswap")

/// Polls the auto-swap policy and acts on it — and, independent of the toggle, owns the
/// background gauge refresh for every stored account.
///
/// Policy evaluation is cheap and purely local, so fresh active limits wake it immediately.
/// The candidate gauge refresh keeps its own three-minute cadence even when auto-swap is
/// disabled: it is the only thing keeping a sleeping account's token and usage numbers
/// current between visits to the popover or the Accounts tab.
@MainActor
final class AutoSwapDriver {
    private let accounts: AccountsViewModel
    private let notifier: SwapNotifier
    private let settings: @MainActor () -> AutoSwapSettings
    private let now: @MainActor () -> Date
    private var notifications = AutoSwapNotificationPolicy()
    private var lastSwapAt: Date?
    private var failedAttemptsByTarget: [String: Date] = [:]
    private var candidatesRefreshedAt: Date?
    private var periodicTask: Task<Void, Never>?
    private var evaluationTask: Task<Void, Never>?
    private var pendingEvaluation = false
    private var pendingCandidateRefresh = false
    private var started = false
    private var generation = 0
    // `nonisolated(unsafe)` only so `deinit` — which is nonisolated, and is the last chance
    // to unregister — can read it. Every write happens on the main actor.
    private nonisolated(unsafe) var enabledObserver: (any NSObjectProtocol)?

    init(
        accounts: AccountsViewModel,
        notifier: SwapNotifier,
        settings: @escaping @MainActor () -> AutoSwapSettings,
        now: @escaping @MainActor () -> Date = Date.init
    ) {
        self.accounts = accounts
        self.notifier = notifier
        self.settings = settings
        self.now = now
    }

    deinit {
        periodicTask?.cancel()
        evaluationTask?.cancel()
        if let enabledObserver { NotificationCenter.default.removeObserver(enabledObserver) }
    }

    func start() {
        stop()
        started = true
        generation += 1
        let activeGeneration = generation
        observePolicyInputs(generation: activeGeneration)
        requestEvaluation(refreshCandidates: true)
        periodicTask = Task { [weak self] in
            while !Task.isCancelled {
                // no-log: cancellation is the periodic loop's normal teardown path.
                try? await Task.sleep(for: .seconds(180))
                guard !Task.isCancelled else { return }
                self?.requestEvaluation(refreshCandidates: true)
            }
        }
        // Without this the switch in Settings takes up to a poll interval to mean anything,
        // which reads as a broken toggle at exactly the moment the user is watching it.
        enabledObserver = NotificationCenter.default.addObserver(
            forName: .tokiAutoSwapEnabled, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.requestEvaluation(refreshCandidates: true)
            }
        }
    }

    func stop() {
        started = false
        generation += 1
        periodicTask?.cancel()
        periodicTask = nil
        evaluationTask?.cancel()
        evaluationTask = nil
        pendingEvaluation = false
        pendingCandidateRefresh = false
        candidatesRefreshedAt = nil
        failedAttemptsByTarget.removeAll()
        if let enabledObserver { NotificationCenter.default.removeObserver(enabledObserver) }
        enabledObserver = nil
    }

    /// Compatibility seam for focused app probes and explicit callers. Every request still
    /// goes through the same runner, so awaiting this cannot create a parallel evaluation.
    func evaluateOnce() async {
        requestEvaluation(refreshCandidates: true)
        await evaluationTask?.value
    }

    private func observePolicyInputs(generation expectedGeneration: Int) {
        guard started, generation == expectedGeneration else { return }
        withObservationTracking {
            _ = accounts.activeAccountLimits
            _ = accounts.accounts
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.started, self.generation == expectedGeneration else { return }
                self.observePolicyInputs(generation: expectedGeneration)
                self.requestEvaluation(refreshCandidates: false)
            }
        }
    }

    private func requestEvaluation(refreshCandidates: Bool) {
        guard started else { return }
        pendingEvaluation = true
        pendingCandidateRefresh = pendingCandidateRefresh || refreshCandidates
        guard evaluationTask == nil else { return }
        let activeGeneration = generation
        evaluationTask = Task { [weak self] in
            await self?.drainEvaluations(generation: activeGeneration)
        }
    }

    private func drainEvaluations(generation expectedGeneration: Int) async {
        while started, generation == expectedGeneration, pendingEvaluation, !Task.isCancelled {
            let refreshCandidates = pendingCandidateRefresh || candidatesAreExpired
            pendingEvaluation = false
            pendingCandidateRefresh = false
            await performEvaluation(
                refreshCandidates: refreshCandidates, generation: expectedGeneration
            )
        }
        if generation == expectedGeneration { evaluationTask = nil }
    }

    private var candidatesAreExpired: Bool {
        guard let candidatesRefreshedAt else { return true }
        return now().timeIntervalSince(candidatesRefreshedAt) >= 180
    }

    private func performEvaluation(refreshCandidates: Bool, generation expectedGeneration: Int) async {
        // Fixture rows must never cause background Keychain/network work or a real swap.
        guard accounts.runMode.isLive else { return }

        // Gauge upkeep runs on every tick whether auto-swap is enabled or not: the
        // popover rows and the Accounts tab read these gauges, and without a
        // background refresh a sleeping account's token quietly expires and its row
        // reads "unavailable" until the user happens to open the Accounts tab.
        //
        // This driver's whole purpose is to run while nobody is looking, so nothing else
        // has populated the account list: without loading it here the count guard below
        // reads the empty list a freshly launched app starts with, and gauges never
        // refresh until the user opens the popover or the Accounts tab.
        if refreshCandidates { await accounts.reload() }
        guard started, generation == expectedGeneration, !Task.isCancelled else { return }
        // Reload itself mutates the observed row array. Mark this upkeep request consumed
        // before the empty guard so an empty store cannot requeue expired refreshes forever.
        if refreshCandidates { candidatesRefreshedAt = now() }
        guard !accounts.accounts.isEmpty else {
            log.debug("evaluateOnce: no accounts stored yet; skipping this tick")
            return
        }
        if refreshCandidates {
            await accounts.refreshGauges()
            guard started, generation == expectedGeneration, !Task.isCancelled else { return }
            candidatesRefreshedAt = now()
        }
        guard started, generation == expectedGeneration, !Task.isCancelled else { return }

        let current = settings()
        // Re-read every tick, like `settings()`: the notifications editor writes these and
        // must take effect without restarting the driver.
        let alerts = NotificationSettingsStore(defaults: .standard).load()
        // Decide, and if the chosen target turns out to be unusable (its grant died at the
        // freshen step), decide again — the slot is flagged by then, so the policy ranks
        // the next candidate. Mirrors claude-swap, which walks its ordered candidates and
        // quarantines the dead ones rather than failing the whole tick. Bounded by the
        // number of stored accounts so a pathological store cannot spin.
        var snapshots = accounts.snapshotsForPolicy()
        logInputs(snapshots)
        var result = AutoSwapPolicy.evaluate(
            accounts: snapshots,
            settings: current,
            now: now(),
            lastSwapAt: lastSwapAt
        )
        log.debug("evaluateOnce: policy result reason=\(result.reason.rawValue, privacy: .public)")

        // Preserve the delivery/latch behavior of the old early guards while still logging
        // the policy's exact reason for these states.
        guard current.enabled, accounts.accounts.count > 1 else { return }

        // A refused transaction forces row/live refreshes in AccountsViewModel. Those
        // changes are observed inputs, so without a separate backoff they immediately
        // request the same target again. Keep successful-swap cooldown semantics untouched.
        // The policy owns the latches, so it must keep seeing every decision whenever EITHER
        // notification it can return is wanted; which one the user actually hears about is
        // decided here, per kind.
        switch notifications.notification(
            for: result.decision,
            accounts: snapshots,
            notificationsEnabled: alerts.onAllExhausted || alerts.onNeedsReauth
        ) {
        case .allExhausted:
            if alerts.onAllExhausted {
                log.info("evaluateOnce: posting an all-accounts-exhausted notification")
                notifier.notifyAllExhausted()
            } else {
                log.notice("evaluateOnce: all accounts are exhausted; notification suppressed by settings")
            }
        case let .needsReauth(label):
            if alerts.onNeedsReauth {
                log.info("evaluateOnce: posting a needs-reauth notification")
                notifier.notifyNeedsReauth(label: label)
            } else {
                log.notice("evaluateOnce: an account needs re-auth; notification suppressed by settings")
            }
        case nil:
            break
        }

        var attemptsLeft = max(accounts.accounts.count, 1)
        while attemptsLeft > 0 {
            attemptsLeft -= 1
            guard case let .swap(target, trigger) = result.decision else {
                return
            }
            if let failedAt = failedAttemptsByTarget[target],
               now().timeIntervalSince(failedAt) < 180 {
                log.debug(
                    "evaluateOnce: policy result reason=recentRefusalBackoff target=\(account: target)"
                )
                return
            }
            let from = accounts.accounts.first(where: \.isActive)?.label
            let toLabel = accounts.accounts.first { $0.accountUuid == target }?.label ?? target
            log.info("evaluateOnce: policy decided to swap to \(account: target)")

            // Only a real swap starts the cooldown and announces itself. Stamping either on
            // a failure would suppress the retry and tell the user something that did not
            // happen.
            if await accounts.swap(to: target) {
                guard started, generation == expectedGeneration, !Task.isCancelled else { return }
                lastSwapAt = now()
                failedAttemptsByTarget.removeAll()
                log.info("evaluateOnce: swap to \(account: target) succeeded")
                if alerts.onSwap {
                    notifier.notifySwap(from: from, to: toLabel, trigger: trigger)
                } else {
                    log.notice("evaluateOnce: swap notification suppressed by settings")
                }
                return
            }
            guard started, generation == expectedGeneration, !Task.isCancelled else { return }
            failedAttemptsByTarget[target] = now()
            log.notice("evaluateOnce: swap to \(account: target) was refused; re-evaluating")

            // The swap refused. `AccountsViewModel.swap` has already reloaded, so a target
            // whose grant died now reads as unhealthy and the next decision skips it. If
            // the new decision names the same target, nothing changed and retrying would
            // loop — stop.
            snapshots = accounts.snapshotsForPolicy()
            logInputs(snapshots)
            let next = AutoSwapPolicy.evaluate(
                accounts: snapshots,
                settings: current,
                now: now(),
                lastSwapAt: lastSwapAt
            )
            log.debug("evaluateOnce: retry result reason=\(next.reason.rawValue, privacy: .public)")
            guard case let .swap(nextTarget, _) = next.decision, nextTarget != target else {
                log.debug("evaluateOnce: no different candidate to retry with; stopping")
                return
            }
            result = next
        }
        _ = snapshots
    }

    private func logInputs(_ snapshots: [AccountSnapshot]) {
        for snapshot in snapshots {
            let fiveHour = snapshot.fiveHour.map { String(format: "%.3f", $0) } ?? "unknown"
            let weekly = snapshot.weekly.map { String(format: "%.3f", $0) } ?? "unknown"
            let binding = snapshot.activeBindingMatches.map { $0 ? "match" : "mismatch" }
                ?? "unknown"
            log.debug(
                "evaluateOnce: input account=\(account: snapshot.accountUuid) active=\(snapshot.isActive) healthy=\(snapshot.isHealthy) stale=\(snapshot.gaugesAreStale) binding=\(binding, privacy: .public) fiveHour=\(fiveHour, privacy: .public) weekly=\(weekly, privacy: .public)"
            )
        }
    }
}
