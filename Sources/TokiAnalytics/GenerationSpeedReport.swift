/// GenerationSpeedReport — tokens per second per model × effort × mode, all-time and by day.
import Foundation
import TokiModels

public struct GenerationSpeedReport: Sendable, Equatable {
    public struct DayPoint: Sendable, Equatable {
        public let day: Date
        public let median: Double
        public let p10: Double
        public let p90: Double
        public let count: Int

        public init(day: Date, median: Double, p10: Double, p90: Double, count: Int) {
            self.day = day
            self.median = median
            self.p10 = p10
            self.p90 = p90
            self.count = count
        }
    }

    public struct Group: Sendable, Equatable, Identifiable {
        /// `"\(model)|\(effort ?? "")|\(isFast ? "fast" : "standard")"`
        public let id: String
        public let model: String
        public let effort: String?
        public let isFast: Bool
        public let provider: UsageProvider
        public let count: Int
        /// Σ tokens / Σ seconds.
        public let weightedAverage: Double
        public let median: Double
        public let p10: Double
        public let p90: Double
        public let firstDay: Date
        public let lastDay: Date
        /// Days with at least `minDaySamples` samples, ascending.
        public let daily: [DayPoint]

        public init(
            id: String, model: String, effort: String?, isFast: Bool, provider: UsageProvider,
            count: Int, weightedAverage: Double, median: Double, p10: Double, p90: Double,
            firstDay: Date, lastDay: Date, daily: [DayPoint]
        ) {
            self.id = id
            self.model = model
            self.effort = effort
            self.isFast = isFast
            self.provider = provider
            self.count = count
            self.weightedAverage = weightedAverage
            self.median = median
            self.p10 = p10
            self.p90 = p90
            self.firstDay = firstDay
            self.lastDay = lastDay
            self.daily = daily
        }
    }

    public static let minGroupSamples = 20
    public static let minDaySamples = 20
    public static let empty = GenerationSpeedReport(groups: [], hiddenGroupCount: 0)

    /// Count desc, then id asc.
    public let groups: [Group]
    public let hiddenGroupCount: Int

    private init(groups: [Group], hiddenGroupCount: Int) {
        self.groups = groups
        self.hiddenGroupCount = hiddenGroupCount
    }

    /// Builds the report in one pass over `samples`, whose groups are contiguous and
    /// time-ordered (see `SpeedSamples`). Per row it does only arithmetic: no `Date`, no
    /// `Calendar` call, no allocation. The local days are computed once per report (see
    /// `DayTable`), so the `Calendar` work is per calendar day, not per group-day.
    public init(samples: SpeedSamples, calendar: Calendar) {
        let n = samples.count
        guard n > 0 else { self.init(groups: [], hiddenGroupCount: 0); return }
        let days = DayTable(samples.timestampMs, calendar)
        var rates = [Float](repeating: 0, count: n)
        for i in 0..<n {
            rates[i] = Float(samples.outputTokens[i]) / (Float(samples.generationMs[i]) / 1000)
        }
        var groups: [Group] = []
        var hidden = 0
        var lo = 0
        var scratch = BucketScratch()
        rates.withUnsafeMutableBufferPointer { rate in
            while lo < n {
                let g = samples.group[lo]
                var hi = lo
                var tokens = 0.0, seconds = 0.0
                while hi < n, samples.group[hi] == g {
                    tokens += Double(samples.outputTokens[hi])
                    seconds += Double(samples.generationMs[hi]) / 1000
                    hi += 1
                }
                defer { lo = hi }
                guard hi - lo >= Self.minGroupSamples else { hidden += 1; continue }
                let daily = Self.dailyPoints(rate, samples.timestampMs, lo, hi, days)
                // `dailyPoints` reordered the days' rates in place; selection does not need
                // any order, so the group's three ranks are selected from them as they are.
                let slice = UnsafeMutableBufferPointer(rebasing: rate[lo..<hi])
                let (p10, p50, p90) = slice.count >= Self.bucketSelectMinimum
                    ? Self.bucketQuantiles(UnsafeBufferPointer(slice), &scratch)
                    : Self.selectQuantiles(slice)
                let key = samples.groups[Int(g)]
                groups.append(Group(
                    id: "\(key.model)|\(key.effort ?? "")|\(key.isFast ? "fast" : "standard")",
                    model: key.model, effort: key.effort, isFast: key.isFast,
                    provider: Self.provider(ofModel: key.model),
                    count: hi - lo, weightedAverage: tokens / seconds,
                    median: Double(p50), p10: Double(p10), p90: Double(p90),
                    firstDay: days.start[days.index(of: samples.timestampMs[lo])],
                    lastDay: days.start[days.index(of: samples.timestampMs[hi - 1])],
                    daily: daily))
            }
        }
        groups.sort { $0.count != $1.count ? $0.count > $1.count : $0.id < $1.id }
        self.init(groups: groups, hiddenGroupCount: hidden)
    }

