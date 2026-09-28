/// How long until a rate-limit window clears, worded once for every surface that says it.
///
/// The popover, the Usage strip and the account cards all answer the same question, so the
/// wording lives here rather than being re-implemented per view — a percentage without a
/// reset time is not actionable, and two surfaces phrasing it differently is worse than one.
import Foundation

public enum ResetCountdown {

    /// `"resets in ~2h 29m"`, `"resets in ~14m"`, `"resets in ~4d 17h"`, or `"resets now"`
    /// once the window has elapsed. Returns nil for an unknown reset time: no text at all
    /// beats inventing one, the same way a nil utilization means *unknown*, never *zero*.
    ///
    /// Past a day, minutes are dropped: a weekly window's countdown doesn't need
    /// minute-level precision, and showing all three units ("~4d 17h 22m") is noise, not
    /// information. Below a day, hours+minutes (or minutes alone) is exactly the precision
    /// people act on — never three units at once.
    public static func text(for date: Date?, now: Date = Date()) -> String? {
        guard let date else { return nil }
        let remaining = date.timeIntervalSince(now)
        // Under a minute counts as now. Integer-dividing 30 seconds by 60 gives 0, so the
        // sub-minute range used to render "resets in ~0m" — a countdown to zero that still
        // says "in", which reads as broken rather than imminent.
        guard remaining >= 60 else { return "resets now" }

        guard remaining >= 3600 else {
            let minutes = Int(remaining / 60)
            return "resets in ~\(minutes)m"
        }

        guard remaining >= 86400 else {
            let hours = Int(remaining / 3600)
            let minutes = Int(remaining.truncatingRemainder(dividingBy: 3600) / 60)
            return "resets in ~\(hours)h \(minutes)m"
        }

        let days = Int(remaining / 86400)
        let hours = Int(remaining.truncatingRemainder(dividingBy: 86400) / 3600)
        return "resets in ~\(days)d \(hours)h"
    }
}
