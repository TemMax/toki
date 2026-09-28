/// Value types describing the local Claude Code CLI environment (~/.claude),
/// surfaced in the app's "Your Claude" section.
///
/// SECURITY: these types intentionally carry NO field that can hold a secret.
/// Readers populating them must read only a non-sensitive allowlist of fields
/// from disk — never credentials, tokens, API keys, OAuth account data, or raw
/// MCP server env/headers/args/URLs. See `EnvironmentProviding` conformers for
/// the enforced allowlist.
import Foundation

/// CLI install/version metadata.
public struct CLIInfo: Sendable, Codable, Equatable {
    public var version: String?
    public var installMethod: String?
    public var autoUpdates: Bool?
    public var lastUpdateFrom: String?
    public var lastUpdateTo: String?
    public var lastUpdateAt: Date?
    public var lastUpdateOutcome: String?
    /// Release channel the native updater tracks (`stable` / `latest` / `rc`),
    /// when configured. nil means the CLI's default (`latest`) applies.
    public var releaseChannel: String?
    /// Latest version published to the CLI's release channel, if a network
    /// check succeeded (nil when offline / the check was skipped or failed).
    public var latestVersion: String?
    /// True only when `latestVersion` is confidently newer than `version`.
    public var updateAvailable: Bool

    public init(
        version: String?,
        installMethod: String?,
        autoUpdates: Bool?,
        lastUpdateFrom: String?,
        lastUpdateTo: String?,
        lastUpdateAt: Date?,
        lastUpdateOutcome: String?,
        releaseChannel: String? = nil,
        latestVersion: String? = nil,
        updateAvailable: Bool = false
    ) {
        self.version = version
        self.installMethod = installMethod
        self.autoUpdates = autoUpdates
        self.lastUpdateFrom = lastUpdateFrom
        self.lastUpdateTo = lastUpdateTo
        self.lastUpdateAt = lastUpdateAt
        self.lastUpdateOutcome = lastUpdateOutcome
        self.releaseChannel = releaseChannel
        self.latestVersion = latestVersion
        self.updateAvailable = updateAvailable
    }
}

/// A configured plugin marketplace.
public struct MarketplaceInfo: Sendable, Codable, Equatable, Identifiable {
    public var name: String
    public var repo: String?
    public var lastUpdated: Date?

    public var id: String { name }

    public init(name: String, repo: String?, lastUpdated: Date?) {
        self.name = name
        self.repo = repo
        self.lastUpdated = lastUpdated
    }
}

/// An installed plugin and its update/usage state.
public enum PluginVersionStatus: String, Sendable, Codable, Equatable {
    case upToDate
    case outdated
    case unknown
}

public struct PluginInfo: Sendable, Codable, Equatable, Identifiable {
    public var name: String
    public var marketplace: String
    public var version: String?
    public var latestVersion: String?
    public var updateAvailable: Bool
    public var enabled: Bool
    public var installedAt: Date?
    public var lastUpdated: Date?
    public var description: String?
    public var usageCount: Int?
    public var isFavorite: Bool

    public var id: String { name + "@" + marketplace }

    /// A deliberately conservative status. Marketplace snapshots are not
    /// guaranteed to contain every installed plugin, so missing or opaque
    /// version data must stay unknown rather than being reported as current.
    public var versionStatus: PluginVersionStatus {
        if updateAvailable { return .outdated }
        guard let installed = Self.normalizedVersion(version),
              let latest = Self.normalizedVersion(latestVersion) else {
            return .unknown
        }
        if installed == latest { return .upToDate }
        guard let installedParts = Self.numericVersion(installed),
              let latestParts = Self.numericVersion(latest) else {
            return .unknown
        }

        let count = max(installedParts.count, latestParts.count)
        for index in 0..<count {
            let installedPart = index < installedParts.count ? installedParts[index] : 0
            let latestPart = index < latestParts.count ? latestParts[index] : 0
            if installedPart != latestPart {
                return installedPart > latestPart ? .upToDate : .outdated
            }
        }
        return .upToDate
    }