    /// Nearest-rank percentile of an ascending array.
    public static func nearestRank(_ sorted: UnsafeBufferPointer<Float>, _ p: Double) -> Float {
        sorted[rankIndex(sorted.count, p)]
    }

    static func rankIndex(_ n: Int, _ p: Double) -> Int {
        min(n - 1, max(0, Int((Double(n) * p).rounded(.up)) - 1))
    }

    /// Codex model ids are `gpt-…`, `codex…` and `o<digit>…`; anything else Claude Code
    /// recorded (a proxy's or a custom model id included) is Claude.
    static func provider(ofModel model: String) -> UsageProvider {
        let id = model.lowercased().utf8
        if id.starts(with: "gpt-".utf8) || id.starts(with: "codex".utf8) { return .codex }
        var bytes = id.makeIterator()
        if bytes.next() == UInt8(ascii: "o"), let next = bytes.next(),
           (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(next) { return .codex }
        return .claudeCode
    }

    /// The local days the samples span, built once per report: `start[k]` is day `k`'s
    /// midnight and `bound[k]` its first millisecond (`bound` has one more entry, the end of
    /// the last day). One `startOfDay` and one `date(byAdding: .day)` per calendar day, so a
    /// DST change makes that day 23 or 25 hours long, as it is.
    struct DayTable {
        var start: [Date] = []
        var bound: [Int64] = []

        init(_ ts: [Int64], _ calendar: Calendar) {
            var lo = Int64.max, hi = Int64.min
            for t in ts { lo = Swift.min(lo, t); hi = Swift.max(hi, t) }
            var day = calendar.startOfDay(for: Date(timeIntervalSince1970: Double(lo) / 1000))
            bound.append(Self.milliseconds(day))
            repeat {
                start.append(day)
                day = calendar.startOfDay(for: calendar.date(byAdding: .day, value: 1, to: day)!)
                bound.append(Self.milliseconds(day))
            } while bound[bound.count - 1] <= hi
        }

        /// The day holding `ms`, which must lie within the table (binary search; once per group).
        func index(of ms: Int64) -> Int {
            var lo = 0, hi = start.count - 1
            while lo < hi {
                let mid = (lo + hi + 1) / 2
                if bound[mid] <= ms { lo = mid } else { hi = mid - 1 }
            }
            return lo
        }

        private static func milliseconds(_ date: Date) -> Int64 {
            Int64((date.timeIntervalSince1970 * 1000).rounded())
        }
    }

    /// Splits `[lo, hi)` (time-ordered) into local days by advancing an index into `days`;
    /// reorders each day's rates in place while selecting its ranks.
    private static func dailyPoints(
        _ rate: UnsafeMutableBufferPointer<Float>, _ ts: [Int64], _ lo: Int, _ hi: Int, _ days: DayTable
    ) -> [DayPoint] {
        var points: [DayPoint] = []
        var start = lo
        var d = days.index(of: ts[lo])
        days.bound.withUnsafeBufferPointer { bound in
            ts.withUnsafeBufferPointer { ts in
                while start < hi {
                    while bound[d + 1] <= ts[start] { d += 1 }
                    let nextMs = bound[d + 1]
                    var end = start
                    while end < hi, ts[end] < nextMs { end += 1 }
                    if end - start >= minDaySamples {
                        let (p10, p50, p90) = selectQuantiles(UnsafeMutableBufferPointer(rebasing: rate[start..<end]))
                        points.append(DayPoint(day: days.start[d],
                                               median: Double(p50), p10: Double(p10), p90: Double(p90),
                                               count: end - start))
                    }
                    start = end
                }
            }
        }
        return points
    }

    /// p10, p50, p90 by nearest rank, in O(n): three quickselects, each on the part the
    /// previous one left to its right.
    private static func selectQuantiles(_ a: UnsafeMutableBufferPointer<Float>) -> (Float, Float, Float) {
        let n = a.count
        let k10 = rankIndex(n, 0.1), k50 = rankIndex(n, 0.5), k90 = rankIndex(n, 0.9)
        select(a, k10, 0, n - 1)
        select(a, k50, k10, n - 1)
        select(a, k90, k50, n - 1)
        return (a[k10], a[k50], a[k90])
    }

    /// From this many rates on, a group's ranks are found by `bucketQuantiles`: on a large
    /// group three quickselects spend most of their time on mispredicted comparisons.
    static let bucketSelectMinimum = 4_096

    /// Reused across a report's groups by `bucketQuantiles`.
    struct BucketScratch {
        var counts = [Int32](repeating: 0, count: 4_096)
        var gathered: [Float] = []
    }

    /// p10, p50, p90 by nearest rank, without reordering `a`: one pass for the range, one to
    /// count the values into equal-width buckets, and per bucket holding a wanted rank one
    /// pass to gather that bucket's values, whose rank is then selected among them alone.
    /// The bucket of a value never decreases as the value grows, so the k-th smallest value
    /// is the right one within its bucket.
    static func bucketQuantiles(
        _ a: UnsafeBufferPointer<Float>, _ scratch: inout BucketScratch
    ) -> (Float, Float, Float) {
        let n = a.count
        let ranks = (rankIndex(n, 0.1), rankIndex(n, 0.5), rankIndex(n, 0.9))
        var low = a[0], high = a[0]
        for v in a { low = Swift.min(low, v); high = Swift.max(high, v) }
        guard low < high else { return (low, low, low) }
        let buckets = scratch.counts.count
        // A range too narrow to divide puts everything in one bucket: still exact, just slower.
        let divided = Float(buckets) / (high - low)
        let scale = divided.isFinite ? divided : 0
        // Non-finite products (from a NaN or infinite rate) all go to the last bucket, so the
        // conversion never traps.
        func bucket(_ v: Float) -> Int {
            let x = (v - low) * scale
            return x < Float(buckets - 1) ? Int(x) : buckets - 1
        }
        if scratch.gathered.count < n { scratch.gathered = [Float](repeating: 0, count: n) }
        return scratch.counts.withUnsafeMutableBufferPointer { counts in
            scratch.gathered.withUnsafeMutableBufferPointer { gathered in
                counts.update(repeating: 0)
                for v in a { counts[bucket(v)] &+= 1 }
                func find(_ k: Int) -> (bucket: Int, within: Int) {
                    var before = 0
                    for b in 0..<buckets {
                        let count = Int(counts[b])
                        if k < before + count { return (b, k - before) }
                        before += count
                    }
                    preconditionFailure("rank \(k) is beyond the \(before) values counted")
                }
                var cached: (bucket: Int, count: Int) = (-1, 0)
                func value(_ k: Int) -> Float {
                    let (b, within) = find(k)
                    if cached.bucket != b {
                        var count = 0
                        for v in a where bucket(v) == b { gathered[count] = v; count += 1 }
                        cached = (b, count)
                    }
                    // The gathered values are reordered by selection, never changed, so a
                    // second rank in the same bucket can select among them again.
                    let part = UnsafeMutableBufferPointer(rebasing: gathered[0..<cached.count])
                    select(part, within, 0, part.count - 1)
                    return part[within]
                }
                return (value(ranks.0), value(ranks.1), value(ranks.2))
            }
        }
    }

    /// Hoare-partition quickselect: afterwards `a[k]` holds the k-th smallest of `a[lo…hi]`,
    /// with nothing larger before it and nothing smaller after it.
    private static func select(_ a: UnsafeMutableBufferPointer<Float>, _ k: Int, _ lo: Int, _ hi: Int) {
        var lo = lo, hi = hi
        while lo < hi {
            let pivot = a[lo + (hi - lo) / 2]
            var i = lo, j = hi
            while i <= j {
                while a[i] < pivot { i += 1 }
                while a[j] > pivot { j -= 1 }
                if i <= j { a.swapAt(i, j); i += 1; j -= 1 }
            }
            if k <= j { hi = j } else if k >= i { lo = i } else { return }
        }
    }
}
