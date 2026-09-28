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

private func gmtDate(_ y: Int, _ m: Int, _ d: Int, _ hh: Int = 12, _ mm: Int = 0) -> Date {
    var comps = DateComponents()
    comps.year = y; comps.month = m; comps.day = d; comps.hour = hh; comps.minute = mm
    return gmtCalendar.date(from: comps)!
}

private func makeRecord(
    id: String,
    timestamp: Date,
    input: Int = 0,
    output: Int = 0,
    cwd: String = "/p/x",
    model: String = "claude-opus-4-8"
) -> TranscriptRecord {
    TranscriptRecord(
        requestId: id,
        sessionId: "s-\(id)",
        cwd: cwd,
        model: model,
        timestamp: timestamp,
        usage: TokenUsage(
            input: input, output: output, cacheRead: 0,
            ephemeral5m: 0, ephemeral1h: 0, webSearch: 0, webFetch: 0
        ),
        isSidechain: false
    )
}

/// Unique temp file per test run, so parallel/repeated runs never collide.
private func tempFileURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("stats-rollup-test-\(UUID().uuidString).json")
}

@Suite("StatsRollupStore")
struct StatsRollupStoreTests {

    // MARK: 1. Aggregation across days and hours

    @Test("merge aggregates records into the right day keys, hour buckets, and request counts")
    func mergeAggregatesDaysAndHours() async throws {
        let store = StatsRollupStore(fileURL: tempFileURL(), calendar: gmtCalendar)

        let records = [
            makeRecord(id: "a", timestamp: gmtDate(2026, 8, 1, 9), input: 100, output: 50),   // day1, hour 9
            makeRecord(id: "b", timestamp: gmtDate(2026, 8, 1, 9), input: 10, output: 5),      // day1, hour 9
            makeRecord(id: "c", timestamp: gmtDate(2026, 8, 1, 14), input: 200, output: 0),    // day1, hour 14
            makeRecord(id: "d", timestamp: gmtDate(2026, 8, 2, 3), input: 1, output: 1),       // day2, hour 3
        ]

        let rollup = try await store.merge(records: records)

        let day1 = try #require(rollup.days["2026-08-01"])
        #expect(day1.requests == 3)
        #expect(day1.tokensByHour[9] == 165) // 100+50+10+5
        #expect(day1.tokensByHour[14] == 200)
        #expect(day1.totalTokens == 365)
        #expect(day1.tokensByHour.count == 24)

        let day2 = try #require(rollup.days["2026-08-02"])
        #expect(day2.requests == 1)
        #expect(day2.tokensByHour[3] == 2)
        #expect(day2.totalTokens == 2)

        // Only input+output count; cache/web fields are ignored (verified separately by
        // construction — TokenUsage.zero baseline here has no cache fields set).
    }

    // MARK: 2. Local-midnight boundary

    @Test("a record just before local midnight and one just after land in different days")
    func midnightBoundarySplitsDays() async throws {
        let store = StatsRollupStore(fileURL: tempFileURL(), calendar: gmtCalendar)

        let beforeMidnight = gmtDate(2026, 8, 1, 23, 59) // day1, hour 23
        let afterMidnight = gmtDate(2026, 8, 2, 0, 1)    // day2, hour 0

        let records = [
            makeRecord(id: "before", timestamp: beforeMidnight, input: 7, output: 0),
            makeRecord(id: "after", timestamp: afterMidnight, input: 3, output: 0),
        ]

        let rollup = try await store.merge(records: records)

        let day1 = try #require(rollup.days["2026-08-01"])
        let day2 = try #require(rollup.days["2026-08-02"])
        #expect(day1.tokensByHour[23] == 7)
        #expect(day2.tokensByHour[0] == 3)
        #expect(day1.requests == 1)
        #expect(day2.requests == 1)
    }

    // MARK: 3. Monotonic merge

