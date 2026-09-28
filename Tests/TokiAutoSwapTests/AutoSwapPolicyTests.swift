import Testing
import Foundation
@testable import TokiAutoSwap

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

@Suite("AutoSwapPolicy")
struct AutoSwapPolicyTests {

    @Test("diagnostics distinguish missing, stale, below-threshold, cooldown and hysteresis rejections")
    func distinctDiagnosticReasons() {
        let cases: [(AutoSwapPolicyResult, AutoSwapReason)] = [
            (AutoSwapPolicy.evaluate(accounts: [account("a"), account("b")], settings: on, now: t0, lastSwapAt: nil), .noActiveAccount),
            (AutoSwapPolicy.evaluate(accounts: AccountSnapshot.withLiveActiveLimits([account("a", active: true), account("b")], activeFiveHour: 0.99, activeWeekly: 0.1, liveIsFresh: true, liveAccountUuid: "b"), settings: on, now: t0, lastSwapAt: nil), .activeBindingMismatch),
            (AutoSwapPolicy.evaluate(accounts: [account("a", fiveHour: 0.99, active: true, stale: true), account("b")], settings: on, now: t0, lastSwapAt: nil), .activeGaugesStale),
            (AutoSwapPolicy.evaluate(accounts: [account("a", fiveHour: 0.20, active: true), account("b")], settings: on, now: t0, lastSwapAt: nil), .belowThreshold),
            (AutoSwapPolicy.evaluate(accounts: [account("a", fiveHour: 0.99, active: true), account("b")], settings: on, now: t0, lastSwapAt: t0.addingTimeInterval(-1)), .cooldown),
            (AutoSwapPolicy.evaluate(accounts: [account("a", fiveHour: 0.92, active: true), account("b", fiveHour: 0.85)], settings: on, now: t0, lastSwapAt: nil), .insufficientImprovement),
        ]

        for (result, reason) in cases {
            #expect(result.decision == .doNothing)
            #expect(result.reason == reason)
        }
    }

    @Test("diagnostics preserve the public decision for actionable outcomes")
    func actionableDiagnosticReasons() {
        let swap = AutoSwapPolicy.evaluate(
            accounts: [account("a", fiveHour: 0.99, active: true), account("b", fiveHour: 0.01)],
            settings: on, now: t0, lastSwapAt: nil
        )
        #expect(swap.decision == .swap(to: "b", trigger: SwapTrigger(window: .fiveHour, utilization: 0.99)))
        #expect(swap.reason == .swapCandidateSelected)

        let exhausted = AutoSwapPolicy.evaluate(
            accounts: [account("a", fiveHour: 0.99, active: true), account("b", fiveHour: 0.95)],
            settings: on, now: t0, lastSwapAt: nil
        )
        #expect(exhausted.reason == .allCandidatesExhausted)
    }

    @Test("stale candidate headroom keeps exhausted decision but reports stale diagnostics")
    func staleCandidateDiagnostic() {
        let result = AutoSwapPolicy.evaluate(
            accounts: [
                account("a", fiveHour: 0.99, active: true),
                account("b", fiveHour: 0.05, stale: true),
            ],
            settings: on, now: t0, lastSwapAt: nil
        )

        #expect(result.decision == .allExhausted(SwapTrigger(window: .fiveHour, utilization: 0.99)))
        #expect(result.reason == .candidateGaugesStale)
    }

