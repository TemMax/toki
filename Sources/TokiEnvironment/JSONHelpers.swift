/// Small tolerant JSON-reading helpers shared by the environment readers.
///
/// Every helper here is deliberately forgiving: a missing file, a malformed
/// document, or an unexpected shape yields `nil` / an empty collection rather
/// than throwing or crashing. Config files under `~/.claude` are written by a
/// separate process and may be partially written, stale, or from a future
/// schema version — readers must degrade gracefully.
import Foundation
import TokiLogging

private let log = TokiLog.logger("environment")

/// True when `error` is Foundation's "no such file" — by far the most common and
/// entirely expected reason a `~/.claude` config file fails to read (most of these
/// files are optional; many installs simply lack one). Shared with `SkillReader`
/// so a missing, expected file is never logged as though it were a failure.
func isMissingFileError(_ error: Error) -> Bool {
    let ns = error as NSError
    return ns.domain == NSCocoaErrorDomain && ns.code == NSFileReadNoSuchFileError
}

/// A loosely-typed JSON value used for tolerant, allowlist-driven field
/// extraction. Decoding into this type never fails on unexpected shapes.
enum JSONValue {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var intValue: Int? {
        if case .number(let value) = self { return Int(value) }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }
}

extension JSONValue: Decodable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        // no-log on every branch below: this is type-probing (try String, else Double, else
        // Bool, ...), not error handling — a "failure" here is the normal, expected way this
        // recursive decoder discovers a node's shape, so it is never worth a log entry. It
        // also runs once per JSON node, so a log call here would be a hot loop of its own for
        // any deeply-nested document.
        if let value = try? container.decode(String.self) { // no-log: type probing, see comment above
            self = .string(value)
        } else if let value = try? container.decode(Double.self) { // no-log: type probing, see comment above
            self = .number(value)
        } else if let value = try? container.decode(Bool.self) { // no-log: type probing, see comment above
            self = .bool(value)
        } else if let value = try? container.decode([String: JSONValue].self) { // no-log: type probing, see comment above
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) { // no-log: type probing, see comment above
            self = .array(value)
        } else {
            self = .null
        }
    }
}

/// Reads and decodes a JSON file at `url`, returning `nil` on any failure
/// (missing file, unreadable, malformed JSON). Never throws.
func readJSON<T: Decodable>(_ type: T.Type, at url: URL) -> T? {
    let data: Data
    do {
        data = try Data(contentsOf: url)
    } catch {
        // A missing file is the overwhelmingly common, expected case (most of these
        // config files are optional) — only a genuine I/O failure is worth logging.
        if !isMissingFileError(error) {
            log.error("failed to read config file \(path: url) \(error: error)")
        }
        return nil
    }
    do {
        return try JSONDecoder().decode(type, from: data)
    } catch {
        // `T.self`'s description is a fixed schema name known at compile time for this
        // call site (e.g. "LastUpdateResult") — never a value read from the file — so it
        // identifies which config field/shape failed to parse without naming the file.
        log.error("unparseable config field \(String(describing: T.self), privacy: .public) \(error: error)")
        return nil
    }
}

/// Reads a JSON file as a loosely-typed `JSONValue`, returning `nil` on any
/// failure. Used when only a small allowlist of fields should be extracted
/// from an otherwise-untrusted document (e.g. `~/.claude.json`).
func readJSONValue(at url: URL) -> JSONValue? {
    readJSON(JSONValue.self, at: url)
}

/// Parses an ISO-8601 timestamp string, tolerating both fractional-second and
/// whole-second forms. Returns `nil` for anything else.
func parseISO8601(_ string: String?) -> Date? {
    guard let string else { return nil }
    let withFractional = ISO8601DateFormatter()
    withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = withFractional.date(from: string) { return date }
    let whole = ISO8601DateFormatter()
    whole.formatOptions = [.withInternetDateTime]
    return whole.date(from: string)
}

/// Parses a Unix epoch timestamp that may be in milliseconds (Claude Code's
/// `lastUsedAt` fields) or seconds, returning `nil` for non-finite/invalid
/// values. Values larger than a plausible "seconds since epoch" range are
/// treated as milliseconds.
func parseEpoch(_ number: Double?) -> Date? {
    guard let number, number.isFinite, number > 0 else { return nil }
    // A seconds-since-epoch timestamp for "now" is ~1.8e9; milliseconds are
    // ~1.8e12. Use 1e11 as the dividing line.
    let seconds = number > 1e11 ? number / 1000 : number
    return Date(timeIntervalSince1970: seconds)
}

/// Returns the basename (last path component) of a shell command string,
/// stripping any path prefix. Used to redact stdio MCP server commands down
/// to e.g. "npx" — never the full path or arguments.
func commandBasename(_ command: String) -> String {
    URL(fileURLWithPath: command).lastPathComponent
}

/// Returns "scheme+host" (e.g. "mcp.amplitude.com") for a URL string, or
/// `nil` if it cannot be parsed. Deliberately drops path, query, and
/// userinfo, any of which may carry a secret token.
func hostOnly(_ urlString: String) -> String? {
    guard let components = URLComponents(string: urlString), let host = components.host else {
        return nil
    }
    return host
}