    public init(
        name: String,
        marketplace: String,
        version: String?,
        latestVersion: String?,
        updateAvailable: Bool,
        enabled: Bool,
        installedAt: Date?,
        lastUpdated: Date?,
        description: String?,
        usageCount: Int?,
        isFavorite: Bool
    ) {
        self.name = name
        self.marketplace = marketplace
        self.version = version
        self.latestVersion = latestVersion
        self.updateAvailable = updateAvailable
        self.enabled = enabled
        self.installedAt = installedAt
        self.lastUpdated = lastUpdated
        self.description = description
        self.usageCount = usageCount
        self.isFavorite = isFavorite
    }

    private static func normalizedVersion(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized.lowercased() != "unknown" else { return nil }
        return normalized
    }

    /// Accepts only dotted numeric releases (with an optional leading `v`).
    /// Hashes and prerelease/build labels remain unknown unless they match
    /// exactly, since their ordering cannot be inferred safely.
    private static func numericVersion(_ value: String) -> [Int]? {
        let numeric = value.first == "v" || value.first == "V" ? String(value.dropFirst()) : value
        let parts = numeric.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }
        var components: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isNumber), let number = Int(part) else {
                return nil
            }
            components.append(number)
        }
        return components
    }
}

/// A skill available to Claude Code, optionally provided by a plugin.
public struct SkillInfo: Sendable, Codable, Equatable, Identifiable {
    public var name: String
    public var plugin: String?
    /// The marketplace the providing plugin came from (nil for non-plugin skills).
    public var marketplace: String?
    public var description: String?
    public var usageCount: Int?

    public var id: String { (marketplace ?? "") + "/" + (plugin ?? "") + ":" + name }

    public init(
        name: String,
        plugin: String?,
        description: String?,
        usageCount: Int?,
        marketplace: String? = nil
    ) {
        self.name = name
        self.plugin = plugin
        self.marketplace = marketplace
        self.description = description
        self.usageCount = usageCount
    }
}

/// A configured MCP server. `detail` is intentionally limited to a host (for
/// HTTP/SSE transports) or a command basename (for stdio transports) — never
/// args, env, headers, or a full URL, which can carry secrets.
public struct MCPServerInfo: Sendable, Codable, Equatable, Identifiable {
    /// "stdio" | "http" | "sse" | "unknown"
    public var name: String
    public var transport: String
    /// Host (e.g. "mcp.amplitude.com") OR command basename (e.g. "npx").
    /// NEVER args, env, headers, or a full URL.
    public var detail: String?
    /// "user" or the name of the plugin providing this server.
    public var source: String
    public var providingPluginVersion: String?
    public var needsAuth: Bool

    public var id: String { name }

    public init(
        name: String,
        transport: String,
        detail: String?,
        source: String,
        providingPluginVersion: String?,
        needsAuth: Bool
    ) {
        self.name = name
        self.transport = transport
        self.detail = detail
        self.source = source
        self.providingPluginVersion = providingPluginVersion
        self.needsAuth = needsAuth
    }
}

/// Snapshot of the local Claude Code environment: CLI version, marketplaces,
/// plugins, skills, and MCP servers. Contains no secrets.
public struct ClaudeEnvironment: Sendable, Codable, Equatable {
    public var cli: CLIInfo?
    public var marketplaces: [MarketplaceInfo]
    public var plugins: [PluginInfo]
    public var skills: [SkillInfo]
    public var mcpServers: [MCPServerInfo]

    public init(
        cli: CLIInfo?,
        marketplaces: [MarketplaceInfo],
        plugins: [PluginInfo],
        skills: [SkillInfo],
        mcpServers: [MCPServerInfo]
    ) {
        self.cli = cli
        self.marketplaces = marketplaces
        self.plugins = plugins
        self.skills = skills
        self.mcpServers = mcpServers
    }

    public static let empty = ClaudeEnvironment(
        cli: nil,
        marketplaces: [],
        plugins: [],
        skills: [],
        mcpServers: []
    )
}

/// Supplies a snapshot of the local Claude Code environment (CLI, plugins,
/// skills, MCP servers). Data is read from local files; the only network use
/// is an optional, best-effort CLI-version check (see `CLIInfo.latestVersion`).
public protocol EnvironmentProviding: Sendable {
    func loadEnvironment() async -> ClaudeEnvironment
}
