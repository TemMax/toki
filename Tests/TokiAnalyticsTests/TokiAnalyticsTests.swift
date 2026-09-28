import Testing
import Foundation
import TokiModels
@testable import TokiAnalytics

// MARK: - Fakes

/// Inline fake: returns only the records whose timestamp falls in [start, end].
private struct FakeRecords: RecordProviding {
    let allRecords: [TranscriptRecord]

    func records(start: Date, end: Date) async throws -> [TranscriptRecord] {
        allRecords.filter { $0.timestamp >= start && $0.timestamp <= end }
    }
}

/// Inline fake: prices "claude-opus-4-8" at the given rates; returns nil for any other model.
private struct FakePricing: PricingProviding {
    static let opusModel = "claude-opus-4-8"

    // USD per million tokens
    static let inputPerMTok: Double     = 5.00
    static let outputPerMTok: Double    = 25.00
    static let cacheWrite5mPerMTok: Double = 6.25
    static let cacheWrite1hPerMTok: Double = 10.00
    static let cacheReadPerMTok: Double = 0.50

    func pricing(for model: String, on date: Date) -> ModelPricing? {
        guard model == Self.opusModel else { return nil }
        return ModelPricing(
            inputPerMTok: Self.inputPerMTok,
            outputPerMTok: Self.outputPerMTok,
            cacheWrite5mPerMTok: Self.cacheWrite5mPerMTok,
            cacheWrite1hPerMTok: Self.cacheWrite1hPerMTok,
            cacheReadPerMTok: Self.cacheReadPerMTok
        )
    }
}

// MARK: - Fixture helpers

private let calendar = Calendar.current

/// Returns a mid-day (12:00) timestamp for `daysFromNow` offset from today.
/// Using local noon avoids any DST-edge ambiguity when bucketing to startOfDay.
private func localNoon(daysFromNow: Int) -> Date {
    let today = calendar.startOfDay(for: Date())
    var comps = DateComponents()
    comps.day = daysFromNow
    comps.hour = 12
    let start = calendar.date(byAdding: comps, to: today)!
    return start
}

/// Convenience: create a TranscriptRecord.
private func makeRecord(
    requestId: String,
    cwd: String,
    model: String,
    timestamp: Date,
    input: Int = 0, output: Int = 0,
    cacheRead: Int = 0, e5m: Int = 0, e1h: Int = 0
) -> TranscriptRecord {
    TranscriptRecord(
        requestId: requestId,
        sessionId: "sess-\(requestId)",
        cwd: cwd,
        model: model,
        timestamp: timestamp,
        usage: TokenUsage(
            input: input,
            output: output,
            cacheRead: cacheRead,
            ephemeral5m: e5m,
            ephemeral1h: e1h,
            webSearch: 0,
            webFetch: 0
        ),
        isSidechain: false
    )
}

// MARK: - Fixture

/// Three-day fixture spanning 3 distinct local days (relative days 0, 1, 2).
///
/// Records:
///  Day 0: rec-A0 (alpha/opus),  rec-B0 (alpha/mystery)
///  Day 1: rec-A1 (alpha/opus),  rec-C1 (beta/opus)
///  Day 2: rec-D2 (beta/mystery)
///
/// Totals:
///  alpha: 3 calls (A0, B0, A1)
///  beta:  2 calls (C1, D2)
///  opus:  3 calls (A0, A1, C1) — priced
///  mystery: 2 calls (B0, D2) — unpriced
private struct Fixture {
    let opus = "claude-opus-4-8"
    let mystery = "mystery-1"
    let alphaPath = "/workspace/alpha"
    let betaPath  = "/workspace/beta"

    // Timestamps
    let t0: Date  // Day 0 noon
    let t1: Date  // Day 1 noon
    let t2: Date  // Day 2 noon

    // Local-midnight keys (expected bucket dates)
    let day0: Date
    let day1: Date
    let day2: Date

    // Records
    let recA0: TranscriptRecord  // Day 0 / alpha / opus
    let recB0: TranscriptRecord  // Day 0 / alpha / mystery
    let recA1: TranscriptRecord  // Day 1 / alpha / opus
    let recC1: TranscriptRecord  // Day 1 / beta  / opus
    let recD2: TranscriptRecord  // Day 2 / beta  / mystery

    // Expected token sums (hand-computed)
    let totalExpected: TokenUsage
    let opusTotalExpected: TokenUsage  // sum of the three opus records

