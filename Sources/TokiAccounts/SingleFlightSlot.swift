/// The in-flight marker behind an operation that must never run twice at once.
import Foundation

/// Holds at most one run, and records *which* run holds it.
///
/// Both rules come from measured bugs. Starting a second run is not merely wasteful: two
/// concurrent gauge refreshes hand `TokenRefresher` slots that were read before the other
/// run rewrote them, and a dead-lineage answer then writes that whole stale slot back —
/// rolling an account's credential onto a generation Claude Code has already spent.
/// Releasing a claim that is not yours is worse: the loser of a swap race cleared the
/// winner's marker and re-enabled the UI while the swap was still running.
public struct SingleFlightSlot<Run: Equatable & Sendable>: Sendable {
    /// The run holding the slot, if any.
    public private(set) var current: Run?

    public init() {}

    /// Claims the slot for `run`. `false` means another run holds it: the caller must not
    /// proceed, and must not call `end`, because the claim is not its own.
    public mutating func begin(_ run: Run) -> Bool {
        guard current == nil else { return false }
        current = run
        return true
    }

    /// Claims the slot for a freshly made run, or hands back the run already holding it.
    /// `make` is called only when the slot is free, so a joining caller can await the
    /// running work without any chance of starting a duplicate.
    public mutating func beginOrJoin(_ make: () -> Run) -> (run: Run, isOwner: Bool) {
        if let current { return (current, false) }
        let run = make()
        current = run
        return (run, true)
    }

    /// Releases the slot only when `run` is the holder.
    public mutating func end(_ run: Run) {
        guard current == run else { return }
        current = nil
    }
}
