/// The seam between raw OS process enumeration and Claude-Code detection.
///
/// `RawProcess` is the minimal set of un-filtered facts the scanner needs about
/// one process. A `ProcessEnumerating` produces them — `LibprocEnumerator` in
/// production (via libproc), fakes in tests — so all the claude-detection logic
/// (path filtering, version-from-path parsing, outdated comparison) is unit
/// testable without touching real processes.
import Foundation

/// Un-filtered facts about a single OS process.
public struct RawProcess: Sendable, Equatable {
    /// OS process id.
    public var pid: Int32
    /// Resolved executable path (the kernel's image path, symlinks resolved).
    public var executablePath: String
    /// Working directory, if readable.
    public var workingDirectory: String?
    /// Process start time, if readable.
    public var startedAt: Date?
    /// Resident memory (RSS) in bytes, if readable.
    public var memoryBytes: UInt64?

    public init(
        pid: Int32,
        executablePath: String,
        workingDirectory: String? = nil,
        startedAt: Date? = nil,
        memoryBytes: UInt64? = nil
    ) {
        self.pid = pid
        self.executablePath = executablePath
        self.workingDirectory = workingDirectory
        self.startedAt = startedAt
        self.memoryBytes = memoryBytes
    }
}

/// Enumerates the processes the caller may inspect (the current user's own).
public protocol ProcessEnumerating: Sendable {
    func enumerate() -> [RawProcess]
}