    init() {
        t0 = localNoon(daysFromNow: -2)
        t1 = localNoon(daysFromNow: -1)
        t2 = localNoon(daysFromNow: 0)

        day0 = calendar.startOfDay(for: t0)
        day1 = calendar.startOfDay(for: t1)
        day2 = calendar.startOfDay(for: t2)

        // Use distinct, easy-to-hand-compute token counts.
        recA0 = makeRecord(requestId: "A0", cwd: "/workspace/alpha", model: "claude-opus-4-8",
                           timestamp: t0, input: 1_000, output: 500, cacheRead: 200, e5m: 100, e1h: 50)
        recB0 = makeRecord(requestId: "B0", cwd: "/workspace/alpha", model: "mystery-1",
                           timestamp: t0, input: 300, output: 150)
        recA1 = makeRecord(requestId: "A1", cwd: "/workspace/alpha", model: "claude-opus-4-8",
                           timestamp: t1, input: 2_000, output: 800, cacheRead: 400, e5m: 200, e1h: 100)
        recC1 = makeRecord(requestId: "C1", cwd: "/workspace/beta", model: "claude-opus-4-8",
                           timestamp: t1, input: 500, output: 250, cacheRead: 0, e5m: 50, e1h: 0)
        recD2 = makeRecord(requestId: "D2", cwd: "/workspace/beta", model: "mystery-1",
                           timestamp: t2, input: 600, output: 300)

        // Hand-computed totals
        totalExpected = TokenUsage(
            input:      1_000 + 300 + 2_000 + 500 + 600,   // 4_400
            output:     500   + 150 + 800   + 250 + 300,    // 2_000
            cacheRead:  200   + 0   + 400   + 0   + 0,      //   600
            ephemeral5m: 100  + 0   + 200   + 50  + 0,      //   350
            ephemeral1h: 50   + 0   + 100   + 0   + 0,      //   150
            webSearch: 0,
            webFetch: 0
        )

        // Opus records: A0 + A1 + C1
        opusTotalExpected = TokenUsage(
            input:      1_000 + 2_000 + 500,
            output:     500   + 800   + 250,
            cacheRead:  200   + 400   + 0,
            ephemeral5m: 100  + 200   + 50,
            ephemeral1h: 50   + 100   + 0,
            webSearch: 0,
            webFetch: 0
        )
    }

    var allRecords: [TranscriptRecord] { [recA0, recB0, recA1, recC1, recD2] }

    /// Wide date range that includes all five records.
    var wideRange: (start: Date, end: Date) {
        (start: t0.addingTimeInterval(-3600), end: t2.addingTimeInterval(3600))
    }

    /// Cost for a single opus record (hand-computed in USD).
    func opusCost(for u: TokenUsage) -> Double {
        let mTok = 1_000_000.0
        let input      = Double(u.input) / mTok * 5.00
        let output     = Double(u.output) / mTok * 25.00
        let cacheWrite = Double(u.ephemeral5m) / mTok * 6.25
                       + Double(u.ephemeral1h)  / mTok * 10.00
        let cacheRead  = Double(u.cacheRead) / mTok * 0.50
        return input + output + cacheWrite + cacheRead
    }

    /// Expected total cost = sum of the three priced (opus) records.
    var expectedTotalCostUSD: Double {
        opusCost(for: recA0.usage) + opusCost(for: recA1.usage) + opusCost(for: recC1.usage)
    }
}

// MARK: - Test suite

@Suite("TokiAnalytics")
struct TokiAnalyticsTests {

    // MARK: Stub / empty path (keep original)

    @Test("AnalyticsService stub returns empty summary")
    func stubReturnsEmptySummary() async throws {
        let service = AnalyticsService(
            records: FakeRecords(allRecords: []),
            pricing: FakePricing()
        )
        let now = Date()
        let summary = try await service.summary(start: now.addingTimeInterval(-86400), end: now)
        #expect(summary.buckets.isEmpty)
        #expect(summary.byProject.isEmpty)
        #expect(summary.byModel.isEmpty)
        #expect(summary.total.input == 0)
        #expect(summary.cost == nil)
    }

    // MARK: Token sum totals

    @Test("Total token sums match hand-computed values")
    func totalTokenSums() async throws {
        let fix = Fixture()
        let (start, end) = fix.wideRange
        let service = AnalyticsService(records: FakeRecords(allRecords: fix.allRecords), pricing: FakePricing())
        let s = try await service.summary(start: start, end: end)

        #expect(s.total.input       == fix.totalExpected.input)
        #expect(s.total.output      == fix.totalExpected.output)
        #expect(s.total.cacheRead   == fix.totalExpected.cacheRead)
        #expect(s.total.ephemeral5m == fix.totalExpected.ephemeral5m)
        #expect(s.total.ephemeral1h == fix.totalExpected.ephemeral1h)
        #expect(s.total.webSearch   == 0)
        #expect(s.total.webFetch    == 0)
    }

