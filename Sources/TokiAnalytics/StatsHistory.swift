/// Pure, synchronous compute layer for the Statistics feature's calendar views: turns a
/// `StatsRollup` snapshot plus a reference "today" into everything the heatmap, punchcard
/// and streak UI need. Holds no I/O and no state beyond its own stored properties, so it is
/// trivially testable and safe to recompute on every rollup change.
import Foundation

public struct StatsHistory: Sendable, Equatable {

    // MARK: Nested types

    /// One cell of the contribution-graph-style heatmap.
    public struct HeatmapCell: Sendable, Equatable, Identifiable {
        public let date: Date
        public let tokens: Int
        public let requests: Int
        /// 0 (no activity) through 4 (top nonzero quartile) — see `StatsHistory.init` for
        /// the nearest-rank quartile formula that derives this from the grid's own data.
        public let level: Int
        public var id: Date { date }

        public init(date: Date, tokens: Int, requests: Int, level: Int) {
            self.date = date
            self.tokens = tokens
            self.requests = requests
            self.level = level
        }
    }

    // MARK: Stored properties

    /// 53 columns (weeks), each exactly 7 rows (Monday = index 0 ... Sunday = 6). The last
    /// column is the week containing `today`; cells whose date is after `today` are `nil`.
    public let heatmapWeeks: [[HeatmapCell?]]
    /// 7 rows (Monday = 0) x 24 hour columns; tokens summed over the heatmap's own date span.
    public let punchcard: [[Int]]
    public let punchcardMax: Int
    public let currentStreak: Int
    public let longestStreak: Int
    public let activeDayCount: Int
    public let firstActiveDay: Date?
    /// The all-history busiest day (not limited to the heatmap window); `level` is always 4.
    public let busiestDay: HeatmapCell?
    public let allTimeTokens: Int
    public let allTimeRequests: Int

    // MARK: Init

