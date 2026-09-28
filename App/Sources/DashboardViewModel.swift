import Foundation
import Observation
import SwiftUI
import TokiCore
import TokiFixtures

private let log = TokiLog.logger("dashboard")

// MARK: - DashboardViewModel

/// View model for the full dashboard window.
///
/// Loads a `UsageSummary` for the selected date range and `UsageLimits`
/// for the gauge section.  Also manages the initial JSONL index pass on first launch.
@Observable
@MainActor
final class DashboardViewModel {

    // MARK: Nested types

    /// The time range for which the dashboard shows analytics — `TokiAnalytics.UsageRange`,
    /// which also owns the range→source rule (which data source answers which range, and
    /// whether the calendar-history section shows). See that type's doc comment; this
    /// typealias just keeps every existing app-target call site (`DashboardViewModel.Range`)
    /// unchanged.
    typealias Range = UsageRange

    // MARK: Published state

    var summary: UsageSummary?
    /// The signed-in account's limits, read from the shared `LiveLimits` store — the same
    /// object the popover and the Accounts tab observe, so the Usage gauges never lag them.
    var limits: UsageLimits? {
        get { live.limits }
        set { live.limits = newValue }
    }
    /// Codex limits from the same shared store. Kept separate from Claude so account
    /// switching and Claude threshold alerts continue to use only Claude's windows.
    var codexLimits: UsageLimits? {
        get { live.codexLimits }
        set { live.codexLimits = newValue }
    }
    /// The Claude account Claude Code is currently signed into (name / email /
    /// organization), read from `~/.claude.json`. Surfaced in the dashboard header
    /// and — since the menu-bar panel is handed this same view model — the popover.
    /// `nil` when no account identity is available (e.g. not signed in).
    /// The signed-in account's display label, from the shared `SignedInAccount` store — the
    /// same source the popover and the Accounts tab read, so the header can't disagree.
    var signedInLabel: String? { signedIn.label }
    var range: Range = .today
    var isLoading: Bool = false
    var isIndexing: Bool = false
    var error: String?

    /// When not `.live`, load()/triggerInitialIndex() are no-ops — used by the demo/snapshot
    /// harness to render injected mock data without touching disk/network.
    var runMode: RunMode = .live

    /// Gates the LIVE limits fetch (the only path that reads the Keychain and can
    /// trigger the macOS prompt). `ServiceContainer` holds this false until Keychain
    /// access is confirmed — by the silent probe or by the user completing onboarding —
    /// so analytics (local, keychain-free) still load while the prompt stays deferred.
    /// The persisted limits cache is still shown regardless. Forwarded to the shared store,
    /// so gating it here or on the menu bar is the same single gate.
    var limitsFetchEnabled: Bool {
        get { live.limitsFetchEnabled }
        set { live.limitsFetchEnabled = newValue }
    }

    /// Set only by explicit setup; the dashboard renders the dismissible onboarding overlay
    /// on top of the analytics content. `ServiceContainer` sets it when access isn't
    /// yet available and clears it (inside `withAnimation`) once the user grants access,
    /// producing a cross-fade from onboarding to the live dashboard.
    var onboarding: OnboardingViewModel?

    // MARK: Private

    private let analyticsService: AnalyticsService
    private let live: LiveLimits
    private let indexer: TranscriptIndexer
    private let signedIn: SignedInAccount
    private var hasTriggeredInitialIndex: Bool = false

    /// Whether the dashboard is on screen. The live-analytics handler stays registered for
    /// the process's lifetime, so without this the app re-aggregates the whole index every
    /// time Claude Code writes a transcript line — with nobody looking at the result. On a
    /// busy session that is a full pass over tens of thousands of records once a second,
    /// which is exactly what burned 75% CPU for hours.
    var isVisible = false {
        didSet {
            guard isVisible, !oldValue, missedRefreshWhileHidden else { return }
            missedRefreshWhileHidden = false
            Task { await refreshAnalytics() }
        }
    }
    /// An index change arrived while hidden: one refresh is owed when the dashboard returns.
    private var missedRefreshWhileHidden = false
    /// Floor between live reloads. The indexer already coalesces bursts into ~1s; this keeps
    /// a continuously-writing session from turning that into a per-second full aggregation.
    private static let minimumRefreshInterval: TimeInterval = 10
    private var lastAnalyticsRefresh: Date?