    @Test("merging a smaller fresh day never clobbers a bigger stored day")
    func monotonicMergeProtectsBiggerDay() async throws {
        let store = StatsRollupStore(fileURL: tempFileURL(), calendar: gmtCalendar)

        // First merge: a big day (2 requests, 1000 tokens total).
        _ = try await store.merge(records: [
            makeRecord(id: "big1", timestamp: gmtDate(2026, 8, 1, 9), input: 600, output: 0),
            makeRecord(id: "big2", timestamp: gmtDate(2026, 8, 1, 10), input: 400, output: 0),
        ])

        // Second merge: a smaller re-scan of the same day (1 request, 50 tokens).
        let afterSmaller = try await store.merge(records: [
            makeRecord(id: "small1", timestamp: gmtDate(2026, 8, 1, 9), input: 50, output: 0),
        ])

        let day = try #require(afterSmaller.days["2026-08-01"])
        #expect(day.totalTokens == 1000, "smaller re-merge must not clobber the bigger stored day")
        #expect(day.requests == 2)

        // Third merge: a genuinely bigger day (3 requests, 2000 tokens) replaces whole.
        let afterBigger = try await store.merge(records: [
            makeRecord(id: "bigger1", timestamp: gmtDate(2026, 8, 1, 1), input: 700, output: 0),
            makeRecord(id: "bigger2", timestamp: gmtDate(2026, 8, 1, 2), input: 700, output: 0),
            makeRecord(id: "bigger3", timestamp: gmtDate(2026, 8, 1, 3), input: 600, output: 0),
        ])

        let replaced = try #require(afterBigger.days["2026-08-01"])
        #expect(replaced.totalTokens == 2000)
        #expect(replaced.requests == 3, "whole-record replace: requests must come from the fresh day, not merged field-by-field")
        // The old hour-9 bucket (from the "big" merge) must be gone — whole-record replace.
        #expect(replaced.tokensByHour[9] == 0)
        #expect(replaced.tokensByHour[1] == 700)
    }

    @Test("merging a fresh day with totalTokens EQUAL to the stored day replaces the whole record")
    func equalTotalTokensReplacesWholeRecord() async throws {
        let store = StatsRollupStore(fileURL: tempFileURL(), calendar: gmtCalendar)

        // First merge: 2 requests, 100 tokens total, all in hour 9.
        _ = try await store.merge(records: [
            makeRecord(id: "orig1", timestamp: gmtDate(2026, 8, 1, 9), input: 60, output: 0),
            makeRecord(id: "orig2", timestamp: gmtDate(2026, 8, 1, 9), input: 40, output: 0),
        ])

        // Second merge: same 100-token total, but different shape (3 requests, hour 1) —
        // spec says fresh replaces iff fresh totalTokens >= existing, so equal must replace.
        let after = try await store.merge(records: [
            makeRecord(id: "new1", timestamp: gmtDate(2026, 8, 1, 1), input: 40, output: 0),
            makeRecord(id: "new2", timestamp: gmtDate(2026, 8, 1, 1), input: 30, output: 0),
            makeRecord(id: "new3", timestamp: gmtDate(2026, 8, 1, 1), input: 30, output: 0),
        ])

        let day = try #require(after.days["2026-08-01"])
        #expect(day.totalTokens == 100)
        #expect(day.requests == 3, "equal totalTokens must still take the fresh whole record, including requests")
        #expect(day.tokensByHour[1] == 100)
        #expect(day.tokensByHour[9] == 0, "the old hour-9 bucket must be gone — whole-record replace, not merge")
    }

    // MARK: 4. Persistence + decode robustness

    @Test("round-trips through a temp fileURL")
    func persistenceRoundTrip() async throws {
        let url = tempFileURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = StatsRollupStore(fileURL: url, calendar: gmtCalendar)
        _ = try await store.merge(records: [
            makeRecord(id: "a", timestamp: gmtDate(2026, 8, 1, 9), input: 100, output: 50),
        ])

        // A fresh store instance pointed at the same file must see what was written.
        let reloaded = StatsRollupStore(fileURL: url, calendar: gmtCalendar)
        let rollup = await reloaded.load()
        #expect(rollup.days["2026-08-01"]?.totalTokens == 150)
        #expect(rollup.schemaVersion == StatsRollup.currentSchemaVersion)
    }

    @Test("a corrupt file decodes to .empty")
    func corruptFileIsEmpty() async throws {
        let url = tempFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("not valid json {{{".utf8).write(to: url)

        let store = StatsRollupStore(fileURL: url, calendar: gmtCalendar)
        #expect(await store.load() == .empty)
    }