    // MARK: Daily buckets

    @Test("A multi-day range buckets by day, one per distinct local day")
    func dailyBucketCount() async throws {
        let fix = Fixture()
        let (start, end) = fix.wideRange
        let service = AnalyticsService(records: FakeRecords(allRecords: fix.allRecords), pricing: FakePricing())
        let s = try await service.summary(start: start, end: end)

        #expect(s.buckets.count == 3)
    }

    @Test("Daily buckets have local-midnight dates sorted ascending")
    func dailyBucketDatesAscending() async throws {
        let fix = Fixture()
        let (start, end) = fix.wideRange
        let service = AnalyticsService(records: FakeRecords(allRecords: fix.allRecords), pricing: FakePricing())
        let s = try await service.summary(start: start, end: end)

        let dates = s.buckets.map { $0.date }
        // Sorted ascending
        #expect(dates == dates.sorted())
        // Each date is local midnight (== startOfDay)
        for d in dates {
            #expect(d == calendar.startOfDay(for: d), "Date \(d) is not local midnight")
        }
        // Values match our expected day keys
        #expect(dates[0] == fix.day0)
        #expect(dates[1] == fix.day1)
        #expect(dates[2] == fix.day2)
    }

    @Test("Daily call counts are correct")
    func dailyCallCounts() async throws {
        let fix = Fixture()
        let (start, end) = fix.wideRange
        let service = AnalyticsService(records: FakeRecords(allRecords: fix.allRecords), pricing: FakePricing())
        let s = try await service.summary(start: start, end: end)

        // Day 0: 2 records (A0 + B0), Day 1: 2 records (A1 + C1), Day 2: 1 record (D2)
        #expect(s.buckets[0].callCount == 2)
        #expect(s.buckets[1].callCount == 2)
        #expect(s.buckets[2].callCount == 1)
    }

    // MARK: byProject sorting

    @Test("byProject sorted descending by callCount (alpha before beta)")
    func byProjectSorting() async throws {
        let fix = Fixture()
        let (start, end) = fix.wideRange
        let service = AnalyticsService(records: FakeRecords(allRecords: fix.allRecords), pricing: FakePricing())
        let s = try await service.summary(start: start, end: end)

        #expect(s.byProject.count == 2)
        // alpha has 3 calls; beta has 2 calls => alpha first
        #expect(s.byProject[0].project == "alpha")
        #expect(s.byProject[0].callCount == 3)
        #expect(s.byProject[1].project == "beta")
        #expect(s.byProject[1].callCount == 2)
    }

    // MARK: byModel sorting

    @Test("byModel sorted descending by callCount (opus before mystery)")
    func byModelSorting() async throws {
        let fix = Fixture()
        let (start, end) = fix.wideRange
        let service = AnalyticsService(records: FakeRecords(allRecords: fix.allRecords), pricing: FakePricing())
        let s = try await service.summary(start: start, end: end)

        #expect(s.byModel.count == 2)
        // opus has 3 calls; mystery has 2 calls => opus first
        #expect(s.byModel[0].model == "claude-opus-4-8")
        #expect(s.byModel[0].callCount == 3)
        #expect(s.byModel[1].model == "mystery-1")
        #expect(s.byModel[1].callCount == 2)
    }

    // MARK: Cost — known-model bucket

    @Test("Known-model (opus) byModel bucket cost matches hand-computed USD")
    func opusBucketCostCorrect() async throws {
        let fix = Fixture()
        let (start, end) = fix.wideRange
        let service = AnalyticsService(records: FakeRecords(allRecords: fix.allRecords), pricing: FakePricing())
        let s = try await service.summary(start: start, end: end)

        let opusBucket = try #require(s.byModel.first { $0.model == "claude-opus-4-8" })
        let cost = try #require(opusBucket.cost)
        let expected = fix.expectedTotalCostUSD
        // All opus cost is in this bucket; tolerance 1e-9 USD
        #expect(abs(cost.total - expected) < 1e-9)
    }

    // MARK: Cost — unpriced-only bucket

    @Test("mystery-1 byModel bucket has nil cost (no pricing available)")
    func mysteryBucketCostNil() async throws {
        let fix = Fixture()
        let (start, end) = fix.wideRange
        let service = AnalyticsService(records: FakeRecords(allRecords: fix.allRecords), pricing: FakePricing())
        let s = try await service.summary(start: start, end: end)

        let mysteryBucket = try #require(s.byModel.first { $0.model == "mystery-1" })
        #expect(mysteryBucket.cost == nil)
        #expect(mysteryBucket.hasUnpricedUsage)
    }

