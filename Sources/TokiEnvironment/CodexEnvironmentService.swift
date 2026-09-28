import Foundation
import TokiModels
import TokiLogging

private let log = TokiLog.logger("codex-environment")

/// Reads Codex's local, non-secret environment from `$CODEX_HOME`/`~/.codex`.
/// Only an explicit allowlist is materialised: CLI version, plugin/marketplace names,
/// skill frontmatter and redacted MCP transport details. Auth and MCP env/header values are
/// never read into a model returned to the app.
public struct CodexEnvironmentService: EnvironmentProviding {
    private let codexHome: URL
    private let executable: URL?

    public init(
        codexHome: URL = Self.defaultHome(),
        executable: URL? = ProviderExecutableResolver.codex()
    ) {
        self.codexHome = codexHome
        self.executable = executable
    }

    public func loadEnvironment() async -> ClaudeEnvironment {
        let config = parseConfig(
            at: codexHome.appendingPathComponent("config.toml"),
            marketplaceVersions: marketplaceVersions()
        )
        return ClaudeEnvironment(
            cli: executable.map { executable in
                CLIInfo(
                    version: version(from: executable),
                    installMethod: installMethod(for: executable),
                    autoUpdates: nil,
                    lastUpdateFrom: nil,
                    lastUpdateTo: nil,
                    lastUpdateAt: nil,
                    lastUpdateOutcome: nil,
                    releaseChannel: nil
                )
            },
            marketplaces: config.marketplaces,
            plugins: config.plugins,
            skills: readSkills(pluginIDs: config.enabledPluginIDs),
            mcpServers: config.mcpServers
        )
    }

    public static func defaultHome(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? homeDirectory.appendingPathComponent(".codex", isDirectory: true)
    }

    private struct ParsedConfig {
        var marketplaces: [MarketplaceInfo] = []
        var plugins: [PluginInfo] = []
        var mcpServers: [MCPServerInfo] = []
        var enabledPluginIDs: Set<String> = []
    }

    private func parseConfig(
        at url: URL,
        marketplaceVersions: [String: String]
    ) -> ParsedConfig {
        let contents: String
        do {
            contents = try String(contentsOf: url, encoding: .utf8)
        } catch {
            // A missing config is a normal state for a fresh install. Permission and I/O
            // failures are not, and need to survive in diagnostics.
            if !isMissingFileError(error) {
                log.error("failed to read Codex config \(path: url) \(error: error)")
            }
            return ParsedConfig()
        }
        var marketplaceNames: Set<String> = []
        var plugins: [String: Bool] = [:]
        var servers: [String: (command: String?, url: String?)] = [:]
        var section = ""

        for rawLine in contents.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            if line.hasPrefix("["), line.hasSuffix("]") {
                section = String(line.dropFirst().dropLast())
                if let name = tableName(section, prefix: "marketplaces.") {
                    marketplaceNames.insert(name)
                }
                if let name = tableName(section, prefix: "plugins.") {
                    plugins[name] = plugins[name] ?? true
                }
                if let name = directMCPName(section) {
                    servers[name] = servers[name] ?? (nil, nil)
                }
                continue
            }

            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            let value = unquote(String(line[line.index(after: equals)...]))
            if let name = tableName(section, prefix: "plugins."), key == "enabled" {
                plugins[name] = value.lowercased() != "false"
            } else if let name = directMCPName(section) {
                var server = servers[name] ?? (nil, nil)
                if key == "command" { server.command = value }
                if key == "url" { server.url = value }
                servers[name] = server
            }
        }