    /// Set to true when load() is called while a load is already in flight.
    /// The in-flight performLoad checks this in its defer block and re-runs load()
    /// so the post-index reload (with freshly-indexed data) is never skipped.
    private var needsReloadAfterIndex: Bool = false

    // MARK: Init

    init(
        analytics analyticsService: AnalyticsService,
        live: LiveLimits,
        indexer: TranscriptIndexer,
        signedIn: SignedInAccount
    ) {
        self.analyticsService = analyticsService
        self.live = live
        self.indexer = indexer
        self.signedIn = signedIn
    }

    // MARK: Public API

    /// Loads analytics summary and latest limits for the currently selected range.
    ///
    /// If a load is already in flight the request is queued: `performLoad`'s
    /// defer block will call `load()` again once the current load completes, so
    /// callers (including `triggerInitialIndex`) always get a fresh result.
    func load() {
        guard runMode.isLive else { return }
        // Refresh the signed-in account label alongside every load (range change,
        // manual refresh, post-index reload) so switching Claude accounts updates
        // the header without a restart. Cheap, off-main, and independent of the
        // in-flight guard below.
        refreshAccount()
        guard !isLoading else {
            needsReloadAfterIndex = true
            return
        }
        isLoading = true
        error = nil

        Task { [weak self] in
            guard let self else { return }
            await self.performLoad()
        }
    }

    /// Brings the transcript index up to date on first call. Subsequent calls are no-ops.
    ///
    /// Never makes the dashboard wait for it. The summary is loaded straight away from the
    /// index as it stands (reads have their own connection, so they don't queue behind the
    /// pass), then reloaded as the pass commits batches — newest files first — and once more
    /// when it finishes. On a normal launch the pass reads only what was appended since the
    /// last one and is over in well under a second; on a first launch the numbers fill in
    /// while it runs.
    func triggerInitialIndex() {
        guard runMode.isLive else { return }
        guard !hasTriggeredInitialIndex else { return }
        hasTriggeredInitialIndex = true
        isIndexing = true
        load()

        Task { [weak self] in
            guard let self else { return }
            await self.indexer.setOnProgress { [weak self] progress in
                await self?.indexDidProgress(progress)
            }
            let caughtUp = await self.catchUpWithRetries()
            await self.indexer.startWatching()
            // Live analytics: when the watcher indexes new transcript records (debounced
            // ~1s), quietly reload the summary so usage grows on screen while you work.
            await self.indexer.setOnIndexChanged { [weak self] in
                await self?.refreshAnalytics()
            }
            self.isIndexing = false
            self.indexProgress = nil
            // Only a completed pass opens the statistics gate: a first-run import from a
            // half-built index would leave older days permanently short.
            if caughtUp { self.onInitialIndexFinished?() }
            await self.load()
        }
    }

    /// Runs the initial catch-up, retrying a failed pass (a transiently locked database, a
    /// full disk) a few times before giving up for this launch. Returns whether one completed.
    private func catchUpWithRetries() async -> Bool {
        for delay in [0, 2, 10, 60] {
            if delay > 0 {
                // no-log: a cancelled sleep only ends the retries early.
                try? await Task.sleep(for: .seconds(delay))
            }
            do {
                try await indexer.reindex()
                return true
            } catch {
                log.error("triggerInitialIndex: transcript catch-up failed: \(error: error)")
            }
        }
        return false
    }

    /// How far the initial catch-up has got; `nil` outside it. Drives the Usage tab's
    /// indexing indicator.
    var indexProgress: IndexProgress?

    /// Called once the initial catch-up has finished, so consumers that must not read a
    /// half-built index (the statistics rollup) know the index is complete.
    var onInitialIndexFinished: (() -> Void)?

    /// Floor between the reloads a running catch-up triggers: often enough that the numbers
    /// visibly fill in, rarely enough that a cold build is not spent re-aggregating.
    private static let progressiveReloadInterval: Duration = .milliseconds(700)
    private var lastProgressiveReload: ContinuousClock.Instant?
    private var progressiveReloadInFlight = false

