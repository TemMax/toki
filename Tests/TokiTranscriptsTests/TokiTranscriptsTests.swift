import Testing
import Foundation
import TokiModels
import SQLite3
@testable import TokiTranscripts

// MARK: - Per-test temp sandbox

/// A unique temporary directory for a single test. Every test that touches the filesystem or a
/// SQLite DB allocates one of these with a fresh UUID, so the default *parallel* Swift Testing
/// runner never sees shared paths. `cleanup()` removes the whole tree.
///
/// IMPORTANT: nothing here ever touches the real Application Support directory or real user data.
private struct TempSandbox {
    let root: URL

    init() {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokiTranscriptsTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// A path for the SQLite DB (parent dir already exists).
    var dbURL: URL { root.appendingPathComponent("index.sqlite3") }

    /// A `projects/` subdirectory, created on demand.
    func projectsDir() -> URL {
        let dir = root.appendingPathComponent("projects", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func file(_ name: String) -> URL { root.appendingPathComponent(name) }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

// MARK: - JSONL fixture builders

/// Builds a single assistant JSONL line with the given fields.
private func assistantLine(
    requestId: String,
    sessionId: String = "sess-1",
    cwd: String = "/Users/me/proj",
    model: String = "claude-opus-4-8",
    timestamp: String = "2026-06-29T16:30:01.123Z",
    isSidechain: Bool? = nil,
    usage: [String: Any]
) -> String {
    var message: [String: Any] = ["model": model, "usage": usage]
    _ = message // silence if unused warnings on some toolchains
    var obj: [String: Any] = [
        "type": "assistant",
        "requestId": requestId,
        "sessionId": sessionId,
        "cwd": cwd,
        "timestamp": timestamp,
        "message": ["model": model, "usage": usage] as [String: Any],
    ]
    if let isSidechain { obj["isSidechain"] = isSidechain }
    let data = try! JSONSerialization.data(withJSONObject: obj)
    return String(data: data, encoding: .utf8)!
}

// MARK: - TranscriptParser

@Suite("TranscriptParser")
struct TranscriptParserTests {

    @Test("Full assistant record with cache_creation split → correct TokenUsage")
    func fullAssistantWithCacheSplit() {
        let line = assistantLine(
            requestId: "req-1",
            usage: [
                "input_tokens": 120,
                "output_tokens": 350,
                "cache_read_input_tokens": 4000,
                "cache_creation_input_tokens": 700,
                "cache_creation": [
                    "ephemeral_5m_input_tokens": 500,
                    "ephemeral_1h_input_tokens": 200,
                ] as [String: Any],
                "server_tool_use": [
                    "web_search_requests": 2,
                    "web_fetch_requests": 1,
                ] as [String: Any],
            ]
        )
        let record = TranscriptParser.parse(line: line)
        #expect(record != nil)
        let u = record!.usage
        #expect(u.input == 120)
        #expect(u.output == 350)
        #expect(u.cacheRead == 4000)
        #expect(u.ephemeral5m == 500)
        #expect(u.ephemeral1h == 200)
        #expect(u.webSearch == 2)
        #expect(u.webFetch == 1)
    }

    @Test("Synthetic-model record → nil")
    func syntheticModelReturnsNil() {
        let line = assistantLine(
            requestId: "req-syn",
            model: "<synthetic>",
            usage: ["input_tokens": 10, "output_tokens": 20]
        )
        #expect(TranscriptParser.parse(line: line) == nil)
    }

    @Test("Non-assistant type → nil")
    func nonAssistantReturnsNil() {
        let obj: [String: Any] = [
            "type": "user",
            "requestId": "req-u",
            "timestamp": "2026-06-29T16:30:01.123Z",
            "message": ["model": "claude-opus-4-8", "usage": ["input_tokens": 5]] as [String: Any],
        ]
        let data = try! JSONSerialization.data(withJSONObject: obj)
        let line = String(data: data, encoding: .utf8)!
        #expect(TranscriptParser.parse(line: line) == nil)
    }

    @Test("No cache_creation object → ephemeral5m == aggregate, ephemeral1h == 0 (D6)")
    func noCacheCreationFallback() {
        let line = assistantLine(
            requestId: "req-2",
            usage: [
                "input_tokens": 50,
                "output_tokens": 60,
                "cache_creation_input_tokens": 900,
                // no "cache_creation" sub-object
            ]
        )
        let record = TranscriptParser.parse(line: line)
        #expect(record != nil)
        #expect(record!.usage.ephemeral5m == 900)
        #expect(record!.usage.ephemeral1h == 0)
    }

    @Test("input_tokens == 1 is parsed as value 1 (D7 placeholder, still recorded faithfully)")
    func inputTokensOnePreserved() {
        let line = assistantLine(
            requestId: "req-3",
            usage: ["input_tokens": 1, "output_tokens": 200]
        )
        let record = TranscriptParser.parse(line: line)
        #expect(record != nil)
        #expect(record!.usage.input == 1)
        #expect(record!.usage.output == 200)
    }

    @Test("Field extraction: requestId/sessionId/cwd/model/timestamp/isSidechain")
    func fieldExtraction() {
        let line = assistantLine(
            requestId: "rid-x",
            sessionId: "sid-y",
            cwd: "/Users/me/myproject",
            model: "claude-sonnet-4-5",
            timestamp: "2026-06-29T16:30:01.123Z",
            isSidechain: true,
            usage: ["input_tokens": 1, "output_tokens": 1]
        )
        let record = TranscriptParser.parse(line: line)
        #expect(record != nil)
        let r = record!
        #expect(r.requestId == "rid-x")
        #expect(r.sessionId == "sid-y")
        #expect(r.cwd == "/Users/me/myproject")
        #expect(r.model == "claude-sonnet-4-5")
        #expect(r.isSidechain == true)
        #expect(r.projectName == "myproject")
        // 2026-06-29T16:30:01.123Z in epoch seconds.
        let expected = ISO8601DateFormatter().date(from: "2026-06-29T16:30:01Z")!
        #expect(abs(r.timestamp.timeIntervalSince1970 - expected.timeIntervalSince1970) < 1.0)
    }

    @Test("Non-fractional timestamp parses via plain formatter")
    func plainTimestampParses() {
        let line = assistantLine(
            requestId: "req-ts",
            timestamp: "2026-06-29T16:30:01Z",
            usage: ["input_tokens": 1, "output_tokens": 1]
        )
        #expect(TranscriptParser.parse(line: line) != nil)
    }
}

// MARK: - LineScanner

/// Collects every line a scan delivers, as strings, with its completeness flag.
private func scanAll(
    _ url: URL,
    from offset: UInt64 = 0,
    maxLineBytes: Int = LineScanner.defaultMaxLineBytes
) throws -> (lines: [String], complete: [Bool], result: LineScanner.Result) {
    var lines: [String] = []
    var complete: [Bool] = []
    let result = try LineScanner.scan(path: url.path, from: offset, maxLineBytes: maxLineBytes) { bytes, isComplete in
        lines.append(String(decoding: bytes, as: UTF8.self))
        complete.append(isComplete)
    }
    return (lines, complete, result)
}

@Suite("LineScanner")
struct LineScannerTests {

    @Test("Every newline-terminated line is delivered complete, and the whole file is consumed")
    func completeLines() throws {
        let sandbox = TempSandbox()
        defer { sandbox.cleanup() }
        let url = sandbox.file("a.jsonl")
        try "one\ntwo\r\nthree\n".write(to: url, atomically: true, encoding: .utf8)

        let scan = try scanAll(url)
        #expect(scan.lines == ["one", "two", "three"], "a trailing CR is trimmed")
        #expect(scan.complete == [true, true, true])
        #expect(scan.result.consumedOffset == 15)
        #expect(scan.result.completeLines == 3)
    }

    @Test("An unterminated last line is delivered as incomplete and not consumed")
    func partialTrailingLine() throws {
        let sandbox = TempSandbox()
        defer { sandbox.cleanup() }
        let url = sandbox.file("a.jsonl")
        try "done\nhalf".write(to: url, atomically: true, encoding: .utf8)

        let scan = try scanAll(url)
        #expect(scan.lines == ["done", "half"])
        #expect(scan.complete == [true, false])
        #expect(scan.result.consumedOffset == 5, "the next scan must re-read the half line")
    }

    @Test("Resuming from the consumed offset returns only what was appended")
    func resumesFromOffset() throws {
        let sandbox = TempSandbox()
        defer { sandbox.cleanup() }
        let url = sandbox.file("a.jsonl")
        try "first\nsec".write(to: url, atomically: true, encoding: .utf8)
        let first = try scanAll(url)

        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("ond\nthird\n".utf8))
        try handle.close()

        let second = try scanAll(url, from: first.result.consumedOffset)
        #expect(second.lines == ["second", "third"])
        #expect(second.complete == [true, true])
    }

    @Test("A line longer than the initial buffer is delivered intact")
    func growsForLongLines() throws {
        let sandbox = TempSandbox()
        defer { sandbox.cleanup() }
        let url = sandbox.file("long.jsonl")
        let long = String(repeating: "L", count: 3 * 1024 * 1024)
        try (long + "\nshort\n").write(to: url, atomically: true, encoding: .utf8)

        let scan = try scanAll(url)
        #expect(scan.lines.map(\.count) == [long.count, 5])
    }

    @Test("A line over the cap is skipped and scanning resynchronises at the next newline")
    func oversizedLineIsSkipped() throws {
        let sandbox = TempSandbox()
        defer { sandbox.cleanup() }
        let url = sandbox.file("huge.jsonl")
        let blob = String(repeating: "B", count: 1000)
        try ("before\n" + blob + "\nafter\n").write(to: url, atomically: true, encoding: .utf8)

        let scan = try scanAll(url, maxLineBytes: 64)
        #expect(scan.lines == ["before", "after"])
        #expect(scan.result.completeLines == 3, "the skipped line still counts as a line")
        #expect(scan.result.consumedOffset == UInt64(7 + blob.count + 1 + 6))
    }

    @Test("An oversized unterminated tail is dropped without growing past the cap")
    func oversizedTailIsDropped() throws {
        let sandbox = TempSandbox()
        defer { sandbox.cleanup() }
        let url = sandbox.file("huge.jsonl")
        try ("good\n" + String(repeating: "A", count: 1000)).write(to: url, atomically: true, encoding: .utf8)

        let scan = try scanAll(url, maxLineBytes: 64)
        #expect(scan.lines == ["good"])
        #expect(scan.result.consumedOffset == 5)
    }

    @Test("An empty file yields nothing; a directory throws")
    func emptyAndDirectory() throws {
        let sandbox = TempSandbox()
        defer { sandbox.cleanup() }
        let url = sandbox.file("empty.jsonl")
        try Data().write(to: url)
        let scan = try scanAll(url)
        #expect(scan.lines.isEmpty)
        #expect(scan.result.consumedOffset == 0)

        #expect(throws: (any Error).self) { _ = try scanAll(sandbox.root) }
    }
}

// MARK: - ScanJob (what a catch-up reads)

@Suite("ScanJob")
struct ScanJobTests {

    private func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url)
    }

    private func state(of url: URL, offset: UInt64, size: UInt64) throws -> FileIndexState {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return FileIndexState(
            path: url.path,
            lastByteOffset: offset,
            lastKnownSize: size,
            inode: (attributes[.systemFileNumber] as! NSNumber).uint64Value,
            device: UInt64(bitPattern: Int64((attributes[.systemNumber] as! NSNumber).int64Value))
        )
    }

    @Test("A file never seen before is read from the start")
    func newFile() throws {
        let sandbox = TempSandbox()
        defer { sandbox.cleanup() }
        let url = sandbox.file("a.jsonl")
        try write("x\n", to: url)
        let job = try #require(ScanJob.make(path: url.path, kind: .claude, prior: nil))
        #expect(job.startOffset == 0)
    }

    @Test("An unchanged file is skipped")
    func unchangedIsSkipped() throws {
        let sandbox = TempSandbox()
        defer { sandbox.cleanup() }
        let url = sandbox.file("a.jsonl")
        try write("line\n", to: url)
        #expect(ScanJob.make(path: url.path, kind: .claude, prior: try state(of: url, offset: 5, size: 5)) == nil)
        // Held back a partial line, nothing appended since: still nothing to read.
        #expect(ScanJob.make(path: url.path, kind: .claude, prior: try state(of: url, offset: 3, size: 5)) == nil)
    }

    @Test("A grown file resumes at its last position")
    func grownResumes() throws {
        let sandbox = TempSandbox()
        defer { sandbox.cleanup() }
        let url = sandbox.file("a.jsonl")
        try write("line\nmore\n", to: url)
        let job = try #require(ScanJob.make(path: url.path, kind: .claude, prior: try state(of: url, offset: 5, size: 5)))
        #expect(job.startOffset == 5)
        #expect(job.size == 10)
    }

    @Test("A truncated or replaced file is read from the start")
    func truncatedOrReplaced() throws {
        let sandbox = TempSandbox()
        defer { sandbox.cleanup() }
        let url = sandbox.file("a.jsonl")
        try write("ab\n", to: url)
        let truncated = try #require(ScanJob.make(path: url.path, kind: .claude, prior: try state(of: url, offset: 50, size: 50)))
        #expect(truncated.startOffset == 0)

        var foreign = try state(of: url, offset: 1, size: 1)
        foreign.inode &+= 1
        let replaced = try #require(ScanJob.make(path: url.path, kind: .claude, prior: foreign))
        #expect(replaced.startOffset == 0)
    }

    @Test("A Codex rollout resumes mid-file only with the context saved there")
    func codexNeedsContext() throws {
        let sandbox = TempSandbox()
        defer { sandbox.cleanup() }
        let url = sandbox.file("rollout.jsonl")
        try write("line\nmore\n", to: url)
        let prior = try state(of: url, offset: 5, size: 5)

        let withoutContext = try #require(ScanJob.make(path: url.path, kind: .codex, prior: prior))
        #expect(withoutContext.startOffset == 0)
        #expect(withoutContext.context == CodexParseContext())

        let saved = CodexParseContext(sessionID: "s", cwd: "/p", model: "gpt", ordinal: 1)
        let withContext = try #require(ScanJob.make(path: url.path, kind: .codex, prior: prior, context: saved))
        #expect(withContext.startOffset == 5)
        #expect(withContext.context == saved)
    }

    @Test("The open Claude request is carried only into a resumed read")
    func openRequestCarried() throws {
        let sandbox = TempSandbox()
        defer { sandbox.cleanup() }
        let url = sandbox.file("a.jsonl")
        try write("line\nmore\n", to: url)
        var prior = try state(of: url, offset: 5, size: 5)
        prior.lastInputMs = 1_780_000_005_000
        prior.openRequestId = "req_1"
        prior.openRequestStartMs = 1_780_000_000_000

        let resumed = try #require(ScanJob.make(path: url.path, kind: .claude, prior: prior))
        #expect(resumed.openRequestId == "req_1")
        #expect(resumed.openRequestStartMs == 1_780_000_000_000)
        let after = resumed.state(after: LineScanner.Result(consumedOffset: 10, completeLines: 1),
                                  lastInputMs: 7, openRequestId: "req_2", openRequestStartMs: 3)
        #expect(after.openRequestId == "req_2")
        #expect(after.openRequestStartMs == 3)

        prior.lastByteOffset = 50
        prior.lastKnownSize = 50
        let restarted = try #require(ScanJob.make(path: url.path, kind: .claude, prior: prior))
        #expect(restarted.startOffset == 0)
        #expect(restarted.openRequestId == nil)
        #expect(restarted.openRequestStartMs == nil)
    }

    @Test("A directory is not a job")
    func directoryIsSkipped() {
        let sandbox = TempSandbox()
        defer { sandbox.cleanup() }
        #expect(ScanJob.make(path: sandbox.root.path, kind: .claude, prior: nil) == nil)
    }
}

// MARK: - TranscriptStore

@Suite("TranscriptStore")
struct TranscriptStoreTests {