        return ParsedConfig(
            marketplaces: marketplaceNames.sorted().map {
                MarketplaceInfo(name: $0, repo: nil, lastUpdated: nil)
            },
            plugins: plugins.keys.sorted().map { name in
                let parts = name.split(separator: "@", maxSplits: 1).map(String.init)
                let metadata = pluginMetadata(id: name)
                let latestVersion = marketplaceVersions[name]
                return PluginInfo(
                    name: parts.first ?? name,
                    marketplace: parts.count > 1 ? parts[1] : "Codex",
                    version: metadata?.version,
                    latestVersion: latestVersion,
                    updateAvailable: VersionCompare.isNewer(
                        latest: latestVersion,
                        than: metadata?.version
                    ),
                    enabled: plugins[name] ?? true,
                    installedAt: nil,
                    lastUpdated: nil,
                    description: metadata?.description,
                    usageCount: nil,
                    isFavorite: false
                )
            },
            mcpServers: servers.keys.sorted().map { name in
                let server = servers[name]!
                let transport = server.url == nil ? "stdio" : "http"
                let detail = server.url.flatMap { URL(string: $0)?.host }
                    ?? server.command.map { URL(fileURLWithPath: $0).lastPathComponent }
                return MCPServerInfo(
                    name: name,
                    transport: transport,
                    detail: detail,
                    source: "user",
                    providingPluginVersion: nil,
                    needsAuth: false
                )
            },
            enabledPluginIDs: Set(plugins.compactMap { $0.value ? $0.key : nil })
        )
    }

    private func marketplaceVersions() -> [String: String] {
        var parents = [
            codexHome.appendingPathComponent(".tmp/marketplaces"),
            codexHome.appendingPathComponent(".tmp/bundled-marketplaces"),
        ]

        // The primary runtime cache lives outside CODEX_HOME. Only consult the
        // current user's real cache for their real Codex home; isolated/test
        // homes must remain isolated from unrelated machine state.
        if codexHome.standardizedFileURL == Self.defaultHome().standardizedFileURL {
            parents.append(
                FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".cache/codex-runtimes/codex-primary-runtime/plugins")
            )
        }
        return PluginMarketplaceVersionReader.versions(under: parents)
    }

    private func readSkills(pluginIDs: Set<String>) -> [SkillInfo] {
        var skills = skillFiles(under: codexHome.appendingPathComponent("skills")).compactMap {
            skill(at: $0, plugin: nil)
        }
        for id in pluginIDs.sorted() {
            let parts = id.split(separator: "@", maxSplits: 1).map(String.init)
            guard parts.count == 2, let versionRoot = latestPluginVersionRoot(id: id) else { continue }
            let pluginName = parts[0]
            skills.append(contentsOf: skillFiles(
                under: versionRoot.appendingPathComponent("skills")
            ).compactMap { skill(at: $0, plugin: pluginName) })
        }
        var seen = Set<String>()
        return skills.filter { seen.insert("\($0.plugin ?? "personal"):\($0.name)").inserted }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func skillFiles(under root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return [] }
        return enumerator.compactMap { $0 as? URL }
            .filter { $0.lastPathComponent == "SKILL.md" }
    }

    private func skill(at file: URL, plugin: String?) -> SkillInfo? {
        let contents: String
        do {
            contents = try String(contentsOf: file, encoding: .utf8)
        } catch {
            // A directory entry can disappear while Codex updates its cache. Other failures
            // should be diagnosable instead of silently hiding an installed skill.
            if !isMissingFileError(error) {
                log.error("failed to read Codex skill \(path: file) \(error: error)")
            }
            return nil
        }
        var name = file.deletingLastPathComponent().lastPathComponent
        var description: String?
        let lines = contents.components(separatedBy: .newlines)
        if lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") {
            for line in lines[1..<end] where !line.hasPrefix(" ") && !line.hasPrefix("\t") {
                if line.hasPrefix("name:") { name = unquote(String(line.dropFirst(5))) }
                if line.hasPrefix("description:") { description = unquote(String(line.dropFirst(12))) }
            }
        }
        return SkillInfo(name: name, plugin: plugin, description: description, usageCount: nil)
    }

    private func pluginMetadata(id: String) -> (version: String?, description: String?)? {
        guard let root = latestPluginVersionRoot(id: id) else { return nil }
        let manifest = root.appendingPathComponent(".codex-plugin/plugin.json")
        let data: Data
        do {
            data = try Data(contentsOf: manifest)
        } catch {
            if !isMissingFileError(error) {
                log.error("failed to read Codex plugin manifest \(path: manifest) \(error: error)")
            }
            return (root.lastPathComponent, nil)
        }
        let object: [String: Any]
        do {
            guard let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                log.error("Codex plugin manifest has an unexpected top-level shape")
                return (root.lastPathComponent, nil)
            }
            object = decoded
        } catch {
            log.error("failed to parse Codex plugin manifest \(error: error)")
            return (root.lastPathComponent, nil)
        }
        return (
            object["version"] as? String ?? root.lastPathComponent,
            object["description"] as? String
        )
    }

    private func latestPluginVersionRoot(id: String) -> URL? {
        let parts = id.split(separator: "@", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        let root = codexHome.appendingPathComponent("plugins/cache")
            .appendingPathComponent(parts[1])
            .appendingPathComponent(parts[0])
        do {
            return try FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey]
            ).sorted { $0.lastPathComponent > $1.lastPathComponent }.first
        } catch {
            if !isMissingFileError(error) {
                log.error("failed to enumerate Codex plugin versions \(path: root) \(error: error)")
            }
            return nil
        }
    }

    private func version(from executable: URL) -> String? {
        let path = executable.resolvingSymlinksInPath().path
        guard let range = path.range(of: #"/releases/([^/]+?)(?:-[^/]+)?/"#, options: .regularExpression) else {
            return nil
        }
        let segment = String(path[range]).split(separator: "/")[1]
        return String(segment.split(separator: "-").first ?? segment)
    }

    private func installMethod(for executable: URL) -> String {
        let path = executable.resolvingSymlinksInPath().path
        if path.contains("/agent-binaries/codex/") { return "managed" }
        // The testable `codexHome` root stands in for `~/.codex`, so do not bake the
        // directory's literal name into installation detection.
        if path.contains("/packages/standalone/") { return "standalone" }
        if path.contains("node_modules") { return "npm" }
        return "local"
    }

    private func tableName(_ section: String, prefix: String) -> String? {
        guard section.hasPrefix(prefix) else { return nil }
        return unquote(String(section.dropFirst(prefix.count)))
    }

    private func directMCPName(_ section: String) -> String? {
        guard let name = tableName(section, prefix: "mcp_servers."), !name.contains(".") else {
            return nil
        }
        return name
    }

    private func unquote(_ raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespaces)
        guard value.count >= 2 else { return value }
        if (value.first == "\"" && value.last == "\"")
            || (value.first == "'" && value.last == "'") {
            return String(value.dropFirst().dropLast())
        }
        return value
    }
}
