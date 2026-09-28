/// User-configurable auto-swap behaviour.
import Foundation

/// Off by default: swapping the user's account without being asked is only acceptable
/// when they have explicitly said "don't let my agents stall".
public struct AutoSwapSettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var watchFiveHour: Bool
    /// Utilization in 0…1 at or above which the 5-hour window triggers a swap.
    public var fiveHourThreshold: Double
    public var watchWeekly: Bool
    public var weeklyThreshold: Double
    public var cooldown: TimeInterval

    public init(
        enabled: Bool, watchFiveHour: Bool, fiveHourThreshold: Double,
        watchWeekly: Bool, weeklyThreshold: Double, cooldown: TimeInterval
    ) {
        self.enabled = enabled
        self.watchFiveHour = watchFiveHour
        self.fiveHourThreshold = fiveHourThreshold
        self.watchWeekly = watchWeekly
        self.weeklyThreshold = weeklyThreshold
        self.cooldown = cooldown
    }

    /// Whether a swap announces itself is NOT here: every notification Toki sends is gated by
    /// `NotificationSettings` in `TokiAlerts`, so there is exactly one place a notification is
    /// switched on or off.
    public static let `default` = AutoSwapSettings(
        enabled: false, watchFiveHour: true, fiveHourThreshold: 0.9,
        watchWeekly: false, weeklyThreshold: 0.9, cooldown: 600
    )
}
