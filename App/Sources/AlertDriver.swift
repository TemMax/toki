import Foundation
import Observation
import TokiAlerts
import TokiCore

private let log = TokiLog.logger("alerts")

/// Turns limit refreshes into notifications. Deliberately thin: every decision lives in
/// `ThresholdAlertPolicy`, which is a pure value and therefore testable without
/// `UserNotifications`. This type only reads the current state and posts.
///
/// It OBSERVES `LiveLimits` rather than living inside it — `LiveLimits` is the single owner of
/// the active account's limits and must stay a store its observers read without side effects.
/// The observation is `withObservationTracking`, not a timer: `LiveLimits` already owns the
/// poll loop, so the driver wakes exactly when a refresh lands and never on its own schedule.
@MainActor
final class AlertDriver {
    private let limits: LiveLimits
    private let signedIn: SignedInAccount
    private let provider: UsageProvider
    private let codexAccountID: @MainActor () -> String?
    private let store: NotificationSettingsStore
    private let latch: ThresholdAlertLatchStore
    private let notifier = SwapNotifier()
    private var policy: ThresholdAlertPolicy
    private var started = false

    init(
        limits: LiveLimits,
        signedIn: SignedInAccount,
        provider: UsageProvider = .claudeCode,
        codexAccountID: @escaping @MainActor () -> String? = { nil },
        store: NotificationSettingsStore,
        latch: ThresholdAlertLatchStore = ThresholdAlertLatchStore(defaults: .standard)
    ) {
        self.limits = limits
        self.signedIn = signedIn
        self.provider = provider
        self.codexAccountID = codexAccountID
        self.store = store
        self.latch = latch
        // Starting empty would re-notify for every rule already over its threshold, on every
        // launch. "Once per window" only holds if the latch outlives the process.
        self.policy = latch.load()
    }

    /// Arms the observation. Idempotent — a second call would double every notification.
    func start() {
        guard !started else { return }
        started = true
        observe()
    }

    /// `withObservationTracking` fires ONCE and only for the next change, so each callback has
    /// to re-arm. It also fires on `willSet`, before the new value is readable, which is why the
    /// evaluation is hopped onto the next main-actor turn rather than run inline.
    private func observe() {
        withObservationTracking {
            switch provider {
            case .claudeCode:
                _ = limits.limits
                _ = limits.state
            case .codex: _ = limits.codexLimits
            }
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.observe()
                self.evaluate()
            }
        }
    }

    /// Called after each limits refresh.
    func evaluate() {
        // Fixture data drives every surface in `--demo`, `--snapshot` and the debug control
        // channel. Notifying on invented numbers would be a real notification about nothing.
        guard limits.runMode.isLive else { return }
        guard provider != .claudeCode || limits.state == .ok else { return }

        let settings = store.load()
        guard let alert = policy.alerts(
            for: provider == .claudeCode ? limits.limits : limits.codexLimits,
            accountUuid: provider == .claudeCode
                ? signedIn.identity?.accountUuid
                : codexAccountID(),
            settings: settings,
            provider: provider
        ) else {
            log.debug("evaluate: no threshold crossed; nothing to notify")
            return
        }

        // Only after the latch actually moved: prune the windows that have since reset so the
        // set cannot grow forever, then write it back. Both are the policy's own rules — the
        // driver just picks the moment and reads the clock.
        policy.forget(before: ThresholdAlertPolicy.minute(Date()))
        latch.save(policy)

        Task {
            guard await notifier.requestAuthorization() else {
                log.notice("evaluate: threshold alert suppressed; notification authorization was not granted")
                return
            }
            log.info("evaluate: posting a threshold alert")
            notifier.notifyThresholds(alert, provider: provider)
        }
    }
}
