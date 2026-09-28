import Testing
import Foundation
import TokiModels
@testable import TokiAnalytics

// MARK: - Fixed-timezone fixture

/// Gregorian calendar pinned to GMT — every test in this suite must be independent of the
/// machine's local timezone.
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

/// A RollupDay with all activity in hour 0, for tests that only care about active/inactive.
private func activeDay(_ key: String, tokens: Int = 10, requests: Int = 1) -> RollupDay {
    var hours = Array(repeating: 0, count: 24)
    hours[0] = tokens
    return RollupDay(day: key, tokensByHour: hours, requests: requests)
}

private func rollup(_ days: [RollupDay]) -> StatsRollup {
    StatsRollup(schemaVersion: 1, days: Dictionary(uniqueKeysWithValues: days.map { ($0.day, $0) }))
}

@Suite("StatsHistory")
struct StatsHistoryTests {

    // MARK: 5. Heatmap grid shape

    @Test("heatmap is exactly 53 columns x 7 rows; today lands at [last column][its weekday row]; later cells are nil")
    func heatmapGridShape() {
        // Wednesday, so Thu/Fri/Sat/Sun of the same week are still in the future.
        let today = gmtDate(2026, 8, 5) // Wednesday
        let history = StatsHistory(rollup: .empty, today: today, calendar: gmtCalendar)

        #expect(history.heatmapWeeks.count == 53)
        for column in history.heatmapWeeks {
            #expect(column.count == 7)
        }

        let lastColumn = history.heatmapWeeks[52]
        // Monday(0)=Aug3, Tue(1)=Aug4, Wed(2)=Aug5 (today), Thu..Sun(3...6) are after today.
        #expect(lastColumn[0]?.date == gmtCalendar.startOfDay(for: gmtDate(2026, 8, 3)))
        #expect(lastColumn[1]?.date == gmtCalendar.startOfDay(for: gmtDate(2026, 8, 4)))
        #expect(lastColumn[2]?.date == gmtCalendar.startOfDay(for: gmtDate(2026, 8, 5)))
        #expect(lastColumn[3] == nil)
        #expect(lastColumn[4] == nil)
        #expect(lastColumn[5] == nil)
        #expect(lastColumn[6] == nil)

        // No-data cells are present (not nil) with zero tokens/level.
        let mondayCell = try! #require(lastColumn[0])
        #expect(mondayCell.tokens == 0)
        #expect(mondayCell.requests == 0)
        #expect(mondayCell.level == 0)
    }

    @Test("the grid's first column starts on the Monday 52 weeks before the current week's Monday")
    func gridSpanStartsAtFirstMonday() {
        let today = gmtDate(2026, 8, 5) // Wednesday; current-week Monday = Aug 3, 2026
        let history = StatsHistory(rollup: .empty, today: today, calendar: gmtCalendar)

        let firstColumn = history.heatmapWeeks[0]
        #expect(firstColumn[0]?.date == gmtCalendar.startOfDay(for: gmtDate(2025, 8, 4)))
        // Every row in every column is Monday-aligned: row N's weekday is N days after row 0.
        for n in 1..<7 {
            let expected = gmtCalendar.date(byAdding: .day, value: n, to: gmtDate(2025, 8, 4))!
            #expect(firstColumn[n]?.date == gmtCalendar.startOfDay(for: expected))
        }
    }

    // MARK: 6. Levels — nearest-rank quartiles

    @Test("levels follow the nearest-rank quartile formula over nonzero grid values")
    func levelsFollowNearestRankQuartiles() {
        // Today = Sunday, so the entire last week (Mon..Sun) is <= today.
        let today = gmtDate(2026, 8, 9) // Sunday
        let days: [RollupDay] = [
            RollupDay(day: "2026-08-03", tokensByHour: hourZero(10), requests: 1),
            RollupDay(day: "2026-08-04", tokensByHour: hourZero(20), requests: 1),
            RollupDay(day: "2026-08-05", tokensByHour: hourZero(30), requests: 1),
            RollupDay(day: "2026-08-06", tokensByHour: hourZero(40), requests: 1),
            RollupDay(day: "2026-08-07", tokensByHour: hourZero(50), requests: 1),
            RollupDay(day: "2026-08-08", tokensByHour: hourZero(60), requests: 1),
            RollupDay(day: "2026-08-09", tokensByHour: hourZero(70), requests: 1),
        ]
        let history = StatsHistory(rollup: rollup(days), today: today, calendar: gmtCalendar)

        // Hand-applied nearest-rank formula over [10,20,30,40,50,60,70] (n=7):
        // q(p) = value[max(0, ceil(n*p)) - 1]
        // q25 = value[ceil(1.75)-1] = value[1] = 20
        // q50 = value[ceil(3.5)-1]  = value[3] = 40
        // q75 = value[ceil(5.25)-1] = value[5] = 60
        let lastColumn = history.heatmapWeeks[52]
        let levelsByTokens = Dictionary(uniqueKeysWithValues: lastColumn.compactMap { cell -> (Int, Int)? in
            guard let cell else { return nil }
            return (cell.tokens, cell.level)
        })

        #expect(levelsByTokens[10] == 1)
        #expect(levelsByTokens[20] == 1)
        #expect(levelsByTokens[30] == 2)
        #expect(levelsByTokens[40] == 2)
        #expect(levelsByTokens[50] == 3)
        #expect(levelsByTokens[60] == 3)
        #expect(levelsByTokens[70] == 4)
    }

