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
        switch LineKind(line) {
        case .input:
            // Input events only move the start anchor, and need nothing but the line's own
            // timestamp — the first key of every rollout line — so they are never decoded.
            if let ms = TranscriptParser.leadingTimestampMs(bytes: line) { context.anchorMs = ms }
            return nil
        case .skipped:
            return nil
        case .wanted:
            break
        }
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
            context.effort = payload.effort?.lowercased() ?? context.effort
        case "event_msg" where payload.type == "thread_settings_applied":
            if let tier = payload.serviceTier { context.isFast = tier == "priority" }
        case "token_usage_record":
            guard let timestamp = object.timestamp.flatMap(TranscriptParser.parseTimestamp),
                  let usage = payload.usage
            else { return nil }
            context.sawUsageRecord = true
            let end = TranscriptStore.milliseconds(timestamp)
            let duration = context.anchorMs.flatMap { end >= $0 ? Int(end - $0) : nil }
            context.anchorMs = end   // a response that follows directly starts here
            let recordSession = payload.sessionID ?? context.sessionID
            let responseID = payload.responseID ?? payload.turnID ?? String(context.ordinal)
            return .usage(record(
                id: "codex:\(recordSession):\(responseID)", session: recordSession,
                usage: usage, timestamp: timestamp, context: context, generationMs: duration
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
            // No duration: this event is written after tool execution, not at the end of
            // generation.
            return .countFallback(record(
                id: "codex:\(context.sessionID):count-\(total.total)", session: context.sessionID,
                usage: last, timestamp: timestamp, context: context, generationMs: nil
            ))
        default:
            break
        }
        return nil
    }

    /// What a line's byte prefilter makes of it, from one walk over its quotes (see
    /// `UnsafeRawBufferPointer.forEachQuote(_:)`): the same answer as a `memmem` per token,
    /// at the cost of reading the line once. Every token contains a quote and cannot appear
    /// unescaped inside a string value.
    enum LineKind: Equatable {
        /// An input event (`"task_started"`, `"role":"user"`, or `_call_output"`, which
        /// closes `function_call_output` / `custom_tool_call_output`). Wins over `wanted`.
        case input
        /// One of the line types that are decoded: `"token_usage_record"`,
        /// `"token_count"`, `"turn_context"`, `"session_meta"`,
        /// `"thread_settings_applied"`.
        case wanted
        /// Anything else — response items, most of a rollout — skipped undecoded.
        case skipped

        init(_ line: UnsafeRawBufferPointer) {
            var input = false
            var wanted = false
            line.forEachQuote { quote in
                // `_call_output"` is the one token that ends, rather than starts, at a quote.
                if quote >= 12, line[quote - 1] == UInt8(ascii: "t"),
                   line.hasBytes("_call_output\"", at: quote - 12) {
                    input = true
                    return false
                }
                guard quote + 1 < line.count else { return true }
                switch line[quote + 1] {
                case UInt8(ascii: "t"):
                    if line.hasBytes("\"task_started\"", at: quote) {
                        input = true
                        return false
                    }
                    if !wanted {
                        wanted = line.hasBytes("\"token_usage_record\"", at: quote)
                            || line.hasBytes("\"token_count\"", at: quote)
                            || line.hasBytes("\"turn_context\"", at: quote)
                            || line.hasBytes("\"thread_settings_applied\"", at: quote)
                    }
                case UInt8(ascii: "r"):
                    if line.hasBytes("\"role\":\"user\"", at: quote) {
                        input = true
                        return false
                    }
                case UInt8(ascii: "s"):
                    if !wanted { wanted = line.hasBytes("\"session_meta\"", at: quote) }
                default:
                    break
                }
                return true
            }
            self = input ? .input : wanted ? .wanted : .skipped
        }
    }

    private static func record(
        id: String,
        session: String,
        usage: CodexLine.Usage,
        timestamp: Date,
        context: CodexParseContext,
        generationMs: Int?
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
            isSidechain: false,
            generationMs: generationMs,
            effort: context.effort,
            isFast: context.isFast
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
    /// When the response now being generated was requested (epoch ms): the latest
    /// task start, user message, tool output or completed response.
    public var anchorMs: Int64?
    /// `turn_context.effort` in effect.
    public var effort: String?
    /// `thread_settings_applied` set `service_tier` to `priority`.
    public var isFast = false

    public init(
        sessionID: String = "",
        cwd: String = "",
        model: String = "codex",
        ordinal: Int = 0,
        sawUsageRecord: Bool = false,
        lastCountTotal: Int = 0,
        anchorMs: Int64? = nil,
        effort: String? = nil,
        isFast: Bool = false
    ) {
        self.sessionID = sessionID
        self.cwd = cwd
        self.model = model
        self.ordinal = ordinal
        self.sawUsageRecord = sawUsageRecord
        self.lastCountTotal = lastCountTotal
        self.anchorMs = anchorMs
        self.effort = effort
        self.isFast = isFast
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
        let effort: String?
        /// `thread_settings.service_tier` of a `thread_settings_applied` event.
        let serviceTier: String?

        enum CodingKeys: String, CodingKey {
            case type, id, cwd, model, usage, info, effort
            case sessionID = "session_id"
            case responseID = "response_id"
            case turnID = "turn_id"
            case threadSettings = "thread_settings"
        }
        enum ThreadSettingsKeys: String, CodingKey { case serviceTier = "service_tier" }

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
            effort = text(.effort)
            serviceTier = c.lenientNested(ThreadSettingsKeys.self, .threadSettings)?
                .lenient(String.self, .serviceTier)
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