    private func indexDidProgress(_ progress: IndexProgress) {
        guard isIndexing else { return }
        indexProgress = progress
        guard isVisible, !progressiveReloadInFlight, progress.filesDone > 0 else { return }
        if let last = lastProgressiveReload, ContinuousClock.now - last < Self.progressiveReloadInterval {
            return
        }
        lastProgressiveReload = .now
        progressiveReloadInFlight = true
        let requested = range
        let (start, end) = requested.dateInterval()
        Task { [weak self] in
            guard let self else { return }
            defer { self.progressiveReloadInFlight = false }
            do {
                let newSummary = try await self.analyticsService.summary(start: start, end: end)
                // A range switched mid-flight has its own load coming, and once the pass has
                // finished its final load is fuller than this one: don't overwrite either.
                guard self.range == requested, self.isIndexing else { return }
                withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
                    self.summary = newSummary
                }
            } catch {
                log.error("indexDidProgress: failed to recompute the summary: \(error: error)")
            }
        }
    }

    /// The Usage tab shows the full-screen indexing state rather than an all-zero dashboard
    /// while the index is still being built and holds nothing for the selected range yet.
    var showsIndexingPlaceholder: Bool {
        guard isIndexing else { return false }
        guard let summary else { return true }
        return summary.byModel.isEmpty
    }

    /// Quietly reloads analytics only (local SQLite — no Keychain, no limits API, no
    /// loading spinner), animating the tiles from old → new values. Driven by the
    /// transcript watcher so usage updates live; the limits gauges keep their own poll.
    func refreshAnalytics() async {
        guard runMode.isLive else { return }
        guard isVisible else {
            missedRefreshWhileHidden = true
            return
        }
        if let last = lastAnalyticsRefresh,
           Date().timeIntervalSince(last) < Self.minimumRefreshInterval {
            // Too soon: the numbers on screen are at most a few seconds stale, which is
            // cheaper than another pass over the whole range.
            missedRefreshWhileHidden = false
            return
        }
        lastAnalyticsRefresh = Date()
        let (start, end) = range.dateInterval()
        do {
            let newSummary = try await analyticsService.summary(start: start, end: end)
            withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
                summary = newSummary
            }
        } catch {
            log.error("refreshAnalytics: failed to recompute the summary: \(error: error)")
        }
    }

    /// Refreshes the shared signed-in-account store (e.g. when the popover opens), so a switch
    /// made outside the app is reflected promptly. The config watcher keeps it current too;
    /// this is a belt-and-suspenders kick on the surfaces the user just opened.
    func refreshAccount() {
        guard runMode.isLive else { return }
        Task { [signedIn] in await signedIn.refresh() }
    }

    // MARK: Private helpers

    private func performLoad() async {
        log.info("performLoad: loading the usage summary for the selected range")
        defer {
            isLoading = false
            // If load() was called while this load was in flight, kick off a
            // fresh load now so callers (e.g. triggerInitialIndex) get up-to-date
            // data from the just-completed index pass.
            if needsReloadAfterIndex {
                needsReloadAfterIndex = false
                load()
            }
        }

        let (start, end) = range.dateInterval()

        // Analytics only. The RATE LIMITS gauges read the shared `LiveLimits` store, which
        // owns the single fetch + poll cycle — the dashboard no longer fetches limits itself,
        // so the Usage tab, the popover and the Accounts tab can never disagree.
        var newSummary: UsageSummary?
        var summaryError: String?
        do {
            newSummary = try await analyticsService.summary(start: start, end: end)
            log.info("performLoad: succeeded")
        } catch {
            log.error("performLoad: failed to load the usage summary: \(error: error)")
            summaryError = error.localizedDescription
        }

        withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
            if let newSummary {
                summary = newSummary
            }
        }

        if let summaryError {
            self.error = summaryError
        }
    }

    // Override that is safe to await internally
    private func load() async {
        guard !isLoading else {
            // The load in flight may predate what the caller needs (the post-index reload
            // usually collides with the pre-index one): owe a fresh load once it finishes.
            needsReloadAfterIndex = true
            return
        }
        isLoading = true
        error = nil
        await performLoad()
    }
}