    public init(rollup: StatsRollup, today: Date, calendar: Calendar) {
        let dayFormatter = Self.dayFormatter(calendar: calendar)
        let todayStart = calendar.startOfDay(for: today)

        // Every stored day, keyed by its parsed local-midnight Date — the single source both
        // the grid build and the all-history accumulation below read from.
        var daysByDate: [Date: RollupDay] = [:]
        for (key, day) in rollup.days {
            guard let parsed = dayFormatter.date(from: key) else { continue }
            daysByDate[calendar.startOfDay(for: parsed)] = day
        }

        // MARK: Grid span: 53 Monday-aligned weeks ending on the week containing `today`.
        let todayWeekdayRow = Self.weekdayRow(for: todayStart, calendar: calendar)
        let currentWeekMonday = calendar.date(byAdding: .day, value: -todayWeekdayRow, to: todayStart)!
        let firstGridMonday = calendar.date(byAdding: .day, value: -52 * 7, to: currentWeekMonday)!

        var weeks: [[HeatmapCell?]] = []
        weeks.reserveCapacity(53)
        for col in 0..<53 {
            let colMonday = calendar.date(byAdding: .day, value: col * 7, to: firstGridMonday)!
            var column: [HeatmapCell?] = []
            column.reserveCapacity(7)
            for row in 0..<7 {
                let date = calendar.startOfDay(for: calendar.date(byAdding: .day, value: row, to: colMonday)!)
                if date > todayStart {
                    column.append(nil)
                } else {
                    let rd = daysByDate[date]
                    column.append(HeatmapCell(date: date, tokens: rd?.totalTokens ?? 0, requests: rd?.requests ?? 0, level: 0))
                }
            }
            weeks.append(column)
        }

        // MARK: Levels: nearest-rank quartiles over the NONZERO token values in the grid.
        let nonzero = weeks.flatMap { $0.compactMap { $0?.tokens } }.filter { $0 > 0 }.sorted()
        func quantile(_ p: Double) -> Int {
            guard !nonzero.isEmpty else { return 0 }
            let idx = max(0, Int((Double(nonzero.count) * p).rounded(.up)) - 1)
            return nonzero[idx]
        }
        let q25 = quantile(0.25), q50 = quantile(0.5), q75 = quantile(0.75)
        func level(for tokens: Int) -> Int {
            guard tokens > 0 else { return 0 }
            if tokens <= q25 { return 1 }
            if tokens <= q50 { return 2 }
            if tokens <= q75 { return 3 }
            return 4
        }
        weeks = weeks.map { column in
            column.map { cell in
                guard let cell else { return nil }
                return HeatmapCell(date: cell.date, tokens: cell.tokens, requests: cell.requests, level: level(for: cell.tokens))
            }
        }
        self.heatmapWeeks = weeks

        // MARK: Punchcard: only rollup days inside [firstGridMonday, todayStart].
        var punch = Array(repeating: Array(repeating: 0, count: 24), count: 7)
        for (date, day) in daysByDate where date >= firstGridMonday && date <= todayStart {
            let row = Self.weekdayRow(for: date, calendar: calendar)
            for hour in 0..<24 {
                punch[row][hour] += day.tokensByHour[hour]
            }
        }
        self.punchcard = punch
        self.punchcardMax = punch.flatMap { $0 }.max() ?? 0

        // MARK: All-history totals, active days, busiest day (unrestricted by the grid).
        var allTokens = 0, allRequests = 0
        var activeDates: Set<Date> = []
        var busiest: (date: Date, day: RollupDay)?
        for (date, day) in daysByDate {
            allTokens += day.totalTokens
            allRequests += day.requests
            guard day.totalTokens > 0 else { continue }
            activeDates.insert(date)
            if let current = busiest {
                // Tie -> most recent day wins.
                if day.totalTokens > current.day.totalTokens
                    || (day.totalTokens == current.day.totalTokens && date > current.date) {
                    busiest = (date, day)
                }
            } else {
                busiest = (date, day)
            }
        }
        self.allTimeTokens = allTokens
        self.allTimeRequests = allRequests
        self.activeDayCount = activeDates.count
        self.firstActiveDay = activeDates.min()
        self.busiestDay = busiest.map { HeatmapCell(date: $0.date, tokens: $0.day.totalTokens, requests: $0.day.requests, level: 4) }

        // MARK: Streaks (all history — not limited to the grid).
        var longest = 0
        var runLength = 0
        var previous: Date?
        for date in activeDates.sorted() {
            // Re-normalize with startOfDay: in zones whose DST transition lands at local
            // midnight (e.g. America/Havana), startOfDay(for:) on the transition day is
            // 01:00, so adding a day to a startOfDay-normalized date can land off the
            // startOfDay grid unless it is re-normalized before comparing/storing.
            if let previous, calendar.startOfDay(for: calendar.date(byAdding: .day, value: 1, to: previous)!) == date {
                runLength += 1
            } else {
                runLength = 1
            }
            longest = max(longest, runLength)
            previous = date
        }
        self.longestStreak = longest

        func streakEnding(at end: Date) -> Int {
            var length = 0
            var cursor = end
            while activeDates.contains(cursor) {
                length += 1
                cursor = calendar.startOfDay(for: calendar.date(byAdding: .day, value: -1, to: cursor)!)
            }
            return length
        }
        if activeDates.contains(todayStart) {
            self.currentStreak = streakEnding(at: todayStart)
        } else {
            let yesterday = calendar.startOfDay(for: calendar.date(byAdding: .day, value: -1, to: todayStart)!)
            self.currentStreak = activeDates.contains(yesterday) ? streakEnding(at: yesterday) : 0
        }
    }

    // MARK: Private helpers

    /// Monday-first weekday row: `Calendar.component(.weekday:)` is 1 (Sunday) ... 7
    /// (Saturday) regardless of `calendar.firstWeekday`, so this remaps it to 0 (Monday)
    /// ... 6 (Sunday) directly rather than trusting the calendar's own first-weekday setting.
    private static func weekdayRow(for date: Date, calendar: Calendar) -> Int {
        (calendar.component(.weekday, from: date) + 5) % 7
    }

    private static func dayFormatter(calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        return formatter
    }
}