    @Test("Day 2 daily bucket (only mystery-1) has nil cost")
    func day2CostNil() async throws {
        let fix = Fixture()
        let (start, end) = fix.wideRange
        let service = AnalyticsService(records: FakeRecords(allRecords: fix.allRecords), pricing: FakePricing())
        let s = try await service.summary(start: start, end: end)

        // Day 2 is the last (ascending sort)
        let day2 = s.buckets[2]
        #expect(day2.cost == nil)
        #expect(day2.hasUnpricedUsage)
    }

    // MARK: Cost — mixed bucket (priced + unpriced)

    @Test("Day 0 daily bucket (opus + mystery) has non-nil cost equal to opus-only sum")
    func day0MixedCostIsOpusOnly() async throws {
        let fix = Fixture()
        let (start, end) = fix.wideRange
        let service = AnalyticsService(records: FakeRecords(allRecords: fix.allRecords), pricing: FakePricing())
        let s = try await service.summary(start: start, end: end)

        let day0 = s.buckets[0]
        let cost = try #require(day0.cost)
        // Only recA0 (opus) is priced in day 0; recB0 (mystery) contributes nothing.
        let expectedDay0Cost = fix.opusCost(for: fix.recA0.usage)
        #expect(abs(cost.total - expectedDay0Cost) < 1e-9)
        #expect(cost.total > 0)
        #expect(day0.hasUnpricedUsage)
    }

    @Test("alpha byProject bucket (has both opus and mystery calls) has non-nil cost")
    func alphaProjectCostNonNil() async throws {
        let fix = Fixture()
        let (start, end) = fix.wideRange
        let service = AnalyticsService(records: FakeRecords(allRecords: fix.allRecords), pricing: FakePricing())
        let s = try await service.summary(start: start, end: end)

        let alphaBucket = try #require(s.byProject.first { $0.project == "alpha" })
        let cost = try #require(alphaBucket.cost)
        // alpha opus records: A0 + A1
        let expected = fix.opusCost(for: fix.recA0.usage) + fix.opusCost(for: fix.recA1.usage)
        #expect(abs(cost.total - expected) < 1e-9)
        #expect(alphaBucket.hasUnpricedUsage)
    }

    // MARK: Top-level summary cost

    @Test("UsageSummary.cost is non-nil and equals sum of all priced records")
    func summaryCostEqualsAllPricedRecords() async throws {
        let fix = Fixture()
        let (start, end) = fix.wideRange
        let service = AnalyticsService(records: FakeRecords(allRecords: fix.allRecords), pricing: FakePricing())
        let s = try await service.summary(start: start, end: end)

        let cost = try #require(s.cost)
        #expect(abs(cost.total - fix.expectedTotalCostUSD) < 1e-9)
        #expect(s.hasUnpricedUsage)
    }

    // MARK: Date range filtering

    @Test("FakeRecords filters to [start, end] — records outside range excluded")
    func dateRangeFiltering() async throws {
        let fix = Fixture()
        // Range covers only day 1 (t1 is noon on day 1)
        let start = fix.t1.addingTimeInterval(-3600)  // 11:00 on day 1
        let end   = fix.t1.addingTimeInterval(3600)   // 13:00 on day 1
        let service = AnalyticsService(records: FakeRecords(allRecords: fix.allRecords), pricing: FakePricing())
        let s = try await service.summary(start: start, end: end)

        // Only A1 (alpha/opus) and C1 (beta/opus) should be included
        #expect(s.byProject.count == 2)
        #expect(s.byModel.count == 1)
        #expect(s.byModel[0].model == "claude-opus-4-8")
        #expect(s.total.input == fix.recA1.usage.input + fix.recC1.usage.input)
    }

    // MARK: Cost components (input / output / cacheWrite / cacheRead)

    @Test("CostBreakdown components for opus byModel bucket are individually correct")
    func opusCostComponentsCorrect() async throws {
        let fix = Fixture()
        let (start, end) = fix.wideRange
        let service = AnalyticsService(records: FakeRecords(allRecords: fix.allRecords), pricing: FakePricing())
        let s = try await service.summary(start: start, end: end)

        let opusBucket = try #require(s.byModel.first { $0.model == "claude-opus-4-8" })
        let cost = try #require(opusBucket.cost)

        let mTok = 1_000_000.0
        let u = fix.opusTotalExpected
        let expectedInput      = Double(u.input)       / mTok * 5.00
        let expectedOutput     = Double(u.output)      / mTok * 25.00
        let expectedCacheWrite = Double(u.ephemeral5m) / mTok * 6.25
                               + Double(u.ephemeral1h) / mTok * 10.00
        let expectedCacheRead  = Double(u.cacheRead)   / mTok * 0.50

        #expect(abs(cost.input      - expectedInput)      < 1e-12)
        #expect(abs(cost.output     - expectedOutput)     < 1e-12)
        #expect(abs(cost.cacheWrite - expectedCacheWrite) < 1e-12)
        #expect(abs(cost.cacheRead  - expectedCacheRead)  < 1e-12)
    }

