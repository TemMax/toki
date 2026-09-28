/// Reads the local Claude Code environment (CLI version, plugins, marketplaces,
/// skills, MCP servers) from `~/.claude` and `~/.claude.json`.
///
/// Reads are local (JSON files, no spawned processes). The single exception is
/// a best-effort, anonymous CLI-version check against the public npm registry
/// (see `CLIUpdateChecker`); it is injectable and its failure never blocks the
/// local snapshot.
///
/// SECURITY: must read ONLY a non-sensitive field allowlist. Never read or surface
/// `.credentials.json`, `.credentials`, the macOS keychain, or any
/// credential/token/secret-bearing file or field (including `oauthAccount` and
/// `customApiKeyResponses` in `~/.claude.json`). For MCP servers, never surface
/// `env`, `headers`, `args`, or a full URL — only scheme+host (for url-based
/// servers) or a command basename (for stdio servers). When in doubt, omit.
import TokiModels
import Foundation

/// Default implementation of `EnvironmentProviding` that reads `~/.claude` and
/// `~/.claude.json` from disk. Injectable paths make this unit-testable against
/// fixture directories instead of the real user home.
public struct EnvironmentService: EnvironmentProviding {
    /// Root of the Claude Code config directory (defaults to `~/.claude`).
    public let claudeHome: URL
    /// Path to the top-level `~/.claude.json` config file.
    public let claudeJSON: URL
    /// Best-effort source of the latest published CLI version, given the
    /// install method and configured release channel. Defaults to a live check
    /// (npm registry or native release channel, per install method); tests
    /// inject a deterministic stub so no test ever touches the network.
    let latestCLIVersion: @Sendable (_ installMethod: String?, _ releaseChannel: String?) async -> String?

    public init(
        claudeHome: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude"),
        claudeJSON: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json"),
        latestCLIVersion: @escaping @Sendable (_ installMethod: String?, _ releaseChannel: String?) async -> String? = {
            await CLIUpdateChecker.fetchLatestVersion(installMethod: $0, releaseChannel: $1)
        }
    ) {
        self.claudeHome = claudeHome
        self.claudeJSON = claudeJSON
        self.latestCLIVersion = latestCLIVersion
    }

    /// Returns a snapshot of the local Claude Code environment. Every reader
    /// is tolerant of missing files/keys, so a fresh or partially-populated
    /// `claudeHome`/`claudeJSON` yields partial data rather than throwing.
    public func loadEnvironment() async -> ClaudeEnvironment {
        // Read the CLI info first (fast, local) so the network check can be
        // routed by install method / release channel, then kick that check off
        // concurrently with the remaining local disk reads below — it never
        // serializes behind them (total ≈ the network round-trip, not the sum).
        var cli = CLIReader.read(claudeHome: claudeHome, claudeJSON: claudeJSON)
        // Capture the routing inputs as immutable, Sendable copies before the
        // `async let` so the concurrent task never captures the mutable `cli`
        // (which is updated below) — avoids a Swift 6 data-race diagnostic.
        let installMethod = cli?.installMethod
        let releaseChannel = cli?.releaseChannel
        async let latestVersion = latestCLIVersion(installMethod, releaseChannel)

        let marketplaces = MarketplaceReader.read(claudeHome: claudeHome)

        let installed = PluginReader.readInstalled(claudeHome: claudeHome)
        let usage = ClaudeJSONReader.readUsage(claudeJSON: claudeJSON)
        let plugins = PluginReader.read(claudeHome: claudeHome, installed: installed, usage: usage)
        let skills = SkillReader.read(installed: installed, usage: usage)

        var mcpServers = MCPReader.readUserServers(claudeJSON: claudeJSON)
        mcpServers += MCPReader.readPluginServers(installed: installed)
        mcpServers = MCPReader.applyNeedsAuth(mcpServers, claudeHome: claudeHome)

        // Annotate the CLI with the latest published version when the check
        // succeeded. A failed/skipped check leaves `latestVersion` nil and
        // `updateAvailable` false — the section still renders from local data.
        if var info = cli, let latest = await latestVersion {
            info.latestVersion = latest
            info.updateAvailable = VersionCompare.isNewer(latest: latest, than: info.version)
            cli = info
        }

        return ClaudeEnvironment(
            cli: cli,
            marketplaces: marketplaces,
            plugins: plugins,
            skills: skills,
            mcpServers: mcpServers
        )
    }
}