    private func record(
        requestId: String,
        output: Int,
        timestamp: Date = Date(timeIntervalSince1970: 1_780_000_000)
    ) -> TranscriptRecord {
        TranscriptRecord(
            requestId: requestId,
            sessionId: "s",
            cwd: "/c",
            model: "claude-opus-4-8",
            timestamp: timestamp,
            usage: TokenUsage(input: 1, output: output, cacheRead: 0, ephemeral5m: 0, ephemeral1h: 0, webSearch: 0, webFetch: 0),
            isSidechain: false
        )
    }

    @Test("Re-insert same request_id → exactly one row, last-wins value (D2)")
    func lastWinsSingleRow() throws {
        let sandbox = TempSandbox()
        defer { sandbox.cleanup() }
        let store = try TranscriptStore(databaseURL: sandbox.dbURL)

        try store.upsertEntry(record(requestId: "r1", output: 100))
        try store.upsertEntry(record(requestId: "r1", output: 250))

        let all = try store.allRecords()
        #expect(all.count == 1)
        #expect(all.first?.requestId == "r1")
        #expect(all.first?.usage.output == 250)
    }

    @Test("records(start:end:) filters by timestamp range")
    func rangeFiltering() throws {
        let sandbox = TempSandbox()
        defer { sandbox.cleanup() }
        let store = try TranscriptStore(databaseURL: sandbox.dbURL)

        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let t1 = Date(timeIntervalSince1970: 2_000_000)
        let t2 = Date(timeIntervalSince1970: 3_000_000)
        try store.upsertEntry(record(requestId: "a", output: 1, timestamp: t0))
        try store.upsertEntry(record(requestId: "b", output: 2, timestamp: t1))
        try store.upsertEntry(record(requestId: "c", output: 3, timestamp: t2))

        let mid = try store.records(start: t1.addingTimeInterval(-1), end: t1.addingTimeInterval(1))
        #expect(mid.map(\.requestId) == ["b"])

        let all = try store.allRecords()
        #expect(all.count == 3)
        // allRecords is ordered ascending by timestamp.
        #expect(all.map(\.requestId) == ["a", "b", "c"])
    }

