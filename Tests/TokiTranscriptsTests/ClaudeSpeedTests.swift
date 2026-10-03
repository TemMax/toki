import Foundation
import Testing
import TokiModels
@testable import TokiTranscripts

/// Lines shaped like real Claude Code transcript lines: top-level `type`, `timestamp` after
/// `message`, usage repeated on every block of one request.
private func user(_ ts: String) -> String {
    #"{"type":"user","message":{"role":"user","content":"hi"},"timestamp":"\#(ts)","sessionId":"s"}"#
}
private func attachment(_ ts: String) -> String {
    #"{"type":"attachment","attachment":{"kind":"hook"},"timestamp":"\#(ts)","sessionId":"s"}"#
}
private func queued(_ ts: String) -> String {
    #"{"type":"queue-operation","operation":"enqueue","timestamp":"\#(ts)","sessionId":"s"}"#
}
private func assistant(_ rid: String, _ ts: String, output: Int = 400, effort: String? = "high", speed: String = "standard") -> String {
    let e = effort.map { #","effort":"\#($0)""# } ?? ""
    return #"{"type":"assistant","requestId":"\#(rid)","message":{"model":"claude-opus-5-5","usage":{"input_tokens":2,"output_tokens":\#(output),"speed":"\#(speed)"},"content":[]},"timestamp":"\#(ts)","sessionId":"s","cwd":"/p"\#(e)}"#
}

private func toolResult(_ ts: String) -> String {
    #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]},"timestamp":"\#(ts)","sessionId":"s"}"#
}

/// One pass over `lines` that starts from (and hands back) everything a pass carries.
private func carriedScan(_ lines: [String], from prior: ClaudeScan? = nil) -> ClaudeScan {
    var scan = ClaudeScan(lastInputMs: prior?.lastInputMs, openRequestId: prior?.openRequestId,
                          openRequestStartMs: prior?.openRequestStartMs)
    for line in lines {
        var copy = line
        copy.withUTF8 { scan.consume(UnsafeRawBufferPointer($0), isComplete: true) }
    }
    return scan
}

private func scan(_ lines: [String], from lastInputMs: Int64? = nil) -> (records: [TranscriptRecord], lastInputMs: Int64?) {
    var scan = ClaudeScan(lastInputMs: lastInputMs)
    for line in lines {
        var copy = line
        copy.withUTF8 { scan.consume(UnsafeRawBufferPointer($0), isComplete: true) }
    }
    return (scan.finish(), scan.lastInputMs)
}

@Suite("Claude generation speed")
struct ClaudeSpeedTests {
    @Test("Start is the last input line before the request; end is its last block")
    func anchorsAndEnd() {
        let result = scan([
            user("2026-10-02T10:00:00.000Z"),
            attachment("2026-10-02T10:00:01.000Z"),
            assistant("r1", "2026-10-02T10:00:09.000Z"),
            assistant("r1", "2026-10-02T10:00:11.500Z"),
        ])
        #expect(result.records.count == 1)
        #expect(result.records.first?.generationMs == 11_500)
        #expect(result.records.first?.effort == "high")
        #expect(result.records.first?.isFast == false)
    }

    @Test("An attachment written after the request was sent does not move the start")
    func attachmentAfterRequestIsNotInput() {
        let result = scan([
            user("2026-10-02T10:00:00.000Z"),
            #"{"type":"attachment","attachment":{"type":"deferred_tools_record"},"timestamp":"2026-10-02T10:00:09.000Z","sessionId":"s"}"#,
            assistant("r1", "2026-10-02T10:00:10.000Z"),
        ])
        #expect(result.records.first?.generationMs == 10_000)
    }

    @Test("A queued message mid-request does not move the start")
    func queueOperationIsNotInput() {
        let result = scan([
            user("2026-10-02T10:00:00.000Z"),
            queued("2026-10-02T10:00:05.000Z"),
            assistant("r1", "2026-10-02T10:00:08.000Z"),
        ])
        #expect(result.records.first?.generationMs == 8_000)
    }

    @Test("A request with no input line before it has no duration")
    func noAnchor() {
        let result = scan([assistant("r1", "2026-10-02T10:00:08.000Z")])
        #expect(result.records.first?.generationMs == nil)
    }

    @Test("Fast mode and effort come from the line")
    func fastAndEffort() {
        let result = scan([user("2026-10-02T10:00:00.000Z"),
                           assistant("r1", "2026-10-02T10:00:04.000Z", effort: "max", speed: "fast")])
        #expect(result.records.first?.isFast == true)
        #expect(result.records.first?.billing.contains(.fastMode) == true)
        #expect(result.records.first?.effort == "max")
    }

    @Test("A request straddling two reads gets the whole-file duration")
    func straddle() {
        let lines = [
            user("2026-10-02T10:00:00.000Z"),
            assistant("r1", "2026-10-02T10:00:06.000Z"),
            assistant("r1", "2026-10-02T10:00:09.000Z"),
            user("2026-10-02T10:00:20.000Z"),
            assistant("r2", "2026-10-02T10:00:24.000Z"),
        ]
        let whole = scan(lines)
        let first = scan(Array(lines[0...1]))
        let second = scan(Array(lines[2...]), from: first.lastInputMs)
        #expect(first.lastInputMs == 1_790_935_200_000)
        #expect(second.records.first { $0.requestId == "r1" }?.generationMs == 9_000)
        #expect(second.records.first { $0.requestId == "r2" }?.generationMs == 4_000)
        #expect(whole.records.map(\.generationMs) == [9_000, 4_000])
    }

    @Test("A tool result between two blocks of a request split across reads keeps its start")
    func straddleAcrossToolResult() {
        let lines = [
            user("2026-10-02T10:00:00.000Z"),
            assistant("r1", "2026-10-02T10:00:04.000Z"),
            toolResult("2026-10-02T10:00:05.000Z"),
            assistant("r1", "2026-10-02T10:00:10.000Z"),
        ]
        let whole = carriedScan(lines)
        let first = carriedScan(Array(lines[0...2]))
        #expect(first.lastInputMs == 1_790_935_205_000)
        #expect(first.openRequestId == "r1")
        #expect(first.openRequestStartMs == 1_790_935_200_000)
        let second = carriedScan(Array(lines[3...]), from: first)
        #expect(whole.finish().first?.generationMs == 10_000)
        #expect(second.finish().first?.generationMs == 10_000)
    }

    @Test("An unterminated block does not become the persisted open request")
    func incompleteBlockIsNotOpen() {
        var scan = ClaudeScan(lastInputMs: nil)
        var a = user("2026-10-02T10:00:00.000Z")
        a.withUTF8 { scan.consume(UnsafeRawBufferPointer($0), isComplete: true) }
        var b = assistant("r1", "2026-10-02T10:00:04.000Z")
        b.withUTF8 { scan.consume(UnsafeRawBufferPointer($0), isComplete: true) }
        var c = assistant("r2", "2026-10-02T10:00:06.000Z")
        c.withUTF8 { scan.consume(UnsafeRawBufferPointer($0), isComplete: false) }
        #expect(scan.openRequestId == "r1")
        #expect(scan.openRequestStartMs == 1_790_935_200_000)
    }

    @Test("Appending the rest of a request after a tool result re-measures it to the whole-file duration")
    func straddleThroughTheIndex() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("speed-straddle-\(UUID().uuidString)")
        let projects = root.appendingPathComponent("projects")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let transcript = projects.appendingPathComponent("s.jsonl")
        let head = [user("2026-10-02T10:00:00.000Z"), assistant("r1", "2026-10-02T10:00:04.000Z"),
                    toolResult("2026-10-02T10:00:05.000Z")]
        try (head.joined(separator: "\n") + "\n").write(to: transcript, atomically: true, encoding: .utf8)

        let indexer = try TranscriptIndexer(databaseURL: root.appendingPathComponent("index.sqlite3"),
                                            projectsDirectory: projects)
        try await indexer.reindex()
        #expect(await indexer.allRecords().first?.generationMs == 4_000)

        let handle = try FileHandle(forWritingTo: transcript)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((assistant("r1", "2026-10-02T10:00:10.000Z") + "\n").utf8))
        try handle.close()
        try await indexer.reindex()
        #expect(await indexer.allRecords().first?.generationMs == 10_000)
    }

    @Test("One walk over a line's quotes finds exactly what a search per token finds")
    func tokensMatchPerTokenSearch() {
        let lines = [
            user("2026-10-02T10:00:00.000Z"),
            toolResult("2026-10-02T10:00:00.000Z"),
            attachment("2026-10-02T10:00:00.000Z"),
            queued("2026-10-02T10:00:00.000Z"),
            assistant("r", "2026-10-02T10:00:00.000Z"),
            #"{"type":"user","note":"say \"type\":\"assistant\" and \"requestId\"","timestamp":"2026-10-02T10:00:00.000Z"}"#,
            #"{"type":"attachment","attachment":{"type":"total_tokens_reminder"},"role":"assistant","timestamp":"x"}"#,
            #"{"requestId":"r","type":"assistant""#,
            "\"",
            "",
        ]
        for line in lines {
            var copy = line
            copy.withUTF8 { raw in
                let bytes = UnsafeRawBufferPointer(raw)
                let tokens = ClaudeLineTokens(bytes)
                #expect(tokens.mayBeRecord == (bytes.containsBytes("\"assistant\"") && bytes.containsBytes("\"requestId\"")), "\(line)")
                #expect(tokens.typeUser == bytes.containsBytes("\"type\":\"user\""), "\(line)")
                #expect(tokens.typeAttachment == bytes.containsBytes("\"type\":\"attachment\""), "\(line)")
                #expect(tokens.typeAssistant == bytes.containsBytes("\"type\":\"assistant\""), "\(line)")
                #expect(tokens.inputTimestampMs(bytes: bytes) == {
                    guard bytes.containsBytes("\"type\":\"user\""),
                          !bytes.containsBytes("\"type\":\"assistant\"") else { return nil }
                    return TranscriptParser.leadingTimestampMs(bytes: bytes)
                }(), "\(line)")
            }
        }
    }

    @Test("An unterminated input line does not become the persisted anchor")
    func incompleteInputLine() {
        var scan = ClaudeScan(lastInputMs: nil)
        var a = user("2026-10-02T10:00:00.000Z")
        a.withUTF8 { scan.consume(UnsafeRawBufferPointer($0), isComplete: true) }
        var b = user("2026-10-02T10:00:30.000Z")
        b.withUTF8 { scan.consume(UnsafeRawBufferPointer($0), isComplete: false) }
        #expect(scan.lastInputMs == 1_790_935_200_000)
    }

    @Test("inputTimestampMs reads only prompt and tool-result lines")
    func inputTimestampFilter() {
        func ms(_ s: String) -> Int64? {
            var s = s
            return s.withUTF8 { TranscriptParser.inputTimestampMs(bytes: UnsafeRawBufferPointer($0)) }
        }
        #expect(ms(user("2026-10-02T10:00:00.000Z")) == 1_790_935_200_000)
        #expect(ms(attachment("2026-10-02T10:00:00.000Z")) == nil)
        #expect(ms(queued("2026-10-02T10:00:00.000Z")) == nil)
        #expect(ms(assistant("r", "2026-10-02T10:00:00.000Z")) == nil)
        #expect(ms(#"{"type":"user","timestamp":"not a date"}"#) == nil)
    }

    @Test("Format 4 re-reads transcripts on disk and keeps records whose files are gone")
    func formatBumpKeepsHistory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("speed-migrate-\(UUID().uuidString)")
        let projects = root.appendingPathComponent("projects")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = root.appendingPathComponent("index.sqlite3")

        // An index written by format 3: one record whose transcript is long gone, and the
        // read position of a transcript that is still on disk.
        let transcript = projects.appendingPathComponent("s.jsonl")
        let body = [user("2026-10-02T10:00:00.000Z"), assistant("live", "2026-10-02T10:00:05.000Z")]
            .joined(separator: "\n") + "\n"
        try body.write(to: transcript, atomically: true, encoding: .utf8)
        do {
            let store = try TranscriptStore(databaseURL: db)
            try store.upsertEntry(TranscriptRecord(
                requestId: "gone", sessionId: "s", cwd: "/p", model: "claude-opus-4-8",
                timestamp: Date(timeIntervalSince1970: 1_780_000_000),
                usage: TokenUsage(input: 1, output: 500, cacheRead: 0, ephemeral5m: 0, ephemeral1h: 0, webSearch: 0, webFetch: 0),
                isSidechain: false))
            var st = stat()
            #expect(stat(transcript.path, &st) == 0)
            // The indexer enumerates the canonical path (`/private/var/…`), and `file_state`
            // is keyed by it: persist that form so the file reads as already indexed.
            let canonical = try #require(realpath(transcript.path, nil))
            defer { free(canonical) }
            try store.upsertFileState(FileIndexState(
                path: String(cString: canonical), lastByteOffset: UInt64(st.st_size), lastKnownSize: UInt64(st.st_size),
                inode: UInt64(st.st_ino), device: UInt64(bitPattern: Int64(st.st_dev))))
            try store.setMeta(key: "index_format", value: "3")
        }

        let indexer = try TranscriptIndexer(databaseURL: db, projectsDirectory: projects)
        try await indexer.reindex()
        let byId = Dictionary(uniqueKeysWithValues: await indexer.allRecords().map { ($0.requestId, $0) })
        #expect(byId["gone"]?.usage.output == 500)
        #expect(byId["gone"]?.generationMs == nil)
        #expect(byId["live"]?.generationMs == 5_000)
    }
}
