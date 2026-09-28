import Testing
import Foundation
@testable import TokiAnalytics

// MARK: - Fixed-timezone fixture

/// Gregorian calendar pinned to GMT — every test in this suite must be independent of the
/// machine's local timezone, matching `StatsHistoryTests`'s convention.
private let gmtCalendar: Calendar = {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "GMT")!
    return cal
}()

private func gmtDate(_ y: Int, _ m: Int, _ d: Int, _ hh: Int = 12) -> Date {
    var comps = DateComponents()
    comps.year = y; comps.month = m; comps.day = d; comps.hour = hh
    return gmtCalendar.date(from: comps)!
}

@Suite("UsageRange")
struct UsageRangeTests {

    // MARK: dateInterval

    @Test("today spans local midnight through now")
    func todayInterval() {
        let now = gmtDate(2026, 8, 11, 15)
        let (start, end) = UsageRange.today.dateInterval(now: now, calendar: gmtCalendar)
        #expect(start == gmtCalendar.startOfDay(for: now))
        #expect(end == now)
    }

    @Test("last7Days spans the 6 preceding local midnights through now — 7 calendar days inclusive")
    func last7DaysInterval() {
        let now = gmtDate(2026, 8, 11, 15)
        let (start, end) = UsageRange.last7Days.dateInterval(now: now, calendar: gmtCalendar)
        #expect(start == gmtCalendar.startOfDay(for: gmtDate(2026, 8, 5)))
        #expect(end == now)
    }

    @Test("last30Days spans the 29 preceding local midnights through now — 30 calendar days inclusive")
    func last30DaysInterval() {
        let now = gmtDate(2026, 8, 11, 15)
        let (start, end) = UsageRange.last30Days.dateInterval(now: now, calendar: gmtCalendar)
        #expect(start == gmtCalendar.startOfDay(for: gmtDate(2026, 7, 13)))
        #expect(end == now)
    }

    @Test("allTime has no lower bound and ends at now")
    func allTimeInterval() {
        let now = gmtDate(2026, 8, 11, 15)
        let (start, end) = UsageRange.allTime.dateInterval(now: now, calendar: gmtCalendar)
        #expect(start == .distantPast)
        #expect(end == now)
    }

    // MARK: Cases

    @Test("allCases is exactly the four ranges, in display order")
    func allCasesOrder() {
        #expect(UsageRange.allCases == [.today, .last7Days, .last30Days, .allTime])
    }

    @Test("rawValue is the display label used by the segmented control")
    func rawValues() {
        #expect(UsageRange.today.rawValue == "Today")
        #expect(UsageRange.last7Days.rawValue == "Last 7 Days")
        #expect(UsageRange.last30Days.rawValue == "Last 30 Days")
        #expect(UsageRange.allTime.rawValue == "All Time")
    }
}
