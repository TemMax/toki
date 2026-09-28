/// Edits `~/.claude.json` without disturbing anything Toki does not own.
import Foundation
import TokiLogging

private let log = TokiLog.logger("swap")

public enum ConfigEditError: Error, Equatable {
    case unreadable
    case noOAuthAccount
    /// The key exists but holds `null`, an array or a scalar — a shape Toki did not
    /// write and must not silently reshape into an object.
    case oauthAccountNotAnObject
    case malformed
}

/// Replaces only the `oauthAccount` value, by splicing text rather than re-serialising.
///
/// The file is ~118 KB of project trust, session history and MCP configuration that
/// belongs to Claude Code. Round-tripping it through `JSONSerialization` would reorder
/// every key and rewrite every byte — a swap would then show up as a 118 KB diff in
/// the user's own config, and any Toki bug would put all of it at risk.
public struct ClaudeConfigEditor: Sendable {
    private let configURL: URL

    public init(configURL: URL) {
        self.configURL = configURL
    }

    public func readOAuthAccount() throws -> [String: Any]? {
        let data: Data
        do {
            data = try Data(contentsOf: configURL)
        } catch {
            log.notice("config could not be read code=\((error as NSError).code) \(path: configURL)")
            throw ConfigEditError.unreadable
        }
        // no-log: the outcome is logged at the throw below, and the decode error adds
        // nothing but a byte offset into the user's own config.
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            log.notice("config is not a JSON object \(path: configURL)")
            throw ConfigEditError.malformed
        }
        return root["oauthAccount"] as? [String: Any]
    }

    public func replaceOAuthAccount(with object: [String: Any]) throws {
        log.info("pointing the config at another account \(path: configURL)")
        let original: String
        do {
            original = try String(contentsOf: configURL, encoding: .utf8)
        } catch {
            log.error("config could not be read for editing code=\((error as NSError).code) \(path: configURL)")
            throw ConfigEditError.unreadable
        }
        // The parser decides whether the key is there and what shape it has; the scanner
        // below only has to find the bytes of a value we already know is an object.
        // no-log: as above — the throw carries the diagnosis, the decode error only a byte
        // offset into the user's own config.
        guard let root = try? JSONSerialization.jsonObject(with: Data(original.utf8)) as? [String: Any]
        else {
            log.error("config is not a JSON object; refusing to edit it \(path: configURL)")
            throw ConfigEditError.malformed
        }
        guard let existing = root["oauthAccount"] else {
            log.error("config names no signed-in account, so there is nothing to repoint")
            throw ConfigEditError.noOAuthAccount
        }
        guard existing is [String: Any] else {
            log.error("the config's signed-in account is not an object; refusing to reshape it")
            throw ConfigEditError.oauthAccountNotAnObject
        }
        guard let span = Self.objectSpan(of: "oauthAccount", in: original) else {
            log.error("the signed-in account could not be located at the top level of the config")
            throw ConfigEditError.malformed
        }
        guard
            JSONSerialization.isValidJSONObject(object),
            // no-log: a re-encode of an object validated by the line above; its only
            // failure mode is the one already excluded, so the error is not diagnostic.
            let encoded = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
            let replacement = String(data: encoded, encoding: .utf8)
        else {
            log.error("the replacement account object could not be encoded")
            throw ConfigEditError.malformed
        }

        let updated = original.replacingCharacters(in: span, with: replacement)
        // Never write a config we just broke.
        // no-log: a validity probe rather than an operation — the refusal it guards is
        // logged in full below.
        guard (try? JSONSerialization.jsonObject(with: Data(updated.utf8))) != nil else {
            log.error("the edit would have produced invalid JSON, so nothing was written \(path: configURL)")
            throw ConfigEditError.malformed
        }

        let temp = configURL.deletingLastPathComponent()
            .appendingPathComponent(".claude.json.toki-\(UUID().uuidString)")
        // A failed rename would otherwise abandon a full copy of the user's config in
        // their home directory forever. On success `replaceItemAt` has consumed it.
        // no-log: on the success path `replaceItemAt` has already consumed the staging
        // copy, so a failure here is the ordinary case and would log on every swap.
        defer { try? FileManager.default.removeItem(at: temp) }
        try Self.writeStagingCopy(Data(updated.utf8), to: temp)
        _ = try FileManager.default.replaceItemAt(configURL, withItemAt: temp)
        log.info("config now names the target account \(path: configURL)")
    }

    /// The staging copy holds the user's whole config — project trust, session history,
    /// MCP configuration — so it is narrowed to `0600` before the rename rather than
    /// left at whatever umask happened to be.
    static func writeStagingCopy(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path
        )
    }

    /// Finds the character range of the object value belonging to `key` **at document
    /// depth 1**.
    ///
    /// Anchoring on the first textual occurrence splices whichever `"oauthAccount"`
    /// comes first, and the user's own data can contain one — an MCP server's `env` map
    /// is the realistic case. The result is still valid JSON, so nothing downstream
    /// catches it: the user's config is corrupted and the account never changes.
    ///
    /// Depth counts braces and brackets outside string literals, so a key that only
    /// looks top-level (or a display name like `"a}b{c"`) cannot anchor the span.
    static func objectSpan(of key: String, in text: String) -> Range<String.Index>? {
        let token = "\"\(key)\""
        var index = text.startIndex
        var depth = 0
        var stringStart: String.Index?
        var escaped = false

        while index < text.endIndex {
            let character = text[index]
            if let stringOpen = stringStart {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    let afterString = text.index(after: index)
                    stringStart = nil
                    // A string that reads as the key but sits in value position has no
                    // colon after it; skipping it keeps the real key findable.
                    if depth == 1, text[stringOpen..<afterString] == token,
                       let brace = Self.objectValueStart(after: afterString, in: text) {
                        return Self.objectRange(from: brace, in: text)
                    }
                }
            } else {
                switch character {
                case "\"": stringStart = index
                case "{", "[": depth += 1
                case "}", "]": depth -= 1
                default: break
                }
            }
            index = text.index(after: index)
        }
        return nil
    }

    /// Index of the `{` opening the value for a key that ends at `index`; nil when only
    /// whitespace and a single colon do not lead straight to an object.
    private static func objectValueStart(
        after index: String.Index, in text: String
    ) -> String.Index? {
        var cursor = index
        var sawColon = false
        while cursor < text.endIndex {
            let character = text[cursor]
            if character == "{" { return sawColon ? cursor : nil }
            if character == ":" {
                if sawColon { return nil }
                sawColon = true
            } else if !character.isWhitespace {
                return nil
            }
            cursor = text.index(after: cursor)
        }
        return nil
    }

    /// Span of the object opening at `start`, skipping string literals and escapes so
    /// that a display name like `"a}b{c"` cannot end it early.
    private static func objectRange(from start: String.Index, in text: String) -> Range<String.Index>? {
        var index = start
        var depth = 0
        var inString = false
        var escaped = false

        while index < text.endIndex {
            let character = text[index]
            if escaped {
                escaped = false
            } else if character == "\\" , inString {
                escaped = true
            } else if character == "\"" {
                inString.toggle()
            } else if !inString {
                if character == "{" { depth += 1 }
                if character == "}" {
                    depth -= 1
                    if depth == 0 { return start..<text.index(after: index) }
                }
            }
            index = text.index(after: index)
        }
        return nil
    }
}
