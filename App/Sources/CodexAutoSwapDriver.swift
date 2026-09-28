import Foundation
import Observation
import TokiAlerts
import TokiAutoSwap
import TokiCore

private let log = TokiLog.logger("codex-autoswap")

/// Independent Codex settings, cooldown and notifications; shared live limits wake
/// a serialized policy runner while inactive accounts retain periodic upkeep.
@MainActor
final class CodexAutoSwapDriver {
    private let accounts: CodexAccountsViewModel
    private let notifier: SwapNotifier
    private let settings: @MainActor () -> AutoSwapSettings
    private let now: @MainActor () -> Date
    private var notifications = AutoSwapNotificationPolicy()
    private var lastSwapAt: Date?
    private var failures: [String: Date] = [:]
    private var refreshedAt: Date?
    private var periodicTask: Task<Void, Never>?
    private var evaluationTask: Task<Void, Never>?
    private var pending = false
    private var pendingRefresh = false
    private var started = false
    private var generation = 0
    private nonisolated(unsafe) var enabledObserver: (any NSObjectProtocol)?

    init(
        accounts: CodexAccountsViewModel, notifier: SwapNotifier,
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
        let currentGeneration = generation
        observe(generation: currentGeneration)
        request(refresh: true)
        periodicTask = Task { [weak self] in
            while !Task.isCancelled {
                // no-log: cancellation is normal periodic-loop teardown.
                try? await Task.sleep(for: .seconds(180))
                guard !Task.isCancelled else { return }
                self?.request(refresh: true)
            }
        }
        enabledObserver = NotificationCenter.default.addObserver(
            forName: .tokiAutoSwapEnabled, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.request(refresh: true) } }
    }

    func stop() {
        started = false
        generation += 1
        periodicTask?.cancel()
        periodicTask = nil
        evaluationTask?.cancel()
        evaluationTask = nil
        pending = false
        pendingRefresh = false
        refreshedAt = nil
        failures.removeAll()
        if let enabledObserver { NotificationCenter.default.removeObserver(enabledObserver) }
        enabledObserver = nil
    }

    func evaluateOnce() async {
        request(refresh: true)
        await evaluationTask?.value
    }

    private func observe(generation expected: Int) {
        guard started, generation == expected else { return }
        withObservationTracking {
            _ = accounts.accounts
            _ = accounts.activeAccountLimits
            _ = accounts.activeAccountLimitsState
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.started, self.generation == expected else { return }
                self.observe(generation: expected)
                self.request(refresh: false)
            }
        }
    }

    private func request(refresh: Bool) {
        guard started else { return }
        pending = true
        pendingRefresh = pendingRefresh || refresh
        guard evaluationTask == nil else { return }
        let currentGeneration = generation
        evaluationTask = Task { [weak self] in await self?.drain(generation: currentGeneration) }
    }

    private func drain(generation expected: Int) async {
        while started, generation == expected, pending, !Task.isCancelled {
            let refresh =
                pendingRefresh || refreshedAt.map { now().timeIntervalSince($0) >= 180 } ?? true
            pending = false
            pendingRefresh = false
            await perform(refresh: refresh, generation: expected)
        }
        if generation == expected { evaluationTask = nil }
    }

    private func perform(refresh: Bool, generation expected: Int) async {
        guard accounts.runMode.isLive else { return }
        if refresh {
            await accounts.refreshGauges()
            guard started, generation == expected, !Task.isCancelled else { return }
            refreshedAt = now()  // consume even an observed empty result
        }
        guard started, generation == expected, !Task.isCancelled else { return }
        let configured = settings()
        var snapshots = accounts.snapshotsForPolicy(now: now())
        logInputs(snapshots)
        var result = AutoSwapPolicy.evaluate(
            accounts: snapshots, settings: configured, now: now(), lastSwapAt: lastSwapAt
        )
        log.debug("evaluateOnce: policy result reason=\(result.reason.rawValue, privacy: .public)")
        guard configured.enabled, snapshots.count > 1 else { return }
        let alerts = NotificationSettingsStore(defaults: .standard).load()
        switch notifications.notification(
            for: result.decision, accounts: snapshots,
            notificationsEnabled: alerts.onAllExhausted || alerts.onNeedsReauth)
        {
        case .allExhausted where alerts.onAllExhausted:
            notifier.notifyAllExhausted(provider: .codex)
        case .needsReauth(let label) where alerts.onNeedsReauth:
            notifier.notifyNeedsReauth(label: label, provider: .codex)
        default: break
        }

        var left = max(snapshots.count, 1)
        while left > 0 {
            left -= 1
            guard case .swap(let target, let trigger) = result.decision else { return }
            if let failedAt = failures[target], now().timeIntervalSince(failedAt) < 180 {
                log.debug(
                    "evaluateOnce: policy result reason=recentRefusalBackoff target=\(account: target)"
                )
                return
            }
            let from = snapshots.first(where: \.isActive)?.label
            let to = snapshots.first { $0.accountUuid == target }?.label ?? target
            log.info("evaluateOnce: policy decided to swap to \(account: target)")
            if await accounts.swap(to: target) {
                guard started, generation == expected, !Task.isCancelled else { return }
                lastSwapAt = now()
                failures.removeAll()
                log.info("Codex auto-swap succeeded")
                if alerts.onSwap {
                    notifier.notifySwap(from: from, to: to, trigger: trigger, provider: .codex)
                }
                return
            }
            guard started, generation == expected, !Task.isCancelled else { return }
            failures[target] = now()
            log.notice("evaluateOnce: swap to \(account: target) was refused; re-evaluating")
            await accounts.refreshGauges()
            guard started, generation == expected, !Task.isCancelled else { return }
            refreshedAt = now()
            snapshots = accounts.snapshotsForPolicy(now: now())
            logInputs(snapshots)
            let next = AutoSwapPolicy.evaluate(
                accounts: snapshots, settings: configured, now: now(), lastSwapAt: lastSwapAt
            )
            log.debug("evaluateOnce: retry result reason=\(next.reason.rawValue, privacy: .public)")
            guard case .swap(let nextTarget, _) = next.decision, nextTarget != target else {
                return
            }
            result = next
        }
    }

    private func logInputs(_ snapshots: [AccountSnapshot]) {
        for item in snapshots {
            let five = item.fiveHour.map { String(format: "%.3f", $0) } ?? "unknown"
            let week = item.weekly.map { String(format: "%.3f", $0) } ?? "unknown"
            let binding = item.activeBindingMatches.map { $0 ? "match" : "mismatch" } ?? "unknown"
            log.debug(
                "evaluateOnce: input account=\(account: item.accountUuid) active=\(item.isActive) healthy=\(item.isHealthy) stale=\(item.gaugesAreStale) binding=\(binding, privacy: .public) fiveHour=\(five, privacy: .public) weekly=\(week, privacy: .public)"
            )
        }
    }
}