    // MARK: Single-day scenario (edge: all records on same day)

    /// A single-day range buckets by HOUR, so two records ten minutes apart land in the
    /// same bucket while the hours around them are present at zero. Bucketed by day this
    /// was one point, which the sparkline can only draw as a flat line.
    @Test("Single-day fixture buckets by hour, with the idle hours filled at zero")
    func singleDayBucketsByHour() async throws {
        let noon = localNoon(daysFromNow: -5)
        let r1 = makeRecord(requestId: "X1", cwd: "/p/foo", model: "claude-opus-4-8",
                            timestamp: noon, input: 100, output: 50)
        let r2 = makeRecord(requestId: "X2", cwd: "/p/bar", model: "claude-opus-4-8",
                            timestamp: noon.addingTimeInterval(600), input: 200, output: 80)
        let service = AnalyticsService(
            records: FakeRecords(allRecords: [r1, r2]),
            pricing: FakePricing()
        )
        let start = noon.addingTimeInterval(-3600)
        let end   = noon.addingTimeInterval(7200)
        let s = try await service.summary(start: start, end: end)

        #expect(s.bucketSize == .hour)
        // 11:00 through 14:00 inclusive — the window's own hours, not just the busy one.
        #expect(s.buckets.count == 4)

        let busy = try #require(s.buckets.first { $0.callCount > 0 })
        #expect(busy.date == calendar.dateInterval(of: .hour, for: noon)?.start)
        #expect(busy.callCount == 2, "Both records are inside the same clock hour")
        #expect(busy.cost != nil)

        // Every other hour is present and empty, so the x-axis means elapsed time.
        let idle = s.buckets.filter { $0.callCount == 0 }
        #expect(idle.count == 3)
        #expect(idle.allSatisfy { $0.usage.input == 0 && $0.usage.output == 0 })
        #expect(idle.allSatisfy { $0.cost == nil })

        #expect(s.total.input == 300)
        #expect(s.total.output == 130)
    }

    // MARK: FakePricing returns nil for unknown model

    @Test("FakePricing returns nil pricing for unknown models")
    func fakePricingReturnsNilForUnknown() {
        let p = FakePricing()
        #expect(p.pricing(for: "mystery-1") == nil)
        #expect(p.cost(for: .zero, model: "mystery-1") == nil)
        #expect(p.pricing(for: "claude-opus-4-8") != nil)
        #expect(p.cost(for: .zero, model: "claude-opus-4-8") != nil)
    }

    // MARK: Point-in-time pricing

    @Test("Each record is priced at the rate effective on its own timestamp, not the latest rate")
    func pointInTimePricing() async throws {
        // Cutoff: a price change takes effect at this instant.
        let cutoff = localNoon(daysFromNow: -1)
        let beforeCutoff = cutoff.addingTimeInterval(-3600)   // rate A
        let onOrAfterCutoff = cutoff                          // rate B

        let model = "claude-sonnet-5"
        let usage = TokenUsage(input: 1_000_000, output: 0, cacheRead: 0, ephemeral5m: 0, ephemeral1h: 0, webSearch: 0, webFetch: 0)

        let recBefore = makeRecord(requestId: "PIT-1", cwd: "/p/x", model: model, timestamp: beforeCutoff, input: 1_000_000)
        let recAfter  = makeRecord(requestId: "PIT-2", cwd: "/p/x", model: model, timestamp: onOrAfterCutoff, input: 1_000_000)

        let pricing = SteppedPricing(cutoff: cutoff, model: model, inputBefore: 2.0, inputAtOrAfter: 3.0)
        let service = AnalyticsService(
            records: FakeRecords(allRecords: [recBefore, recAfter]),
            pricing: pricing
        )

        let s = try await service.summary(
            start: beforeCutoff.addingTimeInterval(-3600),
            end: onOrAfterCutoff.addingTimeInterval(3600)
        )

        let costA = pricing.cost(for: usage, model: model, on: beforeCutoff)!
        let costB = pricing.cost(for: usage, model: model, on: onOrAfterCutoff)!
        let expectedTotal = costA.total + costB.total
        // If pricing were (incorrectly) applied at the latest rate to both records, the
        // total would be 2 * costB.total instead.
        #expect(abs(costA.total - 2.0) < 1e-9)
        #expect(abs(costB.total - 3.0) < 1e-9)

        let total = try #require(s.cost)
        #expect(abs(total.total - expectedTotal) < 1e-9)
        #expect(abs(total.total - 2.0 * costB.total) > 1e-6)
    }

