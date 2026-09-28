/// Discovers skills bundled with installed plugins by enumerating
/// `<installPath>/skills/*/SKILL.md` and parsing each file's YAML
/// frontmatter for `name` and `description`.
import TokiModels
import Foundation
import TokiLogging

private let log = TokiLog.logger("environment")

enum SkillReader {
    static func read(
        installed: [PluginReader.InstalledPlugin],
        usage: ClaudeJSONUsage
    ) -> [SkillInfo] {
        var skills: [SkillInfo] = []

        for plugin in installed {
            guard let installPath = plugin.installPath else { continue }
            let skillsDir = URL(fileURLWithPath: installPath).appendingPathComponent("skills")
            let entries: [URL]
            do {
                entries = try FileManager.default.contentsOfDirectory(
                    at: skillsDir, includingPropertiesForKeys: nil
                )
            } catch {
                // A plugin with no "skills" directory is normal, not a failure.
                if !isMissingFileError(error) {
                    log.error("failed to read config file \(path: skillsDir) \(error: error)")
                }
                continue
            }

            for entry in entries {
                let skillFile = entry.appendingPathComponent("SKILL.md")
                guard let frontmatter = readFrontmatter(at: skillFile) else { continue }
                let name = frontmatter.name ?? entry.lastPathComponent
                skills.append(
                    SkillInfo(
                        name: name,
                        plugin: plugin.name,
                        description: frontmatter.description,
                        usageCount: usageCount(forSkill: name, plugin: plugin.name, usage: usage),
                        marketplace: plugin.marketplace
                    )
                )
            }
        }

        return skills
    }

    private struct Frontmatter {
        var name: String?
        var description: String?
    }

    /// Parses the leading `---` ... `---` YAML frontmatter block of a
    /// SKILL.md for its top-level `name:` and `description:` lines. This is
    /// intentionally a simple line scan, not a YAML parser: it ignores
    /// indented (nested) keys like `metadata.version` and only looks at
    /// keys at column 0, so it won't misfire on nested blocks.
    private static func readFrontmatter(at url: URL) -> Frontmatter? {
        let contents: String
        do {
            contents = try String(contentsOf: url, encoding: .utf8)
        } catch {
            // Not every skill directory entry has a SKILL.md; that is normal.
            if !isMissingFileError(error) {
                log.error("failed to read config file \(path: url) \(error: error)")
            }
            return nil
        }
        let lines = contents.components(separatedBy: .newlines)
        guard lines.first == "---" else { return nil }
        guard let closingIndex = lines.dropFirst().firstIndex(of: "---") else { return nil }

        var frontmatter = Frontmatter()
        for line in lines[1..<closingIndex] {
            // Only consider top-level keys (no leading whitespace) — nested
            // YAML keys (e.g. under `metadata:`) are indented and skipped.
            guard !line.hasPrefix(" "), !line.hasPrefix("\t") else { continue }
            if let value = fieldValue(line, key: "name") {
                frontmatter.name = value
            } else if let value = fieldValue(line, key: "description") {
                frontmatter.description = value
            }
        }
        return frontmatter
    }

    /// Extracts the value of a `key: value` line, stripping a single layer
    /// of surrounding quotes. Returns `nil` if `line` is not for `key`.
    private static func fieldValue(_ line: String, key: String) -> String? {
        let prefix = key + ":"
        guard line.hasPrefix(prefix) else { return nil }
        var value = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
            value = String(value.dropFirst().dropLast())
        } else if value.hasPrefix("'") && value.hasSuffix("'") && value.count >= 2 {
            value = String(value.dropFirst().dropLast())
        }
        return value.isEmpty ? nil : value
    }

    /// Best-effort match of a parsed skill against `skillUsage` keys, which
    /// look like "plugin:skill" or a bare skill name (e.g. "init"). Tries
    /// the qualified form first, then a bare-name fallback.
    private static func usageCount(forSkill name: String, plugin: String, usage: ClaudeJSONUsage) -> Int? {
        if let count = usage.skillUsageCount["\(plugin):\(name)"] {
            return count
        }
        if let count = usage.skillUsageCount[name] {
            return count
        }
        // Fall back to matching by suffix, in case the usage key uses a
        // different (but related) qualifier than the plugin name.
        for (key, count) in usage.skillUsageCount where key.hasSuffix(":\(name)") {
            return count
        }
        return nil
    }
}
