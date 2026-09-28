import Testing
import Foundation
@testable import TokiEnvironment
import TokiModels

// MARK: - Fixture helpers

/// Builds an isolated fixture `claudeHome` directory + `claudeJSON` file
/// under a fresh temp directory, with helpers to write the JSON files the
/// reader consumes. Every test gets its own UUID-named directory; nothing
/// here ever touches the real `~/.claude`.
private struct Fixture {
    let root: URL
    let claudeHome: URL
    let claudeJSON: URL

    init() {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokiEnvironmentTests-\(UUID().uuidString)", isDirectory: true)
        claudeHome = root.appendingPathComponent("claude-home", isDirectory: true)
        claudeJSON = root.appendingPathComponent("claude.json")
        try? FileManager.default.createDirectory(at: claudeHome, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(
            at: claudeHome.appendingPathComponent("plugins"), withIntermediateDirectories: true
        )
    }

    /// Service with the network update-check stubbed out (returns `latest`,
    /// default nil). No test ever performs a real network request.
    func service(latestCLIVersion latest: String? = nil) -> EnvironmentService {
        EnvironmentService(
            claudeHome: claudeHome,
            claudeJSON: claudeJSON,
            latestCLIVersion: { _, _ in latest }
        )
    }

    func write(_ relativePath: String, json: String) {
        let url = claudeHome.appendingPathComponent(relativePath)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? json.write(to: url, atomically: true, encoding: .utf8)
    }

    func writeClaudeJSON(_ json: String) {
        try? json.write(to: claudeJSON, atomically: true, encoding: .utf8)
    }

    /// Creates a fake plugin install directory under the fixture root and
    /// returns its absolute path, for use as an `installPath` value.
    func makePluginInstall(
        marketplace: String,
        name: String,
        version: String,
        description: String? = nil,
        skills: [(name: String, description: String)] = [],
        mcpServersJSON: String? = nil
    ) -> String {
        let installDir = root
            .appendingPathComponent("plugins/cache/\(marketplace)/\(name)/\(version)", isDirectory: true)
        try? FileManager.default.createDirectory(at: installDir, withIntermediateDirectories: true)

        if let description {
            let manifestDir = installDir.appendingPathComponent(".claude-plugin", isDirectory: true)
            try? FileManager.default.createDirectory(at: manifestDir, withIntermediateDirectories: true)
            let manifest = #"{"name": "\#(name)", "description": "\#(description)"}"#
            try? manifest.write(
                to: manifestDir.appendingPathComponent("plugin.json"), atomically: true, encoding: .utf8
            )
        }

        for skill in skills {
            let skillDir = installDir.appendingPathComponent("skills/\(skill.name)", isDirectory: true)
            try? FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
            let content = """
            ---
            name: \(skill.name)
            description: \(skill.description)
            metadata:
              version: 1.0.0
            ---

            # \(skill.name)
            """
            try? content.write(
                to: skillDir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8
            )
        }

        if let mcpServersJSON {
            try? mcpServersJSON.write(
                to: installDir.appendingPathComponent(".mcp.json"), atomically: true, encoding: .utf8
            )
        }

        return installDir.path
    }
}

// MARK: - Secret redaction (mandatory security gate)

@Suite("TokiEnvironment - secret redaction")
struct SecretRedactionTests {
    @Test("loadEnvironment never surfaces secrets present in source config")
    func neverSurfacesSecrets() async throws {
        let fixture = Fixture()

        // ~/.claude.json with secret sentinels in every field this feature
        // must never read: oauthAccount, customApiKeyResponses, and an
        // mcpServers map with env/headers/url-query secrets plus a
        // command-based server with args carrying a secret.
        fixture.writeClaudeJSON("""
        {
            "installMethod": "native",
            "autoUpdates": true,
            "oauthAccount": {
                "emailAddress": "SENTINEL_EMAIL",
                "accessToken": "SENTINEL_OAUTH"
            },
            "customApiKeyResponses": {
                "x": "SENTINEL_APIKEY"
            },
            "mcpServers": {
                "secretHttpServer": {
                    "type": "http",
                    "url": "https://host.example.com/mcp?token=SENTINEL_QUERY",
                    "headers": { "Authorization": "Bearer SENTINEL_HDR" },
                    "env": { "API_KEY": "SENTINEL_ENV_TOKEN" }
                },
                "secretCommandServer": {
                    "command": "/usr/local/bin/some-mcp-server",
                    "args": ["--token", "SENTINEL_ARG"],
                    "env": { "API_KEY": "SENTINEL_ENV_TOKEN" }
                }
            },
            "pluginUsage": {},
            "favoritePlugins": [],
            "skillUsage": {}
        }
        """)

        let environment = await fixture.service().loadEnvironment()
        let encoded = try JSONEncoder().encode(environment)
        let encodedString = String(data: encoded, encoding: .utf8) ?? ""

        let sentinels = [
            "SENTINEL_EMAIL", "SENTINEL_OAUTH", "SENTINEL_APIKEY",
            "SENTINEL_QUERY", "SENTINEL_HDR", "SENTINEL_ENV_TOKEN", "SENTINEL_ARG",
        ]
        for sentinel in sentinels {
            #expect(!encodedString.contains(sentinel), "encoded environment leaked \(sentinel)")
        }

        let httpServer = environment.mcpServers.first { $0.name == "secretHttpServer" }
        #expect(httpServer?.detail == "host.example.com")
        #expect(httpServer?.transport == "http")

        let commandServer = environment.mcpServers.first { $0.name == "secretCommandServer" }
        #expect(commandServer?.detail == "some-mcp-server")
        #expect(commandServer?.transport == "stdio")
    }