    // MARK: byProject aggregates by full path (not basename)

    @Test("Two cwds with the same basename produce two separate rows, each with its own path")
    func byProjectAggregatesByFullPath() async throws {
        let ts = localNoon(daysFromNow: 0)
        let records = [
            makeRecord(requestId: "P1", cwd: "/Users/me/work/repo-a/app", model: "claude-opus-4-8", timestamp: ts, input: 1_000),
            makeRecord(requestId: "P2", cwd: "/Users/me/personal/repo-b/app", model: "claude-opus-4-8", timestamp: ts, input: 1_000),
        ]
        let service = AnalyticsService(records: FakeRecords(allRecords: records), pricing: FakePricing())
        let s = try await service.summary(start: localNoon(daysFromNow: -1), end: localNoon(daysFromNow: 1))

        #expect(s.byProject.count == 2)
        #expect(s.byProject.allSatisfy { $0.project == "app" })
        #expect(Set(s.byProject.map(\.path)) == ["/Users/me/work/repo-a/app", "/Users/me/personal/repo-b/app"])
    }

    @Test("Each project row carries the full cwd as its path")
    func byProjectRowCarriesPath() async throws {
        let ts = localNoon(daysFromNow: 0)
        let records = [
            makeRecord(requestId: "Q1", cwd: "/Users/me/dev/solo", model: "claude-opus-4-8", timestamp: ts, input: 1_000),
        ]
        let service = AnalyticsService(records: FakeRecords(allRecords: records), pricing: FakePricing())
        let s = try await service.summary(start: localNoon(daysFromNow: -1), end: localNoon(daysFromNow: 1))

        let row = try #require(s.byProject.first)
        #expect(row.project == "solo")
        #expect(row.path == "/Users/me/dev/solo")
    }

    // MARK: - Bucket size and contiguity

    /// The rule the whole change turns on: a range covering one local day is bucketed by
    /// hour, anything wider by day.
    @Test("bucketSize is .hour for a same-day range and .day for a wider one")
    func bucketSizeFollowsTheRange() {
        let noon = localNoon(daysFromNow: 0)
        let sameDay = AnalyticsService.bucketSize(
            start: calendar.startOfDay(for: noon), end: noon, calendar: calendar
        )
        #expect(sameDay == .hour)

        let twoDays = AnalyticsService.bucketSize(
            start: localNoon(daysFromNow: -1), end: noon, calendar: calendar
        )
        #expect(twoDays == .day)
    }

    /// "All Time" passes `.distantPast`, which is not the same day as anything — but it must
    /// not walk the calendar to find that out, and it must never produce hour buckets.
    @Test("An unbounded (All Time) range is always bucketed by day")
    func unboundedRangeBucketsByDay() {
        let size = AnalyticsService.bucketSize(
            start: .distantPast, end: Date(), calendar: calendar
        )
        #expect(size == .day)
    }

    /// An idle day in the middle of a range has to appear as a zero, not vanish: a
    /// sparkline plots values at even spacing, so a series that skips idle days draws
    /// three scattered days and three consecutive ones identically.
    @Test("A day with no records is present at zero rather than omitted")
    func idleDaysAreFilled() async throws {
        // Records on day -4 and day 0 only; the three days between are idle.
        let early = localNoon(daysFromNow: -4)
        let late = localNoon(daysFromNow: 0)
        let r1 = makeRecord(requestId: "E", cwd: "/p/foo", model: "claude-opus-4-8",
                            timestamp: early, input: 100, output: 50)
        let r2 = makeRecord(requestId: "L", cwd: "/p/foo", model: "claude-opus-4-8",
                            timestamp: late, input: 100, output: 50)
        let service = AnalyticsService(
            records: FakeRecords(allRecords: [r1, r2]), pricing: FakePricing()
        )
        let s = try await service.summary(start: early.addingTimeInterval(-3600), end: late)

        #expect(s.bucketSize == .day)
        #expect(s.buckets.count == 5, "day -4 through day 0 inclusive")
        #expect(s.buckets.map(\.callCount) == [1, 0, 0, 0, 1])
        // Dates stay contiguous and ascending at local midnight.
        for (index, bucket) in s.buckets.enumerated() {
            let expected = calendar.startOfDay(
                for: calendar.date(byAdding: .day, value: index - 4, to: late)!
            )
            #expect(bucket.date == expected)
        }
    }

