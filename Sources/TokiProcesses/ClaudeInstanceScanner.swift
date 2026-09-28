/// Detects running Claude Code instances from raw process facts.
///
/// Filters the enumerator's `RawProcess` list down to Claude Code CLI
/// processes, parses the version from the executable path, classifies the
/// install source, and marks each instance outdated relative to the newest
/// installed CLI version (`referenceVersion`).
import TokiModels
import Foundation

public struct ClaudeInstanceScanner: ClaudeInstancesProviding {
    /// Source of raw process facts (libproc in production, fakes in tests).
    let enumerator: ProcessEnumerating
    /// Resolves the newest installed CLI version (the reference for "outdated").
    /// Defaults to the real resolver; tests inject a deterministic value.
    let referenceVersion: @Sendable () -> String?
    let includeClaude: Bool
    let includeCodex: Bool

    public init(
        enumerator: ProcessEnumerating = LibprocEnumerator(),
        referenceVersion: @escaping @Sendable () -> String? = { ClaudeInstanceScanner.resolveInstalledVersion() },
        includeClaude: Bool = true,
        includeCodex: Bool = false
    ) {
        self.enumerator = enumerator
        self.referenceVersion = referenceVersion
        self.includeClaude = includeClaude
        self.includeCodex = includeCodex
    }

    public func loadInstances() async -> ClaudeInstancesSnapshot {
        let reference = referenceVersion()

        var seen = Set<Int32>()
        var instances: [ClaudeInstance] = []

        for raw in enumerator.enumerate() {
            guard let detection = Self.detect(
                path: raw.executablePath,
                includeClaude: includeClaude,
                includeCodex: includeCodex
            ) else { continue }
            guard seen.insert(raw.pid).inserted else { continue } // dedup by pid

            let outdated: Bool = {
                guard detection.provider == .claudeCode,
                      let reference, let version = detection.version else { return false }
                return Semver.less(version, reference)
            }()

            instances.append(
                ClaudeInstance(
                    pid: raw.pid,
                    provider: detection.provider,
                    version: detection.version,
                    executablePath: raw.executablePath,
                    workingDirectory: raw.workingDirectory,
                    startedAt: raw.startedAt,
                    memoryBytes: raw.memoryBytes,
                    source: detection.source,
                    isOutdated: outdated
                )
            )
        }

        return ClaudeInstancesSnapshot(instances: instances, referenceVersion: reference)
    }

    // MARK: - Detection

    private struct Detection {
        var version: String?
        var source: ClaudeInstanceSource
        var provider: UsageProvider
    }

    /// Decide whether `path` is a Claude Code CLI binary and, if so, extract its
    /// version and install source. Returns nil for everything that isn't the CLI.
    ///
    /// Rule:
    ///   * must contain a "/claude/" path segment AND a semver path component
    ///     (native ".../claude/versions/<semver>" or managed
    ///     ".../claude/<semver>/claude").
    ///   * EXCLUDE the desktop app ("/Applications/Claude.app" or ".app/Contents").
    ///   * basename must be "claude" or a semver (native binary is named the
    ///     version). Excludes node/npx/bash/zsh/etc — MCP-server children run as
    ///     "node …" and must not match.
    private static func detect(
        path: String,
        includeClaude: Bool,
        includeCodex: Bool
    ) -> Detection? {
        let basename = (path as NSString).lastPathComponent
        if includeCodex, basename == "codex", path.lowercased().contains("/codex") {
            let source: ClaudeInstanceSource = path.contains("/agent-binaries/codex/")
                ? .managed
                : .unknown
            return Detection(
                version: Semver.versionComponent(in: path),
                source: source,
                provider: .codex
            )
        }
        guard includeClaude else { return nil }
        // Exclude the desktop app.
        if path.contains("/Applications/Claude.app") || path.contains(".app/Contents") {
            return nil
        }

        // Require a "/claude/" path segment.
        guard path.contains("/claude/") else { return nil }

        // Require a semver path component.
        guard let version = Semver.versionComponent(in: path) else { return nil }

        // Basename must be "claude" or itself a semver (native binary).
        let basenameIsClaude = basename == "claude"
        let basenameIsSemver = Semver.normalizedVersion(basename) != nil
        guard basenameIsClaude || basenameIsSemver else { return nil }

        let source: ClaudeInstanceSource
        if path.contains("/.local/share/claude/versions/") {
            source = .native
        } else if path.contains("/agent-binaries/claude/") {
            source = .managed
        } else {
            source = .unknown
        }

        return Detection(version: version, source: source, provider: .claudeCode)
    }

    // MARK: - Reference version resolution

    /// Resolve the newest installed CLI version:
    ///   1. read the `~/.local/bin/claude` symlink and parse the semver
    ///      component of its destination;
    ///   2. else take the max semver directory name under
    ///      `~/.local/share/claude/versions/`.
    /// Returns nil when nothing is found.
    public static func resolveInstalledVersion() -> String? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser

        // 1. Symlink destination.
        let symlink = home.appendingPathComponent(".local/bin/claude").path
        // no-log: a missing `.local/bin/claude` symlink is normal (not every install
        // uses the native installer) and falls through to step 2 below; not a failure.
        if let destination = try? fm.destinationOfSymbolicLink(atPath: symlink),
           let version = Semver.versionComponent(in: destination) {
            return version
        }

        // 2. Max semver directory under versions/.
        let versionsDir = home.appendingPathComponent(".local/share/claude/versions").path
        // no-log: a missing `versions` directory is normal (no native CLI installs found);
        // not a failure — `resolveInstalledVersion()` simply returns `nil` below.
        if let entries = try? fm.contentsOfDirectory(atPath: versionsDir) {
            let versions = entries.compactMap { Semver.normalizedVersion($0) }
            if let newest = versions.max(by: { Semver.less($0, $1) }) {
                return newest
            }
        }

        return nil
    }
}
