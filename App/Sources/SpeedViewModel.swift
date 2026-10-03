import Foundation
import Observation
import TokiCore
import TokiFixtures

private let log = TokiLog.logger("speed")

/// The one owner of the generation speed report: the Speed tab observes it.
///
/// It registers no indexer callback — those single slots belong to `DashboardViewModel`;
/// `ServiceContainer` forwards "the index changed" here instead. It only recomputes while the
/// tab is on screen: a change while hidden marks the report stale, and the next appearance
/// pays for it once. The previous report stays published during a recompute, so the tab never
/// flashes empty.
///
/// Index-driven recomputes are throttled: the indexer fires about once a second while Claude
/// Code writes, and a recompute at large history costs a few hundred ms, so two of them start
/// at least `minimumInterval` apart. A change inside the window schedules one trailing
/// computation for when it elapses. The first computation on appearing and `refresh()` are
/// user-visible moments, so they start at once (and restart the interval).
///
/// It also owns which models the table leaves out (`hiddenModels`). The live set is read from
/// `SpeedTableVisibilityStore` on its first use and saved on every change. On fixtures the store
/// is never touched: that set starts empty and lives in memory, so a snapshot never depends on
/// the settings of the machine it is rendered on.
@MainActor
@Observable
final class SpeedViewModel {
    private(set) var report: GenerationSpeedReport?
    private(set) var isComputing = false
    private(set) var errorMessage: String?
    var runMode: RunMode = .live {
        // Every fixture starts with all of its models shown.
        didSet { if runMode != oldValue { fixtureHiddenModels = [] } }
    }

    /// The model ids the table, the default selection and the comparison leave out. May hold ids
    /// the current report does not have: such a model stays hidden when it comes back.
    ///
    /// Computed over two unobserved stores, so the live set can be read from the defaults on
    /// first use instead of in `init` — which runs before `ServiceContainer` applies a fixture.
    /// Observation is forwarded by hand; the mode is observed through `runMode`.
    var hiddenModels: Set<String> {
        access(keyPath: \.hiddenModels)
        guard runMode.isLive else { return fixtureHiddenModels }
        if let liveHiddenModels { return liveHiddenModels }
        let loaded = visibility.load()
        liveHiddenModels = loaded
        return loaded
    }

    var isVisible = false {
        didSet {
            if isVisible, !oldValue, isStale { start() }
            if !isVisible, oldValue { cancelTrailing() }
        }
    }

    private let samples: any SpeedSampleProviding
    private let visibility: SpeedTableVisibilityStore
    /// `nil` until the first live read.
    @ObservationIgnored private var liveHiddenModels: Set<String>?
    @ObservationIgnored private var fixtureHiddenModels: Set<String> = []
    /// Injected for tests; `nil` reads `Calendar.current` at compute time, so a time-zone or
    /// locale change since launch buckets days the same way `SpeedView` draws them.
    private let calendar: Calendar?
    private var isStale = true
    private var rerunOwed = false
    private var task: Task<Void, Never>?
    private let minimumInterval: Duration
    private var lastStart: ContinuousClock.Instant?
    /// The one pending trailing computation; further changes inside the window keep it.
    private var trailing: Task<Void, Never>?

    init(samples: any SpeedSampleProviding, calendar: Calendar? = nil, minimumInterval: Duration = .seconds(30),
         visibility: SpeedTableVisibilityStore = SpeedTableVisibilityStore()) {
        self.samples = samples
        self.calendar = calendar
        self.minimumInterval = minimumInterval
        self.visibility = visibility
    }

    /// Hides or shows every row of one model.
    func setModel(_ id: String, hidden: Bool) {
        var next = hiddenModels
        if hidden { next.insert(id) } else { next.remove(id) }
        setHiddenModels(next)
    }

    func showAllModels() { setHiddenModels([]) }

    private func setHiddenModels(_ next: Set<String>) {
        guard next != hiddenModels else { return }
        withMutation(keyPath: \.hiddenModels) {
            if runMode.isLive {
                liveHiddenModels = next
                visibility.save(next)
            } else {
                fixtureHiddenModels = next
            }
        }
    }

    func indexDidChange() {
        guard runMode.isLive else { return }
        isStale = true
        guard isVisible else { return }
        if let lastStart {
            let remaining = minimumInterval - (.now - lastStart)
            if remaining > .zero { scheduleTrailing(after: remaining); return }
        }
        start()
    }

    /// The toolbar button: never throttled, and it supersedes a pending trailing computation.
    func refresh() {
        guard runMode.isLive else { return }
        isStale = true
        guard isVisible else { return }
        trailing?.cancel()
        trailing = nil
        start()
    }

    func inject(_ report: GenerationSpeedReport?) {
        self.report = report
        isStale = false
    }

    /// Returns once no computation is running or owed. A coalesced re-run replaces `task`
    /// before the previous one finishes, so this follows the chain.
    func waitForIdle() async {
        while let current = task { await current.value }
    }

    private func scheduleTrailing(after delay: Duration) {
        guard trailing == nil else { return }
        trailing = Task { [weak self] in
            do { try await Task.sleep(for: delay) }
            catch {
                log.debug("trailing speed recompute cancelled \(error: error)")
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.trailing = nil
            if self.isVisible { self.start() }
        }
    }

    /// Hiding drops the pending computation; the report stays stale, so the next appearance
    /// computes once.
    private func cancelTrailing() {
        guard let pending = trailing else { return }
        pending.cancel()
        trailing = nil
        isStale = true
    }

    private func start() {
        guard runMode.isLive else { return }
        if isComputing { rerunOwed = true; return }
        isComputing = true
        isStale = false
        lastStart = .now
        let samples = self.samples, calendar = self.calendar ?? .current
        task = Task { [weak self] in
            let result: Result<GenerationSpeedReport, Error> = await Task.detached(priority: .userInitiated) {
                do { return .success(GenerationSpeedReport(samples: try await samples.speedSamples(), calendar: calendar)) }
                catch { return .failure(error) }
            }.value
            guard let self else { return }
            // Switched to a fixture while this ran: the injected report owns the screen now.
            if self.runMode.isLive {
                switch result {
                case .success(let report):
                    self.report = report
                    self.errorMessage = nil
                case .failure(let error):
                    log.error("speed report failed \(error: error)")
                    self.errorMessage = "Couldn't load speed data: \(error.localizedDescription)"
                }
            }
            self.isComputing = false
            if self.rerunOwed {
                self.rerunOwed = false
                if self.isVisible {
                    // Cleared first: `start()` replaces it only if it actually runs, and a
                    // declined start (fixture mode) must not leave `waitForIdle()` spinning.
                    self.task = nil
                    self.start()
                } else {
                    // Hidden since the burst: owe the recompute to the next appearance instead.
                    self.isStale = true
                    self.task = nil
                }
            } else {
                self.task = nil
            }
        }
    }
}