    @Test("plugin-provided MCP servers also redact env/headers/args/url")
    func pluginServersRedacted() async throws {
        let fixture = Fixture()
        let installPath = fixture.makePluginInstall(
            marketplace: "marketA",
            name: "pluginA",
            version: "1.0.0",
            mcpServersJSON: """
            {
                "mcpServers": {
                    "pluginServer": {
                        "type": "http",
                        "url": "https://plugin.example.com/api?token=SENTINEL_PLUGIN_QUERY",
                        "headers": { "Authorization": "Bearer SENTINEL_PLUGIN_HDR" }
                    }
                }
            }
            """
        )

        fixture.write("plugins/installed_plugins.json", json: """
        {
            "version": 2,
            "plugins": {
                "pluginA@marketA": [
                    { "installPath": "\(installPath)", "version": "1.0.0" }
                ]
            }
        }
        """)

        let environment = await fixture.service().loadEnvironment()
        let encoded = try JSONEncoder().encode(environment)
        let encodedString = String(data: encoded, encoding: .utf8) ?? ""

        #expect(!encodedString.contains("SENTINEL_PLUGIN_QUERY"))
        #expect(!encodedString.contains("SENTINEL_PLUGIN_HDR"))

        let server = environment.mcpServers.first { $0.name == "pluginServer" }
        #expect(server?.detail == "plugin.example.com")
        #expect(server?.source == "pluginA")
        #expect(server?.providingPluginVersion == "1.0.0")
    }
}

// MARK: - CLI info

@Suite("TokiEnvironment - CLI info")
struct CLIInfoTests {
    @Test("reads version/update info and allowlisted claude.json keys")
    func readsCLIInfo() async {
        let fixture = Fixture()
        fixture.write(".last-update-result.json", json: """
        {
            "timestamp": "2026-06-30T18:19:07.547Z",
            "outcome": "success",
            "version_from": "2.1.196",
            "version_to": "2.1.197"
        }
        """)
        fixture.writeClaudeJSON("""
        { "installMethod": "native", "autoUpdates": true, "releaseChannel": "stable" }
        """)

        let environment = await fixture.service().loadEnvironment()

        #expect(environment.cli?.version == "2.1.197")
        #expect(environment.cli?.lastUpdateFrom == "2.1.196")
        #expect(environment.cli?.lastUpdateTo == "2.1.197")
        #expect(environment.cli?.lastUpdateOutcome == "success")
        #expect(environment.cli?.installMethod == "native")
        #expect(environment.cli?.autoUpdates == true)
        #expect(environment.cli?.releaseChannel == "stable")
        #expect(environment.cli?.lastUpdateAt != nil)
    }

