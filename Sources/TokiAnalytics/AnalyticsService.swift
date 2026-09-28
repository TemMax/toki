/// AnalyticsService — aggregates transcript records into usage summaries.
import Foundation
import TokiModels

/// Reads records from any `RecordProviding` source, joins with `PricingProviding` at query
/// time (per D3 — cost is never stored, only computed on demand), and aggregates into a
/// `UsageSummary`.
///
/// Cost is computed at query time but POINT-IN-TIME: each record is priced at the rate
/// effective on its own `timestamp`, not the latest rate. So a later price change does NOT
/// retroactively change historical cost — only records dated on/after the new rate's
/// `effectiveFrom` pick it up. Depends on the `RecordProviding` abstraction (not the
/// concrete indexer) so it can be unit-tested with an in-memory fake.
public struct AnalyticsService: AnalyticsProviding {
    private let records: any RecordProviding
    private let pricing: any PricingProviding

    public init(records: any RecordProviding, pricing: any PricingProviding) {
        self.records = records
        self.pricing = pricing
    }

    public func summary(start: Date, end: Date) async throws -> UsageSummary {
        let recs = try await records.records(start: start, end: end)

        let calendar = Calendar.current
        let bucketSize = Self.bucketSize(start: start, end: end, calendar: calendar)
        let aggregate = await Self.aggregate(recs, bucketSize: bucketSize, calendar: calendar, pricing: pricing)
        let totalUsage = aggregate.total
        let trendMap = aggregate.trend
        let projectMap = aggregate.byProject
        let modelMap = aggregate.byModel
        let totalCostAccum = aggregate.cost
        let hasUnpricedUsage = aggregate.hasUnpricedUsage

        let buckets = Self.contiguousBuckets(
            from: trendMap,
            size: bucketSize,
            start: start,
            end: end,
            earliestRecord: recs.first?.timestamp,
            calendar: calendar
        )

        // Sorted by project: descending callCount, then descending cost.total, then ascending name.
        // Aggregated by full working-directory path: two projects that share a basename
        // (e.g. worktrees, or same-named repos in different locations) stay distinct rows,
        // and each row carries its real path for display + reveal-in-Finder.
        let byProject: [ProjectUsage] = projectMap
            .map { path, b in
                ProjectUsage(
                    project: URL(fileURLWithPath: path).lastPathComponent,
                    path: path,
                    usage: b.usage, cost: b.cost, callCount: b.callCount,
                    hasUnpricedUsage: b.hasUnpricedUsage
                )
            }
            .sorted {
                if $0.callCount != $1.callCount { return $0.callCount > $1.callCount }
                let l = $0.cost?.total ?? 0, r = $1.cost?.total ?? 0
                if l != r { return l > r }
                if $0.project != $1.project { return $0.project < $1.project }
                return $0.path < $1.path
            }

        // Sorted by model: descending callCount, then descending cost.total, then ascending name.
        let byModel: [ModelUsage] = modelMap
            .map { name, b in
                ModelUsage(
                    model: name, usage: b.usage, cost: b.cost, callCount: b.callCount,
                    hasUnpricedUsage: b.hasUnpricedUsage
                )
            }
            .sorted {
                if $0.callCount != $1.callCount { return $0.callCount > $1.callCount }
                let l = $0.cost?.total ?? 0, r = $1.cost?.total ?? 0
                if l != r { return l > r }
                return $0.model < $1.model
            }

        return UsageSummary(
            total: totalUsage,
            cost: totalCostAccum,
            buckets: buckets,
            bucketSize: bucketSize,
            byProject: byProject,
            byModel: byModel,
            rangeStart: start,
            rangeEnd: end,
            hasUnpricedUsage: hasUnpricedUsage
        )
    }

    // MARK: - Aggregation

    /// Below this many records one pass is quicker than coordinating several.
    static let parallelAggregationThreshold = 16_384