    @Test("File state round-trips and meta round-trips")
    func stateAndMetaRoundTrip() throws {
        let sandbox = TempSandbox()
        defer { sandbox.cleanup() }
        let store = try TranscriptStore(databaseURL: sandbox.dbURL)

        let state = FileIndexState(path: "/x/y.jsonl", lastByteOffset: 42, lastKnownSize: 99, inode: 7, device: 3, lastEventId: 11)
        try store.upsertFileState(state)
        #expect(try store.fileState(path: "/x/y.jsonl") == state)
        #expect(try store.fileState(path: "/nope") == nil)

        try store.setMeta(key: "k", value: "v")
        #expect(try store.getMeta(key: "k") == "v")
        #expect(try store.getMeta(key: "absent") == nil)
    }

    private func speedRecord(
        _ id: String, output: Int, generationMs: Int?, effort: String? = "high", isFast: Bool = false
    ) -> TranscriptRecord {
        TranscriptRecord(
            requestId: id, sessionId: "s", cwd: "/c", model: "claude-opus-5-5",
            timestamp: Date(timeIntervalSince1970: 1_780_000_000),
            usage: TokenUsage(input: 1, output: output, cacheRead: 0, ephemeral5m: 0, ephemeral1h: 0, webSearch: 0, webFetch: 0),
            isSidechain: false, billing: isFast ? [.fastMode] : [],
            generationMs: generationMs, effort: effort, isFast: isFast
        )
    }

    @Test("Speed fields round-trip, and an absent duration reads back as nil")
    func speedFieldsRoundTrip() throws {
        let sandbox = TempSandbox(); defer { sandbox.cleanup() }
        let store = try TranscriptStore(databaseURL: sandbox.dbURL)
        try store.upsertEntries([
            speedRecord("a", output: 300, generationMs: 4_000, effort: "xhigh", isFast: true),
            speedRecord("b", output: 300, generationMs: nil, effort: nil),
        ])
        let byId = Dictionary(uniqueKeysWithValues: try store.allRecords().map { ($0.requestId, $0) })
        #expect(byId["a"]?.generationMs == 4_000)
        #expect(byId["a"]?.effort == "xhigh")
        #expect(byId["a"]?.isFast == true)
        #expect(byId["b"]?.generationMs == nil)
        #expect(byId["b"]?.effort == nil)
    }

    @Test("Same output: the longer duration wins; a nil duration never erases a known one")
    func durationUpsertRule() throws {
        let sandbox = TempSandbox(); defer { sandbox.cleanup() }
        let store = try TranscriptStore(databaseURL: sandbox.dbURL)
        try store.upsertEntry(speedRecord("r", output: 500, generationMs: 3_000))
        try store.upsertEntry(speedRecord("r", output: 500, generationMs: 5_000)) // later block, same usage
        #expect(try store.allRecords().first?.generationMs == 5_000)
        try store.upsertEntry(speedRecord("r", output: 500, generationMs: 4_000)) // a forked copy, earlier
        #expect(try store.allRecords().first?.generationMs == 5_000)
        try store.upsertEntry(speedRecord("r", output: 500, generationMs: nil))   // a copy without its anchor
        #expect(try store.allRecords().first?.generationMs == 5_000)
        try store.upsertEntry(speedRecord("r", output: 900, generationMs: 6_500)) // grew: replaces
        #expect(try store.allRecords().first?.generationMs == 6_500)
        try store.upsertEntry(speedRecord("r", output: 100, generationMs: 9_999)) // smaller snapshot: ignored
        #expect(try store.allRecords().first?.generationMs == 6_500)
    }

    @Test("An index created before the speed columns gains them without losing rows")
    func speedColumnsMigrate() throws {
        let sandbox = TempSandbox(); defer { sandbox.cleanup() }
        var db: OpaquePointer?
        #expect(sqlite3_open(sandbox.dbURL.path, &db) == SQLITE_OK)
        let legacy = """
        CREATE TABLE entries (request_id TEXT PRIMARY KEY, session_id TEXT NOT NULL, cwd TEXT NOT NULL,
            model TEXT NOT NULL, timestamp_ms INTEGER NOT NULL, input_tokens INTEGER NOT NULL,
            output_tokens INTEGER NOT NULL, cache_read_tokens INTEGER NOT NULL,
            ephemeral_5m_tokens INTEGER NOT NULL, ephemeral_1h_tokens INTEGER NOT NULL,
            web_search INTEGER NOT NULL, web_fetch INTEGER NOT NULL, is_sidechain INTEGER NOT NULL,
            billing INTEGER NOT NULL DEFAULT 0);
        INSERT INTO entries VALUES ('old','s','/c','claude-opus-4-8',1000,1,250,0,0,0,0,0,0,0);
        """
        #expect(sqlite3_exec(db, legacy, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)

        let store = try TranscriptStore(databaseURL: sandbox.dbURL)
        let old = try #require(try store.allRecords().first)
        #expect(old.requestId == "old")
        #expect(old.usage.output == 250)
        #expect(old.generationMs == nil)
        #expect(old.isFast == false)
    }

