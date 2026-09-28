/// Routes Claude Code's status line through Toki so the gauges see what the status line sees.
import Foundation
import TokiLogging
import TokiModels

private let log = TokiLog.logger("statusline")

public enum StatuslineTapError: Error, Equatable {
    case unreadable
    case malformed
    case writeFailed
}

/// Routes Claude Code's status line through a tiny script that saves its stdin for Toki —
/// the `rate_limits` Claude Code reads from its own API responses — then runs the user's own
/// command on the same input, so their status line looks exactly as before.
///
/// Claude Code has exactly one status line slot, so:
/// - a user with a status line has their command wrapped; the original rides inside the
///   wrapped command, shell-quoted, and switching off restores it byte for byte;
/// - a user without one gets Toki's own silent status line, which prints nothing. Claude Code
///   still hides a few footer hints while any status line is set; switching off removes it.
///
/// Only the edited member is spliced; every other byte of `settings.json` is left alone, as
/// `ClaudeConfigEditor` does for `~/.claude.json`. Every write is preceded by a timestamped
/// copy of the file as it was.
public struct StatuslineTap: Sendable {
    public enum State: Sendable, Equatable {
        /// Tapped. An empty original is Toki's own silent status line.
        case tapped(original: String)
        case untapped(command: String)
        case noStatusLine
        /// A `statusLine` Toki does not understand; left alone.
        case unsupported
    }

    /// How many copies of `settings.json` are kept.
    public static let backupLimit = 10

    public let settingsURL: URL
    public let scriptURL: URL
    /// Where the script leaves the latest payload. Owner-only: it names the session's
    /// working directory and transcript.
    public let sampleURL: URL
    /// Copies of `settings.json` taken before each of Toki's edits, newest last by name.
    public let backupsURL: URL
    private let homeDirectory: String

    public init(settingsURL: URL, scriptURL: URL, sampleURL: URL, backupsURL: URL,
                homeDirectory: String = NSHomeDirectory()) {
        self.settingsURL = settingsURL
        self.scriptURL = scriptURL
        self.sampleURL = sampleURL
        self.backupsURL = backupsURL
        self.homeDirectory = homeDirectory
    }

    /// `~/.claude/settings.json`, with the script, payload and backups in Toki's
    /// Application Support.
    public static let live = StatuslineTap(
        settingsURL: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json"),
        scriptURL: AppSupportDirectory.url.appendingPathComponent("statusline-tap.sh"),
        sampleURL: AppSupportDirectory.url.appendingPathComponent("statusline/latest.json"),
        backupsURL: AppSupportDirectory.url.appendingPathComponent("statusline/backups", isDirectory: true)
    )

    // MARK: State

    public func state() throws -> State {
        guard let text = try readSettings() else { return .noStatusLine }
        switch try Self.statusLine(in: text) {
        case .absent:
            return .noStatusLine
        case .other:
            return .unsupported
        case let .command(command, _):
            if let original = original(fromTapped: command) { return .tapped(original: original) }
            return command.isEmpty ? .noStatusLine : .untapped(command: command)
        }
    }

    /// Taps Claude Code's status line, adding Toki's silent one when there is none. Returns
    /// whether `settings.json` changed; also refreshes the script when already tapped, so a
    /// wiped Application Support heals itself.
    @discardableResult
    public func install() throws -> Bool {
        let text = try readSettings()
        let found = try text.map { try Self.statusLine(in: $0) } ?? .absent
        switch found {
        case .other:
            log.notice("status line is not a command one; leaving it alone")
            return false
        case let .command(command, _) where original(fromTapped: command) != nil:
            try writeScript()
            return false
        case let .command(command, _):
            try writeScript()
            try write(Self.replacingCommand(in: text ?? "", with: command.isEmpty ? commandPrefix : wrap(command)),
                      replacing: text)
            log.info("status line tapped for live usage")
            return true
        case .absent:
            try writeScript()
            try write(Self.addingStatusLine(command: commandPrefix, to: text), replacing: text)
            log.info("silent status line added for live usage")
            return true
        }
    }

    /// Puts the user's own command back, or removes Toki's silent status line. Returns
    /// whether `settings.json` changed.
    @discardableResult
    public func uninstall() throws -> Bool {
        guard let text = try readSettings(),
              case let .command(command, keys) = try Self.statusLine(in: text),
              let original = original(fromTapped: command) else { return false }
        if original.isEmpty && keys.isSubset(of: ["type", "command"]) {
            try write(Self.removingStatusLine(from: text), replacing: text)
            log.info("Toki's silent status line removed")
        } else {
            try write(Self.replacingCommand(in: text, with: original), replacing: text)
            log.info("status line restored to the user's own command")
        }
        return true
    }

