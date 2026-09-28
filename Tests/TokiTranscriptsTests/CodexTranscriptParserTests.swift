import Foundation
import Testing
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
}
