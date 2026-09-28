/// UsageRange — the Usage tab's time-range selector, and the one place that decides which
/// data source answers each range.
///
/// Two sources back the Usage tab and they do NOT hold the same things (see
/// `StatsHistory.swift`'s doc comment):
///  - the live transcript index (`RecordProviding` / `AnalyticsService`) holds cost, per-model
///    and per-project breakdowns for whatever transcript files are still on disk;
///  - the durable `StatsRollup` holds only per-day token/request totals, bucketed by hour, but
///    survives transcript cleanup and is the only source with real calendar history.
///
/// So the summary cards / By Model / Top Projects can only ever come from the index, and the
/// activity heatmap / streak tiles / punchcard can only ever come from the rollup — regardless
/// of which range is selected. The range therefore controls only the index-backed period; the
/// rollup-backed calendar history is all-time by nature and is shown on every range, under
/// its own "All-time statistics" header (see `DashboardContent.statisticsSection` in the app).
import Foundation

public enum UsageRange: String, CaseIterable, Sendable {
    case today      = "Today"
    case last7Days  = "Last 7 Days"
    case last30Days = "Last 30 Days"
    case allTime    = "All Time"

    /// Returns the inclusive `[start, end]` window this range covers, relative to `now`.
    /// `calendar`/`now` are parameters (not implicit `Date()`/`Calendar.current` reads) so the
    /// rule is exercised deterministically in tests.
    public func dateInterval(now: Date = Date(), calendar: Calendar = .current) -> (start: Date, end: Date) {
        switch self {
        case .today:
            return (calendar.startOfDay(for: now), now)
        case .last7Days:
            let start = calendar.startOfDay(
                for: calendar.date(byAdding: .day, value: -6, to: now) ?? now
            )
            return (start, now)
        case .last30Days:
            let start = calendar.startOfDay(
                for: calendar.date(byAdding: .day, value: -29, to: now) ?? now
            )
            return (start, now)
        case .allTime:
            // No lower bound: the index has no retention/cleanup path of its own (it only
            // ever INSERT OR REPLACEs — see the divergence doc), so "all time" really does
            // mean everything it still holds.
            return (.distantPast, now)
        }
    }
}
