/// TranscriptParser — parses a single Claude Code JSONL line into a `TranscriptRecord`.
import Foundation
import TokiModels

/// Stateless parser for one JSONL line of a Claude Code transcript.
///
/// Qualifying lines are `type == "assistant"`, carry a non-nil `requestId`, and are not
/// synthetic (`message.model != "<synthetic>"`). All other lines return `nil`.
public enum TranscriptParser {

    /// ISO8601 formatter with fractional seconds (Claude Code emits e.g. `2026-06-29T16:30:01.123Z`).
    /// Some records omit fractional seconds, so we fall back to a non-fractional formatter.
    /// Both are only the fallback behind `ISO8601Timestamp`'s fixed-format fast path.
    // ISO8601DateFormatter is immutable after configuration and its parsing methods are
    // thread-safe, so sharing these read-only instances across actors is safe.
    private nonisolated(unsafe) static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private nonisolated(unsafe) static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Parses one JSONL line. Returns `nil` for any non-qualifying or malformed line.
    ///
    /// - `isSidechain` is taken from the top-level `isSidechain` flag (default `false`).
    /// - `TokenUsage` is built from `message.usage` per the schema in R5/D6.
    public static func parse(line: String) -> TranscriptRecord? {
        var line = line
        return line.withUTF8 { parse(bytes: UnsafeRawBufferPointer($0)) }
    }

    /// Parses one JSONL line provided as raw UTF-8 bytes.
    public static func parse(data: Data) -> TranscriptRecord? {
        data.withUnsafeBytes { parse(bytes: $0) }
    }

    /// Parses one JSONL line in place. The hot path of indexing.
    ///
    /// Two byte searches run before any JSON is decoded: a qualifying line must contain the
    /// string token `"assistant"` and the key `"requestId"`. Neither can match inside a JSON
    /// string value (a quote there is escaped as `\"`), so they only ever reject lines that
    /// could not qualify — the user prompts and tool results that make up most of a
    /// transcript's bytes are skipped without being decoded or even copied.
    public static func parse(bytes: UnsafeRawBufferPointer) -> TranscriptRecord? {
        guard bytes.containsBytes("\"assistant\""), bytes.containsBytes("\"requestId\"") else {
            return nil
        }
        guard let base = bytes.baseAddress else { return nil }
        let data = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: base), count: bytes.count, deallocator: .none)
        guard
            // no-log: parse runs once per transcript line — a log call here would produce
            // megabytes per index pass over a large JSONL file. A malformed line is
            // silently skipped by design (see the type doc comment); it is not a failure.
            // The pool bounds any Objective-C temporaries decoding leaves behind to one line:
            // an index pass is one long synchronous job, and without a pool of its own they
            // would all be released only at its end (the old parser peaked at ~10 GB this way).
            let line = autoreleasepool(invoking: { try? JSONDecoder().decode(ClaudeLine.self, from: data) }),
            line.type == "assistant",
            let requestId = line.requestId, !requestId.isEmpty,
            let message = line.message
        else { return nil }

        // Skip synthetic model records.
        let model = message.model ?? ""
        guard model != "<synthetic>" else { return nil }

        guard let timestampString = line.timestamp,
              let timestamp = parseTimestamp(timestampString)
        else { return nil }

        return TranscriptRecord(
            requestId: requestId,
            sessionId: line.sessionId ?? "",
            cwd: line.cwd ?? "",
            model: model,
            timestamp: timestamp,
            usage: message.usage?.tokenUsage ?? .zero,
            isSidechain: line.isSidechain ?? false,
            billing: message.usage?.billing ?? []
        )
    }

    // MARK: - Helpers

    static func parseTimestamp(_ string: String) -> Date? {
        if let d = ISO8601Timestamp.parse(string) { return d }
        if let d = isoFractional.date(from: string) { return d }
        return isoPlain.date(from: string)
    }
}

// MARK: - Decoding shape

/// The allowlisted fields of one transcript line. Everything else — message content,
/// tool input/output — is skipped by the decoder without being materialised.
///
/// Every field decodes leniently (`try?`): a field of an unexpected type reads as absent
/// rather than failing the whole line, matching the tolerance of the parser this replaced.
private struct ClaudeLine: Decodable {
    let type: String?
    let requestId: String?
    let timestamp: String?
    let sessionId: String?
    let cwd: String?
    let isSidechain: Bool?
    let message: Message?

