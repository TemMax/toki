/// StatuslineRateLimits — the usage Claude Code hands its status line command.
import Foundation
import TokiModels

/// The `rate_limits` Claude Code passes to a status line command on stdin.
///
/// Claude Code fills it from the headers of its own API responses and re-runs the status
/// line on every new assistant message, so while it is in use this is the freshest usage
/// there is — no Keychain, no polling, no rate-limited endpoint. It carries only the 5-hour
/// and 7-day windows and no account identity; everything else still comes from the poll.
public struct StatuslineRateLimits: Sendable, Equatable {
    public struct Window: Sendable, Equatable {
        /// Fraction in [0, 1].
        public let utilization: Double
        public let resetsAt: Date

        public init(utilization: Double, resetsAt: Date) {
            self.utilization = utilization
            self.resetsAt = resetsAt
        }
    }

    public let fiveHour: Window?
    public let sevenDay: Window?
    /// When Claude Code last ran the status line — the file's modification time.
    public let observedAt: Date

    /// Two reset instants this close name the same window. Real ones are hours apart (5-hour)
    /// or fixed for the week per account (7-day), so the margin only absorbs rounding.
    static let sameWindowTolerance: TimeInterval = 15 * 60

    public init(fiveHour: Window?, sevenDay: Window?, observedAt: Date) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.observedAt = observedAt
    }

    /// Nil for anything that carries no usage — which includes every update before the
    /// session's first API response, when Claude Code omits `rate_limits` entirely.
    public static func parse(_ data: Data, observedAt: Date) -> StatuslineRateLimits? {
        // no-log: the tap records whatever Claude Code sends; an unreadable update is simply
        // skipped and the next one replaces it.
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let limits = root["rate_limits"] as? [String: Any] else { return nil }
        let fiveHour = window(limits["five_hour"])
        let sevenDay = window(limits["seven_day"])
        guard fiveHour != nil || sevenDay != nil else { return nil }
        return StatuslineRateLimits(fiveHour: fiveHour, sevenDay: sevenDay, observedAt: observedAt)
    }

    private static func window(_ value: Any?) -> Window? {
        guard let object = value as? [String: Any],
              let percent = (object["used_percentage"] as? NSNumber)?.doubleValue,
              let resetsAt = (object["resets_at"] as? NSNumber)?.doubleValue,
              percent.isFinite, resetsAt.isFinite else { return nil }
        return Window(
            utilization: min(max(percent / 100, 0), 1),
            resetsAt: Date(timeIntervalSince1970: resetsAt)
        )
    }

    /// `current` with its 5-hour and 7-day gauges brought up to this sample, or nil when the
    /// sample must not touch it.
    ///
    /// - Only a sample newer than `current` counts.
    /// - The payload names no account, so the 7-day reset instant — fixed for the week per
    ///   account — must match `current`'s. A session still on another account (or a week that
    ///   has just rolled over) waits for the next poll instead of painting the wrong gauges.
    /// - Usage inside one window only grows, so the higher reading wins: another session
    ///   redrawing with older headers cannot pull a gauge back.
    public func merged(into current: UsageLimits) -> UsageLimits? {
        guard observedAt > current.fetchedAt,
              let sevenDay,
              let polledWeek = current.windows.first(where: { $0.id == "weekly_all" }),
              let polledWeekReset = polledWeek.resetsAt,
              Self.isSameWindow(sevenDay.resetsAt, polledWeekReset) else { return nil }

        var windows = current.windows.map { window -> RateLimitWindow in
            switch window.id {
            case "weekly_all":
                return window.with(utilization: max(window.utilization, sevenDay.utilization),
                                   resetsAt: sevenDay.resetsAt)
            case "session":
                return fiveHour.map { Self.advance(window, to: $0) } ?? window
            default:
                return window
            }
        }
        if let fiveHour, !windows.contains(where: { $0.id == "session" }) {
            windows.insert(RateLimitWindow(id: "session", title: "5-hour", utilization: fiveHour.utilization,
                                           resetsAt: fiveHour.resetsAt, isAvailable: true), at: 0)
        }
        return UsageLimits(
            windows: windows,
            extra: current.extra,
            fetchedAt: observedAt,
            account: current.account,
            bankedResets: current.bankedResets,
            claudeResets: current.claudeResets
        )
    }

    private static func advance(_ window: RateLimitWindow, to sample: Window) -> RateLimitWindow {
        guard let polledReset = window.resetsAt else {
            // An inactive window has just been started by the usage this sample reports.
            return window.with(utilization: sample.utilization, resetsAt: sample.resetsAt)
        }
        if isSameWindow(sample.resetsAt, polledReset) {
            return window.with(utilization: max(window.utilization, sample.utilization), resetsAt: polledReset)
        }
        return sample.resetsAt > polledReset
            ? window.with(utilization: sample.utilization, resetsAt: sample.resetsAt)
            : window
    }

    private static func isSameWindow(_ lhs: Date, _ rhs: Date) -> Bool {
        abs(lhs.timeIntervalSince(rhs)) <= sameWindowTolerance
    }
}

private extension RateLimitWindow {
    func with(utilization: Double, resetsAt: Date) -> RateLimitWindow {
        RateLimitWindow(id: id, title: title, utilization: utilization, resetsAt: resetsAt, isAvailable: true)
    }
}