    // MARK: Command format

    /// `/bin/sh "$HOME/…/statusline-tap.sh"` — through `sh`, so the script needs no execute
    /// bit, and through `$HOME`, so a synced settings file still works on another Mac.
    var commandPrefix: String {
        var path = scriptURL.path
        var home = ""
        if path.hasPrefix(homeDirectory + "/") {
            path.removeFirst(homeDirectory.count)
            home = "$HOME"
        }
        let escaped = path.reduce(into: "") { result, character in
            if "\\\"$`".contains(character) { result.append("\\") }
            result.append(character)
        }
        return "/bin/sh \"\(home)\(escaped)\""
    }

    func wrap(_ original: String) -> String {
        commandPrefix + " '" + original.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// The command a tapped one wraps, or nil when `command` is not exactly `wrap(_:)` output.
    func original(fromTapped command: String) -> String? {
        guard command.hasPrefix(commandPrefix) else { return nil }
        let rest = command.dropFirst(commandPrefix.count)
        guard rest.first == " " else { return rest.isEmpty ? "" : nil }
        var result = ""
        var index = rest.index(after: rest.startIndex)
        while index < rest.endIndex {
            switch rest[index] {
            case "'":
                guard let close = rest[rest.index(after: index)...].firstIndex(of: "'") else { return nil }
                result += rest[rest.index(after: index)..<close]
                index = rest.index(after: close)
            case "\\":
                let escaped = rest.index(after: index)
                guard escaped < rest.endIndex else { return nil }
                result.append(rest[escaped])
                index = rest.index(after: escaped)
            default:
                return nil
            }
        }
        return result
    }

    /// Saves stdin for Toki, then hands the same bytes to the user's command, whose output
    /// and exit status are what Claude Code sees. Saving is best effort and silent: nothing
    /// Toki does may break or delay the user's status line.
    static func scriptSource(sampleURL: URL) -> String {
        let sample = sampleURL.path.replacingOccurrences(of: "'", with: #"'\''"#)
        return """
        #!/bin/sh
        # Installed by Toki. Claude Code runs your status line through this script: it saves
        # the input for Toki's live usage gauges, then runs your own command, unchanged, on
        # the same input. Turn it off in Toki's Settings to put your command back as it was.
        umask 077
        input=$(cat)
        out='\(sample)'
        tmp="$out.$$"
        { [ -d "${out%/*}" ] || mkdir -p "${out%/*}"; } 2>/dev/null
        { printf '%s\\n' "$input" > "$tmp" && mv -f "$tmp" "$out"; } 2>/dev/null || rm -f "$tmp" 2>/dev/null
        [ -n "$1" ] || exit 0
        printf '%s\\n' "$input" | /bin/sh -c "$1"

        """
    }

    // MARK: Files

    private func readSettings() throws -> String? {
        let url = settingsURL.resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            log.notice("status line settings could not be read code=\((error as NSError).code) \(path: url)")
            throw StatuslineTapError.unreadable
        }
    }

    private func writeScript() throws {
        let source = Self.scriptSource(sampleURL: sampleURL)
        // An absent or unreadable script is simply rewritten below.
        if FileManager.default.contents(atPath: scriptURL.path) == Data(source.utf8) { return }
        do {
            try FileManager.default.createDirectory(
                at: scriptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(source.utf8).write(to: scriptURL, options: .atomic)
        } catch {
            log.error("status line script could not be written \(error: error)")
            throw StatuslineTapError.writeFailed
        }
    }

    /// Writes `updated` over the settings file, first saving what was there. `previous` is nil
    /// when the file does not exist yet.
    private func write(_ updated: String, replacing previous: String?) throws {
        let url = settingsURL.resolvingSymlinksInPath()
        if let previous { try backUp(previous) }
        let directory = url.deletingLastPathComponent()
        let temp = directory.appendingPathComponent(".\(url.lastPathComponent).toki-\(UUID().uuidString)")
        // no-log: on success `replaceItemAt` has consumed the staging copy.
        defer { try? FileManager.default.removeItem(at: temp) }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(updated.utf8).write(to: temp)
            if previous != nil,
               let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] {
                try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: temp.path)
            }
            if previous == nil {
                try FileManager.default.moveItem(at: temp, to: url)
            } else {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
            }
        } catch {
            log.error("status line settings could not be written \(error: error)")
            throw StatuslineTapError.writeFailed
        }
    }

    /// Keeps the newest `backupLimit` copies, owner-only, named so they sort by time.
    private func backUp(_ text: String) throws {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss.SSS'Z'"
        let stamp = formatter.string(from: Date())
        do {
            try FileManager.default.createDirectory(
                at: backupsURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            // Two edits inside one millisecond still get distinct, correctly ordered names.
            let file = (0..<1000).lazy
                .map { self.backupsURL.appendingPathComponent(String(format: "settings-%@-%03d.json", stamp, $0)) }
                .first { !FileManager.default.fileExists(atPath: $0.path) }
                ?? backupsURL.appendingPathComponent("settings-\(stamp)-\(UUID().uuidString).json")
            try Data(text.utf8).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            let saved = try FileManager.default.contentsOfDirectory(atPath: backupsURL.path)
                .filter { $0.hasPrefix("settings-") && $0.hasSuffix(".json") }
                .sorted()
            for name in saved.dropLast(Self.backupLimit) {
                try FileManager.default.removeItem(at: backupsURL.appendingPathComponent(name))
            }
        } catch {
            // No backup, no edit: the user's settings are never changed without a copy.
            log.error("settings backup could not be written \(error: error)")
            throw StatuslineTapError.writeFailed
        }
    }

    // MARK: JSON

    enum Found: Equatable {
        case absent
        /// A command status line: its command (empty when unset) and the object's keys.
        case command(String, keys: Set<String>)
        case other
    }

    static func statusLine(in text: String) throws -> Found {
        guard let root = try parseRoot(text) else { throw StatuslineTapError.malformed }
        guard let value = root["statusLine"] else { return .absent }
        guard let object = value as? [String: Any],
              object["type"] as? String == "command",
              object["command"] == nil || object["command"] is String else { return .other }
        return .command(object["command"] as? String ?? "", keys: Set(object.keys))
    }

    /// `statusLine.command` when the status line is a command one; nil otherwise.
    static func statusLineCommand(in text: String) throws -> String? {
        guard case let .command(command, _) = try statusLine(in: text) else { return nil }
        return command
    }

    private static func parseRoot(_ text: String) throws -> [String: Any]? {
        do {
            return try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        } catch {
            // The decode error adds nothing but a byte offset into the user's own settings.
            log.notice("status line settings are not valid JSON")
            throw StatuslineTapError.malformed
        }
    }

    /// `text` with `statusLine.command` set to `command`; nothing else changes.
    static func replacingCommand(in text: String, with command: String) throws -> String {
        guard let span = commandLiteralSpan(in: text) else {
            log.error("status line command could not be located for editing")
            throw StatuslineTapError.malformed
        }
        let updated = text.replacingCharacters(in: span, with: try jsonStringLiteral(command))
        // Never write a settings file we just broke.
        guard try statusLineCommand(in: updated) == command,
              try membersMatch(updated, text, ignoring: "statusLine") else {
            log.error("status line edit would not round-trip; nothing written")
            throw StatuslineTapError.malformed
        }
        return updated
    }

    /// `text` with a `statusLine` member appended to the top-level object (a new file when
    /// nil), indented like the file's own members.
    static func addingStatusLine(command: String, to text: String?) throws -> String {
        let literal = try jsonStringLiteral(command)
        guard let text else {
            return "{\n  \"statusLine\": {\n    \"type\": \"command\",\n    \"command\": \(literal)\n  }\n}\n"
        }
        let indent = memberIndent(in: text)
        let member = "\"statusLine\": {\n\(indent)\(indent)\"type\": \"command\",\n"
            + "\(indent)\(indent)\"command\": \(literal)\n\(indent)}"
        guard let close = text.lastIndex(of: "}"),
              let last = text[..<close].lastIndex(where: { !$0.isWhitespace }) else {
            throw StatuslineTapError.malformed
        }
        let updated = text[last] == "{"
            ? text.replacingCharacters(in: text.index(after: last)..<close, with: "\n\(indent)\(member)\n")
            : text.replacingCharacters(in: text.index(after: last)..<text.index(after: last),
                                       with: ",\n\(indent)\(member)")
        guard try statusLineCommand(in: updated) == command,
              try membersMatch(updated, text, ignoring: "statusLine") else {
            log.error("status line addition would not round-trip; nothing written")
            throw StatuslineTapError.malformed
        }
        return updated
    }

    /// `text` without its top-level `statusLine` member. The inverse of `addingStatusLine`:
    /// removing what it appended restores the file byte for byte.
    static func removingStatusLine(from text: String) throws -> String {
        let key = "\"statusLine\""
        guard let value = ClaudeConfigEditor.objectSpan(of: "statusLine", in: text),
              let colon = text[..<value.lowerBound].lastIndex(where: { !$0.isWhitespace }),
              text[colon] == ":",
              let keyEnd = text[..<colon].lastIndex(where: { !$0.isWhitespace }).map({ text.index(after: $0) }),
              let keyStart = text.index(keyEnd, offsetBy: -key.count, limitedBy: text.startIndex),
              text[keyStart..<keyEnd] == key,
              let before = text[..<keyStart].lastIndex(where: { !$0.isWhitespace }) else {
            throw StatuslineTapError.malformed
        }
        let updated: String
        if text[before] == "," {
            updated = text.replacingCharacters(in: before..<value.upperBound, with: "")
        } else if let next = text[value.upperBound...].firstIndex(where: { !$0.isWhitespace }), text[next] == "," {
            let following = text[text.index(after: next)...].firstIndex(where: { !$0.isWhitespace }) ?? text.endIndex
            updated = text.replacingCharacters(in: keyStart..<following, with: "")
        } else {
            let close = text[value.upperBound...].firstIndex(of: "}") ?? value.upperBound
            updated = text.replacingCharacters(in: text.index(after: before)..<close, with: "\n")
        }
        guard let root = try parseRoot(updated), root["statusLine"] == nil,
              try membersMatch(updated, text, ignoring: "statusLine") else {
            log.error("status line removal would not round-trip; nothing written")
            throw StatuslineTapError.malformed
        }
        return updated
    }

    /// Whether both texts hold the same top-level members apart from `key`.
    private static func membersMatch(_ lhs: String, _ rhs: String, ignoring key: String) throws -> Bool {
        guard var left = try parseRoot(lhs), var right = try parseRoot(rhs) else { return false }
        left[key] = nil
        right[key] = nil
        return NSDictionary(dictionary: left).isEqual(to: right)
    }

    /// The leading whitespace of the file's first member line; two spaces when it has none.
    private static func memberIndent(in text: String) -> String {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let indent = line.prefix { $0 == " " || $0 == "\t" }
            if !indent.isEmpty, line.dropFirst(indent.count).first == "\"" { return String(indent) }
        }
        return "  "
    }

    private static func jsonStringLiteral(_ value: String) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: [value], options: [.withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self).dropFirst().dropLast().description
    }

    /// The span of the string literal (quotes included) holding `command` directly inside the
    /// top-level `statusLine` object — never a `"command"` nested deeper, such as a hook's.
    static func commandLiteralSpan(in text: String) -> Range<String.Index>? {
        guard let object = ClaudeConfigEditor.objectSpan(of: "statusLine", in: text) else { return nil }
        var index = text.index(after: object.lowerBound)
        var depth = 0
        while index < object.upperBound {
            switch text[index] {
            case "{", "[":
                depth += 1
            case "}", "]":
                depth -= 1
            case "\"":
                guard let end = stringEnd(from: index, in: text) else { return nil }
                if depth == 0, text[index..<end] == "\"command\"",
                   let value = valueStart(after: end, in: text), text[value] == "\"",
                   let valueEnd = stringEnd(from: value, in: text) {
                    return value..<valueEnd
                }
                index = end
                continue
            default:
                break
            }
            index = text.index(after: index)
        }
        return nil
    }

    /// Index just past the closing quote of the string literal opening at `start`.
    private static func stringEnd(from start: String.Index, in text: String) -> String.Index? {
        var index = text.index(after: start)
        var escaped = false
        while index < text.endIndex {
            let character = text[index]
            if escaped {
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                return text.index(after: index)
            }
            index = text.index(after: index)
        }
        return nil
    }

    /// First non-whitespace index after `key: `, or nil when no colon follows (a value, not a key).
    private static func valueStart(after index: String.Index, in text: String) -> String.Index? {
        var cursor = index
        var sawColon = false
        while cursor < text.endIndex {
            let character = text[cursor]
            if character == ":" {
                if sawColon { return nil }
                sawColon = true
            } else if !character.isWhitespace {
                return sawColon ? cursor : nil
            }
            cursor = text.index(after: cursor)
        }
        return nil
    }
}