    @Test("missing files yield nil cli rather than crashing")
    func missingFilesYieldNil() async {
        let fixture = Fixture()
        let environment = await fixture.service().loadEnvironment()
        #expect(environment.cli == nil)
    }

    @Test("a newer published version marks updateAvailable and records latestVersion")
    func newerPublishedVersionFlagsUpdate() async {
        let fixture = Fixture()
        fixture.write(".last-update-result.json", json: """
        { "outcome": "success", "version_from": "2.1.196", "version_to": "2.1.197" }
        """)

        let environment = await fixture.service(latestCLIVersion: "2.2.0").loadEnvironment()

        #expect(environment.cli?.version == "2.1.197")
        #expect(environment.cli?.latestVersion == "2.2.0")
        #expect(environment.cli?.updateAvailable == true)
    }

    @Test("up-to-date install records latestVersion but does not flag an update")
    func upToDateDoesNotFlagUpdate() async {
        let fixture = Fixture()
        fixture.write(".last-update-result.json", json: """
        { "outcome": "success", "version_from": "2.1.196", "version_to": "2.1.197" }
        """)

        let environment = await fixture.service(latestCLIVersion: "2.1.197").loadEnvironment()

        #expect(environment.cli?.latestVersion == "2.1.197")
        #expect(environment.cli?.updateAvailable == false)
    }

    @Test("a failed network check leaves latestVersion nil and updateAvailable false")
    func failedNetworkCheckIsGraceful() async {
        let fixture = Fixture()
        fixture.write(".last-update-result.json", json: """
        { "outcome": "success", "version_from": "2.1.196", "version_to": "2.1.197" }
        """)

        // nil models an offline / timed-out / malformed-response check.
        let environment = await fixture.service(latestCLIVersion: nil).loadEnvironment()

        #expect(environment.cli?.version == "2.1.197")
        #expect(environment.cli?.latestVersion == nil)
        #expect(environment.cli?.updateAvailable == false)
    }

    @Test("the version check is routed by install method and configured channel")
    func versionCheckReceivesInstallMethodAndChannel() async {
        let fixture = Fixture()
        fixture.write(".last-update-result.json", json: """
        { "outcome": "success", "version_from": "2.1.196", "version_to": "2.1.197" }
        """)
        fixture.writeClaudeJSON("""
        { "installMethod": "native", "releaseChannel": "stable" }
        """)

        let recorder = ArgRecorder()
        let service = EnvironmentService(
            claudeHome: fixture.claudeHome,
            claudeJSON: fixture.claudeJSON,
            latestCLIVersion: { method, channel in
                await recorder.record(method: method, channel: channel)
                return "9.9.9"
            }
        )

        let environment = await service.loadEnvironment()

        let received = await recorder.value
        #expect(received?.method == "native")
        #expect(received?.channel == "stable")
        #expect(environment.cli?.latestVersion == "9.9.9")
        #expect(environment.cli?.updateAvailable == true)
    }
}

/// Thread-safe capture of the arguments passed to the injected version-check
/// closure (which is `@Sendable`).
private actor ArgRecorder {
    private(set) var value: (method: String?, channel: String?)?
    func record(method: String?, channel: String?) { value = (method, channel) }
}

// MARK: - CLIUpdateChecker (pure helpers)

@Suite("TokiEnvironment - CLIUpdateChecker helpers")
struct CLIUpdateCheckerHelperTests {
    @Test("normalizedChannel keeps known channels and defaults unknown/nil to latest")
    func normalizedChannel() {
        #expect(CLIUpdateChecker.normalizedChannel("stable") == "stable")
        #expect(CLIUpdateChecker.normalizedChannel("latest") == "latest")
        #expect(CLIUpdateChecker.normalizedChannel("rc") == "rc")
        #expect(CLIUpdateChecker.normalizedChannel("STABLE") == "stable")
        #expect(CLIUpdateChecker.normalizedChannel(nil) == "latest")
        #expect(CLIUpdateChecker.normalizedChannel("beta") == "latest")
        #expect(CLIUpdateChecker.normalizedChannel("") == "latest")
    }

