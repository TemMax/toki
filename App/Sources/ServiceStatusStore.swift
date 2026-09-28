import AppKit
import Foundation
import Observation
import TokiCore
import TokiFixtures

private let log = TokiLog.logger("status")

/// The single source of truth for whether Claude Code itself is healthy.
///
/// Modelled on `LiveLimits`: one object owns the value AND the poll loop, every surface
/// (the popover banner, the dashboard banner, the notification driver) observes it, so a
/// single poll updates all of them at once and nothing keeps a second copy that can drift.
///
/// Unlike `LiveLimits` this feed is entirely public — `status.claude.com` needs no
/// credential — so it is started at launch rather than behind the Keychain gate.
@Observable
@MainActor
final class ServiceStatusStore {

    /// The last status Toki managed to read. `.operational` until the first successful poll:
    /// silence is the healthy state, so an unknown status draws nothing anywhere.
    var status: ServiceStatus = .operational

    /// No-ops every network entry point for the demo/snapshot harness, which assigns
    /// `status` directly from a fixture bundle.
    var runMode: RunMode = .live

    private let client: ServiceStatusClient
    private var pollingTask: Task<Void, Never>?
    /// Held so the wake observer is registered once and can be torn down in `stop()`.
    private var wakeObserver: NSObjectProtocol?

    init(client: ServiceStatusClient = ServiceStatusClient()) {
        self.client = client
    }

    /// Starts the background poll. Idempotent — only one loop runs at a time.
    func start() {
        guard runMode.isLive, pollingTask == nil else { return }
        log.info("start: beginning the service-status poll loop")
        pollingTask = Task { [weak self] in
            await self?.pollLoop()
        }
        observeWake()
    }

    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
    }

    /// One immediate poll, on top of whatever the loop is doing. Called when the popover
    /// opens and when the Mac wakes, so the banner is never a sleep's worth out of date.
    func refreshNow() {
        guard runMode.isLive else { return }
        Task { [weak self] in await self?.pollOnce() }
    }

    /// The fixture → live switch: drop the injected value AND the client's conditional-GET
    /// state, then poll. Without the reset the next poll would 304 — "nothing new" is true
    /// of the page but not of a store that just discarded its last real value, so a live
    /// incident would stay hidden until the page happened to change again.
    func resetToLive() {
        guard runMode.isLive else { return }
        status = .operational
        Task { [weak self] in
            guard let self else { return }
            await self.client.resetETags()
            await self.pollOnce()
        }
    }

    /// Sleeping through an incident's start (or its resolution) would leave the banner
    /// asserting something that stopped being true hours ago, and the poll loop's own
    /// `Task.sleep` does not make up the lost time on wake.
    ///
    /// This is `NSWorkspace`'s own notification centre, not `NotificationCenter.default` —
    /// `didWakeNotification` is never posted to the default centre, so an observer
    /// registered there would simply never fire.
    private func observeWake() {
        guard wakeObserver == nil else { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshNow() }
        }
    }

    private func pollLoop() async {
        while !Task.isCancelled {
            await pollOnce()
            let interval = StatusPollPlanner.interval(after: status)
            // no-log: only throws on cancellation (loop teardown), not an error condition.
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
    }

    /// A nil poll means "nothing changed (304)" or "could not reach the page", and both keep
    /// the last known value: a status monitor that turns its own network trouble into a
    /// banner is noise on top of noise.
    ///
    /// `runMode` is re-checked after the await: a poll can be mid-flight (up to the 10 s
    /// timeout) when the debug channel switches to a fixture scenario, and its late result
    /// must not overwrite the status the fixture just injected.
    private func pollOnce() async {
        guard runMode.isLive else { return }
        guard let fresh = await client.poll(), runMode.isLive else { return }
        status = fresh
    }
}