    @Test("a zero-token cell always has level 0, regardless of the surrounding distribution")
    func zeroTokensAlwaysLevelZero() {
        let today = gmtDate(2026, 8, 9)
        let days: [RollupDay] = [
            RollupDay(day: "2026-08-03", tokensByHour: hourZero(100), requests: 1),
        ]
        let history = StatsHistory(rollup: rollup(days), today: today, calendar: gmtCalendar)
        let lastColumn = history.heatmapWeeks[52]
        // 2026-08-04 has no data.
        let empty = try! #require(lastColumn[1])
        #expect(empty.tokens == 0)
        #expect(empty.level == 0)
    }

    // MARK: 7. Streaks

    @Test("a gap breaks the run, but longestStreak still reflects the longest run in history")
    func gapBreaksLongestStreak() {
        let today = gmtDate(2026, 8, 20) // far from any active day; today & yesterday inactive
        let days = [
            activeDay("2026-08-01"), activeDay("2026-08-02"), activeDay("2026-08-03"), // 3-day run
            // gap on 2026-08-04
            activeDay("2026-08-05"), // isolated 1-day run
        ]
        let history = StatsHistory(rollup: rollup(days), today: today, calendar: gmtCalendar)

        #expect(history.longestStreak == 3)
        #expect(history.currentStreak == 0)
    }

    @Test("currentStreak counts the run ending yesterday when today is inactive")
    func currentStreakCountsRunEndingYesterday() {
        let today = gmtDate(2026, 8, 10) // inactive
        let days = [
            activeDay("2026-08-08"), activeDay("2026-08-09"), // run ends yesterday (Aug 9)
        ]
        let history = StatsHistory(rollup: rollup(days), today: today, calendar: gmtCalendar)

        #expect(history.currentStreak == 2)
        #expect(history.longestStreak == 2)
    }

    @Test("currentStreak is 0 when both today and yesterday are inactive")
    func currentStreakZeroWhenBothInactive() {
        let today = gmtDate(2026, 8, 10)
        let days = [
            activeDay("2026-08-01"), // active, but far in the past — neither today nor yesterday
        ]
        let history = StatsHistory(rollup: rollup(days), today: today, calendar: gmtCalendar)

        #expect(history.currentStreak == 0)
        #expect(history.longestStreak == 1)
    }

    @Test("a single active day (which is today) gives both streaks == 1")
    func singleActiveDayGivesStreakOne() {
        let today = gmtDate(2026, 8, 5)
        let days = [activeDay("2026-08-05")]
        let history = StatsHistory(rollup: rollup(days), today: today, calendar: gmtCalendar)

        #expect(history.currentStreak == 1)
        #expect(history.longestStreak == 1)
        #expect(history.activeDayCount == 1)
        #expect(history.firstActiveDay == gmtCalendar.startOfDay(for: today))
    }

    @Test("a streak spanning a spring-forward DST transition is not broken by unnormalized day arithmetic")
    func streakSurvivesDSTSpringForward() {
        // Havana's DST spring-forward happens at local midnight, so startOfDay(for:) on the
        // transition day is 01:00 rather than 00:00 — `calendar.date(byAdding: .day, ...)`
        // results must be re-normalized with startOfDay before being compared against/used as
        // startOfDay-keyed dates, or every streak crossing the transition silently breaks.
        var havanaCalendar = Calendar(identifier: .gregorian)
        havanaCalendar.timeZone = TimeZone(identifier: "America/Havana")!

        func havanaDate(_ y: Int, _ m: Int, _ d: Int) -> Date {
            var comps = DateComponents()
            comps.year = y; comps.month = m; comps.day = d; comps.hour = 12
            return havanaCalendar.date(from: comps)!
        }

        var days: [RollupDay] = []
        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "yyyy-MM-dd"
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.calendar = havanaCalendar
        dayFormatter.timeZone = havanaCalendar.timeZone

        var cursor = havanaDate(2026, 1, 1)
        let end = havanaDate(2026, 3, 20)
        while cursor <= end {
            let key = dayFormatter.string(from: cursor)
            days.append(activeDay(key))
            cursor = havanaCalendar.date(byAdding: .day, value: 1, to: cursor)!
        }

        let today = havanaDate(2026, 3, 20)
        let history = StatsHistory(rollup: rollup(days), today: today, calendar: havanaCalendar)

        #expect(history.currentStreak == 79)
        #expect(history.longestStreak == 79)
    }

