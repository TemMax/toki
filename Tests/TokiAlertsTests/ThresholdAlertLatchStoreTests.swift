import Foundation
import Testing
@testable import TokiAlerts
import TokiModels

@Suite("ThresholdAlertLatchStore")
struct ThresholdAlertLatchStoreTests {
    private let now = Date(timeIntervalSince1970: 1_770_000_000)

    private func limits(five: Double, resetsAt: Date? = nil) -> UsageLimits {
        UsageLimits(
            windows: [
                RateLimitWindow(id: "session", title: "5-hour", utilization: five,
                                resetsAt: resetsAt ?? now.addingTimeInterval(3600), isAvailable: true),
            ],
            extra: nil, fetchedAt: now
        )
    }

    /// Stored, not computed: the latch is keyed on the rule's `id`, and a computed property
    /// would mint a fresh `AlertRule` — and therefore a fresh id — on every access.
    private let fiveHourOnly = NotificationSettings(
        rules: [AlertRule(window: .fiveHour, threshold: 0.9)],
        onSwap: true, onAllExhausted: true, onNeedsReauth: true, onNewAccount: true, onServiceStatus: true
    )

    private func makeStore(_ name: String) -> (ThresholdAlertLatchStore, UserDefaults) {
        let defaults = UserDefaults(suiteName: "toki.tests.latch.\(name).\(UUID().uuidString)")!
        return (ThresholdAlertLatchStore(defaults: defaults), defaults)
    }

    /// The reported bug: the user's 7-day window has been at 100% for days, and every launch
    /// built a fresh empty policy, so every launch said "limit reached" again. Restarting the
    /// app is exactly this — save the latch, load it back, evaluate the same window.
    @Test("a fired latch survives a restart and does not notify twice for the same window")
    func survivesRestart() {
        let (store, _) = makeStore("restart")
        let reset = now.addingTimeInterval(3600)

        var beforeQuit = ThresholdAlertPolicy()
        #expect(beforeQuit.alerts(for: limits(five: 1.0, resetsAt: reset),
                                 accountUuid: "a", settings: fiveHourOnly) != nil)
        store.save(beforeQuit)

        var afterLaunch = store.load()
        #expect(afterLaunch.alerts(for: limits(five: 1.0, resetsAt: reset),
                                   accountUuid: "a", settings: fiveHourOnly) == nil,
                "a window already reported before the quit must stay quiet after the relaunch")
    }

    @Test("a first launch, with nothing stored, notifies normally")
    func absentKey() {
        let (store, _) = makeStore("absent")
        var policy = store.load()
        #expect(policy.alerts(for: limits(five: 0.95), accountUuid: "a", settings: fiveHourOnly) != nil)
    }

    /// A corrupt latch costs at most one duplicate notification — never a crash, and never a
    /// silenced alert.
    @Test("corrupt bytes load a working policy instead of throwing")
    func corruptBytes() {
        let (store, defaults) = makeStore("corrupt")
        defaults.set(Data("not json".utf8), forKey: "toki.notificationLatch")

        var policy = store.load()
        #expect(policy.alerts(for: limits(five: 0.95), accountUuid: "a", settings: fiveHourOnly) != nil)
    }

    @Test("the whole latch, not just one entry, round trips through the store")
    func roundTripIsFaithful() {
        let (store, _) = makeStore("faithful")
        var policy = ThresholdAlertPolicy()
        _ = policy.alerts(for: limits(five: 0.95), accountUuid: "a", settings: fiveHourOnly)
        _ = policy.alerts(for: limits(five: 0.95), accountUuid: "b", settings: fiveHourOnly)
        store.save(policy)
        #expect(store.load() == policy)
    }
}

@Suite("ThresholdAlertPolicy.forget")
struct ThresholdAlertPolicyForgetTests {
    private let now = Date(timeIntervalSince1970: 1_770_000_000)

    private func limits(five: Double, resetsAt: Date?) -> UsageLimits {
        UsageLimits(
            windows: [
                RateLimitWindow(id: "session", title: "5-hour", utilization: five,
                                resetsAt: resetsAt, isAvailable: true),
            ],
            extra: nil, fetchedAt: now
        )
    }

    private let fiveHourOnly = NotificationSettings(
        rules: [AlertRule(window: .fiveHour, threshold: 0.9)],
        onSwap: true, onAllExhausted: true, onNeedsReauth: true, onNewAccount: true, onServiceStatus: true
    )

    /// Without pruning the latch grows one entry per rule per window per account, forever.
    /// Dropping a window that has already reset is safe precisely because that window can
    /// never come back — and it is what lets the NEXT window notify.
    @Test("an entry whose window has passed is dropped, so the next window notifies")
    func dropsExpired() {
        var policy = ThresholdAlertPolicy()
        let reset = now.addingTimeInterval(3600)
        #expect(policy.alerts(for: limits(five: 0.95, resetsAt: reset),
                              accountUuid: "a", settings: fiveHourOnly) != nil)

        // An hour and a half later the window is long gone.
        policy.forget(before: ThresholdAlertPolicy.minute(now.addingTimeInterval(5400)))

        let next = now.addingTimeInterval(5400 + 3600)
        #expect(policy.alerts(for: limits(five: 0.95, resetsAt: next),
                              accountUuid: "a", settings: fiveHourOnly) != nil)
    }

    @Test("an entry whose window is still open is kept")
    func keepsLiveWindow() {
        var policy = ThresholdAlertPolicy()
        let reset = now.addingTimeInterval(3600)
        _ = policy.alerts(for: limits(five: 0.95, resetsAt: reset), accountUuid: "a", settings: fiveHourOnly)

        policy.forget(before: ThresholdAlertPolicy.minute(now))

        #expect(policy.alerts(for: limits(five: 0.99, resetsAt: reset),
                              accountUuid: "a", settings: fiveHourOnly) == nil)
    }

    /// A window that reports no reset time has no moment to compare against. There is no
    /// "it has passed" for it, so dropping it would just re-notify.
    @Test("an entry with no reset time is kept, however far the clock is wound on")
    func keepsNilInstance() {
        var policy = ThresholdAlertPolicy()
        #expect(policy.alerts(for: limits(five: 0.95, resetsAt: nil),
                              accountUuid: "a", settings: fiveHourOnly) != nil)

        policy.forget(before: ThresholdAlertPolicy.minute(now.addingTimeInterval(86_400 * 365)))

        #expect(policy.alerts(for: limits(five: 0.99, resetsAt: nil),
                              accountUuid: "a", settings: fiveHourOnly) == nil,
                "a window with no reset time must stay latched, not re-notify")
    }
}