    @Test("merging over a corrupt file quarantines the garbage to <name>.corrupt instead of overwriting it")
    func corruptFileIsQuarantinedOnMerge() async throws {
        let url = tempFileURL()
        let corruptURL = URL(fileURLWithPath: url.path + ".corrupt")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: corruptURL)
        }

        let garbage = Data("not valid json {{{".utf8)
        try garbage.write(to: url)

        let store = StatsRollupStore(fileURL: url, calendar: gmtCalendar)
        let rollup = try await store.merge(records: [
            makeRecord(id: "a", timestamp: gmtDate(2026, 8, 1, 9), input: 100, output: 0),
        ])

        // The corrupt bytes must be preserved, quarantined, never silently dropped.
        let quarantined = try Data(contentsOf: corruptURL)
        #expect(quarantined == garbage)

        // The main file now holds the fresh rollup, not a further-corrupted mix.
        #expect(rollup.days["2026-08-01"]?.totalTokens == 100)
        let onDisk = try Data(contentsOf: url)
        let decoded = try JSONDecoder().decode(StatsRollup.self, from: onDisk)
        #expect(decoded.days["2026-08-01"]?.totalTokens == 100)
    }

    @Test("A schemaVersion newer than this build understands decodes to .empty")
    func unknownSchemaVersionIsEmpty() async throws {
        let url = tempFileURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let json = """
        {"schemaVersion":99,"days":{"2026-08-01":{"day":"2026-08-01","tokensByHour":[0],"requests":1}}}
        """
        try Data(json.utf8).write(to: url)

        let store = StatsRollupStore(fileURL: url, calendar: gmtCalendar)
        #expect(await store.load() == .empty)
    }

    @Test("tokensByHour of length 23 is normalized to 24 (padded)")
    func shortTokensByHourIsPadded() async throws {
        let url = tempFileURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let shortHours = Array(repeating: 1, count: 23)
        let hoursJSON = "[" + shortHours.map(String.init).joined(separator: ",") + "]"
        let json = """
        {"schemaVersion":1,"days":{"2026-08-01":{"day":"2026-08-01","tokensByHour":\(hoursJSON),"requests":1}}}
        """
        try Data(json.utf8).write(to: url)

        let store = StatsRollupStore(fileURL: url, calendar: gmtCalendar)
        let rollup = await store.load()
        let day = try #require(rollup.days["2026-08-01"])
        #expect(day.tokensByHour.count == 24)
        #expect(day.tokensByHour[23] == 0, "padded slot must be zero")
        #expect(day.tokensByHour[0] == 1)
    }

    @Test("tokensByHour of length 25 is normalized to 24 (truncated)")
    func longTokensByHourIsTruncated() async throws {
        let url = tempFileURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let longHours = (0..<25).map { $0 }
        let hoursJSON = "[" + longHours.map(String.init).joined(separator: ",") + "]"
        let json = """
        {"schemaVersion":1,"days":{"2026-08-01":{"day":"2026-08-01","tokensByHour":\(hoursJSON),"requests":1}}}
        """
        try Data(json.utf8).write(to: url)

        let store = StatsRollupStore(fileURL: url, calendar: gmtCalendar)
        let rollup = await store.load()
        let day = try #require(rollup.days["2026-08-01"])
        #expect(day.tokensByHour.count == 24)
        #expect(day.tokensByHour == Array(0..<24), "must be the first 24 entries, extras truncated")
    }

    // MARK: Untouched days & tokens metric

    @Test("days present in the store but absent from a merge stay untouched")
    func untouchedDaysSurviveMerge() async throws {
        let url = tempFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = StatsRollupStore(fileURL: url, calendar: gmtCalendar)

        _ = try await store.merge(records: [
            makeRecord(id: "a", timestamp: gmtDate(2026, 8, 1, 9), input: 100, output: 0),
        ])
        let rollup = try await store.merge(records: [
            makeRecord(id: "b", timestamp: gmtDate(2026, 8, 5, 9), input: 50, output: 0),
        ])

        #expect(rollup.days["2026-08-01"]?.totalTokens == 100)
        #expect(rollup.days["2026-08-05"]?.totalTokens == 50)
        #expect(rollup.days.count == 2)
    }

    @Test("tokens metric is processed tokens — cache writes count, cache reads and web fields do not")
    func tokensMetricIgnoresCacheReadsAndWebFields() async throws {
        let store = StatsRollupStore(fileURL: tempFileURL(), calendar: gmtCalendar)
        let record = TranscriptRecord(
            requestId: "r1", sessionId: "s1", cwd: "/p", model: "m",
            timestamp: gmtDate(2026, 8, 1, 9),
            usage: TokenUsage(input: 10, output: 5, cacheRead: 999, ephemeral5m: 999, ephemeral1h: 999, webSearch: 999, webFetch: 999),
            isSidechain: false
        )
        let rollup = try await store.merge(records: [record])
        #expect(rollup.days["2026-08-01"]?.totalTokens == 10 + 999 + 999 + 5)
    }

    @Test("sidechain records are included, matching AnalyticsService's own behavior")
    func sidechainRecordsAreIncluded() async throws {
        let store = StatsRollupStore(fileURL: tempFileURL(), calendar: gmtCalendar)
        let record = TranscriptRecord(
            requestId: "r1", sessionId: "s1", cwd: "/p", model: "m",
            timestamp: gmtDate(2026, 8, 1, 9),
            usage: TokenUsage(input: 10, output: 5, cacheRead: 0, ephemeral5m: 0, ephemeral1h: 0, webSearch: 0, webFetch: 0),
            isSidechain: true
        )
        let rollup = try await store.merge(records: [record])
        #expect(rollup.days["2026-08-01"]?.totalTokens == 15)
        #expect(rollup.days["2026-08-01"]?.requests == 1)
    }
}

