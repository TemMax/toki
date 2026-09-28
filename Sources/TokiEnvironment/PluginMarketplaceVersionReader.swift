import Foundation
import TokiLogging

private let log = TokiLog.logger("plugin-marketplace-versions")

/// Reads only plugin names, local source paths and versions from provider-managed
/// marketplace checkouts. Remote sources are intentionally ignored: this reader
/// never performs network requests and never parses credentials or arbitrary
/// plugin contents.
enum PluginMarketplaceVersionReader {
    /// Enumerates the immediate marketplace directories under each parent and
    /// returns versions keyed by `plugin@marketplace`. Earlier parents win.
    static func versions(under parents: [URL]) -> [String: String] {
        var result: [String: String] = [:]
        for parent in parents {
            for marketplaceRoot in marketplaceRoots(under: parent) {
                for (key, version) in versions(in: marketplaceRoot) where result[key] == nil {
                    result[key] = version
                }
            }
        }
        return result
    }

    private static func marketplaceRoots(under parent: URL) -> [URL] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey]
        let children: [URL]
        do {
            children = try FileManager.default.contentsOfDirectory(
                at: parent,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles]
            )
        } catch {
            if !isMissingFileError(error) {
                log.error(
                    "failed to enumerate plugin marketplaces \(path: parent) \(error: error)"
                )
            }
            return []
        }

        return children.filter { child in
            guard !child.lastPathComponent.hasPrefix(".") else { return false }
            return isDirectory(child, keys: keys)
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func isDirectory(_ url: URL, keys: Set<URLResourceKey>) -> Bool {
        do {
            return try url.resourceValues(forKeys: keys).isDirectory == true
        } catch {
            if !isMissingFileError(error) {
                log.error(
                    "failed to inspect plugin marketplace \(path: url) \(error: error)"
                )
            }
            return false
        }
    }

    private static func versions(in marketplaceRoot: URL) -> [String: String] {
        guard let manifest = marketplaceManifest(in: marketplaceRoot),
              let entries = manifest["plugins"]?.arrayValue else {
            return [:]
        }

        let declaredName = manifest["name"]?.stringValue
        let marketplaceNames = Set(
            [declaredName, marketplaceRoot.lastPathComponent]
                .compactMap { normalized($0) }
        )
        var result: [String: String] = [:]

        for entry in entries {
            guard let object = entry.objectValue,
                  let pluginName = normalized(object["name"]?.stringValue),
                  let version = pluginVersion(
                    entry: object,
                    pluginName: pluginName,
                    marketplaceRoot: marketplaceRoot
                  ) else { continue }

            for marketplaceName in marketplaceNames {
                result["\(pluginName)@\(marketplaceName)"] = version
            }
        }
        return result
    }

    private static func marketplaceManifest(in root: URL) -> JSONValue? {
        let candidates = [
            ".agents/plugins/marketplace.json",
            ".claude-plugin/marketplace.json",
            ".codex-plugin/marketplace.json",
        ]
        for path in candidates {
            if let manifest = readJSONValue(at: root.appendingPathComponent(path)) {
                return manifest
            }
        }
        return nil
    }

    private static func pluginVersion(
        entry: [String: JSONValue],
        pluginName: String,
        marketplaceRoot: URL
    ) -> String? {
        if let direct = normalized(entry["version"]?.stringValue) { return direct }

        var sourcePaths: [String] = []
        if let source = entry["source"]?.stringValue {
            sourcePaths.append(source)
        } else if let source = entry["source"]?.objectValue,
                  let path = source["path"]?.stringValue {
            sourcePaths.append(path)
        }
        sourcePaths.append(contentsOf: ["plugins/\(pluginName)", pluginName, "."])

        for sourcePath in sourcePaths {
            guard let sourceRoot = safeLocalSource(sourcePath, within: marketplaceRoot) else {
                continue
            }
            for manifestPath in [
                ".codex-plugin/plugin.json",
                ".claude-plugin/plugin.json",
                "plugin.json",
            ] {
                let manifest = readJSONValue(at: sourceRoot.appendingPathComponent(manifestPath))
                if let version = normalized(manifest?["version"]?.stringValue) {
                    return version
                }
            }
        }
        return nil
    }

    /// Accept only relative paths that remain inside the marketplace checkout,
    /// including after symlink resolution.
    private static func safeLocalSource(_ path: String, within root: URL) -> URL? {
        let value = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              !NSString(string: value).isAbsolutePath,
              !value.hasPrefix("~"),
              !value.contains("://") else { return nil }

        let resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let resolvedSource = root.appendingPathComponent(value)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let rootPath = resolvedRoot.path.hasSuffix("/") ? resolvedRoot.path : resolvedRoot.path + "/"
        guard resolvedSource.path == resolvedRoot.path || resolvedSource.path.hasPrefix(rootPath) else {
            return nil
        }
        return resolvedSource
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized.lowercased() != "unknown" else { return nil }
        return normalized
    }
}