    @Test("A file's last input timestamp round-trips, nil included")
    func lastInputRoundTrip() throws {
        let sandbox = TempSandbox(); defer { sandbox.cleanup() }
        let store = try TranscriptStore(databaseURL: sandbox.dbURL)
        let anchored = FileIndexState(path: "/a.jsonl", lastByteOffset: 10, lastKnownSize: 10, lastInputMs: 1_780_000_000_123)
        let bare = FileIndexState(path: "/b.jsonl", lastByteOffset: 5, lastKnownSize: 5)
        try store.upsertFileState(anchored)
        try store.upsertFileState(bare)
        #expect(try store.fileState(path: "/a.jsonl") == anchored)
        #expect(try store.allFileStates()["/b.jsonl"]?.lastInputMs == nil)
    }

    @Test("A file's open request and its start round-trip, nil included")
    func openRequestRoundTrip() throws {
        let sandbox = TempSandbox(); defer { sandbox.cleanup() }
        let store = try TranscriptStore(databaseURL: sandbox.dbURL)
        let open = FileIndexState(path: "/a.jsonl", lastByteOffset: 10, lastKnownSize: 10,
                                  lastInputMs: 1_780_000_005_000, openRequestId: "req_1",
                                  openRequestStartMs: 1_780_000_000_000)
        let unanchored = FileIndexState(path: "/b.jsonl", lastByteOffset: 5, lastKnownSize: 5, openRequestId: "req_2")
        try store.upsertFileState(open)
        try store.upsertFileState(unanchored)
        #expect(try store.fileState(path: "/a.jsonl") == open)
        #expect(try store.allFileStates()["/a.jsonl"] == open)
        #expect(try store.allFileStates()["/b.jsonl"] == unanchored)
        #expect(try store.fileState(path: "/b.jsonl")?.openRequestStartMs == nil)
    }

    @Test("A Codex context's anchor, effort and tier round-trip")
    func codexContextSpeedRoundTrip() throws {
        let sandbox = TempSandbox(); defer { sandbox.cleanup() }
        let store = try TranscriptStore(databaseURL: sandbox.dbURL)
        let context = CodexParseContext(sessionID: "s", cwd: "/c", model: "gpt-6-sol", ordinal: 7,
                                        anchorMs: 1_780_000_000_000, effort: "high", isFast: true)
        try store.upsertCodexContext(context, path: "/r.jsonl")
        #expect(try store.allCodexContexts()["/r.jsonl"] == context)
    }
}

// MARK: - Integration via the indexer

@Suite("TranscriptIndexer integration")
struct TranscriptIndexerIntegrationTests {

    @Test("Full index dedups by requestId (final values), excludes journal.jsonl")
    func fullIndexDedupAndExcludeJournal() async throws {
        let sandbox = TempSandbox()
        defer { sandbox.cleanup() }
        let projects = sandbox.projectsDir()

        // A project subdirectory holding a primary transcript.
        let projDir = projects.appendingPathComponent("proj-A", isDirectory: true)
        try FileManager.default.createDirectory(at: projDir, withIntermediateDirectories: true)
        let transcript = projDir.appendingPathComponent("session.jsonl")

        // Two content-block records share requestId "dup" (growing output) → last-wins = 555.
        // A distinct requestId "solo".
        // A subagent streaming snapshot pair shares "stream" (growing output) → last-wins = 999,
        // emitted as a sidechain record.
        let lines = [
            assistantLine(requestId: "dup", model: "claude-opus-4-8",
                          usage: ["input_tokens": 10, "output_tokens": 100]),
            assistantLine(requestId: "dup", model: "claude-opus-4-8",
                          usage: ["input_tokens": 10, "output_tokens": 555]),
            assistantLine(requestId: "solo", model: "claude-opus-4-8",
                          usage: ["input_tokens": 5, "output_tokens": 42]),
            assistantLine(requestId: "stream", model: "claude-opus-4-8", isSidechain: true,
                          usage: ["input_tokens": 7, "output_tokens": 300]),
            assistantLine(requestId: "stream", model: "claude-opus-4-8", isSidechain: true,
                          usage: ["input_tokens": 7, "output_tokens": 999]),
            // A synthetic line that must be ignored.
            assistantLine(requestId: "syn", model: "<synthetic>",
                          usage: ["input_tokens": 1, "output_tokens": 1]),
        ]
        try (lines.joined(separator: "\n") + "\n").write(to: transcript, atomically: true, encoding: .utf8)

        // A journal.jsonl that must be excluded — its (valid) assistant record must NOT appear.
        let journal = projDir.appendingPathComponent("journal.jsonl")
        let journalLine = assistantLine(requestId: "journal-rid", model: "claude-opus-4-8",
                                        usage: ["input_tokens": 1, "output_tokens": 1])
        try (journalLine + "\n").write(to: journal, atomically: true, encoding: .utf8)

        let indexer = try TranscriptIndexer(databaseURL: sandbox.dbURL, projectsDirectory: projects)
        try await indexer.reindex()

        let all = await indexer.allRecords()
        let byId = Dictionary(uniqueKeysWithValues: all.map { ($0.requestId, $0) })

        // One row per requestId, final values.
        #expect(all.count == 3)
        #expect(byId["dup"]?.usage.output == 555)
        #expect(byId["solo"]?.usage.output == 42)
        #expect(byId["stream"]?.usage.output == 999)
        #expect(byId["stream"]?.isSidechain == true)
        // journal + synthetic excluded.
        #expect(byId["journal-rid"] == nil)
        #expect(byId["syn"] == nil)
    }

    @Test("records(start:end:) through the indexer filters by range")
    func indexerRangeQuery() async throws {
        let sandbox = TempSandbox()
        defer { sandbox.cleanup() }
        let projects = sandbox.projectsDir()
        let transcript = projects.appendingPathComponent("s.jsonl")

        try (assistantLine(requestId: "only", timestamp: "2026-06-29T16:30:01.000Z",
                           usage: ["input_tokens": 1, "output_tokens": 9]) + "\n")
            .write(to: transcript, atomically: true, encoding: .utf8)

        let indexer = try TranscriptIndexer(databaseURL: sandbox.dbURL, projectsDirectory: projects)
        try await indexer.reindex()

        let ts = ISO8601DateFormatter().date(from: "2026-06-29T16:30:01Z")!
        let inRange = try await indexer.records(start: ts.addingTimeInterval(-60), end: ts.addingTimeInterval(60))
        #expect(inRange.map(\.requestId) == ["only"])

        let outOfRange = try await indexer.records(start: ts.addingTimeInterval(3600), end: ts.addingTimeInterval(7200))
        #expect(outOfRange.isEmpty)
    }
}

// MARK: - Public init resilience

@Suite("TranscriptIndexer public init")
struct TranscriptIndexerPublicInitTests {

    @Test("public init() does not crash and does not create the real index database")
    func publicInitIsInert() async {
        // The real default database. Record whether it already exists so we never assert
        // against a pre-existing user index; we only assert that *we* did not create it.
        // The directory itself is not a signal: any concurrent test that logs a hashed path
        // creates it for the logging salt.
        let realDatabase = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Toki", isDirectory: true)
            .appendingPathComponent("index.sqlite3")
        let existedBefore = realDatabase.map { FileManager.default.fileExists(atPath: $0.path) } ?? true

        // Constructing the indexer must not crash and must not eagerly open the real DB.
        let indexer = TranscriptIndexer()
        // allRecords() lazily opens the default store. To avoid touching the real path entirely,
        // we do NOT call it here — merely constructing must be inert.
        _ = indexer

        if let realDatabase, !existedBefore {
            #expect(
                !FileManager.default.fileExists(atPath: realDatabase.path),
                "public init() must not create the real index database"
            )
        }
    }