    @Test("nativeVersionURL targets the release channel endpoint")
    func nativeVersionURL() {
        #expect(
            CLIUpdateChecker.nativeVersionURL(channel: "latest")?.absoluteString
                == "https://downloads.claude.ai/claude-code-releases/latest"
        )
        #expect(
            CLIUpdateChecker.nativeVersionURL(channel: "stable")?.absoluteString
                == "https://downloads.claude.ai/claude-code-releases/stable"
        )
    }

    @Test("sanitizedVersion accepts dotted versions and rejects junk")
    func sanitizedVersion() {
        #expect(CLIUpdateChecker.sanitizedVersion("2.1.197") == "2.1.197")
        #expect(CLIUpdateChecker.sanitizedVersion("  2.1.197\n") == "2.1.197")
        #expect(CLIUpdateChecker.sanitizedVersion("v2.1.197") == "2.1.197")
        #expect(CLIUpdateChecker.sanitizedVersion("2.1.0-rc.1") == "2.1.0-rc.1")
        #expect(CLIUpdateChecker.sanitizedVersion("<!DOCTYPE html>") == nil)
        #expect(CLIUpdateChecker.sanitizedVersion("not a version") == nil)
        #expect(CLIUpdateChecker.sanitizedVersion("2.1") == nil)
        #expect(CLIUpdateChecker.sanitizedVersion("") == nil)
    }
}

// MARK: - Marketplaces

@Suite("TokiEnvironment - marketplaces")
struct MarketplaceTests {
    @Test("reads known marketplaces with repo and lastUpdated")
    func readsMarketplaces() async {
        let fixture = Fixture()
        fixture.write("plugins/known_marketplaces.json", json: """
        {
            "claude-plugins-official": {
                "source": { "source": "github", "repo": "anthropics/claude-plugins-official" },
                "lastUpdated": "2026-06-30T23:26:16.920Z"
            }
        }
        """)

        let environment = await fixture.service().loadEnvironment()

        #expect(environment.marketplaces.count == 1)
        #expect(environment.marketplaces.first?.name == "claude-plugins-official")
        #expect(environment.marketplaces.first?.repo == "anthropics/claude-plugins-official")
        #expect(environment.marketplaces.first?.lastUpdated != nil)
    }
}

// MARK: - Plugins