    /// With no lower bound the fill has to start at the earliest record — starting at
    /// `.distantPast` would try to walk every day since the year 1.
    @Test("An unbounded range starts the series at the first record, not the epoch")
    func unboundedRangeStartsAtFirstRecord() async throws {
        let early = localNoon(daysFromNow: -2)
        let late = localNoon(daysFromNow: 0)
        let r1 = makeRecord(requestId: "E", cwd: "/p/foo", model: "claude-opus-4-8",
                            timestamp: early, input: 100, output: 50)
        let r2 = makeRecord(requestId: "L", cwd: "/p/foo", model: "claude-opus-4-8",
                            timestamp: late, input: 100, output: 50)
        let service = AnalyticsService(
            records: FakeRecords(allRecords: [r1, r2]), pricing: FakePricing()
        )
        let s = try await service.summary(start: .distantPast, end: late)

        #expect(s.bucketSize == .day)
        #expect(s.buckets.count == 3)
        #expect(s.buckets.first?.date == calendar.startOfDay(for: early))
        #expect(s.buckets.last?.date == calendar.startOfDay(for: late))
    }

    @Test("An empty range produces no buckets at all, not a run of zeros")
    func emptyRangeProducesNoBuckets() async throws {
        let service = AnalyticsService(records: FakeRecords(allRecords: []), pricing: FakePricing())
        let now = Date()
        let s = try await service.summary(start: now.addingTimeInterval(-86_400 * 5), end: now)

        #expect(s.buckets.isEmpty)
    }

    /// A timestamp far enough in the past would otherwise make the fill walk millions of
    /// buckets on the main analytics path.
    @Test("The filled series is capped rather than walking an unbounded number of buckets")
    func filledSeriesIsCapped() async throws {
        let ancient = localNoon(daysFromNow: -40_000)   // ~110 years back
        let now = localNoon(daysFromNow: 0)
        let r = makeRecord(requestId: "A", cwd: "/p/foo", model: "claude-opus-4-8",
                           timestamp: ancient, input: 100, output: 50)
        let service = AnalyticsService(
            records: FakeRecords(allRecords: [r]), pricing: FakePricing()
        )
        let s = try await service.summary(start: .distantPast, end: now)

        #expect(s.buckets.count <= AnalyticsService.maximumBuckets)
        #expect(!s.buckets.isEmpty)
    }
}

/// Stub `PricingProviding`: prices `model` at `inputBefore` USD/MTok strictly before
/// `cutoff`, and `inputAtOrAfter` USD/MTok on or after `cutoff` — mirroring how a
/// `RateHistoryStore`-backed table picks rates by record date.
private struct SteppedPricing: PricingProviding {
    let cutoff: Date
    let model: String
    let inputBefore: Double
    let inputAtOrAfter: Double

    func pricing(for model: String, on date: Date) -> ModelPricing? {
        guard model == self.model else { return nil }
        let inputPerMTok = date >= cutoff ? inputAtOrAfter : inputBefore
        return ModelPricing(
            inputPerMTok: inputPerMTok,
            outputPerMTok: 0,
            cacheWrite5mPerMTok: 0,
            cacheWrite1hPerMTok: 0,
            cacheReadPerMTok: 0
        )
    }
}

// MARK: - Large ranges

@Suite("AnalyticsService large ranges")
struct AnalyticsServiceLargeRangeTests {

    /// Prices every model except "unpriced", at a rate that changes mid-range — so a summary
    /// that priced from the wrong period, or dropped the unpriced flag, would show.
    private struct SteppedPricing: PricingProviding {
        let change: Date
        func pricing(for model: String, on date: Date) -> ModelPricing? {
            guard model != "unpriced" else { return nil }
            let rate: Double = date < change ? 1 : 2
            return ModelPricing(
                inputPerMTok: rate, outputPerMTok: rate * 5, cacheWrite5mPerMTok: rate,
                cacheWrite1hPerMTok: rate, cacheReadPerMTok: rate / 10
            )
        }
        func schedule(for model: String) -> PriceSchedule? {
            PriceSchedule(segments: [
                (.distantPast, pricing(for: model, on: .distantPast)),
                (change, pricing(for: model, on: change)),
            ])
        }
    }

    private func makeRecords(start: Date, count: Int) -> [TranscriptRecord] {
        let models = ["a", "b", "unpriced"]
        let projects = ["/p/one", "/p/two", "/p/three", "/p/four"]
        return (0..<count).map { index in
            TranscriptRecord(
                requestId: "r\(index)", sessionId: "s", cwd: projects[index % projects.count],
                model: models[index % models.count],
                // Every 60 s for ~a month, with some records exactly on the hour.
                timestamp: start.addingTimeInterval(Double(index) * 60),
                usage: TokenUsage(input: index % 97, output: index % 13, cacheRead: 3, ephemeral5m: 1,
                                  ephemeral1h: 0, webSearch: 0, webFetch: 0),
                isSidechain: false
            )
        }
    }

