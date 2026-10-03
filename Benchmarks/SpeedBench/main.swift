/// Measures the generation speed report: the covering-index query and the report build.
///
/// Not a test — it reports timings and checks them against the budgets. Run in
/// release: `swift run -c release SpeedBench [fixture.sqlite3]`. Without a fixture it
/// builds a synthetic index of `ROWS` (default 2,000,000) measured requests.
///
/// Budgets for query + report, split 70% / 30% between them: 30 ms on a real archive (the
/// fixture) and 500 ms on the synthetic 2M index. The synthetic budget is the accepted one
/// (2026-10-03): the query reads every sample through `sqlite3_step`,
/// so with 2M of them query + report cannot fit the spec's original 150 ms.
/// A pre-aggregated rollup could; it is deferred until real histories approach that size.
import Foundation
import TokiModels
import TokiTranscripts
import TokiAnalytics

let iterations = Int(ProcessInfo.processInfo.environment["ITERATIONS"] ?? "") ?? 20
let fixture = CommandLine.arguments.dropFirst().first

func measure(_ label: String, budgetMs: Double, _ body: () throws -> Void) rethrows {
    try body()   // warm-up
    var samples: [Double] = []
    for _ in 0..<iterations {
        let t0 = DispatchTime.now().uptimeNanoseconds
        try body()
        samples.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000)
    }
    samples.sort()
    let p50 = samples[samples.count / 2], p90 = samples[Int(Double(samples.count) * 0.9)]
    let verdict = p50 <= budgetMs ? "OK" : "OVER BUDGET"
    print(String(format: "%-34@ p50 %7.2f  p90 %7.2f ms  budget %5.0f  %@",
                 label as NSString, p50, p90, budgetMs, verdict as NSString))
}

let url: URL
let budget: Double
if let fixture {
    url = URL(fileURLWithPath: fixture)
    budget = 30
} else {
    let rows = Int(ProcessInfo.processInfo.environment["ROWS"] ?? "") ?? 2_000_000
    url = URL(fileURLWithPath: NSTemporaryDirectory() + "toki-speed-bench-\(UUID().uuidString).sqlite3")
    budget = 500
    let store = try TranscriptStore(databaseURL: url)
    let models = ["claude-opus-5-5", "claude-sonnet-5-5", "claude-fable-5-1", "gpt-6-sol", "gpt-6.1-sol"]
    let efforts: [String?] = ["low", "medium", "high", "xhigh", nil]
    var rng = SystemRandomNumberGenerator()
    let start = Int64(Date().timeIntervalSince1970 * 1000) - 365 * 86_400_000
    var batch: [TranscriptRecord] = []
    batch.reserveCapacity(50_000)
    for i in 0..<rows {
        let out = Int.random(in: 150...4_000, using: &rng)
        batch.append(TranscriptRecord(
            requestId: "bench-\(i)", sessionId: "s", cwd: "/bench", model: models[i % models.count],
            timestamp: Date(timeIntervalSince1970: Double(start + Int64(i) * 15_000) / 1000),
            usage: TokenUsage(input: 1, output: out, cacheRead: 0, ephemeral5m: 0, ephemeral1h: 0, webSearch: 0, webFetch: 0),
            isSidechain: false,
            generationMs: Int.random(in: 1_000...60_000, using: &rng),
            effort: efforts[(i / 7) % efforts.count], isFast: i % 11 == 0))
        if batch.count == 50_000 { try store.upsertEntries(batch); batch.removeAll(keepingCapacity: true) }
    }
    try store.upsertEntries(batch)
    print("synthetic index: \(rows) rows at \(url.path)")
}

let store = try TranscriptStore(databaseURL: url)
let samples = try store.speedSamples()
print("samples: \(samples.count) in \(samples.groups.count) groups")
try measure("query (speedSamples)", budgetMs: budget * 0.7) { _ = try store.speedSamples() }
measure("report (GenerationSpeedReport)", budgetMs: budget * 0.3) {
    _ = GenerationSpeedReport(samples: samples, calendar: .current)
}
try measure("query + report", budgetMs: budget) {
    _ = GenerationSpeedReport(samples: try store.speedSamples(), calendar: .current)
}
if fixture == nil { try? FileManager.default.removeItem(at: url) }