    /// Prices and buckets `records` by trend bucket, project and model.
    ///
    /// Per-record pricing dominates a long range (each record is priced at its own date and
    /// its own long-context tier, so it cannot be priced in bulk), and records are
    /// independent, so a large range is split into contiguous slices aggregated in parallel
    /// and merged. Slices stay contiguous so each keeps the ordered-bucket shortcut below.
    static func aggregate(
        _ records: [TranscriptRecord],
        bucketSize: BucketSize,
        calendar: Calendar,
        pricing: any PricingProviding
    ) async -> Aggregate {
        guard records.count >= parallelAggregationThreshold else {
            return aggregate(records[...], bucketSize: bucketSize, calendar: calendar, pricing: pricing)
        }
        let sliceCount = min(
            ProcessInfo.processInfo.activeProcessorCount,
            records.count / (parallelAggregationThreshold / 2)
        )
        let sliceLength = (records.count + sliceCount - 1) / sliceCount
        return await withTaskGroup(of: (Int, Aggregate).self) { group in
            for index in 0..<sliceCount {
                let lower = index * sliceLength
                let upper = min(lower + sliceLength, records.count)
                guard lower < upper else { continue }
                group.addTask {
                    (index, aggregate(records[lower..<upper], bucketSize: bucketSize, calendar: calendar, pricing: pricing))
                }
            }
            var partials: [(Int, Aggregate)] = []
            for await partial in group { partials.append(partial) }
            // Merged in slice order, so the floating-point sums do not depend on scheduling.
            return partials.sorted { $0.0 < $1.0 }.reduce(into: Aggregate()) { $0.merge($1.1) }
        }
    }

    private static func aggregate(
        _ records: ArraySlice<TranscriptRecord>,
        bucketSize: BucketSize,
        calendar: Calendar,
        pricing: any PricingProviding
    ) -> Aggregate {
        var result = Aggregate()

        // `Calendar.startOfDay` is the single most expensive call in this loop — it walks
        // the calendar's timezone rules every time. Records arrive ordered by timestamp, so
        // the bucket boundary is recomputed only when one is actually crossed. `dateInterval`
        // gives the true local window, which keeps this exact across DST changes (a day is
        // not always 86,400 seconds, and on a DST boundary neither is an hour).
        var currentBucket: DateInterval?
        // Each model's schedule is fetched once per slice; after that pricing a record
        // touches no provider state (and no lock), which is what lets slices run in parallel.
        var schedules: [String: PriceSchedule?] = [:]

        for record in records {
            let bucketKey: Date
            if let bucket = currentBucket, bucket.containsHalfOpen(record.timestamp) {
                bucketKey = bucket.start
            } else if let bucket = calendar.dateInterval(of: bucketSize.component, for: record.timestamp) {
                currentBucket = bucket
                bucketKey = bucket.start
            } else {
                bucketKey = calendar.startOfDay(for: record.timestamp)
            }
            let schedule: PriceSchedule?
            if let cached = schedules[record.model] {
                schedule = cached
            } else {
                schedule = pricing.schedule(for: record.model)
                schedules[record.model] = .some(schedule)
            }
            // Priced at the model's rate on the record's date, then at what the request was
            // actually billed: fast mode and US-only inference scale every token rate.
            let recordCost = (schedule.map { $0.pricing(on: record.timestamp)?.cost(for: record.usage) }
                ?? pricing.cost(for: record.usage, model: record.model, on: record.timestamp))?
                .applying(record.billing)

            result.total = result.total + record.usage
            result.trend[bucketKey, default: Bucket()].add(usage: record.usage, cost: recordCost)
            result.byProject[record.cwd, default: Bucket()].add(usage: record.usage, cost: recordCost)
            result.byModel[record.model, default: Bucket()].add(usage: record.usage, cost: recordCost)

            if let c = recordCost {
                result.cost = (result.cost ?? .zero) + c
            } else {
                result.hasUnpricedUsage = true
            }
        }
        return result
    }

    /// The three aggregation dimensions plus the grand totals.
    struct Aggregate {
        var total: TokenUsage = .zero
        var trend: [Date: Bucket] = [:]
        var byProject: [String: Bucket] = [:]
        var byModel: [String: Bucket] = [:]
        var cost: CostBreakdown?
        var hasUnpricedUsage = false

        mutating func merge(_ other: Aggregate) {
            total = total + other.total
            trend.merge(other.trend) { $0.merged(with: $1) }
            byProject.merge(other.byProject) { $0.merged(with: $1) }
            byModel.merge(other.byModel) { $0.merged(with: $1) }
            if let c = other.cost { cost = (cost ?? .zero) + c }
            hasUnpricedUsage = hasUnpricedUsage || other.hasUnpricedUsage
        }
    }

    // MARK: - Trend bucketing

    /// Hours when the range covers a single local day, days otherwise.
    ///
    /// "Today" is `[startOfDay, now]`, so bucketed by day it is ONE bucket — a sparkline
    /// with a single point, drawn as a flat line with `min` equal to `max`. That is not a
    /// rendering fault to patch in the chart; it is a series that answers "how did this
    /// change day over day" over a range containing one day. Hours answer the question the
    /// range actually poses.
    static func bucketSize(start: Date, end: Date, calendar: Calendar) -> BucketSize {
        // `.distantPast` (the All Time range) is not the same day as anything, so this
        // short-circuit only exists to skip the calendar walk for it.
        guard start > .distantPast else { return .day }
        return calendar.isDate(start, inSameDayAs: end) ? .hour : .day
    }