    @Test("does nothing while the feature is off")
    func disabledDoesNothing() {
        #expect(
            AutoSwapPolicy.decide(
                accounts: [account("a", fiveHour: 0.99, active: true), account("b")],
                settings: .default, now: t0, lastSwapAt: nil
            ) == .doNothing
        )
    }

    @Test("swaps to the account with the most headroom when the 5-hour window trips")
    func swapsOnFiveHourThreshold() {
        let decision = AutoSwapPolicy.decide(
            accounts: [
                account("a", fiveHour: 0.95, active: true),
                account("b", fiveHour: 0.60),
                account("c", fiveHour: 0.10),
            ],
            settings: on, now: t0, lastSwapAt: nil
        )
        #expect(decision == .swap(to: "c", trigger: SwapTrigger(window: .fiveHour, utilization: 0.95)))
    }

    @Test("an unwatched window never triggers a swap")
    func unwatchedWindowIsIgnored() {
        // Weekly is off by default: a full weekly window must not move the user.
        #expect(
            AutoSwapPolicy.decide(
                accounts: [account("a", fiveHour: 0.1, weekly: 0.99, active: true), account("b")],
                settings: on, now: t0, lastSwapAt: nil
            ) == .doNothing
        )
    }

    @Test("when both windows are watched a candidate must satisfy both")
    func candidateMustSatisfyEveryWatchedWindow() {
        var settings = on
        settings.watchWeekly = true
        // b has 5-hour headroom but its weekly window is over the threshold, so moving
        // there would just stall again.
        let decision = AutoSwapPolicy.decide(
            accounts: [
                account("a", fiveHour: 0.95, weekly: 0.2, active: true),
                account("b", fiveHour: 0.05, weekly: 0.97),
                account("c", fiveHour: 0.30, weekly: 0.30),
            ],
            settings: settings, now: t0, lastSwapAt: nil
        )
        #expect(decision == .swap(to: "c", trigger: SwapTrigger(window: .fiveHour, utilization: 0.95)))
    }

    @Test("a marginally better account does not qualify — hysteresis stops ping-pong")
    func hysteresisPreventsPingPong() {
        // b clears the 5-hour threshold (0.85 < 0.9) but not by enough margin to be worth
        // moving to — this is NOT the same as every account being genuinely exhausted
        // (F12), so the right outcome is `.doNothing`, not `.allExhausted`.
        #expect(
            AutoSwapPolicy.decide(
                accounts: [account("a", fiveHour: 0.92, active: true), account("b", fiveHour: 0.85)],
                settings: on, now: t0, lastSwapAt: nil
            ) == .doNothing
        )
    }

    @Test("the cooldown suppresses a second swap")
    func cooldownSuppresses() {
        #expect(
            AutoSwapPolicy.decide(
                accounts: [account("a", fiveHour: 0.99, active: true), account("b", fiveHour: 0.01)],
                settings: on, now: t0, lastSwapAt: t0.addingTimeInterval(-60)
            ) == .doNothing
        )
    }

    @Test("unhealthy and stale-gauge accounts are not swap candidates")
    func excludesUnusableCandidates() {
        // Unknown headroom must never be guessed at, and an account needing a re-login
        // would strand the user mid-session. b has plenty of headroom (0.01) and clears
        // the threshold, but is unhealthy; that is a `.needsReauth` case (F12), not
        // `.allExhausted` — the account is not at its limit, it just needs a re-login.
        #expect(
            AutoSwapPolicy.decide(
                accounts: [
                    account("a", fiveHour: 0.99, active: true),
                    account("b", fiveHour: 0.01, healthy: false),
                    account("c", fiveHour: 0.01, stale: true),
                ],
                settings: on, now: t0, lastSwapAt: nil
            ) == .needsReauth(SwapTrigger(window: .fiveHour, utilization: 0.99))
        )
    }

    @Test("no candidate clears the threshold at all — genuinely exhausted")
    func allExhaustedWhenNoCandidateClearsThreshold() {
        // Both other accounts are over the 5-hour threshold too, so there is truly nowhere
        // better to move to — unlike excludesUnusableCandidates, health/staleness are not
        // even the deciding factor here.
        #expect(
            AutoSwapPolicy.decide(
                accounts: [
                    account("a", fiveHour: 0.99, active: true),
                    account("b", fiveHour: 0.95),
                    account("c", fiveHour: 0.92),
                ],
                settings: on, now: t0, lastSwapAt: nil
            ) == .allExhausted(SwapTrigger(window: .fiveHour, utilization: 0.99))
        )
    }

    @Test("with no active account there is nothing to swap away from")
    func noActiveAccount() {
        #expect(
            AutoSwapPolicy.decide(
                accounts: [account("a"), account("b")], settings: on, now: t0, lastSwapAt: nil
            ) == .doNothing
        )
    }

    @Test("a stale active gauge never triggers a swap (F11)")
    func staleActiveGaugeDoesNothing() {
        // A 429-frozen gauge on the active account can carry an hours-old peak past a
        // window reset. Trusting it would swap the user off an account that may already
        // have full headroom and burn a healthy candidate's quota instead.
        #expect(
            AutoSwapPolicy.decide(
                accounts: [
                    account("a", fiveHour: 0.99, active: true, stale: true),
                    account("b", fiveHour: 0.01),
                ],
                settings: on, now: t0, lastSwapAt: nil
            ) == .doNothing
        )
    }

    @Test("a single stored account is `.doNothing`, not `.allExhausted` (F12)")
    func singleAccountDoesNothing() {
        // The policy must own this outcome rather than depend on the driver's
        // accounts.count > 1 guard — there genuinely is no candidate, but that is a
        // different claim from "every other account is at its limit too".
        #expect(
            AutoSwapPolicy.decide(
                accounts: [account("a", fiveHour: 0.99, active: true)],
                settings: on, now: t0, lastSwapAt: nil
            ) == .doNothing
        )
    }
}
