import Foundation
import TokiLogging

private let log = TokiLog.logger("alerts")

/// Persists the "already notified" latch across launches.
///
/// Modelled on `NotificationSettingsStore`: injected `UserDefaults` so tests never touch the
/// real domain, and an unreadable value costs the user nothing. The failure budget here is
/// deliberately one duplicate notification — a latch that cannot be read or written falls back
/// to an empty policy, which at worst says something the user already heard once. It never
/// throws, and it never touches the settings key, so a corrupt latch cannot cost a setting.
public struct ThresholdAlertLatchStore: @unchecked Sendable {
    private static let key = "toki.notificationLatch"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults) { self.defaults = defaults }

    /// The stored latch, or a fresh empty policy when the key is absent or the bytes do not
    /// decode. Empty means "nothing has been reported yet", so the worst case is one repeat.
    public func load() -> ThresholdAlertPolicy {
        guard let data = defaults.data(forKey: Self.key) else { return ThresholdAlertPolicy() }
        do {
            return try JSONDecoder().decode(ThresholdAlertPolicy.self, from: data)
        } catch {
            log.error("threshold alert latch decode failed, resetting to empty \(error: error)")
            return ThresholdAlertPolicy()
        }
    }

    public func save(_ policy: ThresholdAlertPolicy) {
        let data: Data
        do {
            data = try JSONEncoder().encode(policy)
        } catch {
            log.error("threshold alert latch encode failed \(error: error)")
            return
        }
        defaults.set(data, forKey: Self.key)
    }
}
