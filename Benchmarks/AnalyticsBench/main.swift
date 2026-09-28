/// Measures the analytics query path against a real transcript index.
///
/// Not a test: it reports timings, so it lives outside the suite and is run by hand
/// (`swift run -c release AnalyticsBench <fixture.sqlite3>`). Release configuration is not
/// optional — a debug build measures Swift's unoptimised retain/release traffic, not the
/// query path.
import Foundation
import TokiModels
import TokiTranscripts
import TokiAnalytics
import TokiPricing
import SQLite3

let fixture = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "/tmp/toki-bench/fixture.sqlite3"

let iterations = Int(ProcessInfo.processInfo.environment["ITERATIONS"] ?? "") ?? 30

struct Stats {
    let samples: [Double]
    var sorted: [Double] { samples.sorted() }
    func percentile(_ p: Double) -> Double {
        let s = sorted
        guard !s.isEmpty else { return 0 }
        let rank = max(0, Int((Double(s.count) * p).rounded(.up)) - 1)
        return s[rank]
    }
    var min: Double { sorted.first ?? 0 }
    var mean: Double { samples.reduce(0, +) / Double(samples.count) }
}

func measure(_ label: String, _ body: () async throws -> Void) async rethrows -> Stats {
    // One warm-up pass so page cache and prepared-statement costs are not counted as p50.
    try await body()
    var samples: [Double] = []
    for _ in 0..<iterations {
        let t0 = DispatchTime.now().uptimeNanoseconds
        try await body()
        samples.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000)
    }
    let stats = Stats(samples: samples)
    print(String(
        format: "%-28@ min %7.2f  p50 %7.2f  p90 %7.2f  p99 %7.2f  mean %7.2f  (ms, n=%d)",
        label as NSString, stats.min, stats.percentile(0.5), stats.percentile(0.9),
        stats.percentile(0.99), stats.mean, iterations
    ))
    return stats
}

let store = try TranscriptStore(databaseURL: URL(fileURLWithPath: fixture))
let pricing = LivePricingTable()

/// Adapter so the benchmark drives the same `AnalyticsProviding` the app uses.
/// `@unchecked`: the harness is single-threaded, and the store is opened once here.
final class StoreRecords: RecordProviding, @unchecked Sendable {
    let store: TranscriptStore
    init(store: TranscriptStore) { self.store = store }
    func records(start: Date, end: Date) async throws -> [TranscriptRecord] {
        try store.records(start: start, end: end)
    }
}

let analytics = AnalyticsService(records: StoreRecords(store: store), pricing: pricing)
let now = Date()
let ranges: [(String, Date)] = [
    ("today", now.addingTimeInterval(-24 * 3600)),
    ("7 days", now.addingTimeInterval(-7 * 24 * 3600)),
    ("30 days", now.addingTimeInterval(-30 * 24 * 3600)),
    ("all time", Date(timeIntervalSince1970: 0)),
]

print("fixture: \(fixture)")
print("--- full summary (fetch + aggregate + price) ---")
for (label, start) in ranges {
    let count = try store.records(start: start, end: now).count
    _ = try await measure("summary(\(label)) \(count) rows") {
        _ = try await analytics.summary(start: start, end: now)
    }
}

// Split the cost: how much is fetching rows out of SQLite, and how much is the Swift-side
// aggregation and per-record price lookup layered on top?
print("--- fetch only (SQLite -> [TranscriptRecord]) ---")
for (label, start) in ranges {
    _ = try await measure("records(\(label))") {
        _ = try store.records(start: start, end: now)
    }
}

print("--- price lookup only (one call per row, no aggregation) ---")
for (label, start) in ranges {
    let rows = try store.records(start: start, end: now)
    _ = await measure("pricing(\(label))") {
        var sink = 0.0
        for r in rows {
            sink += pricing.cost(for: r.usage, model: r.model, on: r.timestamp)?.total ?? 0
        }
        if sink.isNaN { print("unreachable") }
    }
}


// MARK: - Where does the fetch cost actually sit?
//
// The question this answers: would a custom-built SQLite (compile-time tuning, vendored
// amalgamation) pay off? Only if the engine itself dominates. So walk the same rows three
// ways — engine only, engine + the four per-row strings, and engine + full row decode —
// and compare.
print("--- fetch anatomy (all time, 36,720 rows) ---")

/// Wrapped in a class so the raw handle is not main-actor-isolated global state.
final class RawDB: @unchecked Sendable {
    var handle: OpaquePointer?
    init(path: String) { sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil) }
    deinit { sqlite3_close(handle) }

    func scan(_ sql: String, readStrings: Bool) -> Int {
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(handle, sql, -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        var n = 0
        while sqlite3_step(stmt) == SQLITE_ROW {
            n += Int(sqlite3_column_int64(stmt, 0))
            if readStrings {
                for col in Int32(1)...Int32(4) {
                    _ = String(cString: sqlite3_column_text(stmt, col))
                }
            }
        }
        return n
    }

    func groupBy() {
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(handle, """
            SELECT timestamp_ms / 86400000, model,
                   SUM(input_tokens), SUM(output_tokens), SUM(cache_read_tokens), COUNT(*)
            FROM entries GROUP BY 1, 2;
            """, -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {}
    }
}
let raw = RawDB(path: fixture)

_ = await measure("engine only (ints)") {
    _ = raw.scan("SELECT input_tokens FROM entries ORDER BY timestamp_ms ASC;", readStrings: false)
}
_ = await measure("engine + 4 strings/row") {
    _ = raw.scan(
        "SELECT input_tokens, request_id, session_id, cwd, model FROM entries ORDER BY timestamp_ms ASC;",
        readStrings: true
    )
}
_ = await measure("full decode (store)") {
    _ = try? store.records(start: Date(timeIntervalSince1970: 0), end: now)
}

// And the aggregate the app actually needs, computed by the engine instead of in Swift.
_ = await measure("SQL GROUP BY day+model") { raw.groupBy() }


// PRAGMA tuning, measured rather than assumed: memory-mapped I/O and a bigger page cache
// are the two knobs that cost nothing to set.
print("--- pragma tuning (engine only, all rows) ---")
let tuned = RawDB(path: fixture)
for pragma in ["mmap_size=268435456", "cache_size=-16000", "temp_store=MEMORY"] {
    sqlite3_exec(tuned.handle, "PRAGMA \(pragma);", nil, nil, nil)
}
_ = await measure("tuned engine only (ints)") {
    _ = tuned.scan("SELECT input_tokens FROM entries ORDER BY timestamp_ms ASC;", readStrings: false)
}
_ = await measure("tuned SQL GROUP BY") { tuned.groupBy() }

var version: String = ""
if let v = sqlite3_libversion() { version = String(cString: v) }
print("system sqlite: \(version)")

// MARK: - Statistics rollup merge
//
// The Usage tab's all-time statistics re-merge the last 45 days of records into the durable
// rollup on every load (launch, opening the dashboard, refresh).
print("--- statistics rollup merge (last 45 days) ---")
let rollupURL = URL(fileURLWithPath: NSTemporaryDirectory() + "toki-bench-rollup-\(UUID().uuidString).json")
let rollupStore = StatsRollupStore(fileURL: rollupURL)
let mergeStart = Calendar.current.date(byAdding: .day, value: -45, to: now)!
let mergeRows = try store.records(start: mergeStart, end: now)
_ = try await measure("merge(\(mergeRows.count) rows)") {
    _ = try await rollupStore.merge(records: mergeRows)
}
try? FileManager.default.removeItem(at: rollupURL)
