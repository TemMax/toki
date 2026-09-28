/// Measures building the transcript index from the real on-disk archive.
///
/// Not a test: it reports timings, so it lives outside the suite and is run by hand
/// (`swift run -c release IndexBench [db-path]`). It indexes `~/.claude/projects` and
/// `~/.codex/sessions` (+ `archived_sessions`) into a scratch database, twice: the first
/// pass is a cold build from nothing, the second is the launch-time catch-up over an index
/// that is already current — the case every normal launch hits.
import Foundation
import TokiTranscripts

let dbPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : NSTemporaryDirectory() + "toki-index-bench-\(UUID().uuidString).sqlite3"
let dbURL = URL(fileURLWithPath: dbPath)

/// Peak resident set size so far, in MB (`ru_maxrss` is bytes on macOS).
func peakRSSMegabytes() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_maxrss) / 1_048_576
}

func timed(_ label: String, _ body: () async throws -> Void) async rethrows {
    let start = DispatchTime.now().uptimeNanoseconds
    try await body()
    let seconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
    print(String(format: "%-22@ %8.2f s   peak RSS %8.1f MB", label as NSString, seconds, peakRSSMegabytes()))
}

print("database: \(dbPath)")
let indexer = TranscriptIndexer(databaseURL: dbURL)
try await timed("cold build") { try await indexer.reindex() }
try await timed("warm catch-up") { try await indexer.reindex() }
let count = await indexer.allRecords().count
print("records: \(count)")
