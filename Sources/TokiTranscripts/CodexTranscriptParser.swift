import Foundation
import TokiModels

/// Parses Codex rollout logs into per-response usage records.
///
/// Codex records model and cwd in context lines, then emits `token_usage_record` lines.
/// Parsing the file as a stream preserves that context without materialising message/tool
/// content; only the allowlisted identifiers, timestamps and numeric counters are retained.
///
/// The context is a value (`CodexParseContext`) the indexer persists next to the file's
/// offset, so a growing rollout is tailed from where the last pass stopped instead of being
/// re-read from the start on every write.
public enum CodexTranscriptParser {
    public static func parseFile(_ url: URL) throws -> [TranscriptRecord] {
        var scan = CodexScan(context: CodexParseContext())
        _ = try LineScanner.scan(path: url.path, from: 0) { line, isComplete in
            scan.consume(line, isComplete: isComplete)
        }
        return scan.finish()
    }

    /// One line's contribution to a scan.
    enum LineRecord {
        /// A `token_usage_record`: one model response, exactly.
        case usage(TranscriptRecord)
        /// A `token_count` event of a rollout written before `token_usage_record` existed.
        /// Only counted for a file that has no usage records (see `CodexScan.finish()`).
        case countFallback(TranscriptRecord)
    }

    /// Advances `context` past one line and returns the usage it carries, if any.
    ///
    /// Every line counts toward `context.ordinal` (the fallback response id), whether or not
    /// it parses — so an ordinal means the same line no matter where a scan started.
    static func parse(line: UnsafeRawBufferPointer, context: inout CodexParseContext) -> LineRecord? {
        context.ordinal += 1
        // Byte prefilter: only four line types matter, and their type names cannot appear
        // unescaped inside a string value. Response items (most of a rollout) are skipped
        // without being decoded.
        guard line.containsBytes("\"token_usage_record\"")
            || line.containsBytes("\"token_count\"")
            || line.containsBytes("\"turn_context\"")
            || line.containsBytes("\"session_meta\"")
        else { return nil }
        guard let base = line.baseAddress else { return nil }
        let data = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: base), count: line.count, deallocator: .none)
        // no-log: rollout parsing runs once per line and deliberately skips
        // malformed/non-JSON lines; logging each one can flood diagnostics.
        // Pooled per line for the same reason as `TranscriptParser.parse(bytes:)`.
        guard let object = autoreleasepool(invoking: { try? JSONDecoder().decode(CodexLine.self, from: data) }),
              let payload = object.payload
        else { return nil }

        switch object.type {
        case "session_meta":
            context.sessionID = payload.id ?? payload.sessionID ?? context.sessionID
            context.cwd = payload.cwd ?? context.cwd
        case "turn_context":
            context.cwd = payload.cwd ?? context.cwd
            context.model = payload.model ?? context.model
        case "token_usage_record":
            guard let timestamp = object.timestamp.flatMap(TranscriptParser.parseTimestamp),
                  let usage = payload.usage
            else { return nil }
            context.sawUsageRecord = true
            let recordSession = payload.sessionID ?? context.sessionID
            let responseID = payload.responseID ?? payload.turnID ?? String(context.ordinal)
            return .usage(record(
                id: "codex:\(recordSession):\(responseID)", session: recordSession,
                usage: usage, timestamp: timestamp, context: context
            ))
        case "event_msg" where payload.type == "token_count":
            // `last_token_usage` is the response that just finished; `total_token_usage`
            // only grows, and a repeat event (rate-limit refreshes re-send the same info)
            // is recognised by it not having moved.
            guard let info = payload.info,
                  let last = info.last, let total = info.total,
                  total.total > context.lastCountTotal,
                  let timestamp = object.timestamp.flatMap(TranscriptParser.parseTimestamp)
            else { return nil }
            context.lastCountTotal = total.total
            return .countFallback(record(
                id: "codex:\(context.sessionID):count-\(total.total)", session: context.sessionID,
                usage: last, timestamp: timestamp, context: context
            ))
        default:
            break
        }
        return nil
    }

    private static func record(
        id: String,
        session: String,
        usage: CodexLine.Usage,
        timestamp: Date,
        context: CodexParseContext
    ) -> TranscriptRecord {
        // Codex reports cached and cache-write tokens inside `input_tokens`, and reasoning
        // tokens inside `output_tokens`. Partition input into mutually exclusive buckets so
        // analytics does not count or price either cache class twice.
        TranscriptRecord(
            requestId: id,
            sessionId: session,
            cwd: context.cwd,
            model: context.model,
            timestamp: timestamp,
            usage: TokenUsage(
                input: max(usage.input - usage.cached - usage.cacheWrite, 0),
                output: usage.output,
                cacheRead: usage.cached,
                ephemeral5m: usage.cacheWrite,
                ephemeral1h: 0,
                webSearch: 0,
                webFetch: 0
            ),
            isSidechain: false
        )
    }
}