    @Test("Lazy open failure surfaces as TokiError and allRecords returns []")
    func lazyOpenFailureIsResilient() async throws {
        let sandbox = TempSandbox()
        defer { sandbox.cleanup() }
        // Point the DB at a path whose parent cannot be created (a file used as a directory),
        // forcing the lazy open to fail without ever touching real user data.
        let blocker = sandbox.file("blocker")
        try Data("x".utf8).write(to: blocker)
        let badDBURL = blocker.appendingPathComponent("nested/index.sqlite3")

        let indexer = TranscriptIndexer(databaseURL: badDBURL)

        // Non-throwing path tolerates the failure.
        let records = await indexer.allRecords()
        #expect(records.isEmpty)

        // Throwing path surfaces a TokiError rather than crashing.
        await #expect(throws: TokiError.self) {
            _ = try await indexer.records(start: .distantPast, end: .distantFuture)
        }
    }
}

// MARK: - Fix 2 & 3: DirectoryWatcher rescan signal logic

@Suite("DirectoryWatcher rescan decision logic (Fix 2/3)")
struct DirectoryWatcherRescanLogicTests {

    @Test("handleEvents with MustScanSubDirs flag triggers onNeedsFullRescan")
    func mustScanSubDirsTriggersRescan() {
        // We test the decision logic by calling handleEvents directly through a
        // subclass-accessible path. Since handleEvents is fileprivate, we invoke it
        // via a real DirectoryWatcher constructed with a test callback.
        let rescanTriggered = SendableBox(false)
        let changedPaths = SendableBox<[String]>([])

        // We can't call handleEvents directly (fileprivate), so we simulate the scenario
        // by inspecting what the watcher would do with the control flag. We verify this
        // through the public interface: the onNeedsFullRescan closure being invoked.
        // This test documents the decision-logic contract.
        let sandbox = TempSandbox()
        defer { sandbox.cleanup() }

        let watcher = DirectoryWatcher(
            url: sandbox.root,
            sinceWhen: nil,
            latency: 0.5,
            onChange: { paths in changedPaths.value = paths },
            onNeedsFullRescan: { rescanTriggered.value = true }
        )

        // Directly call the internal handler to exercise the flag-checking logic.
        // kFSEventStreamEventFlagMustScanSubDirs == 0x00000001
        let mustScanFlag = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs)
        watcher.handleEventsForTesting(
            paths: ["/some/path"],
            flags: [mustScanFlag],
            ids: [FSEventStreamEventId(42)]
        )

        #expect(rescanTriggered.value == true)
        // No .jsonl path was in the event, so onChange must not have fired.
        #expect(changedPaths.value.isEmpty)
    }

    @Test("handleEvents with UserDropped flag triggers onNeedsFullRescan")
    func userDroppedTriggersRescan() {
        let rescanTriggered = SendableBox(false)
        let sandbox = TempSandbox()
        defer { sandbox.cleanup() }

        let watcher = DirectoryWatcher(
            url: sandbox.root,
            sinceWhen: nil,
            latency: 0.5,
            onChange: { _ in },
            onNeedsFullRescan: { rescanTriggered.value = true }
        )

        let userDroppedFlag = FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped)
        watcher.handleEventsForTesting(
            paths: ["/some/path"],
            flags: [userDroppedFlag],
            ids: [FSEventStreamEventId(99)]
        )

        #expect(rescanTriggered.value == true)
    }

    @Test("handleEvents with normal modify flag does NOT trigger onNeedsFullRescan")
    func normalModifyFlagDoesNotTriggerRescan() {
        let rescanTriggered = SendableBox(false)
        let sandbox = TempSandbox()
        defer { sandbox.cleanup() }

        let watcher = DirectoryWatcher(
            url: sandbox.root,
            sinceWhen: nil,
            latency: 0.5,
            onChange: { _ in },
            onNeedsFullRescan: { rescanTriggered.value = true }
        )

        let modifyFlag = FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified)
        watcher.handleEventsForTesting(
            paths: ["/some/file.jsonl"],
            flags: [modifyFlag],
            ids: [FSEventStreamEventId(7)]
        )

        #expect(rescanTriggered.value == false)
    }

    @Test("maxEventId is updated even for control-flag-only batches (Fix 3)")
    func maxEventIdUpdatedForControlFlagBatch() {
        let sandbox = TempSandbox()
        defer { sandbox.cleanup() }

        let watcher = DirectoryWatcher(
            url: sandbox.root,
            sinceWhen: nil,
            latency: 0.5,
            onChange: { _ in },
            onNeedsFullRescan: nil
        )

        // A batch with only a control flag (non-jsonl path) — no onChange fires.
        let kernelDroppedFlag = FSEventStreamEventFlags(kFSEventStreamEventFlagKernelDropped)
        watcher.handleEventsForTesting(
            paths: ["/some/non-jsonl-path"],
            flags: [kernelDroppedFlag],
            ids: [FSEventStreamEventId(12345)]
        )

        // Despite no .jsonl content, the maxEventId must have advanced.
        #expect(watcher.currentMaxEventId() == 12345)
    }
}

/// A Sendable reference box for use in test callbacks across concurrency boundaries.
/// Only used in tests; no production code.
private final class SendableBox<T: Sendable>: @unchecked Sendable {
    var value: T
    init(_ initial: T) { value = initial }
}

// MARK: - Change notification (debounce)

/// These tests used to sleep a fixed 1.3–1.4s against the indexer's 1s debounce window,
/// leaving ~300ms for a `Task` to be scheduled and run. That margin survived the suite in
/// isolation and disappeared under the full parallel suite, so they failed for machine load
/// rather than for behaviour — measured: 3/3 passes alone, 3/3 failures in the full run.
///
/// Both now inject a short window and wait for the CONDITION rather than for the clock. Under
/// load that only makes them slower, never red.
@Suite("TranscriptIndexer change notification")
struct TranscriptIndexerChangeNotificationTests {

    /// Short enough to keep the tests quick, long enough that a burst issued in a tight loop
    /// lands inside one window even on a loaded machine.
    private static let window: UInt64 = 200_000_000  // 0.2s

    /// Waits for `predicate` to hold, polling until a deadline generous enough that only a
    /// genuine failure to fire runs it out.
    private func waitUntil(
        _ predicate: @Sendable () -> Bool,
        timeout: Duration = .seconds(10)
    ) async throws -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if predicate() { return true }
            try await Task.sleep(for: .milliseconds(20))
        }
        return predicate()
    }

    /// A burst of change signals within the debounce window coalesces into a single fire.
    @Test("debounced handler fires once for a burst of changes")
    func coalescesBurst() async throws {
        let sandbox = TempSandbox()
        defer { sandbox.cleanup() }
        let indexer = try TranscriptIndexer(
            databaseURL: sandbox.dbURL,
            projectsDirectory: sandbox.projectsDir(),
            changeNotifyDelayNanos: Self.window
        )

        let fires = SendableBox(0)
        await indexer.setOnIndexChanged { fires.value += 1 }

        // Five rapid signals — each restarts the trailing window.
        for _ in 0..<5 { await indexer.notifyChangeForTesting() }

        #expect(try await waitUntil { fires.value >= 1 }, "the handler never fired")

        // Coalescing is the actual claim, so having fired is not enough: give the four
        // cancelled windows several more windows to prove they stay cancelled.
        try await Task.sleep(nanoseconds: Self.window * 4)
        #expect(fires.value == 1, "a burst must coalesce into exactly one fire")
    }

    /// A signal after the window elapsed starts a fresh window and fires again.
    @Test("a change after the window fires the handler again")
    func firesAgainAfterWindow() async throws {
        let sandbox = TempSandbox()
        defer { sandbox.cleanup() }
        let indexer = try TranscriptIndexer(
            databaseURL: sandbox.dbURL,
            projectsDirectory: sandbox.projectsDir(),
            changeNotifyDelayNanos: Self.window
        )

        let fires = SendableBox(0)
        await indexer.setOnIndexChanged { fires.value += 1 }

        await indexer.notifyChangeForTesting()
        #expect(try await waitUntil { fires.value == 1 }, "the first change never fired")

        await indexer.notifyChangeForTesting()
        #expect(try await waitUntil { fires.value == 2 }, "a change after the window must fire again")
    }
}

