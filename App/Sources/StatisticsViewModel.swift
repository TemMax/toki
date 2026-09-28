import Foundation
import Observation
import TokiCore
import TokiFixtures

private let log = TokiLog.logger("statistics")

// MARK: - StatisticsViewModel

/// View model for the calendar-history section (activity heatmap, streak tiles, punchcard)
/// that appears on the Usage tab on every range, under its "All-time statistics" header — see
/// `DashboardContent.statisticsSection` in `DashboardView.swift`. Not a dashboard tab of its
/// own anymore (the standalone Statistics tab retired into Usage; `StatisticsView` itself
/// lives on only as a reusable content view and a standalone comparison surface — see
/// `DashboardNavigation.swift`).
///
/// Owns the load path from local transcripts to the durable rollup to the derived
/// `StatsHistory` the view renders: pulls records from `RecordProviding` (a full
/// `.distantPast`...now import on first run, otherwise just the last 45 days — older days are
/// already immutable in the monotonic rollup), merges them into the persistent
/// `StatsRollupStore`, then recomputes `StatsHistory` from the merged rollup. `load()` is
/// called on every launch (see `ServiceContainer.beginAuthenticatedWork`) so history
/// accumulates even if the dashboard is never opened — the rollup is the only place this data
/// survives transcript cleanup.
///
/// **Today's heatmap cell can lag.** It comes from this rollup, which is only re-merged from
/// the live transcript index on demand (launch, opening the dashboard, hitting refresh on
/// the Usage tab — see `DashboardView`), not on every write the way the
/// Usage tab's own summary cards are. In the measured sample, the two sources agree to the token on
/// every settled day and differ only on the still-accruing "today", by under 1% of the
/// all-time total at measurement time. Closing that gap fully — sourcing today's cell straight
/// from the live index on every redraw — was assessed and rejected for this phase: the cell's
/// color level is a nearest-rank quartile computed once, over the whole grid, inside
/// `StatsHistory.init` (private); making today's cell participate in that computation with a
/// live number would mean exposing/duplicating that quantile pass outside the initializer, or
/// feeding a live override INTO it — both restructure how `StatsHistory` is built, which the
/// task this comment was written for explicitly rules out. Reloading more often (above) is the
/// small, contained fix that ships instead: it does not make the cell live, but it bounds the
/// staleness to "since you last opened or refreshed the Usage tab" instead of "since launch".
@Observable
@MainActor
final class StatisticsViewModel {

    // MARK: Published state

    var history: StatsHistory?
    var isLoading: Bool = false
    var errorMessage: String?

    /// When not `.live`, load() is a no-op — used by the demo/snapshot harness to render
    /// injected mock data without touching the transcript index or the rollup file.
    var runMode: RunMode = .live

    // MARK: Private

    private let records: any RecordProviding
    private let store: StatsRollupStore

    // MARK: Init

    init(records: any RecordProviding, store: StatsRollupStore) {
        self.records = records
        self.store = store
    }

    // MARK: Public API

    /// Whether the transcript index has finished its launch catch-up. Until then `load()`
    /// shows the persisted rollup but does not merge into it: on a first run the merge is a
    /// one-time import from `.distantPast`, and importing a half-built index would leave every
    /// day older than the 45-day re-merge window permanently short.
    private(set) var indexReady = false

    /// A `load()` arrived before the index was ready; the merge it asked for is owed.
    private var mergeOwed = false

    /// Called once the index has caught up; runs any merge that was held back for it.
    func indexDidCatchUp() {
        guard !indexReady else { return }
        indexReady = true
        if mergeOwed {
            mergeOwed = false
            load()
        }
    }

    /// One-shot refresh: reads every transcript record, merges it into the rollup, and
    /// recomputes `history` against "now". Keeps the previous `history` visible while
    /// loading — never blanks the UI mid-refresh.
    func load() {
        guard runMode.isLive else { return }
        guard !isLoading else { return }
        isLoading = true

        Task { [weak self] in
            guard let self else { return }
            log.info("load: loading statistics rollup")
            do {
                let rollup = await self.store.load()
                guard self.indexReady else {
                    // The persisted rollup is complete for every settled day, so it is worth
                    // showing at once; the merge waits for the index (see `indexReady`).
                    if self.history == nil, !rollup.days.isEmpty {
                        self.history = StatsHistory(rollup: rollup, today: Date(), calendar: .current)
                    }
                    self.mergeOwed = true
                    self.isLoading = false
                    return
                }
                // First run (empty rollup): do a full import from the beginning of history.
                // Otherwise every older day is already immutable in the monotonic rollup, so
                // only re-query the last 45 days — comfortably more than Claude Code's default
                // 30-day transcript cleanupPeriodDays, so nothing merge-eligible is missed,
                // without re-materializing the whole ever-growing transcript index every load.
                // A rollup from an older token definition is recomputed from all history.
                let start: Date = rollup.days.isEmpty || rollup.needsFullRecompute
                    ? .distantPast
                    : Calendar.current.date(byAdding: .day, value: -45, to: Date())!
                let all = try await self.records.records(start: start, end: Date())
                let merged = try await self.store.merge(records: all)
                self.history = StatsHistory(rollup: merged, today: Date(), calendar: .current)
                self.errorMessage = nil
                log.info("load: succeeded")
            } catch {
                log.error("load: failed to load statistics: \(error: error)")
                self.errorMessage = "Couldn't load statistics: \(error.localizedDescription)"
            }
            self.isLoading = false
        }
    }
}