    @Test("a RollupDay with a short tokensByHour array (memberwise init, no decode normalization) does not crash StatsHistory and counts correctly")
    func shortTokensByHourFromMemberwiseInitDoesNotCrash() {
        let today = gmtDate(2026, 8, 5)
        let shortDay = RollupDay(day: "2026-08-05", tokensByHour: [1, 2, 3], requests: 1)
        let history = StatsHistory(rollup: rollup([shortDay]), today: today, calendar: gmtCalendar)

        #expect(history.allTimeTokens == 6)
    }

    // MARK: 8. busiestDay tie-break, punchcard mapping, out-of-window day

    @Test("busiestDay ties are broken by most recent date")
    func busiestDayTieBreaksToMostRecent() {
        let today = gmtDate(2026, 8, 10)
        let days = [
            RollupDay(day: "2026-08-01", tokensByHour: hourZero(500), requests: 1),
            RollupDay(day: "2026-08-05", tokensByHour: hourZero(500), requests: 1), // same tokens, later date
        ]
        let history = StatsHistory(rollup: rollup(days), today: today, calendar: gmtCalendar)

        let busiest = try! #require(history.busiestDay)
        #expect(busiest.date == gmtCalendar.startOfDay(for: gmtDate(2026, 8, 5)))
        #expect(busiest.tokens == 500)
        #expect(busiest.level == 4)
    }

    @Test("each of 7 consecutive known dates lands in its expected Monday-first heatmap row")
    func mondayFirstRowIndexForKnownDates() {
        // 2026-08-03 is a Monday; 2026-08-09 is the following Sunday.
        let today = gmtDate(2026, 8, 9) // Sunday, so the whole week is in the grid.
        let dates: [(row: Int, date: Date)] = [
            (0, gmtDate(2026, 8, 3)), // Monday
            (1, gmtDate(2026, 8, 4)), // Tuesday
            (2, gmtDate(2026, 8, 5)), // Wednesday
            (3, gmtDate(2026, 8, 6)), // Thursday
            (4, gmtDate(2026, 8, 7)), // Friday
            (5, gmtDate(2026, 8, 8)), // Saturday
            (6, gmtDate(2026, 8, 9)), // Sunday
        ]
        let history = StatsHistory(rollup: .empty, today: today, calendar: gmtCalendar)
        let lastColumn = history.heatmapWeeks[52]
        for (expectedRow, date) in dates {
            #expect(lastColumn[expectedRow]?.date == gmtCalendar.startOfDay(for: date))
        }
    }

    @Test("a known record maps into the correct [weekdayRow][hour] punchcard cell")
    func punchcardMapsToCorrectCell() {
        let today = gmtDate(2026, 8, 9) // Sunday; grid covers the whole prior week too
        // 2026-08-04 is a Tuesday -> weekday row 1. Put tokens in hour 15.
        var hours = Array(repeating: 0, count: 24)
        hours[15] = 42
        let days = [RollupDay(day: "2026-08-04", tokensByHour: hours, requests: 1)]
        let history = StatsHistory(rollup: rollup(days), today: today, calendar: gmtCalendar)

        #expect(history.punchcard[1][15] == 42)
        #expect(history.punchcardMax == 42)
        // Every other cell is untouched.
        var total = 0
        for row in history.punchcard { total += row.reduce(0, +) }
        #expect(total == 42)
    }

    @Test("a day older than the grid span is excluded from punchcard but still counts toward allTime totals and streaks")
    func oldDayExcludedFromPunchcardButCountsAllTime() {
        let today = gmtDate(2026, 8, 9)
        // Two full years before today — well outside the 53-week grid span.
        var oldHours = Array(repeating: 0, count: 24)
        oldHours[5] = 999
        let oldDay = RollupDay(day: "2020-01-01", tokensByHour: oldHours, requests: 7)

        // One in-window day for contrast.
        var recentHours = Array(repeating: 0, count: 24)
        recentHours[5] = 1
        let recentDay = RollupDay(day: "2026-08-04", tokensByHour: recentHours, requests: 1)

        let history = StatsHistory(rollup: rollup([oldDay, recentDay]), today: today, calendar: gmtCalendar)

        // Punchcard hour 5 only reflects the in-window day.
        let totalHour5 = history.punchcard.reduce(0) { $0 + $1[5] }
        #expect(totalHour5 == 1)

        // But all-time totals and active-day accounting include the old day.
        #expect(history.allTimeTokens == 999 + 1)
        #expect(history.allTimeRequests == 7 + 1)
        #expect(history.activeDayCount == 2)
        #expect(history.firstActiveDay == gmtCalendar.startOfDay(for: gmtDate(2020, 1, 1)))
    }
}

// MARK: - Helpers

private func hourZero(_ tokens: Int) -> [Int] {
    var hours = Array(repeating: 0, count: 24)
    hours[0] = tokens
    return hours
}
