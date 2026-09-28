/// Reads configured MCP servers from two sources: the user-level
/// `mcpServers` map in `~/.claude.json`, and each installed plugin's own
/// `.mcp.json`.
///
/// SECURITY: this is the most sensitive reader in the feature. MCP server
/// configs routinely carry secrets in `env`, `headers`, `args`, or embedded in
/// a full URL (path/query/userinfo). This reader reads ONLY:
///   - `type` / `command` / `url` (to classify transport),
///   - the URL's scheme+host (via `hostOnly`, never path/query/userinfo),
///   - the command's basename (via `commandBasename`, never argv).
/// `env`, `headers`, and `args` are NEVER decoded by this reader, even
/// transiently — they are absent from the `MCPServerConfig` shape below.
import TokiModels
import Foundation

enum MCPReader {
    /// The only fields ever read from an MCP server config. There is
    /// deliberately no `env`, `headers`, or `args` property on this type —
    /// add one only if it is added to the model's redaction allowlist too.
    private struct MCPServerConfig: Decodable {
        var type: String?
        var command: String?
        var url: String?
    }

    /// User-level servers from `~/.claude.json`'s `mcpServers` map.
    static func readUserServers(claudeJSON: URL) -> [MCPServerInfo] {
        guard let root = readJSONValue(at: claudeJSON),
              let servers = root["mcpServers"]?.objectValue else {
            return []
        }

        return servers.compactMap { name, value in
            guard let object = value.objectValue else { return nil }
            return buildServer(
                name: name,
                config: configFromAllowlist(object),
                source: "user",
                providingPluginVersion: nil,
                needsAuth: false
            )
        }
    }

    /// Plugin-provided servers from `<installPath>/.mcp.json`, which may be
    /// either `{"mcpServers": {name: config}}` or a bare `{name: config}`
    /// top-level map.
    static func readPluginServers(installed: [PluginReader.InstalledPlugin]) -> [MCPServerInfo] {
        var servers: [MCPServerInfo] = []

        for plugin in installed {
            guard let installPath = plugin.installPath else { continue }
            let mcpFile = URL(fileURLWithPath: installPath).appendingPathComponent(".mcp.json")
            guard let root = readJSONValue(at: mcpFile), let object = root.objectValue else { continue }

            let serverMap = object["mcpServers"]?.objectValue ?? object
            for (name, value) in serverMap {
                guard let serverObject = value.objectValue else { continue }
                if let server = buildServer(
                    name: name,
                    config: configFromAllowlist(serverObject),
                    source: plugin.name,
                    providingPluginVersion: plugin.version,
                    needsAuth: false
                ) {
                    servers.append(server)
                }
            }
        }

        return servers
    }

    /// Cross-references `mcp-needs-auth-cache.json` to flag servers needing
    /// re-authentication. The cache is keyed by server name.
    static func applyNeedsAuth(_ servers: [MCPServerInfo], claudeHome: URL) -> [MCPServerInfo] {
        let cache = readJSONValue(at: claudeHome.appendingPathComponent("mcp-needs-auth-cache.json"))
        guard let names = cache?.objectValue?.keys else { return servers }
        let needsAuthNames = Set(names)
        return servers.map { server in
            var server = server
            server.needsAuth = needsAuthNames.contains(server.name)
            return server
        }
    }

    // MARK: - Helpers

    /// Re-decodes an already-parsed `[String: JSONValue]` object into the
    /// strict `MCPServerConfig` allowlist by round-tripping through JSON —
    /// this guarantees only `type`/`command`/`url` are ever materialized,
    /// regardless of what other keys (env, headers, args) are present.
    private static func configFromAllowlist(_ object: [String: JSONValue]) -> MCPServerConfig {
        var config = MCPServerConfig()
        config.type = object["type"]?.stringValue
        config.command = object["command"]?.stringValue
        config.url = object["url"]?.stringValue
        return config
    }

    private static func buildServer(
        name: String,
        config: MCPServerConfig,
        source: String,
        providingPluginVersion: String?,
        needsAuth: Bool
    ) -> MCPServerInfo? {
        let transport: String
        let detail: String?

        if let type = config.type, !type.isEmpty {
            transport = type
            detail = detailFor(config: config)
        } else if let url = config.url, !url.isEmpty {
            transport = "http"
            detail = hostOnly(url)
        } else if let command = config.command, !command.isEmpty {
            transport = "stdio"
            detail = commandBasename(command)
        } else {
            transport = "unknown"
            detail = nil
        }

        return MCPServerInfo(
            name: name,
            transport: transport,
            detail: detail,
            source: source,
            providingPluginVersion: providingPluginVersion,
            needsAuth: needsAuth
        )
    }

    /// When an explicit `type` is given, still prefer redacted detail from
    /// whichever of url/command is present (a server can declare `type` and
    /// either field depending on transport).
    private static func detailFor(config: MCPServerConfig) -> String? {
        if let url = config.url, !url.isEmpty {
            return hostOnly(url)
        }
        if let command = config.command, !command.isEmpty {
            return commandBasename(command)
        }
        return nil
    }
}
