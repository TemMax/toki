/// The auto-swap decision — a pure function so every rule is testable without I/O.
import Foundation

public enum WatchedWindow: String, Equatable, Sendable {
    case fiveHour
    case weekly
}

public struct SwapTrigger: Equatable, Sendable {
    public let window: WatchedWindow
    public let utilization: Double

    public init(window: WatchedWindow, utilization: Double) {
        self.window = window
        self.utilization = utilization
    }
}

public struct AccountSnapshot: Equatable, Sendable {
    public let accountUuid: String
    public let label: String
    /// Utilization in 0…1, or nil when unknown.
    public let fiveHour: Double?
    public let weekly: Double?
    public let isActive: Bool
    public let isHealthy: Bool
    /// True when the last usage poll failed (e.g. a 429) and the numbers are old.
    public let gaugesAreStale: Bool
    /// For the active row, whether the live usage payload names that same account.
    /// Nil means the source did not provide binding metadata.
    public let activeBindingMatches: Bool?

    public init(
        accountUuid: String, label: String, fiveHour: Double?, weekly: Double?,
        isActive: Bool, isHealthy: Bool, gaugesAreStale: Bool,
        activeBindingMatches: Bool? = nil
    ) {
        self.accountUuid = accountUuid
        self.label = label
        self.fiveHour = gaugesAreStale ? nil : fiveHour
        self.weekly = gaugesAreStale ? nil : weekly
        self.isActive = isActive
        self.isHealthy = isHealthy
        self.gaugesAreStale = gaugesAreStale
        self.activeBindingMatches = activeBindingMatches
    }

    func utilization(_ window: WatchedWindow) -> Double? {
        switch window {
        case .fiveHour: return fiveHour
        case .weekly: return weekly
        }
    }

    /// Feeds the signed-in account's live utilization into its snapshot.
    ///
    /// The active account is deliberately never polled per-account — its usage has exactly
    /// one owner, the shared live-limits store the popover, the Usage tab and the Accounts
    /// tab all observe. So the per-account gauge cache the other snapshots come from holds
    /// nothing for it, and a snapshot built straight from that cache reports `nil` for both
    /// windows. `nil` is not "no usage", it is "unknown" — the policy can raise no trigger
    /// from it, which silently disables auto-swap for every account. Callers must apply this
    /// overlay before handing snapshots to `AutoSwapPolicy.decide`.
    ///
    /// Callers must explicitly attest that live limits are fresh. Missing or stale live
    /// limits mark the active account stale and remove their values, so the policy waits
    /// instead of acting on historical percentages.
    public static func withLiveActiveLimits(
        _ snapshots: [AccountSnapshot],
        activeFiveHour: Double?,
        activeWeekly: Double?,
        liveIsFresh: Bool = false,
        liveAccountUuid: String? = nil
    ) -> [AccountSnapshot] {
        snapshots.map { snapshot in
            guard snapshot.isActive else { return snapshot }
            let bindingMatches = liveAccountUuid.map { $0 == snapshot.accountUuid }
            return AccountSnapshot(
                accountUuid: snapshot.accountUuid,
                label: snapshot.label,
                fiveHour: activeFiveHour,
                weekly: activeWeekly,
                isActive: true,
                isHealthy: snapshot.isHealthy,
                gaugesAreStale: !liveIsFresh || (activeFiveHour == nil && activeWeekly == nil)
                    || bindingMatches == false,
                activeBindingMatches: bindingMatches
            )
        }
    }
}

public enum SwapDecision: Equatable, Sendable {
    case doNothing
    case swap(to: String, trigger: SwapTrigger)
    /// Something tripped and no other account is even under its threshold — everyone
    /// genuinely is at their limit. Worth telling the user once.
    case allExhausted(SwapTrigger)
    /// Something tripped and an account cleared every watched threshold, but it was the
    /// *only* thing standing between it and being a candidate was needing a re-login —
    /// distinct from `.allExhausted` because re-authenticating, not waiting, fixes it.
    case needsReauth(SwapTrigger)
}

/// Stable, non-sensitive explanations for every policy exit. Callers can log these without
/// flattening materially different states into a generic "no swap" message.
public enum AutoSwapReason: String, Equatable, Sendable {
    case featureDisabled
    case noActiveAccount
    case activeBindingMismatch
    case activeGaugesStale
    case noWatchedWindows
    case noAlternativeAccount
    case belowThreshold
    case cooldown
    case allCandidatesExhausted
    case candidateNeedsReauth
    case candidateGaugesStale
    case insufficientImprovement
    case swapCandidateSelected
}

public struct AutoSwapPolicyResult: Equatable, Sendable {
    public let decision: SwapDecision
    public let reason: AutoSwapReason

    public init(decision: SwapDecision, reason: AutoSwapReason) {
        self.decision = decision
        self.reason = reason
    }
}

public enum AutoSwapPolicy {
    /// A candidate must be this much better than the active account. Without it, two
    /// accounts hovering at similar utilization would swap back and forth forever.
    public static let hysteresis = 0.15

    public static func decide(
        accounts: [AccountSnapshot],
        settings: AutoSwapSettings,
        now: Date,
        lastSwapAt: Date?
    ) -> SwapDecision {
        evaluate(accounts: accounts, settings: settings, now: now, lastSwapAt: lastSwapAt).decision
    }