    /// The aggregated buckets as a CONTIGUOUS ascending series: every bucket boundary from
    /// the start of the window to the bucket containing `end`, with idle buckets present at
    /// zero rather than omitted.
    ///
    /// Omitting idle buckets is what a sparkline cannot survive: it plots values at even
    /// spacing, so five busy days scattered across a month and five consecutive ones drew
    /// the same shape. Filling them makes the x-axis mean elapsed time again.
    ///
    /// The lower bound is the window's own `start`, EXCEPT for a range with no real lower
    /// bound (All Time passes `.distantPast`), where it is the earliest record — otherwise
    /// the series would run from the year 1 to today.
    static func contiguousBuckets(
        from aggregated: [Date: Bucket],
        size: BucketSize,
        start: Date,
        end: Date,
        earliestRecord: Date?,
        calendar: Calendar
    ) -> [UsageBucket] {
        guard !aggregated.isEmpty else { return [] }

        let lowerBound = start > .distantPast ? start : (earliestRecord ?? end)
        guard
            var cursor = calendar.dateInterval(of: size.component, for: lowerBound)?.start,
            let lastBoundary = calendar.dateInterval(of: size.component, for: end)?.start
        else {
            // No usable calendar boundary: fall back to whatever was aggregated, in order,
            // rather than dropping the series entirely.
            return aggregated
                .map {
                    UsageBucket(
                        date: $0.key, usage: $0.value.usage, cost: $0.value.cost,
                        callCount: $0.value.callCount,
                        hasUnpricedUsage: $0.value.hasUnpricedUsage
                    )
                }
                .sorted { $0.date < $1.date }
        }

        // A bucket carrying data before `cursor` can only mean the caller aggregated
        // records outside the window it asked for; keep them rather than silently drop.
        if let earliestKey = aggregated.keys.min(), earliestKey < cursor {
            cursor = earliestKey
        }

        var series: [UsageBucket] = []
        // Guard against a non-advancing calendar step turning this into an infinite loop.
        var remaining = Self.maximumBuckets
        while cursor <= lastBoundary, remaining > 0 {
            let bucket = aggregated[cursor]
            series.append(
                UsageBucket(
                    date: cursor,
                    usage: bucket?.usage ?? .zero,
                    cost: bucket?.cost,
                    callCount: bucket?.callCount ?? 0,
                    hasUnpricedUsage: bucket?.hasUnpricedUsage ?? false
                )
            )
            guard let next = calendar.date(byAdding: size.component, value: 1, to: cursor), next > cursor else { break }
            cursor = next
            remaining -= 1
        }
        return series
    }

    /// Ceiling on the filled series, so a corrupt timestamp far in the past cannot make
    /// this walk millions of buckets. Ten years of days, or a decade's worth of hours in
    /// the single-day case (which can never approach it).
    static let maximumBuckets = 4000
}

// MARK: - Private bucket accumulator

/// Mutable accumulator for a single bucketing dimension (trend bucket, project, or model).
/// Internal rather than private so `contiguousBuckets` can take it and stay unit-testable.
struct Bucket {
    var usage: TokenUsage = .zero
    var callCount: Int = 0
    /// nil until the first record with known pricing is added.
    private var costAccum: CostBreakdown? = nil
    private(set) var hasUnpricedUsage = false

    var cost: CostBreakdown? { costAccum }

    /// This bucket's records followed by `other`'s.
    func merged(with other: Bucket) -> Bucket {
        var result = self
        result.usage = usage + other.usage
        result.callCount = callCount + other.callCount
        if let c = other.costAccum { result.costAccum = (costAccum ?? .zero) + c }
        result.hasUnpricedUsage = hasUnpricedUsage || other.hasUnpricedUsage
        return result
    }

    mutating func add(usage addUsage: TokenUsage, cost: CostBreakdown?) {
        usage = usage + addUsage
        callCount += 1
        if let c = cost {
            costAccum = (costAccum ?? .zero) + c
        } else {
            hasUnpricedUsage = true
        }
    }
}

extension DateInterval {
    /// `start <= date < end`. `contains(_:)` includes `end`, which for a calendar bucket is
    /// the first instant of the NEXT bucket — a record stamped exactly on the hour would be
    /// counted in the hour before.
    func containsHalfOpen(_ date: Date) -> Bool {
        date >= start && date < end
    }
}