/// Collects one pass over (part of) a rollout.
///
/// Rollouts from before `token_usage_record` existed report usage only through
/// `token_count` events; newer ones write both, one per response. So `token_count` usage is
/// held aside and kept only if the file turns out to have no usage records at all —
/// counting both would double every response.
struct CodexScan {
    private(set) var context: CodexParseContext
    private var records: [TranscriptRecord] = []
    private var fallback: [TranscriptRecord] = []

    init(context: CodexParseContext) {
        self.context = context
    }

    mutating func consume(_ line: UnsafeRawBufferPointer, isComplete: Bool) {
        let result: CodexTranscriptParser.LineRecord?
        if isComplete {
            result = CodexTranscriptParser.parse(line: line, context: &context)
        } else {
            // An unterminated last line is read but not consumed: its context change must
            // not outlive this pass, it is re-read once complete.
            var provisional = context
            result = CodexTranscriptParser.parse(line: line, context: &provisional)
        }
        switch result {
        case .usage(let record): records.append(record)
        case .countFallback(let record): fallback.append(record)
        case nil: break
        }
    }

    func finish() -> [TranscriptRecord] {
        context.sawUsageRecord ? records : records + fallback
    }
}

/// What a Codex rollout has established by a given line: the session, working directory and
/// model that later usage lines are attributed to, and how many lines precede that point.
public struct CodexParseContext: Sendable, Equatable {
    public var sessionID = ""
    public var cwd = ""
    public var model = "codex"
    /// Lines consumed so far (1-based ordinal of the last one).
    public var ordinal = 0
    /// The rollout has at least one `token_usage_record`, so its `token_count` events are
    /// duplicates, not a fallback (see `CodexScan`).
    public var sawUsageRecord = false
    /// The highest `total_token_usage.total_tokens` counted from a `token_count` event.
    public var lastCountTotal = 0

    public init(
        sessionID: String = "",
        cwd: String = "",
        model: String = "codex",
        ordinal: Int = 0,
        sawUsageRecord: Bool = false,
        lastCountTotal: Int = 0
    ) {
        self.sessionID = sessionID
        self.cwd = cwd
        self.model = model
        self.ordinal = ordinal
        self.sawUsageRecord = sawUsageRecord
        self.lastCountTotal = lastCountTotal
    }
}

// MARK: - Decoding shape

/// The allowlisted fields of one rollout line; `payload` content is otherwise skipped.
/// Lenient field-by-field, like `ClaudeLine`: a string field of another type reads as absent,
/// and an empty string is treated as absent too.
private struct CodexLine: Decodable {
    let type: String?
    let timestamp: String?
    let payload: Payload?

    enum CodingKeys: String, CodingKey { case type, timestamp, payload }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = c.lenient(String.self, .type)
        timestamp = c.lenient(String.self, .timestamp)
        payload = c.lenient(Payload.self, .payload)
    }

    struct Payload: Decodable {
        let type: String?
        let id: String?
        let sessionID: String?
        let cwd: String?
        let model: String?
        let responseID: String?
        let turnID: String?
        let usage: Usage?
        let info: CountInfo?

        enum CodingKeys: String, CodingKey {
            case type, id, cwd, model, usage, info
            case sessionID = "session_id"
            case responseID = "response_id"
            case turnID = "turn_id"
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            func text(_ key: CodingKeys) -> String? {
                guard let value = c.lenient(String.self, key), !value.isEmpty else { return nil }
                return value
            }
            type = text(.type)
            info = c.lenient(CountInfo.self, .info)
            id = text(.id)
            sessionID = text(.sessionID)
            cwd = text(.cwd)
            model = text(.model)
            responseID = text(.responseID)
            turnID = text(.turnID)
            usage = c.lenient(Usage.self, .usage)
        }
    }

    /// A `token_count` event's payload: the last response and the running total.
    struct CountInfo: Decodable {
        let last: Usage?
        let total: Usage?

        enum CodingKeys: String, CodingKey {
            case last = "last_token_usage"
            case total = "total_token_usage"
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            last = c.lenient(Usage.self, .last)
            total = c.lenient(Usage.self, .total)
        }
    }

    struct Usage: Decodable {
        let input: Int
        let cached: Int
        let cacheWrite: Int
        let output: Int
        /// `total_tokens` (input + output), falling back to their sum when absent.
        let total: Int

        enum CodingKeys: String, CodingKey {
            case input = "input_tokens"
            case cached = "cached_input_tokens"
            case cacheWrite = "cache_write_input_tokens"
            case output = "output_tokens"
            case total = "total_tokens"
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            input = c.lenientInt(.input)
            cached = c.lenientInt(.cached)
            cacheWrite = c.lenientInt(.cacheWrite)
            output = c.lenientInt(.output)
            let reported = c.lenientInt(.total)
            total = reported > 0 ? reported : input + output
        }
    }
}