// MARK: - Incremental catch-up

@Suite("TranscriptIndexer catch-up")
struct TranscriptIndexerCatchUpTests {

    private func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }

    private func line(_ requestId: String, output: Int) -> String {
        assistantLine(requestId: requestId, usage: ["input_tokens": 1, "output_tokens": output])
    }

    @Test("An appended file contributes only its new records; an unchanged one is not re-read")
    func incremental() async throws {
        let sandbox = TempSandbox()
        defer { sandbox.cleanup() }
        let projects = sandbox.projectsDir()
        let growing = projects.appendingPathComponent("growing.jsonl")
        let untouched = projects.appendingPathComponent("untouched.jsonl")
        try (line("a", output: 10) + "\n").write(to: growing, atomically: true, encoding: .utf8)
        try (line("b", output: 20) + "\n").write(to: untouched, atomically: true, encoding: .utf8)

        let indexer = try TranscriptIndexer(databaseURL: sandbox.dbURL, projectsDirectory: projects)
        try await indexer.reindex()

        // Rewrite the untouched file in place with a different value of the SAME length: a
        // pass that re-read it would pick the change up, a pass that skipped it cannot.
        let handle = try FileHandle(forWritingTo: untouched)
        try handle.write(contentsOf: Data((line("b", output: 99) + "\n").utf8))
        try handle.close()
        try append(line("c", output: 30) + "\n", to: growing)

        try await indexer.reindex()
        let byId = Dictionary(uniqueKeysWithValues: await indexer.allRecords().map { ($0.requestId, $0.usage.output) })
        #expect(byId == ["a": 10, "b": 20, "c": 30])
    }

    @Test("A half-written last line is picked up once it is complete")
    func partialLineCompletes() async throws {
        let sandbox = TempSandbox()
        defer { sandbox.cleanup() }
        let projects = sandbox.projectsDir()
        let file = projects.appendingPathComponent("s.jsonl")
        let second = line("second", output: 7)
        let cut = second.index(second.startIndex, offsetBy: second.count / 2)
        try (line("first", output: 5) + "\n" + String(second[..<cut])).write(to: file, atomically: true, encoding: .utf8)

        let indexer = try TranscriptIndexer(databaseURL: sandbox.dbURL, projectsDirectory: projects)
        try await indexer.reindex()
        #expect(await indexer.allRecords().map(\.requestId) == ["first"])

        try append(String(second[cut...]) + "\n", to: file)
        try await indexer.reindex()
        let ids = Set(await indexer.allRecords().map(\.requestId))
        #expect(ids == ["first", "second"])
    }

    @Test("A complete last line without a newline is indexed, and not duplicated later")
    func unterminatedCompleteLine() async throws {
        let sandbox = TempSandbox()
        defer { sandbox.cleanup() }
        let projects = sandbox.projectsDir()
        let file = projects.appendingPathComponent("s.jsonl")
        try line("only", output: 3).write(to: file, atomically: true, encoding: .utf8)

        let indexer = try TranscriptIndexer(databaseURL: sandbox.dbURL, projectsDirectory: projects)
        try await indexer.reindex()
        #expect(await indexer.allRecords().map(\.requestId) == ["only"])

        try append("\n" + line("next", output: 4) + "\n", to: file)
        try await indexer.reindex()
        #expect(await indexer.allRecords().map(\.requestId).sorted() == ["next", "only"])
    }

    @Test("A replaced file is re-read from the start")
    func replacedFile() async throws {
        let sandbox = TempSandbox()
        defer { sandbox.cleanup() }
        let projects = sandbox.projectsDir()
        let file = projects.appendingPathComponent("s.jsonl")
        try (line("old", output: 1) + "\n" + line("old2", output: 1) + "\n")
            .write(to: file, atomically: true, encoding: .utf8)

        let indexer = try TranscriptIndexer(databaseURL: sandbox.dbURL, projectsDirectory: projects)
        try await indexer.reindex()

        // An atomic write is a new inode: shorter, different content.
        try (line("new", output: 2) + "\n").write(to: file, atomically: true, encoding: .utf8)
        try await indexer.reindex()
        let ids = Set(await indexer.allRecords().map(\.requestId))
        #expect(ids.contains("new"))
    }

    @Test("A changed index format re-reads every file once")
    func formatChangeRereads() async throws {
        let sandbox = TempSandbox()
        defer { sandbox.cleanup() }
        let projects = sandbox.projectsDir()
        let file = projects.appendingPathComponent("s.jsonl")
        try (line("r", output: 10) + "\n").write(to: file, atomically: true, encoding: .utf8)

        let indexer = try TranscriptIndexer(databaseURL: sandbox.dbURL, projectsDirectory: projects)
        try await indexer.reindex()

        let handle = try FileHandle(forWritingTo: file)
        try handle.write(contentsOf: Data((line("r", output: 90) + "\n").utf8))
        try handle.close()
        let store = try TranscriptStore(databaseURL: sandbox.dbURL)
        try store.setMeta(key: "index_format", value: "1")

        try await indexer.reindex()
        #expect(await indexer.allRecords().first?.usage.output == 90)
        #expect(try store.getMeta(key: "index_format") == TranscriptIndexer.indexFormatVersion)
    }

    @Test("Progress counts the files a pass reads, and a pass over an unchanged archive reads none")
    func progress() async throws {
        let sandbox = TempSandbox()
        defer { sandbox.cleanup() }
        let projects = sandbox.projectsDir()
        for index in 0..<5 {
            try (line("r\(index)", output: index) + "\n")
                .write(to: projects.appendingPathComponent("\(index).jsonl"), atomically: true, encoding: .utf8)
        }
        let indexer = try TranscriptIndexer(databaseURL: sandbox.dbURL, projectsDirectory: projects)
        let reports = SendableBox<[IndexProgress]>([])
        await indexer.setOnProgress { reports.value.append($0) }

        try await indexer.reindex()
        #expect(reports.value.last == IndexProgress(filesDone: 5, filesTotal: 5))
        #expect(reports.value.map(\.filesDone) == reports.value.map(\.filesDone).sorted())

        reports.value = []
        try await indexer.reindex()
        #expect(reports.value == [IndexProgress(filesDone: 0, filesTotal: 0)])
        #expect(reports.value.last?.isFinished == true)
    }

    @Test("A growing Codex rollout is tailed with the context established before the tail")
    func codexTail() async throws {
        let sandbox = TempSandbox()
        defer { sandbox.cleanup() }
        let sessions = sandbox.root.appendingPathComponent("codex/sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let rollout = sessions.appendingPathComponent("rollout.jsonl")
        try """
        {"timestamp":"2026-09-04T10:00:00.000Z","type":"session_meta","payload":{"id":"sess","cwd":"/tmp/project"}}
        {"timestamp":"2026-09-04T10:00:01.000Z","type":"turn_context","payload":{"model":"gpt-5.3-codex"}}
        {"timestamp":"2026-09-04T10:00:02.000Z","type":"token_usage_record","payload":{"response_id":"one","usage":{"input_tokens":10,"output_tokens":5}}}

        """.write(to: rollout, atomically: true, encoding: .utf8)

        let indexer = try TranscriptIndexer(
            databaseURL: sandbox.dbURL,
            projectsDirectory: sandbox.projectsDir(),
            codexSessionsDirectory: sessions
        )
        try await indexer.reindex()

        // No response or turn id: its id falls back to the line ordinal, which must be the
        // same whether the file is read whole or tailed.
        try append("""
        {"timestamp":"2026-09-04T10:00:03.000Z","type":"response_item","payload":{"type":"message"}}
        {"timestamp":"2026-09-04T10:00:04.000Z","type":"token_usage_record","payload":{"usage":{"input_tokens":7,"output_tokens":2}}}

        """, to: rollout)
        try await indexer.reindex()

        let tailed = await indexer.allRecords().sorted { $0.timestamp < $1.timestamp }
        let whole = try CodexTranscriptParser.parseFile(rollout)
        #expect(tailed.map(\.requestId) == whole.map(\.requestId))
        #expect(tailed.map(\.requestId) == ["codex:sess:one", "codex:sess:5"])
        #expect(tailed.last?.cwd == "/tmp/project")
        #expect(tailed.last?.model == "gpt-5.3-codex")
    }

    @Test("Reads through the separate reader connection see each committed pass")
    func readsUseTheirOwnConnection() async throws {
        let sandbox = TempSandbox()
        defer { sandbox.cleanup() }
        let projects = sandbox.projectsDir()
        try (line("x", output: 1) + "\n").write(to: projects.appendingPathComponent("s.jsonl"), atomically: true, encoding: .utf8)
        let indexer = try TranscriptIndexer(databaseURL: sandbox.dbURL, projectsDirectory: projects)
        #expect(try await indexer.records(start: .distantPast, end: .distantFuture).isEmpty)
        try await indexer.reindex()
        #expect(try await indexer.records(start: .distantPast, end: .distantFuture).map(\.requestId) == ["x"])
    }
}

