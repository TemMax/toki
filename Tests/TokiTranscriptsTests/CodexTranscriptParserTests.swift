import Foundation
import Testing
import TokiModels
@testable import TokiTranscripts

@Suite("CodexTranscriptParser")
struct CodexTranscriptParserTests {
    @Test("rollout usage becomes one privacy-minimal record with context")
    func parsesUsageWithContext() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-rollout-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: file) }
        let jsonl = """
        {"timestamp":"2026-09-04T10:00:00.000Z","type":"session_meta","payload":{"id":"session-1","cwd":"/tmp/project","sensitive":"ignored"}}
        {"timestamp":"2026-09-04T10:00:01.000Z","type":"turn_context","payload":{"model":"gpt-5.3-codex","cwd":"/tmp/project"}}
        {"timestamp":"2026-09-04T10:00:02.000Z","type":"response_item","payload":{"type":"message","content":"must never be retained"}}
        {"timestamp":"2026-09-04T10:00:03.000Z","type":"token_usage_record","payload":{"session_id":"session-1","response_id":"response-1","usage":{"input_tokens":120,"cached_input_tokens":20,"output_tokens":30,"cache_write_input_tokens":4}}}
        """
        try Data(jsonl.utf8).write(to: file)

        let records = try CodexTranscriptParser.parseFile(file)
        let record = try #require(records.first)
        #expect(records.count == 1)
        #expect(record.requestId == "codex:session-1:response-1")
        #expect(record.sessionId == "session-1")
        #expect(record.cwd == "/tmp/project")
        #expect(record.model == "gpt-5.3-codex")
        #expect(record.usage.input == 96)
        #expect(record.usage.cacheRead == 20)
        #expect(record.usage.output == 30)
        #expect(record.usage.ephemeral5m == 4)
        #expect(
            record.usage.input + record.usage.cacheRead + record.usage.cacheCreationTotal == 120,
            "Codex input buckets must partition input_tokens without double counting"
        )
    }

    @Test("full indexing includes Codex archived sessions beside active sessions")
    func indexesArchivedSessions() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-archive-index-\(UUID().uuidString)")
        let projects = root.appendingPathComponent("claude-projects")
        let sessions = root.appendingPathComponent("sessions")
        let archive = root.appendingPathComponent("archived_sessions")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)

        let rollout = """
        {"timestamp":"2026-09-04T10:00:00.000Z","type":"session_meta","payload":{"id":"archived-session","cwd":"/tmp/project"}}
        {"timestamp":"2026-09-04T10:00:01.000Z","type":"turn_context","payload":{"model":"gpt-5.3-codex"}}
        {"timestamp":"2026-09-04T10:00:02.000Z","type":"token_usage_record","payload":{"response_id":"archived-response","usage":{"input_tokens":10,"cached_input_tokens":0,"output_tokens":5}}}
        """
        try Data(rollout.utf8).write(to: archive.appendingPathComponent("rollout.jsonl"))

        let indexer = try TranscriptIndexer(
            databaseURL: root.appendingPathComponent("index.sqlite3"),
            projectsDirectory: projects,
            codexSessionsDirectory: sessions
        )
        try await indexer.reindex()

        let records = await indexer.allRecords()
        #expect(records.map(\.requestId) == ["codex:archived-session:archived-response"])
    }

    private func records(_ jsonl: String) throws -> [TranscriptRecord] {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("codex-speed-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(jsonl.utf8).write(to: file)
        return try CodexTranscriptParser.parseFile(file)
    }

    @Test("A response is timed from the latest input event to its usage record")
    func codexAnchors() throws {
        let result = try records("""
        {"timestamp":"2026-10-02T10:00:00.000Z","type":"session_meta","payload":{"id":"s1","cwd":"/p"}}
        {"timestamp":"2026-10-02T10:00:00.100Z","type":"event_msg","payload":{"type":"thread_settings_applied","thread_settings":{"service_tier":"priority"}}}
        {"timestamp":"2026-10-02T10:00:00.200Z","type":"event_msg","payload":{"type":"task_started"}}
        {"timestamp":"2026-10-02T10:00:00.300Z","type":"turn_context","payload":{"model":"gpt-6.1-sol","effort":"high"}}
        {"timestamp":"2026-10-02T10:00:01.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[]}}
        {"timestamp":"2026-10-02T10:00:07.000Z","type":"response_item","payload":{"type":"function_call","name":"x"}}
        {"timestamp":"2026-10-02T10:00:07.200Z","type":"token_usage_record","payload":{"response_id":"a","usage":{"input_tokens":10,"output_tokens":300}}}
        {"timestamp":"2026-10-02T10:01:00.000Z","type":"response_item","payload":{"type":"function_call_output","output":"ok"}}
        {"timestamp":"2026-10-02T10:01:05.000Z","type":"token_usage_record","payload":{"response_id":"b","usage":{"input_tokens":10,"output_tokens":250}}}
        {"timestamp":"2026-10-02T10:01:09.000Z","type":"token_usage_record","payload":{"response_id":"c","usage":{"input_tokens":10,"output_tokens":220}}}
        """)
        let byId = Dictionary(uniqueKeysWithValues: result.map { ($0.requestId, $0) })
        #expect(byId["codex:s1:a"]?.generationMs == 6_200)   // user message -> record
        #expect(byId["codex:s1:b"]?.generationMs == 5_000)   // tool output -> record (tool time excluded)
        #expect(byId["codex:s1:c"]?.generationMs == 4_000)   // back-to-back: previous record -> record
        #expect(byId["codex:s1:a"]?.effort == "high")
        #expect(byId["codex:s1:a"]?.isFast == true)
    }

    @Test("Without thread settings a session is standard; token_count fallback has no duration")
    func codexDefaultsAndFallback() throws {
        let result = try records("""
        {"timestamp":"2026-10-02T10:00:00.000Z","type":"session_meta","payload":{"id":"s2"}}
        {"timestamp":"2026-10-02T10:00:00.200Z","type":"event_msg","payload":{"type":"task_started"}}
        {"timestamp":"2026-10-02T10:00:09.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":5,"output_tokens":400,"total_tokens":405},"total_token_usage":{"input_tokens":5,"output_tokens":400,"total_tokens":405}}}}
        """)
        #expect(result.count == 1)
        #expect(result.first?.generationMs == nil)
        #expect(result.first?.isFast == false)
    }

    @Test("Resuming mid-rollout keeps the anchor saved with the context")
    func codexResume() throws {
        var context = CodexParseContext(sessionID: "s3", model: "gpt-6-sol",
                                        anchorMs: 1_790_935_200_000, effort: "low", isFast: false)
        var line = #"{"timestamp":"2026-10-02T10:00:03.000Z","type":"token_usage_record","payload":{"response_id":"r","usage":{"input_tokens":1,"output_tokens":300}}}"#
        let parsed = line.withUTF8 { CodexTranscriptParser.parse(line: UnsafeRawBufferPointer($0), context: &context) }
        guard case .usage(let record) = parsed else { Issue.record("expected usage"); return }
        #expect(record.generationMs == 3_000)
        #expect(record.effort == "low")
        #expect(context.anchorMs == 1_790_935_203_000)
    }

    @Test("One walk over a rollout line's quotes classifies it as a search per token does")
    func lineKindMatchesPerTokenSearch() {
        let cases: [(String, CodexTranscriptParser.LineKind)] = [
            (#"{"timestamp":"t","type":"event_msg","payload":{"type":"task_started"}}"#, .input),
            (#"{"timestamp":"t","type":"response_item","payload":{"type":"function_call_output","output":"x"}}"#, .input),
            (#"{"timestamp":"t","type":"response_item","payload":{"type":"custom_tool_call_output"}}"#, .input),
            (#"{"timestamp":"t","type":"response_item","payload":{"type":"message","role":"user"}}"#, .input),
            (#"{"timestamp":"t","type":"token_usage_record","payload":{"usage":{}}}"#, .wanted),
            (#"{"timestamp":"t","type":"event_msg","payload":{"type":"token_count"}}"#, .wanted),
            (#"{"timestamp":"t","type":"turn_context","payload":{}}"#, .wanted),
            (#"{"timestamp":"t","type":"session_meta","payload":{}}"#, .wanted),
            (#"{"timestamp":"t","type":"event_msg","payload":{"type":"thread_settings_applied"}}"#, .wanted),
            // An input token wins over a wanted one, wherever each appears.
            (#"{"timestamp":"t","type":"session_meta","payload":{"role":"user"}}"#, .input),
            (#"{"timestamp":"t","type":"response_item","payload":{"type":"message","role":"assistant"}}"#, .skipped),
            // Inside a string value the quotes are escaped, so nothing matches.
            (#"{"timestamp":"t","type":"response_item","payload":{"text":"\"task_started\" \"role\":\"user\" x_call_output\" \"token_count\""}}"#, .skipped),
            (#"_call_output""#, .input),
            ("", .skipped),
        ]
        for (line, expected) in cases {
            var copy = line
            copy.withUTF8 { raw in
                let bytes = UnsafeRawBufferPointer(raw)
                let searched: CodexTranscriptParser.LineKind =
                    bytes.containsBytes("\"task_started\"") || bytes.containsBytes("_call_output\"")
                        || bytes.containsBytes("\"role\":\"user\"") ? .input
                    : bytes.containsBytes("\"token_usage_record\"") || bytes.containsBytes("\"token_count\"")
                        || bytes.containsBytes("\"turn_context\"") || bytes.containsBytes("\"session_meta\"")
                        || bytes.containsBytes("\"thread_settings_applied\"") ? .wanted
                    : .skipped
                #expect(CodexTranscriptParser.LineKind(bytes) == expected, "\(line)")
                #expect(searched == expected, "\(line)")
            }
        }
    }
}