    enum CodingKeys: String, CodingKey {
        case type, requestId, timestamp, sessionId, cwd, isSidechain, message
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = c.lenient(String.self, .type)
        requestId = c.lenient(String.self, .requestId)
        timestamp = c.lenient(String.self, .timestamp)
        sessionId = c.lenient(String.self, .sessionId)
        cwd = c.lenient(String.self, .cwd)
        isSidechain = c.lenient(Bool.self, .isSidechain)
        message = c.lenient(Message.self, .message)
    }

    struct Message: Decodable {
        let model: String?
        let usage: Usage?

        enum CodingKeys: String, CodingKey { case model, usage }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            model = c.lenient(String.self, .model)
            usage = c.lenient(Usage.self, .usage)
        }
    }

    struct Usage: Decodable {
        var input = 0
        var output = 0
        var cacheRead = 0
        var cacheCreationAggregate = 0
        var cacheCreation: (fiveMinute: Int, oneHour: Int)?
        var webSearch = 0
        var webFetch = 0
        /// `speed` / `inference_geo`: how the request was billed (see `BillingModifiers`).
        var billing: BillingModifiers = []

        enum CodingKeys: String, CodingKey {
            case input_tokens, output_tokens, cache_read_input_tokens
            case cache_creation_input_tokens, cache_creation, server_tool_use
            case speed, inference_geo
        }
        enum CacheCreationKeys: String, CodingKey {
            case ephemeral_5m_input_tokens, ephemeral_1h_input_tokens
        }
        enum ServerToolKeys: String, CodingKey {
            case web_search_requests, web_fetch_requests
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            input = c.lenientInt(.input_tokens)
            output = c.lenientInt(.output_tokens)
            cacheRead = c.lenientInt(.cache_read_input_tokens)
            cacheCreationAggregate = c.lenientInt(.cache_creation_input_tokens)
            if let split = c.lenientNested(CacheCreationKeys.self, .cache_creation) {
                cacheCreation = (
                    split.lenientInt(.ephemeral_5m_input_tokens),
                    split.lenientInt(.ephemeral_1h_input_tokens)
                )
            }
            if let tools = c.lenientNested(ServerToolKeys.self, .server_tool_use) {
                webSearch = tools.lenientInt(.web_search_requests)
                webFetch = tools.lenientInt(.web_fetch_requests)
            }
            if (c.lenient(String.self, .speed)) == "fast" {
                billing.insert(.fastMode)
            }
            if (c.lenient(String.self, .inference_geo)) == "us" {
                billing.insert(.usOnlyInference)
            }
        }

        /// Applies the D6 aggregate-fallback rule: without a `cache_creation` breakdown the
        /// aggregate is treated as 5-minute cache writes.
        var tokenUsage: TokenUsage {
            TokenUsage(
                input: input,
                output: output,
                cacheRead: cacheRead,
                ephemeral5m: cacheCreation?.fiveMinute ?? cacheCreationAggregate,
                ephemeral1h: cacheCreation?.oneHour ?? 0,
                webSearch: webSearch,
                webFetch: webFetch
            )
        }
    }
}

extension KeyedDecodingContainer {
    // Transcript fields are read leniently: a field that is missing or of an unexpected type
    // reads as absent instead of failing the whole line, matching the tolerance of the
    // parser this replaced. These helpers are the only place that swallows the decoding
    // error, so the rule is stated once.

    /// The value at `key`, or nil when it is missing or not a `T`.
    func lenient<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        // no-log: runs for every field of every transcript line; a malformed field is
        // expected input, not a failure worth a log line.
        (try? decodeIfPresent(type, forKey: key)) ?? nil
    }

    /// The nested object at `key`, or nil when it is missing or not an object.
    func lenientNested<NestedKey: CodingKey>(_ keys: NestedKey.Type, _ key: Key) -> KeyedDecodingContainer<NestedKey>? {
        // no-log: as for `lenient(_:_:)` — an absent or foreign-shaped object is expected.
        try? nestedContainer(keyedBy: keys, forKey: key)
    }

    /// A token counter: an integer, a float truncated to one, or 0 when missing or of any
    /// other type.
    func lenientInt(_ key: Key) -> Int {
        if let value = lenient(Int.self, key) { return value }
        if let value = lenient(Double.self, key), value.isFinite,
           value > Double(Int.min), value < Double(Int.max) {
            return Int(value)
        }
        return 0
    }
}
