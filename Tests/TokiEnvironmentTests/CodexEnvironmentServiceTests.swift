import Foundation
import Testing
@testable import TokiEnvironment
import TokiModels

@Suite("CodexEnvironmentService")
struct CodexEnvironmentServiceTests {
    @Test("compares a cached Codex plugin with its configured marketplace snapshot")
    func readsPluginVersionStatus() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-plugin-versions-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("plugins/cache/team/example/1.0.0/.codex-plugin"),
            withIntermediateDirectories: true
        )
        try Data("""
        [marketplaces.team]
        source = "https://example.invalid/team.git"
        [plugins."example@team"]
        enabled = true
        """.utf8).write(to: root.appendingPathComponent("config.toml"))
        try Data("""
        { "name": "example", "version": "1.0.0" }
        """.utf8).write(
            to: root.appendingPathComponent(
                "plugins/cache/team/example/1.0.0/.codex-plugin/plugin.json"
            )
        )

        let marketplace = root.appendingPathComponent(".tmp/marketplaces/team")
        try FileManager.default.createDirectory(
            at: marketplace.appendingPathComponent(".agents/plugins"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: marketplace.appendingPathComponent("plugins/example/.codex-plugin"),
            withIntermediateDirectories: true
        )
        try Data("""
        {
            "name": "team",
            "plugins": [
                {
                    "name": "example",
                    "source": { "source": "local", "path": "./plugins/example" }
                }
            ]
        }
        """.utf8).write(
            to: marketplace.appendingPathComponent(".agents/plugins/marketplace.json")
        )
        try Data("""
        { "name": "example", "version": "1.4.0" }
        """.utf8).write(
            to: marketplace.appendingPathComponent("plugins/example/.codex-plugin/plugin.json")
        )

        let environment = await CodexEnvironmentService(
            codexHome: root,
            executable: nil
        ).loadEnvironment()
        let plugin = try #require(environment.plugins.first)

        #expect(plugin.version == "1.0.0")
        #expect(plugin.latestVersion == "1.4.0")
        #expect(plugin.updateAvailable == true)
        #expect(plugin.versionStatus == .outdated)
    }

    @Test("reads only allowlisted Codex configuration and skill metadata")
    func readsRedactedEnvironment() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-environment-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("skills/.system/review"),
            withIntermediateDirectories: true
        )
        try Data("""
        [marketplaces.openai-bundled]
        source = "https://secret.example/repo?token=must-not-leak"
        [plugins."browser@openai-bundled"]
        enabled = true
        [mcp_servers.remote]
        url = "https://mcp.example/private/path?token=must-not-leak"
        bearer_token = "must-not-leak"
        [mcp_servers.local]
        command = "/private/bin/npx"
        args = ["--token", "must-not-leak"]
        [mcp_servers.local.env]
        API_KEY = "must-not-leak"
        """.utf8).write(to: root.appendingPathComponent("config.toml"))
        try Data("""
        ---
        name: review
        description: Review a change safely.
        ---
        Secret body content must not be parsed.
        """.utf8).write(to: root.appendingPathComponent("skills/.system/review/SKILL.md"))

        let executable = root.appendingPathComponent(
            "packages/standalone/releases/0.153.2-aarch64-apple-darwin/bin/codex"
        )
        let environment = await CodexEnvironmentService(
            codexHome: root,
            executable: executable
        ).loadEnvironment()

        #expect(environment.cli?.version == "0.153.2")
        #expect(environment.cli?.installMethod == "standalone")
        #expect(environment.marketplaces.map(\.name) == ["openai-bundled"])
        #expect(environment.plugins.map(\.name) == ["browser"])
        #expect(environment.skills.map(\.name) == ["review"])
        #expect(environment.skills.first?.description == "Review a change safely.")
        #expect(environment.mcpServers.first(where: { $0.name == "remote" })?.detail == "mcp.example")
        #expect(environment.mcpServers.first(where: { $0.name == "local" })?.detail == "npx")
        #expect(!String(describing: environment).contains("must-not-leak"))
    }
}
