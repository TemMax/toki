/// Reads installed plugins from `~/.claude/plugins/installed_plugins.json`,
/// cross-referencing enabled state (`settings.json`), update availability
/// (`plugin-catalog-cache.json`), usage/favorites (`~/.claude.json`), and each
/// plugin's own description (`<installPath>/.claude-plugin/plugin.json`).
import TokiModels
import Foundation

enum PluginReader {
    // MARK: installed_plugins.json

    /// `~/.claude/plugins/installed_plugins.json` shape:
    /// `{"version": 2, "plugins": {"name@marketplace": [{install record}, ...]}}`.
    /// Each key maps to a *list* of install records (normally one); the most
    /// recently installed/updated record is used.
    private struct InstalledPluginsFile: Decodable {
        var plugins: [String: [InstallRecord]]?
    }

    private struct InstallRecord: Decodable {
        var installPath: String?
        var version: String?
        var installedAt: String?
        var lastUpdated: String?
    }

    // MARK: plugin-catalog-cache.json

    private struct CatalogCacheFile: Decodable {
        var catalog: Catalog?
    }

    private struct Catalog: Decodable {
        var plugins: [String: CatalogEntry]?
    }

    private struct CatalogEntry: Decodable {
        var plugin: String?
        var version: String?
    }

    // MARK: .claude-plugin/plugin.json

    private struct PluginManifest: Decodable {
        var description: String?
    }

    /// Parsed installed-plugin info, keyed by "name@marketplace", before
    /// usage/favorite enrichment (those require `~/.claude.json`, read
    /// separately so callers can also build `SkillInfo`/`MCPServerInfo` from
    /// the same install paths without re-parsing this file).
    struct InstalledPlugin {
        var key: String
        var name: String
        var marketplace: String
        var version: String?
        var installPath: String?
        var installedAt: Date?
        var lastUpdated: Date?
    }

    /// Parses `installed_plugins.json` into one entry per "name@marketplace"
    /// key, picking the most-recently-updated install record when multiple
    /// exist for the same key.
    static func readInstalled(claudeHome: URL) -> [InstalledPlugin] {
        guard let file = readJSON(
            InstalledPluginsFile.self,
            at: claudeHome.appendingPathComponent("plugins/installed_plugins.json")
        ), let plugins = file.plugins else {
            return []
        }

        return plugins.compactMap { key, records in
            guard let record = latest(of: records) else { return nil }
            let (name, marketplace) = splitKey(key)
            let rawVersion = record.version
            let version = (rawVersion?.lowercased() == "unknown") ? nil : rawVersion
            return InstalledPlugin(
                key: key,
                name: name,
                marketplace: marketplace,
                version: version,
                installPath: record.installPath,
                installedAt: parseISO8601(record.installedAt),
                lastUpdated: parseISO8601(record.lastUpdated)
            )
        }
    }

    /// Builds the full `[PluginInfo]` list from installed plugins plus the
    /// catalog (for update detection), settings (for enabled state), and
    /// `~/.claude.json` (for usage/favorites).
    static func read(
        claudeHome: URL,
        installed: [InstalledPlugin],
        usage: ClaudeJSONUsage
    ) -> [PluginInfo] {
        let catalogVersions = readCatalogVersions(claudeHome: claudeHome)
        let marketplaceVersions = PluginMarketplaceVersionReader.versions(
            under: [claudeHome.appendingPathComponent("plugins/marketplaces")]
        )
        let enabledPlugins = readEnabledPlugins(claudeHome: claudeHome)

        return installed.map { plugin in
            let latestVersion = catalogVersions[plugin.key]
                ?? marketplaceVersions[plugin.key]
                ?? catalogVersions[plugin.name]
            let enabled = enabledPlugins[plugin.key] ?? true
            let description = plugin.installPath.flatMap { readDescription(installPath: $0) }
            let usageCount = usage.pluginUsageCount[plugin.key]
            let isFavorite = usage.favoritePlugins.contains(plugin.key)

            return PluginInfo(
                name: plugin.name,
                marketplace: plugin.marketplace,
                version: plugin.version,
                latestVersion: latestVersion,
                updateAvailable: VersionCompare.isNewer(latest: latestVersion, than: plugin.version),
                enabled: enabled,
                installedAt: plugin.installedAt,
                lastUpdated: plugin.lastUpdated,
                description: description,
                usageCount: usageCount,
                isFavorite: isFavorite
            )
        }
    }

    // MARK: - Helpers

    /// "name@marketplace" -> (name, marketplace). Tolerates a missing "@" by
    /// treating the whole string as the name with an empty marketplace.
    private static func splitKey(_ key: String) -> (name: String, marketplace: String) {
        guard let atIndex = key.lastIndex(of: "@") else { return (key, "") }
        let name = String(key[key.startIndex..<atIndex])
        let marketplace = String(key[key.index(after: atIndex)...])
        return (name, marketplace)
    }

    private static func latest(of records: [InstallRecord]) -> InstallRecord? {
        records.max { lhs, rhs in
            (parseISO8601(lhs.lastUpdated) ?? .distantPast)
                < (parseISO8601(rhs.lastUpdated) ?? .distantPast)
        }
    }

    /// Maps both the full "name@marketplace" key and the bare plugin name to
    /// the catalog's version string, so lookups can fall back to a
    /// name-only match when the marketplace segment differs.
    private static func readCatalogVersions(claudeHome: URL) -> [String: String] {
        guard let file = readJSON(
            CatalogCacheFile.self,
            at: claudeHome.appendingPathComponent("plugins/plugin-catalog-cache.json")
        ), let plugins = file.catalog?.plugins else {
            return [:]
        }

        var versions: [String: String] = [:]
        for (key, entry) in plugins {
            guard let version = entry.version else { continue }
            versions[key] = version
            if let name = entry.plugin {
                versions[name] = version
            }
        }
        return versions
    }

    /// `~/.claude/settings.json`'s `enabledPlugins` map, keyed by
    /// "name@marketplace". Absent keys default to enabled (handled by the
    /// caller).
    private static func readEnabledPlugins(claudeHome: URL) -> [String: Bool] {
        let settings = readJSONValue(at: claudeHome.appendingPathComponent("settings.json"))
        guard let enabled = settings?["enabledPlugins"]?.objectValue else { return [:] }
        var result: [String: Bool] = [:]
        for (key, value) in enabled {
            if let flag = value.boolValue {
                result[key] = flag
            }
        }
        return result
    }

    private static func readDescription(installPath: String) -> String? {
        let manifestURL = URL(fileURLWithPath: installPath)
            .appendingPathComponent(".claude-plugin/plugin.json")
        return readJSON(PluginManifest.self, at: manifestURL)?.description
    }
}
