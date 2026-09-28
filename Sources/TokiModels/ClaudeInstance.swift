/// Value types describing a running Claude Code CLI process, surfaced in the
/// dashboard's "Instances" tab.
///
/// PRIVACY: these types intentionally carry NO process arguments. A running
/// `claude` invocation can hold prompt text or other sensitive data in its
/// argv (`-p "…"`); the scanner never reads argv. Only the executable path
/// (→ version), the working directory (the user's own project path), and
/// coarse resource facts (start time, resident memory) are surfaced.
import Foundation

/// How a Claude Code instance was installed / launched.
public enum ClaudeInstanceSource: String, Sendable, Codable, Equatable {
    /// Native install under `~/.local/share/claude/versions/<version>`.
    case native
    /// A managed/vendored install (e.g. Conductor's `agent-binaries/claude/<version>/claude`).
    case managed
    /// Detected as Claude Code but from an unrecognized location.
    case unknown
}

/// A single running Claude Code CLI process.
public struct ClaudeInstance: Sendable, Codable, Equatable, Identifiable {
    /// nil decodes as Claude for records produced before multi-provider process scanning.
    public var provider: UsageProvider?
    /// OS process id.
    public var pid: Int32
    /// Version parsed from the executable path (e.g. "2.1.197"); nil if unparseable.
    public var version: String?
    /// Full resolved executable path (e.g. ".../claude/versions/2.1.197").
    public var executablePath: String
    /// Working directory (project root), if readable.
    public var workingDirectory: String?
    /// Process start time, if readable.
    public var startedAt: Date?
    /// Resident memory (RSS) in bytes, if readable.
    public var memoryBytes: UInt64?
    /// How this instance was installed / launched.
    public var source: ClaudeInstanceSource
    /// True when `version` is confidently older than the newest installed CLI
    /// (`ClaudeInstancesSnapshot.referenceVersion`) — i.e. this session would
    /// pick up a newer binary if restarted.
    public var isOutdated: Bool

    public var id: Int32 { pid }

    /// Last path component of `workingDirectory` — the project folder name.
    public var projectName: String? {
        guard let workingDirectory, !workingDirectory.isEmpty else { return nil }
        let name = (workingDirectory as NSString).lastPathComponent
        return name.isEmpty ? nil : name
    }

    public init(
        pid: Int32,
        provider: UsageProvider = .claudeCode,
        version: String?,
        executablePath: String,
        workingDirectory: String? = nil,
        startedAt: Date? = nil,
        memoryBytes: UInt64? = nil,
        source: ClaudeInstanceSource = .unknown,
        isOutdated: Bool = false
    ) {
        self.pid = pid
        self.provider = provider
        self.version = version
        self.executablePath = executablePath
        self.workingDirectory = workingDirectory
        self.startedAt = startedAt
        self.memoryBytes = memoryBytes
        self.source = source
        self.isOutdated = isOutdated
    }
}

/// A point-in-time snapshot of all running Claude Code instances, plus the
/// reference version used to decide which are outdated.
public struct ClaudeInstancesSnapshot: Sendable, Codable, Equatable {
    /// Running instances (order is defined by the presentation layer).
    public var instances: [ClaudeInstance]
    /// Newest installed CLI version — the one a fresh `claude` launch would use
    /// (resolved from the `~/.local/bin/claude` symlink / versions directory).
    /// nil when it can't be determined; then no instance is marked outdated.
    public var referenceVersion: String?

    public init(instances: [ClaudeInstance], referenceVersion: String?) {
        self.instances = instances
        self.referenceVersion = referenceVersion
    }

    public static let empty = ClaudeInstancesSnapshot(instances: [], referenceVersion: nil)
}

/// Supplies a snapshot of running Claude Code instances. Reads only the current
/// user's own processes; never spawns processes and never reads process argv.
public protocol ClaudeInstancesProviding: Sendable {
    func loadInstances() async -> ClaudeInstancesSnapshot
}
