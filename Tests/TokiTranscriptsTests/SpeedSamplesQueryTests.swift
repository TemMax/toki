import Foundation
import SQLite3
import Testing
import TokiModels
@testable import TokiTranscripts

@Suite("Speed sample query")
struct SpeedSamplesQueryTests {
    private func rec(_ id: String, model: String, effort: String?, fast: Bool = false,
                     ms: Int?, out: Int, at t: Int64) -> TranscriptRecord {
        TranscriptRecord(requestId: id, sessionId: "s", cwd: "/c", model: model,
                         timestamp: Date(timeIntervalSince1970: Double(t) / 1000),
                         usage: TokenUsage(input: 1, output: out, cacheRead: 0, ephemeral5m: 0, ephemeral1h: 0, webSearch: 0, webFetch: 0),
                         isSidechain: false, generationMs: ms, effort: effort, isFast: fast)
    }

    private func makeStore() throws -> (TranscriptStore, URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("speed-q-\(UUID().uuidString).sqlite3")
        return (try TranscriptStore(databaseURL: url), url)
    }

    @Test("Only measurable samples, grouped and in group-then-time order")
    func filtersAndOrders() throws {
        let (store, url) = try makeStore(); defer { try? FileManager.default.removeItem(at: url) }
        try store.upsertEntries([
            rec("b2", model: "claude-opus-5-5", effort: "high", ms: 2_000, out: 300, at: 2_000),
            rec("a1", model: "claude-haiku-4-5", effort: nil, ms: 1_000, out: 250, at: 5_000),
            rec("b1", model: "claude-opus-5-5", effort: "high", ms: 3_000, out: 600, at: 1_000),
            rec("f1", model: "claude-opus-5-5", effort: "high", fast: true, ms: 1_500, out: 400, at: 1_500),
            rec("x1", model: "claude-opus-5-5", effort: "high", ms: nil, out: 900, at: 3_000),     // no duration
            rec("x2", model: "claude-opus-5-5", effort: "high", ms: 5_000, out: 199, at: 3_000),   // too short
            rec("x3", model: "claude-opus-5-5", effort: "high", ms: 300, out: 500, at: 3_000),     // ≤ 300 ms
            rec("x4", model: "claude-opus-5-5", effort: "high", ms: 900_001, out: 500, at: 3_000), // > 15 min
        ])
        let s = try store.speedSamples()
        #expect(s.groups == [
            SpeedSampleGroup(model: "claude-haiku-4-5", effort: nil, isFast: false),
            SpeedSampleGroup(model: "claude-opus-5-5", effort: "high", isFast: false),
            SpeedSampleGroup(model: "claude-opus-5-5", effort: "high", isFast: true),
        ])
        #expect(s.group == [0, 1, 1, 2])
        #expect(s.timestampMs == [5_000, 1_000, 2_000, 1_500])
        #expect(s.outputTokens == [250, 600, 300, 400])
        #expect(s.generationMs == [1_000, 3_000, 2_000, 1_500])
    }

    @Test("The one statement is answered from the covering index alone, without a sort")
    func usesCoveringIndex() throws {
        let (_, url) = try makeStore(); defer { try? FileManager.default.removeItem(at: url) }
        let name = "idx_entries_speed_\(SpeedSampleFilter.minOutputTokens)_\(SpeedSampleFilter.minGenerationMs)_\(SpeedSampleFilter.maxGenerationMs)"
        #expect(TranscriptStore.speedIndexName == name)
        #expect(name == "idx_entries_speed_200_300_900000")
        var db: OpaquePointer?
        sqlite3_open(url.path, &db); defer { sqlite3_close(db) }
        let sql = TranscriptStore.speedSamplesSQL
        var stmt: OpaquePointer?
        #expect(sqlite3_prepare_v2(db, "EXPLAIN QUERY PLAN " + sql, -1, &stmt, nil) == SQLITE_OK,
                "\(String(cString: sqlite3_errmsg(db)))")
        var plan = ""
        while sqlite3_step(stmt) == SQLITE_ROW { plan += String(cString: sqlite3_column_text(stmt, 3)) + "\n" }
        sqlite3_finalize(stmt)
        #expect(plan.contains("COVERING INDEX \(name)"), "\(sql)\n\(plan)")
        #expect(!plan.contains("TEMP B-TREE"), "the index order must make sorting unnecessary: \(sql)\n\(plan)")
    }

    @Test("Durations at 300 ms or past 900,000 ms are outside the index and never read")
    func durationBoundsAreInTheIndex() throws {
        let (store, url) = try makeStore(); defer { try? FileManager.default.removeItem(at: url) }
        try store.upsertEntries([
            rec("lo", model: "claude-opus-5-5", effort: "high", ms: 300, out: 500, at: 1_000),       // excluded
            rec("lo1", model: "claude-opus-5-5", effort: "high", ms: 301, out: 500, at: 2_000),
            rec("hi", model: "claude-opus-5-5", effort: "high", ms: 900_000, out: 500, at: 3_000),
            rec("hi1", model: "claude-opus-5-5", effort: "high", ms: 900_001, out: 500, at: 4_000),  // excluded
        ])
        let s = try store.speedSamples()
        #expect(s.groups == [SpeedSampleGroup(model: "claude-opus-5-5", effort: "high", isFast: false)])
        #expect(s.group == [0, 0])
        #expect(s.timestampMs == [2_000, 3_000])
        #expect(s.generationMs == [301, 900_000])

        // The index itself holds only the two in-range rows of the table's four: its `WHERE`
        // carries both bounds, and counting through it finds two entries.
        var db: OpaquePointer?
        sqlite3_open(url.path, &db); defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT sql FROM sqlite_master WHERE name = '\(TranscriptStore.speedIndexName)';", -1, &stmt, nil)
        #expect(sqlite3_step(stmt) == SQLITE_ROW)
        let indexSQL = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
        sqlite3_finalize(stmt)
        #expect(indexSQL.hasSuffix("WHERE \(TranscriptStore.speedIndexPredicate)"), "\(indexSQL)")
        #expect(indexSQL.contains("generation_ms > 300"), "\(indexSQL)")
        #expect(indexSQL.contains("generation_ms <= 900000"), "\(indexSQL)")
        #expect(sqlite3_prepare_v2(db, """
            SELECT COUNT(*) FROM entries INDEXED BY \(TranscriptStore.speedIndexName)
            WHERE \(TranscriptStore.speedIndexPredicate);
            """, -1, &stmt, nil) == SQLITE_OK, "\(String(cString: sqlite3_errmsg(db)))")
        #expect(sqlite3_step(stmt) == SQLITE_ROW)
        #expect(sqlite3_column_int64(stmt, 0) == 2)
        sqlite3_finalize(stmt)
    }

    @Test("A speed index built for another floor is replaced, and the query still runs")
    func replacesIndexOfAnotherFloor() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("speed-q-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: url) }
        try TranscriptStore(databaseURL: url).upsertEntries([
            rec("a1", model: "claude-opus-5-5", effort: "high", ms: 2_000, out: 300, at: 1_000),
            rec("a2", model: "claude-opus-5-5", effort: "high", ms: 1_000, out: 150, at: 2_000),
        ])
        // What an index of an older build looks like: the floor alone in its name (no duration
        // bounds in its `WHERE`), another floor, and the name from before the floor was part
        // of it.
        var db: OpaquePointer?
        sqlite3_open(url.path, &db)
        for sql in [
            "DROP INDEX \(TranscriptStore.speedIndexName);",
            """
            CREATE INDEX idx_entries_speed_\(SpeedSampleFilter.minOutputTokens) ON entries(model, effort, fast, timestamp_ms, output_tokens, generation_ms)
            WHERE generation_ms IS NOT NULL AND output_tokens >= \(SpeedSampleFilter.minOutputTokens);
            """,
            """
            CREATE INDEX idx_entries_speed_100 ON entries(model, effort, fast, timestamp_ms, output_tokens, generation_ms)
            WHERE generation_ms IS NOT NULL AND output_tokens >= 100;
            """,
            """
            CREATE INDEX idx_entries_speed ON entries(model, effort, fast, timestamp_ms, output_tokens, generation_ms)
            WHERE generation_ms IS NOT NULL AND output_tokens >= 100;
            """,
        ] {
            #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK, "\(String(cString: sqlite3_errmsg(db)))")
        }
        sqlite3_close(db)

        let store = try TranscriptStore(databaseURL: url)
        let s = try store.speedSamples()
        #expect(s.groups == [SpeedSampleGroup(model: "claude-opus-5-5", effort: "high", isFast: false)])
        #expect(s.timestampMs == [1_000])

        sqlite3_open(url.path, &db); defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT name FROM sqlite_master WHERE type = 'index' AND name LIKE 'idx_entries_speed%';", -1, &stmt, nil)
        var names: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW { names.append(String(cString: sqlite3_column_text(stmt, 0))) }
        sqlite3_finalize(stmt)
        #expect(names == [TranscriptStore.speedIndexName])
    }
}
