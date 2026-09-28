/// Reads the small, explicitly-allowlisted set of fields this feature needs
/// from `~/.claude.json`.
///
/// SECURITY: `~/.claude.json` is a large, mixed-sensitivity document (it also
/// holds `oauthAccount`, `customApiKeyResponses`, and raw MCP server configs
/// that can carry tokens in `env`/`headers`/`url`). This reader decodes the
/// document as an untyped `JSONValue` tree and reads ONLY the keys named
/// below — `oauthAccount` and `customApiKeyResponses` are never read, and MCP
/// server entries are passed through `MCPServerReader`'s redaction, never
/// surfaced raw.
import TokiModels
import Foundation

/// Usage/favorite data extracted from `~/.claude.json`, used to enrich
/// `PluginInfo` and `SkillInfo` built from `~/.claude` files.
struct ClaudeJSONUsage {
    /// "name@marketplace" -> usageCount.
    var pluginUsageCount: [String: Int] = [:]
    /// "name@marketplace" set.
    var favoritePlugins: Set<String> = []
    /// Raw skillUsage keys (e.g. "superpowers:systematic-debugging", "init")
    /// mapped to usageCount, for best-effort suffix matching against parsed
    /// skill names.
    var skillUsageCount: [String: Int] = [:]

    static let empty = ClaudeJSONUsage()
}

enum ClaudeJSONReader {
    static func readUsage(claudeJSON: URL) -> ClaudeJSONUsage {
        guard let root = readJSONValue(at: claudeJSON) else { return .empty }

        var usage = ClaudeJSONUsage()

        if let pluginUsage = root["pluginUsage"]?.objectValue {
            for (key, value) in pluginUsage {
                if let count = usageCount(from: value) {
                    usage.pluginUsageCount[key] = count
                }
            }
        }

        if let favorites = root["favoritePlugins"]?.arrayValue {
            usage.favoritePlugins = Set(favorites.compactMap(\.stringValue))
        }

        if let skillUsage = root["skillUsage"]?.objectValue {
            for (key, value) in skillUsage {
                if let count = usageCount(from: value) {
                    usage.skillUsageCount[key] = count
                }
            }
        }

        return usage
    }

    /// `pluginUsage`/`skillUsage` entries are observed as
    /// `{"usageCount": Int, "lastUsedAt": ..., ...}` objects, but tolerate a
    /// bare integer too, in case of a future/alternate schema.
    private static func usageCount(from value: JSONValue) -> Int? {
        value.intValue ?? value["usageCount"]?.intValue
    }
}
