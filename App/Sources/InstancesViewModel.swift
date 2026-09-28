import Foundation
import Observation
import TokiCore
import TokiFixtures

// MARK: - InstancesViewModel

/// View model for the dashboard's "Instances" tab.
///
/// Loads a `ClaudeInstancesSnapshot` (running Claude Code CLI processes) from
/// a `ClaudeInstancesProviding` service and polls it on a ~3s cadence while
/// the tab is visible. Data is local/offline — no network calls.
@Observable
@MainActor
final class InstancesViewModel {

    // MARK: Published state

    var snapshot: ClaudeInstancesSnapshot?
    var isLoading: Bool = false

    /// When not `.live`, load()/polling are no-ops — used by the demo/snapshot
    /// harness to render injected mock data without touching /proc.
    var runMode: RunMode = .live

    // MARK: Private

    private let service: ClaudeInstancesProviding
    private let terminator: ProcessTerminating
    private var pollTask: Task<Void, Never>?

    // MARK: Init

    init(service: ClaudeInstancesProviding, terminator: ProcessTerminating = SignalTerminator()) {
        self.service = service
        self.terminator = terminator
    }

    // MARK: Public API

    /// One-shot refresh. Keeps the previous snapshot visible while loading —
    /// never blanks the UI mid-refresh.
    func load() {
        guard runMode.isLive else { return }
        guard !isLoading else { return }
        isLoading = true

        Task { [weak self] in
            guard let self else { return }
            let result = await self.service.loadInstances()
            self.snapshot = result
            self.isLoading = false
        }
    }

    /// Sends SIGTERM to `pid` and optimistically drops its card immediately so
    /// the UI feels instant; the next poll reconciles (re-adding it if the signal
    /// didn't take — e.g. not our process). No-op in demo mode.
    func kill(pid: Int32) {
        guard runMode.isLive else { return }
        terminator.terminate(pid: pid)
        if var snapshot {
            snapshot.instances.removeAll { $0.pid == pid }
            self.snapshot = snapshot
        }
    }

    /// Begins a ~3s polling loop. Safe to call multiple times — a second call
    /// while already polling is a no-op.
    func startPolling() {
        guard runMode.isLive else { return }
        guard pollTask == nil else { return }

        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshOnce()
                // no-log: only throws on cancellation (loop teardown), not an error condition.
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    /// Cancels the polling loop started by `startPolling()`.
    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: Private helpers

    /// Loads a fresh snapshot without the `isLoading` re-entrancy guard used
    /// by `load()` — called on each polling tick so a slow tick can't starve
    /// the loop, while still keeping the previous snapshot visible.
    private func refreshOnce() async {
        isLoading = true
        let result = await service.loadInstances()
        snapshot = result
        isLoading = false
    }
}
