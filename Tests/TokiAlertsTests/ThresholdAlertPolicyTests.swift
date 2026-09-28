import Foundation
import Testing
@testable import TokiAlerts
import TokiModels

@Suite("ThresholdAlertPolicy")
struct ThresholdAlertPolicyTests {
    private let now = Date(timeIntervalSince1970: 1_770_000_000)

    private func limits(five: Double, weekly: Double = 0, resetsAt: Date? = nil) -> UsageLimits {
        UsageLimits(
            windows: [
                RateLimitWindow(id: "session", title: "5-hour", utilization: five,
                                resetsAt: resetsAt ?? now.addingTimeInterval(3600), isAvailable: true),
                RateLimitWindow(id: "weekly_all", title: "7-day", utilization: weekly,
                                resetsAt: resetsAt ?? now.addingTimeInterval(86400), isAvailable: true),
            ],
            extra: nil, fetchedAt: now
        )
    }

    /// Stored, not computed: every access to a computed property would mint a fresh
    /// `AlertRule` with a new `id`, and the latch is keyed on that id — so the policy would
    /// look un-latched to a test that meant to hand it the same rule twice. The real caller
    /// decodes the same stored rules on every evaluation, which is what this models.
    private let fiveHourOnly = NotificationSettings(
        rules: [AlertRule(window: .fiveHour, threshold: 0.9)],
        onSwap: true, onAllExhausted: true, onNeedsReauth: true, onNewAccount: true, onServiceStatus: true
    )

    @Test("below the threshold says nothing")
    func belowThreshold() {
        var policy = ThresholdAlertPolicy()
        #expect(policy.alerts(for: limits(five: 0.5), accountUuid: "a", settings: fiveHourOnly) == nil)
    }

    @Test("fires once, then stays quiet while still above the threshold")
    func firesOnce() {
        var policy = ThresholdAlertPolicy()
        let first = policy.alerts(for: limits(five: 0.91), accountUuid: "a", settings: fiveHourOnly)
        #expect(first?.entries.count == 1)
        #expect(first?.entries.first?.title == "5-hour")
        #expect(policy.alerts(for: limits(five: 0.95), accountUuid: "a", settings: fiveHourOnly) == nil)
    }

    /// The Mac slept through the crossing and woke up already past the threshold. A detector
    /// that looked for a crossing would never fire at all.
    @Test("fires for a crossing it never observed")
    func firesAfterMissedCrossing() {
        var policy = ThresholdAlertPolicy()
        #expect(policy.alerts(for: limits(five: 0.99), accountUuid: "a", settings: fiveHourOnly) != nil)
    }

    /// The bug this feature shipped with, reproduced from live data.
    ///
    /// The API's `resets_at` carries fractional seconds that move between responses for the
    /// same window — a 5-hour window reported `…400.511091` and then `…400.775991` 32 seconds
    /// later. Keyed on `Date` equality that minted a fresh latch key every poll, so the user
    /// got a notification on every percentage change instead of one per window.
    @Test("sub-second drift in the reset time is not a new window")
    func subSecondDriftDoesNotReArm() {
        var policy = ThresholdAlertPolicy()
        let boundary = Date(timeIntervalSinceReferenceDate: 808_250_400)
        let first = boundary.addingTimeInterval(0.511091)
        let second = boundary.addingTimeInterval(0.775991)

        #expect(policy.alerts(for: limits(five: 0.91, resetsAt: first),
                              accountUuid: "a", settings: fiveHourOnly) != nil)
        #expect(policy.alerts(for: limits(five: 0.99, resetsAt: second),
                              accountUuid: "a", settings: fiveHourOnly) == nil,
                "the same window drifting by a fraction of a second must not notify again")
    }

    /// Same guarantee a little wider: a server that shifts the instant by a couple of seconds
    /// has not reset the window either.
    @Test("a few seconds of jitter is not a new window")
    func secondsJitterDoesNotReArm() {
        var policy = ThresholdAlertPolicy()
        let boundary = Date(timeIntervalSinceReferenceDate: 808_250_400)
        _ = policy.alerts(for: limits(five: 0.91, resetsAt: boundary),
                          accountUuid: "a", settings: fiveHourOnly)
        #expect(policy.alerts(for: limits(five: 0.95, resetsAt: boundary.addingTimeInterval(2)),
                              accountUuid: "a", settings: fiveHourOnly) == nil)
    }

    @Test("re-arms when the window resets")
    func reArmsOnReset() {
        var policy = ThresholdAlertPolicy()
        let old = now.addingTimeInterval(3600)
        _ = policy.alerts(for: limits(five: 0.91, resetsAt: old), accountUuid: "a", settings: fiveHourOnly)
        let next = now.addingTimeInterval(3600 + 5 * 3600)
        #expect(policy.alerts(for: limits(five: 0.92, resetsAt: next), accountUuid: "a", settings: fiveHourOnly) != nil)
    }

    @Test("re-arms when the active account changes")
    func reArmsOnAccountSwitch() {
        var policy = ThresholdAlertPolicy()
        _ = policy.alerts(for: limits(five: 0.91), accountUuid: "a", settings: fiveHourOnly)
        #expect(policy.alerts(for: limits(five: 0.93), accountUuid: "b", settings: fiveHourOnly) != nil)
    }

    @Test("rules that trip together produce ONE alert, not one each")
    func coalesces() {
        var policy = ThresholdAlertPolicy()
        let both = NotificationSettings(
            rules: [AlertRule(window: .fiveHour, threshold: 0.9), AlertRule(window: .sevenDay, threshold: 0.9)],
            onSwap: true, onAllExhausted: true, onNeedsReauth: true, onNewAccount: true, onServiceStatus: true
        )
        let alert = policy.alerts(for: limits(five: 0.91, weekly: 0.95), accountUuid: "a", settings: both)
        #expect(alert?.entries.count == 2)
    }

    @Test("a disabled rule never fires")
    func disabledRule() {
        var policy = ThresholdAlertPolicy()
        let off = NotificationSettings(rules: [AlertRule(window: .fiveHour, threshold: 0.9, isEnabled: false)],
                                       onSwap: true, onAllExhausted: true, onNeedsReauth: true, onNewAccount: true, onServiceStatus: true)
        #expect(policy.alerts(for: limits(five: 0.99), accountUuid: "a", settings: off) == nil)
    }

    @Test("no limits yet is not treated as zero usage")
    func noLimits() {
        var policy = ThresholdAlertPolicy()
        #expect(policy.alerts(for: nil, accountUuid: "a", settings: fiveHourOnly) == nil)
    }
}