    public static func evaluate(
        accounts: [AccountSnapshot],
        settings: AutoSwapSettings,
        now: Date,
        lastSwapAt: Date?
    ) -> AutoSwapPolicyResult {
        func result(_ decision: SwapDecision, _ reason: AutoSwapReason) -> AutoSwapPolicyResult {
            AutoSwapPolicyResult(decision: decision, reason: reason)
        }

        guard settings.enabled else { return result(.doNothing, .featureDisabled) }
        guard let active = accounts.first(where: \.isActive) else {
            return result(.doNothing, .noActiveAccount)
        }
        guard active.activeBindingMatches != false else {
            return result(.doNothing, .activeBindingMismatch)
        }
        // A 429-frozen gauge is exactly what a heavily-used account produces: it can carry
        // an hours-old peak past a window reset. Trusting it would swap the user off an
        // account that already has headroom and burn a healthy candidate's quota instead.
        guard !active.gaugesAreStale else { return result(.doNothing, .activeGaugesStale) }

        let watched = watchedWindows(settings)
        guard !watched.isEmpty else { return result(.doNothing, .noWatchedWindows) }

        // No other stored account to move to. This is not the same claim as "everyone is
        // exhausted" (`.allExhausted`), so it must not fall through to that branch below —
        // the policy owns this outcome rather than relying on the driver's account-count guard.
        guard accounts.contains(where: { !$0.isActive }) else {
            return result(.doNothing, .noAlternativeAccount)
        }

        // Trigger: any watched window of the active account at or above its threshold.
        let triggers = watched.compactMap { window -> SwapTrigger? in
            guard let utilization = active.utilization(window),
                  utilization >= threshold(window, settings)
            else { return nil }
            return SwapTrigger(window: window, utilization: utilization)
        }
        guard let trigger = triggers.max(by: { $0.utilization < $1.utilization }) else {
            return result(.doNothing, .belowThreshold)
        }

        if let lastSwapAt, now.timeIntervalSince(lastSwapAt) < settings.cooldown {
            return result(.doNothing, .cooldown)
        }

        // Accounts that clear every watched window's threshold, independent of health,
        // staleness or hysteresis. Used to separate "nothing is even under the limit"
        // (genuine exhaustion) from "something is under the limit but unusable right now".
        let thresholdClearers = accounts.filter { candidate in
            guard !candidate.isActive else { return false }
            for window in watched {
                guard let utilization = candidate.utilization(window),
                      utilization < threshold(window, settings)
                else { return false }
            }
            return candidate.utilization(trigger.window) != nil
        }
        guard !thresholdClearers.isEmpty else {
            // Stale snapshots intentionally erase their percentages at construction, so
            // they cannot enter `thresholdClearers`. Preserve the conservative exhausted
            // decision, but explain that unknown stale data contributed to it.
            let hasStaleCandidate = accounts.contains { !$0.isActive && $0.gaugesAreStale }
            return result(
                .allExhausted(trigger),
                hasStaleCandidate ? .candidateGaugesStale : .allCandidatesExhausted
            )
        }

        let candidates = thresholdClearers.filter { candidate in
            guard candidate.isHealthy, !candidate.gaugesAreStale else { return false }
            guard let candidateTrigger = candidate.utilization(trigger.window) else { return false }
            return candidateTrigger <= trigger.utilization - hysteresis
        }

        guard let best = candidates.min(by: { worst($0, watched) < worst($1, watched) }) else {
            // Something cleared the threshold but was declined by hysteresis, health or
            // staleness — everyone is not actually at their limit. When re-authenticating
            // (not waiting) would fix it, say so distinctly.
            let onlyBlockedByHealth = thresholdClearers.contains { candidate in
                !candidate.isHealthy && !candidate.gaugesAreStale
                    && (candidate.utilization(trigger.window).map { $0 <= trigger.utilization - hysteresis } ?? false)
            }
            if onlyBlockedByHealth {
                return result(.needsReauth(trigger), .candidateNeedsReauth)
            }
            return result(.doNothing, .insufficientImprovement)
        }
        return result(.swap(to: best.accountUuid, trigger: trigger), .swapCandidateSelected)
    }

    private static func watchedWindows(_ settings: AutoSwapSettings) -> [WatchedWindow] {
        var windows: [WatchedWindow] = []
        if settings.watchFiveHour { windows.append(.fiveHour) }
        if settings.watchWeekly { windows.append(.weekly) }
        return windows
    }

    private static func threshold(_ window: WatchedWindow, _ settings: AutoSwapSettings) -> Double {
        switch window {
        case .fiveHour: return settings.fiveHourThreshold
        case .weekly: return settings.weeklyThreshold
        }
    }

    private static func worst(_ account: AccountSnapshot, _ watched: [WatchedWindow]) -> Double {
        watched.compactMap { account.utilization($0) }.max() ?? 1
    }
}

/// Keeps the "all accounts are at their limit" notification from repeating on every poll.
///
/// It re-arms as soon as anything changes — a swap happened, or some account dropped back
/// below its threshold — so the user is told once per episode rather than every 3 minutes.
public struct ExhaustionLatch: Equatable, Sendable {
    private var notified = false

    public init() {}

    public mutating func shouldNotify(decision: SwapDecision) -> Bool {
        switch decision {
        case .allExhausted:
            guard !notified else { return false }
            notified = true
            return true
        case .doNothing, .swap, .needsReauth:
            notified = false
            return false
        }
    }
}
