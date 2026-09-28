import Foundation

public extension AutoSwapSettings {
    /// On, but with nothing to watch: no window means no threshold, so the policy can never
    /// produce a trigger and the feature is disarmed while its switch reads as armed. The
    /// settings UI has to say so — the user cannot see it any other way.
    var isSilentlyDisarmed: Bool { enabled && !watchFiveHour && !watchWeekly }
}
