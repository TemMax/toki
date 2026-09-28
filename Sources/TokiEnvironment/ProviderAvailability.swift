import Foundation

/// The provider integrations that can actually run on this Mac.
///
/// Availability is intentionally about an installed executable, not about a config or auth
/// file: signing out must not make a provider disappear, while uninstalling its CLI must.
public struct ProviderAvailability: Equatable, Sendable {
    public let claudeCode: Bool
    public let codex: Bool

    public init(claudeCode: Bool, codex: Bool) {
        self.claudeCode = claudeCode
        self.codex = codex
    }

    public var hasAnyProvider: Bool { claudeCode || codex }

    /// Snapshot/demo surfaces exercise both integrations independently of the host machine.
    public static let all = ProviderAvailability(claudeCode: true, codex: true)

    public static func detected(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> ProviderAvailability {
        ProviderAvailability(
            claudeCode: ProviderExecutableResolver.claudeCode(
                environment: environment,
                homeDirectory: homeDirectory,
                fileManager: fileManager
            ) != nil,
            codex: ProviderExecutableResolver.codex(
                environment: environment,
                homeDirectory: homeDirectory,
                fileManager: fileManager
            ) != nil
        )
    }
}

/// Finds provider CLIs without launching a shell. macOS GUI apps inherit a deliberately small
/// PATH, so package-manager and Conductor-managed locations must be checked explicitly.
public enum ProviderExecutableResolver {
    public static func claudeCode(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> URL? {
        resolve(
            executableName: "claude",
            overrideKey: "TOKI_CLAUDE_EXECUTABLE",
            environment: environment,
            homeDirectory: homeDirectory,
            fileManager: fileManager,
            additionalCandidates: claudeCandidates(homeDirectory: homeDirectory, fileManager: fileManager)
        )
    }

    public static func codex(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> URL? {
        resolve(
            executableName: "codex",
            overrideKey: "TOKI_CODEX_EXECUTABLE",
            environment: environment,
            homeDirectory: homeDirectory,
            fileManager: fileManager,
            additionalCandidates: conductorManagedCandidates(
                provider: "codex",
                executableName: "codex",
                homeDirectory: homeDirectory,
                fileManager: fileManager
            )
        )
    }

    private static func resolve(
        executableName: String,
        overrideKey: String,
        environment: [String: String],
        homeDirectory: URL,
        fileManager: FileManager,
        additionalCandidates: [URL]
    ) -> URL? {
        var candidates: [URL] = []

        if let override = environment[overrideKey], !override.isEmpty {
            candidates.append(URL(fileURLWithPath: override))
        }

        if let path = environment["PATH"] {
            candidates.append(contentsOf: path
                .split(separator: ":")
                .map { URL(fileURLWithPath: String($0)).appendingPathComponent(executableName) })
        }

        candidates.append(contentsOf: [
            URL(fileURLWithPath: "/opt/homebrew/bin").appendingPathComponent(executableName),
            URL(fileURLWithPath: "/usr/local/bin").appendingPathComponent(executableName),
            homeDirectory.appendingPathComponent(".local/bin").appendingPathComponent(executableName),
            homeDirectory.appendingPathComponent(".npm-global/bin").appendingPathComponent(executableName),
            homeDirectory.appendingPathComponent(".volta/bin").appendingPathComponent(executableName),
            homeDirectory.appendingPathComponent(".bun/bin").appendingPathComponent(executableName),
            homeDirectory.appendingPathComponent(
                "Library/Application Support/com.conductor.app/bin"
            ).appendingPathComponent(executableName),
        ])
        candidates.append(contentsOf: nvmCandidates(
            executableName: executableName,
            homeDirectory: homeDirectory,
            fileManager: fileManager
        ))
        candidates.append(contentsOf: additionalCandidates)

        var seen = Set<String>()
        return candidates.first { candidate in
            let path = candidate.standardizedFileURL.path
            guard seen.insert(path).inserted else { return false }
            return fileManager.isExecutableFile(atPath: path)
        }
    }

    private static func nvmCandidates(
        executableName: String,
        homeDirectory: URL,
        fileManager: FileManager
    ) -> [URL] {
        let versionsDirectory = homeDirectory.appendingPathComponent(".nvm/versions/node")
        let read = Result {
            try fileManager.contentsOfDirectory(at: versionsDirectory, includingPropertiesForKeys: nil)
        }
        // A missing nvm directory simply means this optional installation source is absent.
        guard case let .success(versions) = read else { return [] }
        return versions
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .map { $0.appendingPathComponent("bin").appendingPathComponent(executableName) }
    }

    private static func claudeCandidates(
        homeDirectory: URL,
        fileManager: FileManager
    ) -> [URL] {
        let nativeVersions = homeDirectory.appendingPathComponent(".local/share/claude/versions")
        var candidates = versionedEntries(in: nativeVersions, fileManager: fileManager).flatMap {
            // Claude's native installer has used both a version-named executable and a
            // version directory containing `claude`; supporting both costs no process launch.
            [$0, $0.appendingPathComponent("claude")]
        }
        candidates.append(contentsOf: conductorManagedCandidates(
            provider: "claude",
            executableName: "claude",
            homeDirectory: homeDirectory,
            fileManager: fileManager
        ))
        return candidates
    }

    private static func conductorManagedCandidates(
        provider: String,
        executableName: String,
        homeDirectory: URL,
        fileManager: FileManager
    ) -> [URL] {
        let roots = [
            homeDirectory.appendingPathComponent(
                "Library/Application Support/com.conductor.app/agent-binaries"
            ).appendingPathComponent(provider),
            URL(fileURLWithPath: "/Applications/Conductor.app/Contents/Resources/agent-binaries")
                .appendingPathComponent(provider),
        ]
        return roots.flatMap { root in
            versionedEntries(in: root, fileManager: fileManager)
                .map { $0.appendingPathComponent(executableName) }
        }
    }

    private static func versionedEntries(in directory: URL, fileManager: FileManager) -> [URL] {
        let read = Result {
            try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        }
        // Each optional install root is expected to be missing on most Macs.
        guard case let .success(entries) = read else { return [] }
        return entries.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }
}
