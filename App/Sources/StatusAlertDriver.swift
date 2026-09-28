import Foundation
import Observation
import TokiAlerts
import TokiCore

private let log = TokiLog.logger("status")

/// Turns service-status changes into notifications. The sibling of `AlertDriver`, and thin
/// for the same reason: every decision lives in `StatusAlertPolicy`, which is a pure value
/// and therefore testable without `UserNotifications`. This type only reads the current
/// status and posts.
///
/// It OBSERVES `ServiceStatusStore` rather than living inside it — the store is the single
/// owner of the status and must stay something its observers read without side effects. The
/// observation is `withObservationTracking`, not a timer: the store already owns the poll
/// loop, so the driver wakes exactly when a poll lands and never on its own schedule.
@MainActor
final class StatusAlertDriver {
    private let store: ServiceStatusStore
    private let settings: NotificationSettingsStore
    private let latch: StatusAlertLatchStore
    private let provider: UsageProvider
    private let notifier = SwapNotifier()
    private var policy: StatusAlertPolicy
    private var started = false

    init(
        store: ServiceStatusStore,
        settings: NotificationSettingsStore,
        provider: UsageProvider = .claudeCode,
        latch: StatusAlertLatchStore = StatusAlertLatchStore(defaults: .standard)
    ) {
        self.store = store
        self.settings = settings
        self.latch = latch
        self.provider = provider
        // Starting empty would re-announce an incident on every launch for as long as
        // Anthropic's incident lasts. "Once per episode" only holds if the latch outlives
        // the process.
        self.policy = latch.load()
    }

    /// Arms the observation. Idempotent — a second call would double every notification.
    func start() {
        guard !started else { return }
        started = true
        observe()
    }

    /// `withObservationTracking` fires ONCE and only for the next change, so each callback
    /// has to re-arm. It also fires on `willSet`, before the new value is readable, which is
    /// why the evaluation is hopped onto the next main-actor turn rather than run inline.
    private func observe() {
        withObservationTracking {
            _ = store.status
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.observe()
                self.evaluate()
            }
        }
    }

    /// Called after each status change.
    func evaluate() {
        // Fixture data drives every surface in `--demo`, `--snapshot` and the debug control
        // channel. It must not reach the policy at all: latching an invented incident id
        // into the persisted latch would mute the next REAL episode.
        guard store.runMode.isLive else { return }

        guard let event = policy.event(for: store.status) else {
            log.debug("evaluate: status change did not cross a notify-worthy episode boundary")
            return
        }

        // Only after the latch actually moved, so a relaunch mid-incident stays quiet.
        latch.save(policy)

        // The toggle mutes DELIVERY only — the policy above has already tracked the episode.
        // Gating earlier would freeze the latch while the toggle is off, and a muted
        // incident's stale keys would then suppress the next episode's "began", or fire a
        // stray "resolved" for an outage that ended while nobody was listening.
        let loadedSettings = settings.load()
        let isEnabled = provider == .claudeCode
            ? loadedSettings.onServiceStatus
            : loadedSettings.onCodexServiceStatus
        guard isEnabled else {
            log.notice("evaluate: service-status notification suppressed; the user has this notification off")
            return
        }

        Task {
            guard await notifier.requestAuthorization() else {
                log.notice("evaluate: service-status notification suppressed; authorization was not granted")
                return
            }
            log.info("evaluate: posting a service-status notification")
            notifier.notifyServiceStatus(event, provider: provider)
        }
    }
}