@Suite("TokiEnvironment - plugins")
struct PluginTests {
    @Test("marketplace plugin sources cannot escape their checkout")
    func marketplaceSourceTraversalIsRejected() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("plugin-marketplace-safety-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: parent) }

        let marketplace = parent.appendingPathComponent("team")
        let outsideManifest = parent.appendingPathComponent("outside/.claude-plugin/plugin.json")
        try FileManager.default.createDirectory(
            at: marketplace.appendingPathComponent(".claude-plugin"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: outsideManifest.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("""
        {
            "name": "team",
            "plugins": [{ "name": "example", "source": "../outside" }]
        }
        """.utf8).write(
            to: marketplace.appendingPathComponent(".claude-plugin/marketplace.json")
        )
        try Data(#"{ "name": "example", "version": "9.9.9" }"#.utf8)
            .write(to: outsideManifest)

        let versions = PluginMarketplaceVersionReader.versions(under: [parent])

        #expect(versions["example@team"] == nil)
    }

    @Test("a local marketplace manifest supplies versions absent from Claude's catalog cache")
    func localMarketplaceVersionFallback() async {
        let fixture = Fixture()
        let installPath = fixture.makePluginInstall(
            marketplace: "marketA", name: "pluginA", version: "1.0.0"
        )
        fixture.write("plugins/installed_plugins.json", json: """
        {
            "version": 2,
            "plugins": {
                "pluginA@marketA": [
                    { "installPath": "\(installPath)", "version": "1.0.0" }
                ]
            }
        }
        """)
        fixture.write("plugins/marketplaces/marketA/.claude-plugin/marketplace.json", json: """
        {
            "name": "marketA",
            "plugins": [
                { "name": "pluginA", "source": "./plugins/pluginA" }
            ]
        }
        """)
        fixture.write("plugins/marketplaces/marketA/plugins/pluginA/.claude-plugin/plugin.json", json: """
        { "name": "pluginA", "version": "1.2.0" }
        """)

        let plugin = await fixture.service().loadEnvironment().plugins.first

        #expect(plugin?.version == "1.0.0")
        #expect(plugin?.latestVersion == "1.2.0")
        #expect(plugin?.updateAvailable == true)
        #expect(plugin?.versionStatus == .outdated)
    }

    @Test("a plugin without a catalog version stays explicitly unverified")
    func missingCatalogVersionIsUnknown() async {
        let fixture = Fixture()
        let installPath = fixture.makePluginInstall(
            marketplace: "marketA", name: "pluginA", version: "1.0.0"
        )
        fixture.write("plugins/installed_plugins.json", json: """
        {
            "version": 2,
            "plugins": {
                "pluginA@marketA": [
                    { "installPath": "\(installPath)", "version": "1.0.0" }
                ]
            }
        }
        """)

        let plugin = await fixture.service().loadEnvironment().plugins.first

        #expect(plugin?.latestVersion == nil)
        #expect(plugin?.versionStatus == .unknown)
    }

    @Test("newer catalog version marks updateAvailable true")
    func updateAvailableTrue() async {
        let fixture = Fixture()
        let installPath = fixture.makePluginInstall(
            marketplace: "marketA", name: "pluginA", version: "1.0.0",
            description: "Plugin A description"
        )
        fixture.write("plugins/installed_plugins.json", json: """
        {
            "version": 2,
            "plugins": {
                "pluginA@marketA": [
                    { "installPath": "\(installPath)", "version": "1.0.0" }
                ]
            }
        }
        """)
        fixture.write("plugins/plugin-catalog-cache.json", json: """
        {
            "catalog": {
                "plugins": {
                    "pluginA@marketA": { "plugin": "pluginA", "version": "1.2.0" }
                }
            }
        }
        """)

        let environment = await fixture.service().loadEnvironment()
        let plugin = environment.plugins.first { $0.name == "pluginA" }

        #expect(plugin?.version == "1.0.0")
        #expect(plugin?.latestVersion == "1.2.0")
        #expect(plugin?.updateAvailable == true)
        #expect(plugin?.description == "Plugin A description")
    }

    @Test("\"unknown\" installed version yields nil version and updateAvailable false")
    func unknownVersionNoUpdate() async {
        let fixture = Fixture()
        let installPath = fixture.makePluginInstall(marketplace: "marketA", name: "pluginA", version: "unknown")
        fixture.write("plugins/installed_plugins.json", json: """
        {
            "version": 2,
            "plugins": {
                "pluginA@marketA": [
                    { "installPath": "\(installPath)", "version": "unknown" }
                ]
            }
        }
        """)
        fixture.write("plugins/plugin-catalog-cache.json", json: """
        {
            "catalog": {
                "plugins": {
                    "pluginA@marketA": { "plugin": "pluginA", "version": "1.2.0" }
                }
            }
        }
        """)

        let environment = await fixture.service().loadEnvironment()
        let plugin = environment.plugins.first { $0.name == "pluginA" }

        #expect(plugin?.version == nil)
        #expect(plugin?.updateAvailable == false)
    }

    @Test("enabled=false in settings.json is respected")
    func enabledFalseRespected() async {
        let fixture = Fixture()
        let installPath = fixture.makePluginInstall(marketplace: "marketA", name: "pluginA", version: "1.0.0")
        fixture.write("plugins/installed_plugins.json", json: """
        {
            "version": 2,
            "plugins": {
                "pluginA@marketA": [
                    { "installPath": "\(installPath)", "version": "1.0.0" }
                ]
            }
        }
        """)
        fixture.write("settings.json", json: """
        { "enabledPlugins": { "pluginA@marketA": false } }
        """)

        let environment = await fixture.service().loadEnvironment()
        let plugin = environment.plugins.first { $0.name == "pluginA" }

        #expect(plugin?.enabled == false)
    }

    @Test("absent enabledPlugins entry defaults to enabled")
    func defaultsToEnabled() async {
        let fixture = Fixture()
        let installPath = fixture.makePluginInstall(marketplace: "marketA", name: "pluginA", version: "1.0.0")
        fixture.write("plugins/installed_plugins.json", json: """
        {
            "version": 2,
            "plugins": {
                "pluginA@marketA": [
                    { "installPath": "\(installPath)", "version": "1.0.0" }
                ]
            }
        }
        """)

        let environment = await fixture.service().loadEnvironment()
        let plugin = environment.plugins.first { $0.name == "pluginA" }

        #expect(plugin?.enabled == true)
    }

    @Test("usageCount and isFavorite come from claude.json")
    func usageAndFavorite() async {
        let fixture = Fixture()
        let installPath = fixture.makePluginInstall(marketplace: "marketA", name: "pluginA", version: "1.0.0")
        fixture.write("plugins/installed_plugins.json", json: """
        {
            "version": 2,
            "plugins": {
                "pluginA@marketA": [
                    { "installPath": "\(installPath)", "version": "1.0.0" }
                ]
            }
        }
        """)
        fixture.writeClaudeJSON("""
        {
            "pluginUsage": { "pluginA@marketA": { "usageCount": 7, "lastUsedAt": 123 } },
            "favoritePlugins": ["pluginA@marketA"]
        }
        """)

        let environment = await fixture.service().loadEnvironment()
        let plugin = environment.plugins.first { $0.name == "pluginA" }

        #expect(plugin?.usageCount == 7)
        #expect(plugin?.isFavorite == true)
    }
}

// MARK: - Skills

@Suite("TokiEnvironment - skills")
struct SkillTests {
    @Test("parses SKILL.md frontmatter from an installed plugin")
    func parsesSkillFrontmatter() async {
        let fixture = Fixture()
        let installPath = fixture.makePluginInstall(
            marketplace: "marketA", name: "pluginA", version: "1.0.0",
            skills: [(name: "my-skill", description: "Does a thing")]
        )
        fixture.write("plugins/installed_plugins.json", json: """
        {
            "version": 2,
            "plugins": {
                "pluginA@marketA": [
                    { "installPath": "\(installPath)", "version": "1.0.0" }
                ]
            }
        }
        """)
        fixture.writeClaudeJSON("""
        { "skillUsage": { "pluginA:my-skill": { "usageCount": 4 } } }
        """)

        let environment = await fixture.service().loadEnvironment()

        #expect(environment.skills.count == 1)
        let skill = environment.skills.first
        #expect(skill?.name == "my-skill")
        #expect(skill?.plugin == "pluginA")
        #expect(skill?.description == "Does a thing")
        #expect(skill?.usageCount == 4)
    }
}

// MARK: - MCP servers

@Suite("TokiEnvironment - MCP servers")
struct MCPServerTests {
    @Test("needsAuth is flagged from mcp-needs-auth-cache.json")
    func needsAuthFlagged() async {
        let fixture = Fixture()
        fixture.writeClaudeJSON("""
        {
            "mcpServers": {
                "myServer": { "type": "http", "url": "https://mcp.example.com/path" }
            }
        }
        """)
        fixture.write("mcp-needs-auth-cache.json", json: """
        { "myServer": { "timestamp": 123, "id": "abc" } }
        """)

        let environment = await fixture.service().loadEnvironment()
        let server = environment.mcpServers.first { $0.name == "myServer" }

        #expect(server?.needsAuth == true)
        #expect(server?.detail == "mcp.example.com")
        #expect(server?.source == "user")
    }

    @Test("stdio command server detail is basename only")
    func stdioCommandBasename() async {
        let fixture = Fixture()
        fixture.writeClaudeJSON("""
        {
            "mcpServers": {
                "npxServer": { "command": "/usr/local/bin/npx", "args": ["-y", "@scope/pkg"] }
            }
        }
        """)

        let environment = await fixture.service().loadEnvironment()
        let server = environment.mcpServers.first { $0.name == "npxServer" }

        #expect(server?.transport == "stdio")
        #expect(server?.detail == "npx")
    }
}

// MARK: - Stub/default behavior

@Suite("TokiEnvironment")
struct TokiEnvironmentTests {
    @Test("EnvironmentService returns .empty for an empty fixture")
    func emptyFixtureReturnsEmpty() async {
        let fixtureHome = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fixtureJSON = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".json")

        let service = EnvironmentService(claudeHome: fixtureHome, claudeJSON: fixtureJSON, latestCLIVersion: { _, _ in nil })
        let environment = await service.loadEnvironment()

        #expect(environment == ClaudeEnvironment.empty)
    }
}
