/// The seam between the UI's "kill this instance" intent and the OS.
///
/// A `ProcessTerminating` sends a termination signal to one process the current
/// user owns — `SignalTerminator` in production (via `kill(2)`), a fake in tests
/// — so `InstancesViewModel`'s kill wiring can be exercised without touching real
/// processes.
import Darwin
import Foundation

/// Sends a graceful termination signal to a process the current user owns.
public protocol ProcessTerminating: Sendable {
    /// Requests termination of `pid`. Returns `true` when the signal was
    /// delivered (the process existed and we had permission), `false` otherwise
    /// (dead pid / not our process).
    @discardableResult
    func terminate(pid: Int32) -> Bool
}

/// `ProcessTerminating` backed by `kill(pid, SIGTERM)`.
///
/// SIGTERM is graceful: it asks the target to shut down cleanly and can be
/// caught by the process to flush state before exiting (Claude Code does its own
/// cleanup on it). Only the current user's own processes can be signalled — the
/// kernel returns EPERM for others, surfaced here as `false`. This never escalates
/// to SIGKILL.
public struct SignalTerminator: ProcessTerminating {
    public init() {}

    @discardableResult
    public func terminate(pid: Int32) -> Bool {
        kill(pid, SIGTERM) == 0
    }
}