// MARK: - Token definition

@Suite("StatsRollupStore token definition")
struct StatsRollupTokenDefinitionTests {

    private func tempFileURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("rollup-\(UUID().uuidString).json")
    }

    private func record(_ id: String, _ timestamp: Date, input: Int, cacheWrite: Int, cacheRead: Int, output: Int) -> TranscriptRecord {
        TranscriptRecord(
            requestId: id, sessionId: "s", cwd: "/p", model: "m", timestamp: timestamp,
            usage: TokenUsage(input: input, output: output, cacheRead: cacheRead,
                              ephemeral5m: cacheWrite, ephemeral1h: 0, webSearch: 0, webFetch: 0),
            isSidechain: false
        )
    }

    @Test("A day counts uncached input, cache writes and output — never cache reads")
    func countsProcessedTokens() async throws {
        let url = tempFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = StatsRollupStore(fileURL: url, calendar: gmtCalendar)
        // Claude-shaped (new context as cache writes) and Codex-shaped (as input) requests of
        // the same size must count the same.
        let merged = try await store.merge(records: [
            record("claude", gmtDate(2026, 8, 1, 9), input: 5, cacheWrite: 995, cacheRead: 50_000, output: 100),
            record("codex", gmtDate(2026, 8, 1, 10), input: 1000, cacheWrite: 0, cacheRead: 50_000, output: 100),
        ])
        let day = try #require(merged.days["2026-08-01"])
        #expect(day.tokensByHour[9] == 1100)
        #expect(day.tokensByHour[10] == 1100)
    }

    @Test("A rollup from the old definition is recomputed wholesale, keeping days it cannot recompute")
    func oldSchemaIsRecomputed() async throws {
        let url = tempFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        // Version 1 stored input + output. A recomputed day can legitimately come out SMALLER
        // (never for real data, but the monotonic guard must not be what decides), and a day
        // with no surviving records keeps its old value.
        let hours = Array(repeating: 0, count: 23) + [9_999]
        let json = """
        {"schemaVersion":1,"days":{\
        "2026-08-01":{"day":"2026-08-01","tokensByHour":\(hours),"requests":9},\
        "2026-07-01":{"day":"2026-07-01","tokensByHour":\(hours),"requests":9}}}
        """
        try Data(json.utf8).write(to: url)
        let store = StatsRollupStore(fileURL: url, calendar: gmtCalendar)
        #expect(await store.load().needsFullRecompute)

        let merged = try await store.merge(records: [
            record("a", gmtDate(2026, 8, 1, 9), input: 5, cacheWrite: 95, cacheRead: 7, output: 10),
        ])
        #expect(merged.schemaVersion == StatsRollup.currentSchemaVersion)
        #expect(merged.days["2026-08-01"]?.totalTokens == 110)
        #expect(merged.days["2026-08-01"]?.requests == 1)
        #expect(merged.days["2026-07-01"]?.totalTokens == 9_999)
        #expect(await store.load().needsFullRecompute == false)
    }
}