    @Test("A range large enough to aggregate in parallel matches a record-by-record tally", arguments: [false, true])
    func parallelMatchesSequential(useSchedule: Bool) async throws {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_780_000_000))
        let records = makeRecords(start: start, count: 40_000)
        #expect(records.count > AnalyticsService.parallelAggregationThreshold)
        let change = start.addingTimeInterval(10 * 86_400 + 1234)
        let stepped = SteppedPricing(change: change)
        let pricing: any PricingProviding = useSchedule ? stepped : NoSchedule(base: stepped)
        let end = records.last!.timestamp
        let summary = try await AnalyticsService(records: FakeRecords(allRecords: records), pricing: pricing)
            .summary(start: start, end: end)

        var expectedCost = 0.0
        var calls: [String: Int] = [:]
        var perDay: [Date: Int] = [:]
        for record in records {
            expectedCost += stepped.cost(for: record.usage, model: record.model, on: record.timestamp)?.total ?? 0
            calls[record.model, default: 0] += 1
            perDay[calendar.startOfDay(for: record.timestamp), default: 0] += 1
        }
        let total = try #require(summary.cost?.total)
        #expect(abs(total - expectedCost) <= expectedCost * 1e-12)
        #expect(summary.hasUnpricedUsage)
        #expect(Dictionary(uniqueKeysWithValues: summary.byModel.map { ($0.model, $0.callCount) }) == calls)
        #expect(summary.byProject.map(\.callCount).reduce(0, +) == records.count)
        let dayCounts = Dictionary(uniqueKeysWithValues: summary.buckets.map { ($0.date, $0.callCount) })
            .filter { $0.value > 0 }
        #expect(dayCounts == perDay, "a record exactly at midnight belongs to the day it starts")
        #expect(summary.total.input == records.reduce(0) { $0 + $1.usage.input })
    }

    /// Hides a provider's schedule, forcing the record-by-record pricing path.
    private struct NoSchedule: PricingProviding {
        let base: SteppedPricing
        func pricing(for model: String, on date: Date) -> ModelPricing? { base.pricing(for: model, on: date) }
    }

    @Test("Records stamped exactly on the hour land in that hour's bucket")
    func onTheHour() async throws {
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_780_000_000))
        let ten = calendar.date(byAdding: .hour, value: 10, to: day)!
        let eleven = calendar.date(byAdding: .hour, value: 11, to: day)!
        let records = [ten, eleven].enumerated().map { index, timestamp in
            TranscriptRecord(requestId: "r\(index)", sessionId: "s", cwd: "/p", model: "m", timestamp: timestamp,
                             usage: TokenUsage(input: 1, output: 1, cacheRead: 0, ephemeral5m: 0, ephemeral1h: 0,
                                               webSearch: 0, webFetch: 0),
                             isSidechain: false)
        }
        let summary = try await AnalyticsService(records: FakeRecords(allRecords: records), pricing: FakePricing())
            .summary(start: day, end: calendar.date(byAdding: .hour, value: 12, to: day)!)
        let counts = Dictionary(uniqueKeysWithValues: summary.buckets.map { ($0.date, $0.callCount) })
        #expect(counts[ten] == 1)
        #expect(counts[eleven] == 1)
    }
}

@Suite("AnalyticsService billing")
struct AnalyticsServiceBillingTests {

    @Test("A fast-mode request costs twice the same standard request")
    func fastModeCost() async throws {
        let usage = TokenUsage(input: 1000, output: 1000, cacheRead: 0, ephemeral5m: 0, ephemeral1h: 0,
                               webSearch: 0, webFetch: 0)
        let when = Date(timeIntervalSince1970: 1_780_000_000)
        let records = [
            TranscriptRecord(requestId: "std", sessionId: "s", cwd: "/p", model: FakePricing.opusModel,
                             timestamp: when, usage: usage, isSidechain: false),
            TranscriptRecord(requestId: "fast", sessionId: "s", cwd: "/q", model: FakePricing.opusModel,
                             timestamp: when, usage: usage, isSidechain: false, billing: .fastMode),
        ]
        let summary = try await AnalyticsService(records: FakeRecords(allRecords: records), pricing: FakePricing())
            .summary(start: when.addingTimeInterval(-60), end: when.addingTimeInterval(60))
        let byProject = Dictionary(uniqueKeysWithValues: summary.byProject.map { ($0.path, $0.cost?.total ?? 0) })
        let standard = try #require(byProject["/p"])
        #expect(standard > 0)
        #expect(abs(try #require(byProject["/q"]) - 2 * standard) < 1e-12)
    }
}
