/// Whether usage in a rate-limit window is running ahead of the clock.
///
/// A bare "60%" says how much is gone, not whether that is a problem. Three days into a
/// seven-day window, even spending would have used 43%; 60% means the limit runs out about
/// two days before the reset. This type answers that, for every surface that shows a gauge.
import Foundation

public struct UsagePace: Equatable, Sendable {
    public enum Verdict: Equatable, Sendable {
        /// Using noticeably less than even spending would.
        case under
        /// Within `tolerance` of even spending.
        case onPace
        /// Using noticeably more: at this rate the limit runs out before the reset.
        case ahead
    }

    /// Share of the window's time already gone, 0…1. Even spending would have used exactly
    /// this much, so it is where the gauge draws its pace mark.
    public let expected: Double
    public let utilization: Double
    public let verdict: Verdict
    /// When usage hits 100% if it keeps its average rate so far. Only set when that happens
    /// before the reset (which is exactly when the verdict is `.ahead`), and not for a window
    /// already at its limit.
    public let projectedExhaustion: Date?

    /// Points of slack either side of even spending before the verdict moves, so a figure
    /// sitting right on the line does not flip back and forth with every poll.
    public static let tolerance = 0.05
    /// No verdict before this share of the window has passed. Extrapolating the first few
    /// minutes of a window turns one long prompt into "runs out in 2 hours".
    public static let minimumElapsed = 0.05

    /// The pace of `utilization` in a window of `duration` that resets at `resetsAt`, or nil
    /// when it cannot be judged: unknown length or reset time, a reset already past, or too
    /// early in the window.
    public init?(utilization: Double, resetsAt: Date?, duration: TimeInterval?, now: Date = Date()) {
        guard let resetsAt, let duration, duration > 0, utilization.isFinite else { return nil }
        let remaining = resetsAt.timeIntervalSince(now)
        guard remaining > 0 else { return nil }
        let elapsedTime = min(duration - remaining, duration)
        let expected = elapsedTime / duration
        guard expected >= Self.minimumElapsed else { return nil }

        let used = min(max(utilization, 0), 1)
        self.expected = expected
        self.utilization = used
        let delta = used - expected
        if delta > Self.tolerance {
            verdict = .ahead
        } else if delta < -Self.tolerance {
            verdict = .under
        } else {
            verdict = .onPace
        }

        if verdict == .ahead, used < 1 {
            let rate = used / elapsedTime
            let exhaustion = now.addingTimeInterval((1 - used) / rate)
            projectedExhaustion = exhaustion < resetsAt ? exhaustion : nil
        } else {
            projectedExhaustion = nil
        }
    }

    /// `"out in ~1d 4h at this pace"`, or nil when the pace is not a problem. Same rounding
    /// as `ResetCountdown`, so the two lines under a gauge read alike.
    public func warningText(now: Date = Date()) -> String? {
        guard verdict == .ahead, let projectedExhaustion else { return nil }
        guard let countdown = ResetCountdown.text(for: projectedExhaustion, now: now) else { return nil }
        let span = countdown.replacingOccurrences(of: "resets ", with: "")
        return span == "now" ? "runs out soon at this pace" : "runs out \(span) at this pace"
    }
}

public extension RateLimitWindow {
    /// How long this window lasts, known from its id: `session` windows are five hours and
    /// weekly ones seven days. nil for anything else (a provider-specific window Toki does
    /// not know the length of), which simply gets no pace.
    var duration: TimeInterval? {
        Self.duration(forId: id)
    }

    static func duration(forId id: String) -> TimeInterval? {
        if id == "session" || id.hasPrefix("session_scoped:") { return 5 * 3600 }
        if id == "weekly_all" || id.hasPrefix("weekly_scoped:") { return 7 * 86400 }
        return nil
    }

    func pace(now: Date = Date()) -> UsagePace? {
        guard isAvailable else { return nil }
        return UsagePace(utilization: utilization, resetsAt: resetsAt, duration: duration, now: now)
    }
}