@Suite("TranscriptStore snapshot order")
struct TranscriptStoreSnapshotOrderTests {

    private func record(_ output: Int, timestamp: Date = Date(timeIntervalSince1970: 1_780_000_000.123)) -> TranscriptRecord {
        TranscriptRecord(
            requestId: "r", sessionId: "s", cwd: "/p", model: "m", timestamp: timestamp,
            usage: TokenUsage(input: 1, output: output, cacheRead: 0, ephemeral5m: 0, ephemeral1h: 0, webSearch: 0, webFetch: 0),
            isSidechain: false
        )
    }

    @Test("A request's larger streamed snapshot wins whichever order the files are committed in")
    func largerSnapshotWins() throws {
        for order in [[2, 308], [308, 2]] {
            let sandbox = TempSandbox()
            defer { sandbox.cleanup() }
            let store = try TranscriptStore(databaseURL: sandbox.dbURL)
            for output in order { try store.upsertEntry(record(output)) }
            #expect(try store.allRecords().map(\.usage.output) == [308], "order \(order)")
        }
    }

    @Test("Timestamps round-trip to the exact millisecond")
    func millisecondRoundTrip() throws {
        let sandbox = TempSandbox()
        defer { sandbox.cleanup() }
        let store = try TranscriptStore(databaseURL: sandbox.dbURL)
        // 1.123 is 1.12299… in binary; truncation would store …122.
        let parsed = try #require(TranscriptParser.parseTimestamp("2026-06-29T16:30:01.123Z"))
        try store.upsertEntry(record(1, timestamp: parsed))
        let stored = try #require(try store.allRecords().first?.timestamp)
        #expect(TranscriptStore.milliseconds(stored) == TranscriptStore.milliseconds(parsed))
        #expect(TranscriptStore.milliseconds(stored) % 1000 == 123)
    }
}

// MARK: - Parser byte prefilter and leniency

@Suite("TranscriptParser prefilter")
struct TranscriptParserPrefilterTests {

    @Test("Whitespace-formatted JSON still passes the byte prefilter")
    func spacedJSON() throws {
        let line = """
        { "type": "assistant", "requestId": "spaced", "timestamp": "2026-06-29T16:30:01.123Z",
          "message": { "model": "claude-opus-4-8", "usage": { "input_tokens": 3, "output_tokens": 4 } } }
        """.replacingOccurrences(of: "\n", with: " ")
        let record = try #require(TranscriptParser.parse(line: line))
        #expect(record.requestId == "spaced")
        #expect(record.usage.output == 4)
    }

    @Test("A user line quoting an assistant record inside a string is not a record")
    func quotedAssistantIsIgnored() throws {
        let quoted = assistantLine(requestId: "inner", usage: ["input_tokens": 1, "output_tokens": 1])
        let object: [String: Any] = ["type": "user", "message": ["content": quoted]]
        let line = String(data: try JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
        #expect(TranscriptParser.parse(line: line) == nil)
    }

    @Test("Counters decode leniently: floats truncate, other types read as zero, wrong-typed flags as absent")
    func lenientFields() throws {
        let line = """
        {"type":"assistant","requestId":"lenient","timestamp":"2026-06-29T16:30:01Z","isSidechain":"yes",        "message":{"model":"m","usage":{"input_tokens":12.0,"output_tokens":"many","cache_read_input_tokens":5}}}
        """
        let record = try #require(TranscriptParser.parse(line: line))
        #expect(record.usage.input == 12)
        #expect(record.usage.output == 0)
        #expect(record.usage.cacheRead == 5)
        #expect(record.isSidechain == false)
    }
}

// MARK: - ISO8601Timestamp

@Suite("ISO8601Timestamp")
struct ISO8601TimestampTests {

    private let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    @Test("Agrees with ISO8601DateFormatter to the millisecond across years, leap days and fractions")
    func agreesWithFormatter() throws {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<2000 {
            let millis = Int64.random(in: 0...4_102_444_800_000, using: &generator) // 1970…2100
            let date = Date(timeIntervalSince1970: Double(millis) / 1000)
            let text = formatter.string(from: date)
            let parsed = try #require(ISO8601Timestamp.parse(text), "\(text)")
            #expect(TranscriptStore.milliseconds(parsed) == millis, "\(text)")
        }
        let leap = try #require(ISO8601Timestamp.parse("2024-02-29T23:59:59.999Z"))
        #expect(TranscriptStore.milliseconds(leap) == TranscriptStore.milliseconds(formatter.date(from: "2024-02-29T23:59:59.999Z")!))
    }

    @Test("Fractions of any length are read to the millisecond")
    func fractionLengths() throws {
        let base = try #require(ISO8601Timestamp.parse("2026-06-29T16:30:01Z"))
        let cases: [(String, Int64)] = [(".1", 100), (".12", 120), (".123", 123), (".123456", 123), (".999999", 999)]
        for (fraction, millis) in cases {
            let parsed = try #require(ISO8601Timestamp.parse("2026-06-29T16:30:01\(fraction)Z"))
            #expect(TranscriptStore.milliseconds(parsed) - TranscriptStore.milliseconds(base) == millis, "\(fraction)")
        }
    }

