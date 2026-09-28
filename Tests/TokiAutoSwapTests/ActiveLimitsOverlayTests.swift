import Testing
import Foundation
@testable import TokiAutoSwap

/// Regression suite for the seam between the app's per-account gauge cache and the policy.
///
/// The active account is deliberately NOT polled per-account (its usage comes from the
/// shared live-limits store, so the popover, the Usage tab and the Accounts tab all move
/// together). That left the policy's snapshot of the active account with `fiveHour == nil`,
/// which silently disabled auto-swap entirely: no trigger can fire from a nil utilization.
/// `AccountSnapshot.withLiveActiveLimits` is what feeds those live numbers back in.
private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

private func account(
    _ uuid: String, fiveHour: Double? = 0.1, weekly: Double? = 0.1,
    active: Bool = false, healthy: Bool = true, stale: Bool = false
) -> AccountSnapshot {
    AccountSnapshot(
        accountUuid: uuid, label: uuid, fiveHour: fiveHour, weekly: weekly,
        isActive: active, isHealthy: healthy, gaugesAreStale: stale
    )
}

private var on: AutoSwapSettings {
    var s = AutoSwapSettings.default
    s.enabled = true
    return s
}

@Suite("AccountSnapshot live-limits overlay")
struct ActiveLimitsOverlayTests {
    @Test("fresh usage from B must not trigger a swap for a row still naming A")
    func foreignUsageCannotTriggerSwap() {
        let rows = AccountSnapshot.withLiveActiveLimits(
            [account("a", active: true), account("b")],
            activeFiveHour: 0.99, activeWeekly: 0.99,
            liveIsFresh: true, liveAccountUuid: "b"
        )
        #expect(rows[0].fiveHour == nil)
        #expect(rows[0].gaugesAreStale)
        #expect(AutoSwapPolicy.decide(accounts: rows, settings: on, now: t0, lastSwapAt: nil) == .doNothing)
    }

    @Test("the active account's nil gauges are replaced by the live limits")
    func overlayFillsActiveAccount() {
        let overlaid = AccountSnapshot.withLiveActiveLimits(
            [account("live", fiveHour: nil, weekly: nil, active: true), account("sleeping")],
            activeFiveHour: 0.98,
            activeWeekly: 0.42,
            liveIsFresh: true
        )

        let active = overlaid.first { $0.isActive }
        #expect(active?.fiveHour == 0.98)
        #expect(active?.weekly == 0.42)
        #expect(active?.gaugesAreStale == false)
    }

    @Test("sleeping stale accounts keep their stale state without cached percentages")
    func overlayKeepsSleepingAccountStale() {
        let overlaid = AccountSnapshot.withLiveActiveLimits(
            [
                account("live", fiveHour: nil, active: true),
                account("sleeping", fiveHour: 0.12, weekly: 0.30, stale: true),
            ],
            activeFiveHour: 0.98,
            activeWeekly: 0.42,
            liveIsFresh: true
        )

        let sleeping = overlaid.first { !$0.isActive }
        #expect(sleeping?.fiveHour == nil)
        #expect(sleeping?.weekly == nil)
        #expect(sleeping?.gaugesAreStale == true)
    }

    @Test("no live limits yet marks the active account stale rather than inventing headroom")
    func overlayWithoutLiveLimitsMarksStale() {
        let overlaid = AccountSnapshot.withLiveActiveLimits(
            [account("live", fiveHour: nil, active: true), account("sleeping")],
            activeFiveHour: nil,
            activeWeekly: nil
        )

        let active = overlaid.first { $0.isActive }
        #expect(active?.fiveHour == nil)
        #expect(active?.gaugesAreStale == true)
        // A stale active account must never trigger a swap — the policy would be acting on
        // numbers it does not have.
        #expect(
            AutoSwapPolicy.decide(accounts: overlaid, settings: on, now: t0, lastSwapAt: nil)
                == .doNothing
        )
    }

    @Test("the real-world case: 98% of the 5-hour window swaps once the live limits are applied")
    func liveLimitsRestoreTheSwapDecision() {
        // Exactly the shipped shape: the active account's per-account gauges are nil because
        // it is never polled per-account, and the live store says it is at 98%.
        let raw = [
            account("active-acct", fiveHour: nil, weekly: nil, active: true),
            account("rested-acct", fiveHour: 0.05, weekly: 0.10),
        ]

        // Before the overlay the policy is blind and does nothing — the shipped bug.
        #expect(
            AutoSwapPolicy.decide(accounts: raw, settings: on, now: t0, lastSwapAt: nil)
                == .doNothing
        )

        let overlaid = AccountSnapshot.withLiveActiveLimits(
            raw, activeFiveHour: 0.98, activeWeekly: 0.42, liveIsFresh: true
        )
        #expect(
            AutoSwapPolicy.decide(accounts: overlaid, settings: on, now: t0, lastSwapAt: nil)
                == .swap(to: "rested-acct", trigger: SwapTrigger(window: .fiveHour, utilization: 0.98))
        )
    }

    @Test("stale live percentages are removed before policy evaluation")
    func staleLiveLimitsCannotTriggerSwap() {
        let overlaid = AccountSnapshot.withLiveActiveLimits(
            [
                account("active-acct", fiveHour: nil, weekly: nil, active: true),
                account("rested-acct", fiveHour: 0.05, weekly: 0.10),
            ],
            activeFiveHour: 0.98,
            activeWeekly: 0.42,
            liveIsFresh: false
        )

        let active = overlaid.first { $0.isActive }
        #expect(active?.fiveHour == nil)
        #expect(active?.weekly == nil)
        #expect(active?.gaugesAreStale == true)
        #expect(
            AutoSwapPolicy.decide(accounts: overlaid, settings: on, now: t0, lastSwapAt: nil)
                == .doNothing
        )
    }

    @Test("a stale sleeping snapshot cannot retain policy-visible percentages")
    func staleSleepingSnapshotHidesCachedLimits() {
        let stale = account("sleeping", fiveHour: 0.95, weekly: 0.85, stale: true)

        #expect(stale.fiveHour == nil)
        #expect(stale.weekly == nil)
        #expect(stale.gaugesAreStale)
    }
}