    @Test("Anything else is left to the formatter fallback")
    func rejectsOtherShapes() throws {
        for text in ["2026-13-01T00:00:00Z", "2026-02-30T00:00:00Z", "2026-06-29T24:00:00Z",
                     "2026-06-29T16:30:01", "2026-06-29T16:30:01.Z", "2026-06-29T16:30:01+02:00", "garbage"] {
            #expect(ISO8601Timestamp.parse(text) == nil, "\(text)")
        }
        // The fallback still accepts a zone offset.
        let offset = try #require(TranscriptParser.parseTimestamp("2026-06-29T18:30:01+02:00"))
        #expect(offset == ISO8601Timestamp.parse("2026-06-29T16:30:01Z"))
    }
}

@Suite("TranscriptStore concurrent open")
struct TranscriptStoreConcurrentOpenTests {

    @Test("Connections opened at the same moment all succeed, on a fresh and on an existing file")
    func concurrentOpens() async throws {
        for round in 0..<20 {
            let sandbox = TempSandbox()
            defer { sandbox.cleanup() }
            // Even rounds race on a fresh file; odd rounds on an existing WAL file with no
            // connection open — the normal launch, when writer and reader open together.
            if round % 2 == 1 { _ = try TranscriptStore(databaseURL: sandbox.dbURL) }
            let url = sandbox.dbURL
            let failures = await withTaskGroup(of: Bool.self) { group in
                for _ in 0..<6 {
                    group.addTask { (try? TranscriptStore(databaseURL: url)) == nil }
                }
                var failed = 0
                for await didFail in group where didFail { failed += 1 }
                return failed
            }
            #expect(failures == 0, "round \(round)")
        }
    }
}

// MARK: - Billing modifiers and older formats

@Suite("Billing modifiers and legacy usage")
struct BillingAndLegacyUsageTests {

    private func claudeLine(speed: String?, geo: String?, webSearch: Int = 0) -> String {
        var usage: [String: Any] = ["input_tokens": 1, "output_tokens": 2,
                                    "server_tool_use": ["web_search_requests": webSearch, "web_fetch_requests": 0]]
        if let speed { usage["speed"] = speed }
        if let geo { usage["inference_geo"] = geo }
        return assistantLine(requestId: "r", usage: usage)
    }

    @Test("Fast mode and US-only inference are read from the usage block; standard is none")
    func claudeBillingFlags() throws {
        #expect(try #require(TranscriptParser.parse(line: claudeLine(speed: "standard", geo: "not_available"))).billing == [])
        #expect(try #require(TranscriptParser.parse(line: claudeLine(speed: nil, geo: nil))).billing == [])
        #expect(try #require(TranscriptParser.parse(line: claudeLine(speed: "fast", geo: "global"))).billing == [.fastMode])
        #expect(try #require(TranscriptParser.parse(line: claudeLine(speed: "fast", geo: "us"))).billing == [.fastMode, .usOnlyInference])
        #expect(try #require(TranscriptParser.parse(line: claudeLine(speed: nil, geo: nil, webSearch: 3))).usage.webSearch == 3)
    }

    @Test("Billing modifiers survive the index round trip")
    func billingRoundTrip() throws {
        let sandbox = TempSandbox()
        defer { sandbox.cleanup() }
        let store = try TranscriptStore(databaseURL: sandbox.dbURL)
        let record = try #require(TranscriptParser.parse(line: claudeLine(speed: "fast", geo: "us")))
        try store.upsertEntry(record)
        #expect(try store.allRecords().first?.billing == [.fastMode, .usOnlyInference])
    }

    @Test("An index created before the billing column gains it, keeping its rows")
    func migratesOldSchema() throws {
        let sandbox = TempSandbox()
        defer { sandbox.cleanup() }
        var db: OpaquePointer?
        sqlite3_open(sandbox.dbURL.path, &db)
        sqlite3_exec(db, """
        CREATE TABLE entries (request_id TEXT PRIMARY KEY, session_id TEXT NOT NULL, cwd TEXT NOT NULL,
            model TEXT NOT NULL, timestamp_ms INTEGER NOT NULL, input_tokens INTEGER NOT NULL,
            output_tokens INTEGER NOT NULL, cache_read_tokens INTEGER NOT NULL,
            ephemeral_5m_tokens INTEGER NOT NULL, ephemeral_1h_tokens INTEGER NOT NULL,
            web_search INTEGER NOT NULL, web_fetch INTEGER NOT NULL, is_sidechain INTEGER NOT NULL);
        INSERT INTO entries VALUES ('old','s','/p','m',1000,1,2,3,4,5,0,0,0);
        CREATE TABLE codex_parse_context (path TEXT PRIMARY KEY, session_id TEXT NOT NULL,
            cwd TEXT NOT NULL, model TEXT NOT NULL, ordinal INTEGER NOT NULL);
        """, nil, nil, nil)
        sqlite3_close(db)

        let store = try TranscriptStore(databaseURL: sandbox.dbURL)
        let old = try #require(try store.allRecords().first)
        #expect(old.requestId == "old")
        #expect(old.billing == [])
        try store.upsertCodexContext(CodexParseContext(sessionID: "s", sawUsageRecord: true, lastCountTotal: 7), path: "/r")
        #expect(try store.allCodexContexts()["/r"]?.lastCountTotal == 7)
    }

    private func rollout(_ lines: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rollout-\(UUID().uuidString).jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private let meta = #"{"timestamp":"2026-09-04T10:00:00.000Z","type":"session_meta","payload":{"id":"old-session","cwd":"/p"}}"#
    private let context = #"{"timestamp":"2026-09-04T10:00:01.000Z","type":"turn_context","payload":{"model":"gpt-5.3-codex"}}"#

    private func tokenCount(total: Int, lastInput: Int, cached: Int, output: Int) -> String {
        #"{"timestamp":"2026-09-04T10:00:05.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1,"output_tokens":1,"total_tokens":"# + "\(total)" + #"},"last_token_usage":{"input_tokens":"# + "\(lastInput)" + #","cached_input_tokens":"# + "\(cached)" + #","output_tokens":"# + "\(output)" + #"}}}}"#
    }

    @Test("A rollout from before usage records counts its token_count events, once each")
    func legacyTokenCount() throws {
        let url = try rollout([
            meta, context,
            #"{"timestamp":"2026-09-04T10:00:02.000Z","type":"event_msg","payload":{"type":"token_count","info":null}}"#,
            tokenCount(total: 1100, lastInput: 1000, cached: 400, output: 100),
            // A rate-limit refresh re-sends the same totals: not a new response.
            tokenCount(total: 1100, lastInput: 1000, cached: 400, output: 100),
            tokenCount(total: 3300, lastInput: 2000, cached: 1500, output: 200),
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let records = try CodexTranscriptParser.parseFile(url)
        #expect(records.map(\.requestId) == ["codex:old-session:count-1100", "codex:old-session:count-3300"])
        #expect(records.map(\.usage.input) == [600, 500])
        #expect(records.map(\.usage.cacheRead) == [400, 1500])
        #expect(records.map(\.usage.output) == [100, 200])
        #expect(records.allSatisfy { $0.model == "gpt-5.3-codex" && $0.cwd == "/p" })
    }

    @Test("A rollout with usage records ignores its token_count events")
    func tokenCountIsNotDoubleCounted() throws {
        let url = try rollout([
            meta, context,
            #"{"timestamp":"2026-09-04T10:00:03.000Z","type":"token_usage_record","payload":{"response_id":"r1","usage":{"input_tokens":1000,"cached_input_tokens":400,"output_tokens":100}}}"#,
            tokenCount(total: 1100, lastInput: 1000, cached: 400, output: 100),
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try CodexTranscriptParser.parseFile(url).map(\.requestId) == ["codex:old-session:r1"])
    }
}
