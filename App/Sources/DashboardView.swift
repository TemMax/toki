/// DashboardView — glass-aesthetic full-window analytics dashboard.
///
/// Uses only design-system primitives (panelCard, glassPanel, Sparkline,
/// MiniBars, CapsuleGauge, SectionHeader, heroNumber, cardLabel).
/// No Swift Charts dependency.
import TokiCore
import TokiAccounts
import SwiftUI

// MARK: - DashboardView

@MainActor
struct DashboardView: View {
    @Bindable var model: DashboardViewModel
    @Bindable var instances: InstancesViewModel
    @Bindable var environment: EnvironmentViewModel
    /// Backs the Settings tab's Menu Bar section — the one owner of the indicator
    /// configuration and the live limits it previews against. Required,
    /// not optional like `accounts`/`statistics` below: every real call site already owns a
    /// `ServiceContainer` (and therefore a `menuBarVM`), and Settings has nothing sensible to
    /// show without it.
    @Bindable var menuBar: MenuBarViewModel
    /// The one owner of Claude Code's service status (`ServiceContainer.serviceStatus`).
    /// Required for the same reason as `menuBar`: every real call site owns a container, and
    /// the Usage tab must be able to say the service is down.
    var serviceStatus: ServiceStatusStore
    var codexServiceStatus: ServiceStatusStore
    let providerAvailability: ProviderAvailability
    // Optional so the demo/snapshot harness (which never sets this up) still compiles;
    // nil just hides the Accounts tab's content (the tab itself is still selectable).
    var accounts: AccountsViewModel? = nil
    @Bindable var codexAccounts: CodexAccountsViewModel
    // Optional for the same reason — nil just hides the Usage tab's all-time statistics block.
    var statistics: StatisticsViewModel? = nil
    /// Adopts / discards a quarantined credential — see `AccountsView`'s doc comment
    /// for why these are closures rather than `AccountsViewModel` methods.
    var addQuarantineEntry: (QuarantineEntry) async -> Void = { _ in }
    var deleteQuarantineEntry: (QuarantineEntry) async -> Void = { _ in }

    /// The selected tab. Shared source of truth (owned by `ServiceContainer`) so every
    /// entry point can route here. A fresh default is used only by the snapshot/demo
    /// harness, which never wires the container's instance in.
    @Bindable var navigation: DashboardNavigation = DashboardNavigation()

    /// Supplies the Settings tab (`SettingsSections`). Passed in via `.environmentObject`
    /// by the dashboard `Window`; only read when the Settings tab is showing.
    @EnvironmentObject private var updater: UpdaterController

    /// Session-scoped Machine disclosure state. Keeping it above `contentArea` matters: the
    /// switch below removes MachineView while another tab is selected, but returning to it in
    /// the same window should restore the groups the user was comparing.
    @State private var machineExpansion = MachineExpansionState()

    /// Height reserved for the floating toolbar. Scroll content is inset by this so it
    /// starts below the bar, then scrolls *under* it through the progressive blur.
    private let toolbarHeight = Measure.dashboardToolbar

    private var availableSections: [DashboardSection] {
        var sections: [DashboardSection] = []
        if providerAvailability.hasAnyProvider { sections.append(.usage) }
        if providerAvailability.hasAnyProvider { sections.append(.machine) }
        if providerAvailability.hasAnyProvider { sections.append(.accounts) }
        sections.append(.settings)
        return sections
    }

    var body: some View {
        ZStack {
            contentArea
                .overlay(alignment: .top) { toolbarBar }
                .frame(minWidth: 860, minHeight: 540)
                .modifier(DashboardWindowBackground())
                .onAppear {
                    if !availableSections.contains(navigation.section) {
                        navigation.section = availableSections.first ?? .settings
                    }
                    model.isVisible = providerAvailability.hasAnyProvider
                    if providerAvailability.hasAnyProvider {
                        model.load()
                        statistics?.load()
                    }
                    if providerAvailability.codex {
                        codexAccounts.load()
                    }
                }
                .onDisappear {
                    // Live analytics reloads are pointless — and expensive — with the
                    // window closed.
                    model.isVisible = false
                }

            // Keychain-onboarding overlay: covers the dashboard until access is granted,
            // then cross-fades out (ServiceContainer clears `model.onboarding` inside a
            // withAnimation) to reveal the live dashboard underneath.
            if providerAvailability.claudeCode, let onboarding = model.onboarding {
                OnboardingView(model: onboarding, onDismiss: { model.onboarding = nil })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
    }

    // MARK: - Floating toolbar (progressive-blur scroll edge)

    /// The toolbar floats above the scrolling content: a progressive-blur backdrop
    /// (frosted at the very top, fading to clear) with the controls layered on top, so
    /// content dissolves into blur as it scrolls under instead of hitting a hard edge.
    private var toolbarBar: some View {
        ZStack(alignment: .top) {
            ProgressiveBlurHeader(height: toolbarHeight + 32)
            topBar
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .ignoresSafeArea(edges: .top)
    }

    // MARK: - Top bar

    @ViewBuilder
    private var topBar: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            // Row 0: the "Toki" wordmark, nudged clear of the traffic-light buttons.
            // It's the app's only title now that the logo + "Dashboard" subtitle are gone.
            // The 28-pt band is the standard title-bar height AppKit centers the
            // traffic-light buttons within, so centering the text in it lines the
            // wordmark up vertically with the buttons.
            Text("Toki")
                .textStyle(.headline)
                .foregroundStyle(Palette.textPrimary)
                .padding(.leading, 52)
                .frame(height: 28)

            // Row 1: both provider-scoped accounts get the full width. Keeping the range
            // picker off this row matters: at the minimum window width it otherwise
            // compresses the Claude menu down to only its provider name and hides the
            // actual account being used.
            HStack(spacing: Spacing.sm) {
                accountIdentity

                Spacer()

                // Indexing indicator (inline, non-blocking) — only meaningful for Usage.
                if providerAvailability.hasAnyProvider,
                   navigation.section == .usage,
                   model.isIndexing {
                    HStack(spacing: 5) {
                        ProgressView()
                            .controlSize(.mini)
                        Text(indexingLabel)
                            .textStyle(.caption)
                            .monospacedDigit()
                            .foregroundStyle(Palette.textSecondary)
                    }
                    .padding(.horizontal, Spacing.xs)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(Palette.textSecondary.opacity(0.10))
                    )
                }

            }
            .frame(height: 30)

            // Row 2: navigation on the left, tab-specific controls on the right.
            HStack(spacing: Spacing.sm) {
                SectionSwitch(selection: $navigation.section, items: availableSections)
                Spacer()

                if providerAvailability.hasAnyProvider, navigation.section == .usage {
                    SegmentedControl(selection: $model.range)
                        .onChange(of: model.range) { _, _ in
                            model.load()
                        }
                }

                if navigation.section != .settings {
                    Button {
                        switch navigation.section {
                        case .usage:
                            if providerAvailability.hasAnyProvider {
                                model.load()
                                statistics?.load()
                            }
                            if providerAvailability.codex {
                                menuBar.refreshCodexNow()
                            }
                        case .machine:
                            if providerAvailability.hasAnyProvider {
                                instances.load()
                                environment.load()
                            }
                        case .accounts:
                            Task {
                                if providerAvailability.claudeCode {
                                    await accounts?.refreshGauges()
                                }
                                if providerAvailability.codex {
                                    await codexAccounts.refreshGauges()
                                }
                            }
                        case .settings:
                            break
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .iconSize(.medium, weight: .semibold)
                    }
                    .buttonStyle(.borderless)
                    .help("Refresh")
                    .disabled(refreshDisabled)
                }
            }
            .frame(height: 30)
        }
        // The title row sits ON the traffic-light band (nudged right of the buttons);
        // the account + tabs rows fall directly beneath it, aligned to the content's
        // left edge.
        .padding(.leading, Spacing.xl)
        .padding(.trailing, Spacing.xl)
        // Nudge the whole header down so the "Toki" wordmark drops onto the
        // traffic-light buttons' vertical center (SF glyphs sit high in their line
        // box, so band-centering at y=0 alone reads as too high).
        .padding(.top, 2)
        .padding(.bottom, Spacing.sm)
    }

    /// Two provider-scoped account controls. They deliberately do not share a selection:
    /// changing Claude must never rewrite Codex auth, and vice versa.
    @ViewBuilder
    private var accountIdentity: some View {
        HStack(spacing: Spacing.sm) {
            if providerAvailability.claudeCode, let accounts {
                ClaudeAccountMenu(
                    model: accounts,
                    signedInLabel: model.signedInLabel,
                    providerLabel: "Claude"
                )
                .layoutPriority(1)
            } else if providerAvailability.claudeCode, let label = model.signedInLabel {
                Text(label).textStyle(.body).foregroundStyle(Palette.textPrimary)
            }
            if providerAvailability.claudeCode, providerAvailability.codex {
                Divider().frame(height: 16)
            }
            if providerAvailability.codex {
                CodexAccountMenu(model: codexAccounts, providerLabel: "Codex")
                    .layoutPriority(1)
            }
        }
    }

    /// Whether the refresh button is disabled — reflects the active tab's VM. The Settings
    /// tab hides the button entirely, so its value here is inert.
    private var refreshDisabled: Bool {
        switch navigation.section {
        case .usage:
            return providerAvailability.hasAnyProvider
                && (model.isLoading || (statistics?.isLoading ?? false))
        case .machine: return instances.isLoading || environment.isLoading
        case .accounts:
            let claudeBusy = providerAvailability.claudeCode && accounts?.swapInFlight != nil
            let codexBusy = providerAvailability.codex && codexAccounts.swapInFlight != nil
            return claudeBusy || codexBusy
        case .settings: return false
        }
    }

    private var displayedClaudeLimits: UsageLimits? {
        guard providerAvailability.claudeCode else { return nil }
        return menuBar.displayedLimits(for: .claudeCode)
    }

    private var displayedCodexLimits: UsageLimits? {
        guard providerAvailability.codex else { return nil }
        return menuBar.displayedLimits(for: .codex)
    }

    // MARK: - Content area

    @ViewBuilder
    private var contentArea: some View {
        ZStack {
            switch navigation.section {
            case .machine:
                MachineView(
                    instances: instances,
                    environment: environment,
                    expansion: machineExpansion
                )
            case .accounts:
                if let accounts {
                    AccountsView(
                        model: accounts,
                        codex: codexAccounts,
                        providerAvailability: providerAvailability,
                        addQuarantineEntry: addQuarantineEntry,
                        deleteQuarantineEntry: deleteQuarantineEntry
                    )
                }
            case .settings:
                SettingsSections(menuBar: menuBar, providerAvailability: providerAvailability)
                    .environmentObject(updater)
            case .usage:
                usageContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Where the tabs start, decided ONCE for all four (`Measure.dashboardContentTop`)
        // rather than by four separate `topInset:` arguments that only happened to agree.
        //
        // A content margin, NOT a safe area: it moves where SCROLL content begins and nothing
        // else, which is the whole of what the four tabs' `topInset:` arguments used to do.
        // `safeAreaPadding` was tried and rejected — it repositions every child, so the
        // non-scrolling states below (indexing, loading) stopped being centered in the window
        // and the error banner picked up a second toolbar's worth of offset.
        //
        // It is an environment value, so it reaches the Settings tab's sheets as well; those
        // opt back out where they are presented (see `SettingsSections.body`).
        .contentMargins(.top, Measure.dashboardContentTop, for: .scrollContent)
    }


    /// The Usage tab's body — the indexing / loading / empty / populated states.
    @ViewBuilder
    private var usageContent: some View {
        if model.showsIndexingPlaceholder {
            indexingState
        } else if model.isLoading && model.summary == nil {
            loadingState
        } else if let errorMsg = model.error {
            // Non-blocking error banner (sits just below the floating toolbar), with the
            // scroll region beneath it.
            VStack(spacing: 0) {
                errorBanner(errorMsg)
                    .padding(.top, toolbarHeight)
                usageScroll
                    // The banner has already spent the toolbar band, so this scroll region
                    // OVERRIDES the inset `contentArea` hands every tab instead of starting
                    // a second toolbar's worth further down. An override, not a second copy.
                    .contentMargins(.top, Spacing.md, for: .scrollContent)
            }
        } else {
            usageScroll
        }
    }

    /// The Usage tab's scroll region — the populated and empty-range states. Its top inset
    /// is the shared one applied in `contentArea`, not one of its own.
    @ViewBuilder
    private var usageScroll: some View {
        ScrollView {
            if providerAvailability.claudeCode {
                if case .stale = menuBar.state {
                    Text("Claude usage could not be updated. Showing the last available values.")
                        .textStyle(.detail)
                        .foregroundStyle(Palette.warn)
                        .padding(.horizontal, Spacing.xl)
                }
                if menuBar.state == .needsAccess || menuBar.state == .notLoggedIn || menuBar.claudeNeedsReconnect {
                    Button("Connect Claude…") {
                        NotificationCenter.default.post(name: .tokiPresentKeychainSetup, object: nil)
                    }
                    .padding(.horizontal, Spacing.xl)
                }
            }
            if let summary = model.summary, !summary.buckets.isEmpty {
                DashboardContent(
                    summary: summary,
                    limits: displayedClaudeLimits,
                    claudeResetLimits: menuBar.currentClaudeResetLimits,
                    allowsStaleClaudeResetDisplay: menuBar.allowsStaleClaudeResetDisplay,
                    codexLimits: displayedCodexLimits,
                    codexResetLimits: menuBar.currentCodexResetLimits,
                    // Before accounts load the list is empty (0), which is neither
                    // "one account" nor grounds to claim "all accounts": treat it
                    // as one until a real count arrives, so the disclaimer never
                    // flashes wrong on first run.
                    accountCount: max(accounts?.accounts.count ?? 1, 1),
                    statisticsHistory: statistics?.history,
                    statisticsErrorMessage: statistics?.errorMessage,
                    // A value, not the store: `DashboardContent` is also rendered offscreen
                    // by the snapshot harness from a fixture bundle.
                    serviceStatus: providerAvailability.claudeCode
                        ? serviceStatus.status
                        : .operational,
                    codexServiceStatus: providerAvailability.codex
                        ? codexServiceStatus.status
                        : .operational,
                    showsClaudeCode: providerAvailability.claudeCode,
                    showsCodex: providerAvailability.codex
                )
                    .padding(.horizontal, Spacing.xl)
                    .padding(.bottom, Spacing.xl)
            } else if model.error == nil {
                // No index data in this range — but the all-time block does not depend on
                // the range, so it stays on screen under the empty state instead of
                // vanishing with it (otherwise "Today" at 9 a.m. would hide a year of
                // history).
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    DashboardContent(
                        summary: nil,
                        limits: displayedClaudeLimits,
                        claudeResetLimits: menuBar.currentClaudeResetLimits,
                        allowsStaleClaudeResetDisplay: menuBar.allowsStaleClaudeResetDisplay,
                        codexLimits: displayedCodexLimits,
                        codexResetLimits: menuBar.currentCodexResetLimits,
                        serviceStatus: providerAvailability.claudeCode
                            ? serviceStatus.status
                            : .operational,
                        codexServiceStatus: providerAvailability.codex
                            ? codexServiceStatus.status
                            : .operational,
                        showsClaudeCode: providerAvailability.claudeCode,
                        showsCodex: providerAvailability.codex
                    )
                    emptyRangeState
                    AllTimeStatisticsSection(
                        history: statistics?.history,
                        errorMessage: statistics?.errorMessage
                    )
                }
                .padding(.horizontal, Spacing.xl)
                .padding(.bottom, Spacing.xl)
            }
        }
    }

    // MARK: - States

    /// "Indexing", with how far the pass has got once it knows how many files it has to read.
    private var indexingLabel: String {
        guard let progress = model.indexProgress, progress.filesTotal > 0 else { return "Indexing" }
        return "Indexing \(Int((progress.fractionCompleted * 100).rounded(.down)))%"
    }

    @ViewBuilder
    private var indexingState: some View {
        VStack(spacing: Spacing.sm) {
            if let progress = model.indexProgress, progress.filesTotal > 0 {
                ProgressView(value: progress.fractionCompleted) {
                    Text("Indexing transcripts\u{2026}")
                }
                .frame(maxWidth: 260)
            } else {
                ProgressView("Indexing transcripts\u{2026}")
                    .controlSize(.regular)
            }
            Text("Building the local analytics index. This takes a moment on first launch.")
                .textStyle(.detail)
                .foregroundStyle(Palette.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var loadingState: some View {
        ProgressView("Loading\u{2026}")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var emptyRangeState: some View {
        VStack(spacing: Spacing.sm) {
            Image(systemName: "chart.bar.xaxis")
                .iconSize(.hero)
                .foregroundStyle(Palette.textSecondary)
            Text("No usage in this range")
                .textStyle(.headline)
                .foregroundStyle(Palette.textSecondary)
            Text("Try a wider range or wait for an installed coding tool to record more sessions.")
                .textStyle(.detail)
                .foregroundStyle(Palette.textSecondary.opacity(0.7))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
        .padding(.top, 40)
    }

    @ViewBuilder
    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Palette.warn)
            Text(message)
                .textStyle(.detail)
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(2)
            Spacer()
            Button("Retry") { model.load() }
                .textStyle(.detail)
                .foregroundStyle(Palette.accent)
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.xs)
        .panelCard()
        .padding(.horizontal, Spacing.xl)
        .padding(.top, Spacing.md)
    }
}

// MARK: - Progressive-blur header

/// Toolbar backdrop with a progressive (gradient) blur: a material masked by a vertical
/// gradient — fully frosted at the top, fading to clear at the bottom — so content scrolling
/// underneath dissolves into blur instead of stopping at a hard edge. A matching slate
/// gradient keeps the bar on-brand and the controls legible.
private struct ProgressiveBlurHeader: View {
    let height: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            // The only translucent surface in the app that had no opaque path at all. It still
            // has to fade — it exists so content scrolling under the toolbar stays legible —
            // so the opaque form keeps the same mask and swaps the material for a flat fill.
            Rectangle()
                .fill(SnapshotConfig.opaqueSurfaces(reduceTransparency: reduceTransparency)
                      ? AnyShapeStyle(Palette.bg)
                      : AnyShapeStyle(.regularMaterial))
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .black, location: 0.0),
                            .init(color: .black, location: 0.6),
                            .init(color: .clear, location: 1.0)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            LinearGradient(
                colors: [Palette.bg.opacity(0.55), Palette.bg.opacity(0.0)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .allowsHitTesting(false)
    }
}

// MARK: - Dashboard window background

/// Translucent Liquid Glass window background. On macOS 15+ uses `containerBackground`
/// (`.window`) with an ultra-thin material over a non-opaque window, lightly tinted toward
/// Quarried Slate — the desktop refracts through the margins and gaps between the solid
/// content cards. Snapshots and macOS 14 fall back to an opaque slate fill.
private struct DashboardWindowBackground: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder
    func body(content: Content) -> some View {
        if SnapshotConfig.opaqueSurfaces(reduceTransparency: reduceTransparency) {
            content.background(Palette.bg)
        } else if #available(macOS 15.0, *) {
            content
                .containerBackground(for: .window) {
                    ZStack {
                        // Frosted blur of the desktop for a living, glassy quality...
                        Rectangle().fill(.regularMaterial)
                        // ...but the slate gradient dominates (~62%) so the window stays
                        // Quarried Slate on ANY wallpaper — dark, light, or busy — instead
                        // of turning muddy gray. A subtle top→bottom shift adds depth.
                        LinearGradient(
                            colors: [Palette.bg.opacity(0.60), Palette.surface.opacity(0.66)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    }
                }
                .background(TransparentWindow())
        } else {
            content.background(Palette.bg)
        }
    }
}

// MARK: - DashboardContent

/// The scrollable body of the dashboard — extracted so it can be rendered
/// by ImageRenderer (which cannot render inside a ScrollView) in SnapshotRunner.
@MainActor
struct DashboardContent: View {
    let summary: UsageSummary?
    let limits: UsageLimits?
    var claudeResetLimits: UsageLimits? = nil
    var allowsStaleClaudeResetDisplay = false
    var codexLimits: UsageLimits? = nil
    var codexResetLimits: UsageLimits? = nil
    /// Accounts currently stored. Defaults to 1 (the pre-multi-account behavior) for the
    /// snapshot/demo harness, which doesn't wire an `AccountsViewModel` into this view.
    var accountCount: Int = 1
    /// All-time calendar history (activity heatmap, streak tiles, punchcard), shown on every
    /// range under its own header — sourced from the durable `StatsRollup`, never from
    /// `summary` above (see `UsageRange`'s doc comment for why the two cannot be merged into
    /// one source). `nil` before the rollup has produced anything, e.g. a fresh install.
    var statisticsHistory: StatsHistory? = nil
    var statisticsErrorMessage: String? = nil
    /// Whether Claude Code itself is healthy. A plain value (defaulted, like the harness-
    /// friendly parameters above) rather than the store, so the snapshot harness can render
    /// this content straight from a fixture bundle. `.operational` draws nothing.
    var serviceStatus: ServiceStatus = .operational
    var codexServiceStatus: ServiceStatus = .operational
    /// Claude owns transcript analytics, Anthropic status and the original limits feed.
    /// Codex-only installs use the same view for their limits without revealing any of those
    /// Claude-specific sections.
    var showsClaudeCode: Bool = true
    var showsCodex: Bool = false

    @State private var isVisible = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            // First, above everything: when Anthropic reports a problem, that is the fact
            // that explains the session the user is having. Shares index 0 with the limits
            // strip below — a deterministic entrance, not a race.
            //
            // The disruption test is here as well as inside the banner so the healthy case
            // leaves NO subview behind: a zero-height child still earns its share of the
            // stack's spacing, which is exactly the empty banner slot this feature promised
            // never to show. It reads the value it was handed, never `onAppear` state, so
            // offscreen rendering resolves it identically.
            if showsClaudeCode, serviceStatus.isDisrupted {
                ServiceStatusBannerFull(status: serviceStatus, provider: .claudeCode)
                    .staggerIn(index: 0, isVisible: isVisible)
            }
            if showsCodex, codexServiceStatus.isDisrupted {
                ServiceStatusBannerFull(status: codexServiceStatus, provider: .codex)
                    .staggerIn(index: 0, isVisible: isVisible)
            }

            // Rate limits strip
            if showsClaudeCode, let limits {
                limitsSection(
                    limits,
                    provider: "CLAUDE",
                    claudeResets: claudeResetLimits,
                    allowsStaleClaudeResetDisplay: allowsStaleClaudeResetDisplay
                )
                    .staggerIn(index: 0, isVisible: isVisible)
            } else if showsClaudeCode, let claudeResetLimits {
                resetOnlySection(
                    provider: "CLAUDE",
                    claudeResets: claudeResetLimits,
                    allowsStaleClaudeResetDisplay: allowsStaleClaudeResetDisplay
                )
                    .staggerIn(index: 0, isVisible: isVisible)
            }
            if showsCodex, let codexLimits {
                limitsSection(codexLimits, provider: "CODEX", showsAccountScope: false, resets: codexResetLimits)
                    .staggerIn(index: 0, isVisible: isVisible)
            }

            // Analytics come from local transcript files, which carry no account
            // identity — with more than one account stored, this header says so, so the
            // totals below aren't misread as belonging only to the active account.
            if let summary {
                usageHeader
                    .staggerIn(index: 1, isVisible: isVisible)

                // Summary KPI row
                SummaryCardsRow(summary: summary)
                    .staggerIn(index: 1, isVisible: isVisible)

                // Second row: sparkline trend + by-model breakdown (equal heights)
                HStack(alignment: .top, spacing: Spacing.md) {
                    TrendCard(buckets: summary.buckets, bucketSize: summary.bucketSize)
                        .frame(maxWidth: .infinity)

                    ByModelCard(byModel: summary.byModel)
                        .frame(maxWidth: .infinity)
                }
                .frame(height: 240)
                .staggerIn(index: 2, isVisible: isVisible)

                // Third row: top projects
                if !summary.byProject.isEmpty {
                    TopProjectsCard(byProject: summary.byProject)
                        .staggerIn(index: 3, isVisible: isVisible)
                }

                // Fourth row: all-time calendar history.
                statisticsSection
                    .staggerIn(index: 4, isVisible: isVisible)
            }
        }
        .onAppear {
            isVisible = true
        }
    }

    // MARK: - Calendar history (reused from StatisticsView, not restyled)

    /// See `AllTimeStatisticsSection` — shared with the empty-range branch of
    /// `DashboardView.usageScroll`, which is why it is not a private builder here.
    private var statisticsSection: some View {
        AllTimeStatisticsSection(history: statisticsHistory, errorMessage: statisticsErrorMessage)
    }

    // MARK: - Usage header

    @ViewBuilder
    private var usageHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
            SectionHeader("Usage")
            if accountCount > 1 {
                Text("\u{2014} across all accounts")
                    .textStyle(.detail)
                    .foregroundStyle(Palette.textSecondary.opacity(0.8))
            }
        }
    }

    // MARK: - Limits section

    @ViewBuilder
    private func limitsSection(
        _ limits: UsageLimits,
        provider: String,
        showsAccountScope: Bool = true,
        claudeResets: UsageLimits? = nil,
        allowsStaleClaudeResetDisplay: Bool = false,
        resets: UsageLimits? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            // These gauges are the ACTIVE account's, but they sit directly above the
            // all-accounts usage totals — so with more than one account stored, say whose
            // limits these are to keep the two figures from being conflated.
            HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                SectionHeader("\(provider) LIMITS")
                if showsAccountScope, accountCount > 1 {
                    Text("\u{2014} active account")
                        .textStyle(.detail)
                        .foregroundStyle(Palette.textSecondary.opacity(0.8))
                }
                Spacer(minLength: Spacing.xs)
                if let claudeResets {
                    ClaudeResetsView(
                        limits: claudeResets,
                        allowsStaleDisplay: allowsStaleClaudeResetDisplay
                    )
                }
                if let resets {
                    BankedResetsView(limits: resets)
                }
            }
            LimitsStrip(limits: limits, uppercaseTitles: provider != "CODEX")
                .padding(Spacing.md)
                .panelCard()
        }
    }

    @ViewBuilder
    private func resetOnlySection(
        provider: String,
        claudeResets: UsageLimits,
        allowsStaleClaudeResetDisplay: Bool
    ) -> some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            if let resets = claudeResets.claudeResets,
               resets.displayState(
                   fetchedAt: claudeResets.fetchedAt,
                   now: context.date,
                   allowsStale: allowsStaleClaudeResetDisplay
               ) != .hidden {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                    SectionHeader("\(provider) LIMITS")
                    if accountCount > 1 {
                        Text("\u{2014} active account")
                            .textStyle(.detail)
                            .foregroundStyle(Palette.textSecondary.opacity(0.8))
                    }
                    Spacer(minLength: Spacing.xs)
                    ClaudeResetsView(
                        limits: claudeResets,
                        allowsStaleDisplay: allowsStaleClaudeResetDisplay
                    )
                }
            }
        }
    }
}

// MARK: - All-time statistics section

/// The Usage tab's all-time block — header, optional error banner, and the calendar history
/// (`StatisticsContent`: heatmap, streak tiles, punchcard), all sourced from the durable
/// `StatsRollup`. A view of its own because it is rendered from TWO places: below
/// `DashboardContent` when the selected range has index data, and below the empty-range
/// state when it has none — the rollup does not care which range is selected, so neither
/// may hide this block. Shows nothing at all (not even the header) when there is neither
/// history nor an error, so a fresh install stays blank rather than showing a heading over
/// empty space.
struct AllTimeStatisticsSection: View {
    /// `nil` before the rollup has produced anything, e.g. a fresh install.
    let history: StatsHistory?
    let errorMessage: String?

    var body: some View {
        let hasHistory = (history?.allTimeRequests ?? 0) > 0
        if errorMessage != nil || hasHistory {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                header
                if let errorMessage {
                    errorBanner(errorMessage)
                }
                if hasHistory, let history {
                    StatisticsContent(history: history)
                }
            }
        }
    }

    /// Names the scope of the block below it, the way `DashboardContent.usageHeader` names
    /// the scope of the cards above: this history is all-time and is NOT filtered by the
    /// range selector.
    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
            SectionHeader("All-time statistics")
            Text("\u{2014} every day on record, whatever range is selected above")
                .textStyle(.detail)
                .foregroundStyle(Palette.textSecondary.opacity(0.8))
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Palette.warn)
            Text(message)
                .textStyle(.detail)
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(2)
            Spacer()
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.xs)
        .panelCard()
    }
}

// MARK: - Section switch (Usage | Machine | Accounts | Settings)

/// Compact 2-item pill switch for the top-level dashboard section, styled to
/// match `SegmentedControl`'s tray/pill visual language (Radius.element tray,
/// matchedGeometryEffect sliding selection) but bound to the local
/// `DashboardSection` enum rather than `DashboardViewModel.Range`.
private struct SectionSwitch: View {
    @Binding var selection: DashboardSection
    let items: [DashboardSection]
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items, id: \.self) { item in
                segment(for: item)
            }
        }
        // Names the set the four buttons belong to, so a screen-reader user hears
        // "Section, Usage, selected" instead of four unrelated buttons.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Section")
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: Radius.element, style: .continuous)
                .fill(Palette.textPrimary.opacity(0.06))
        )
        // Was a fixed 540 for 5 segments (108pt each) before the Statistics tab retired into
        // Usage; 4 segments at the same per-item width.
        .frame(
            minWidth: CGFloat(items.count) * 82.5,
            maxWidth: CGFloat(items.count) * 108
        )
        .frame(height: 30)
        .fixedSize(horizontal: false, vertical: true)
        .animation(.spring(response: 0.28, dampingFraction: 0.85), value: selection)
    }

    private func label(for item: DashboardSection) -> String {
        switch item {
        case .usage:       return "Usage"
        case .machine:     return "Machine"
        case .accounts:    return "Accounts"
        case .settings:    return "Settings"
        }
    }

    @ViewBuilder
    private func segment(for item: DashboardSection) -> some View {
        let isSelected = selection == item

        Button {
            selection = item
        } label: {
            ZStack {
                if isSelected {
                    SectionSwitchPill()
                        .matchedGeometryEffect(id: "section_switch_selection", in: namespace)
                }

                Text(label(for: item))
                    // `label`, not `body`: this is a tab label inside the fixed-width five-segment
                    // strip, not running prose. `body` (13pt) truncated "Environment" to "Environm…"
                    // at this width when that was still its own tab — the size table applied too
                    // literally. `label` (11pt medium) is both semantically right (a tab label IS
                    // a label) and fits without widening the strip.
                    .textStyle(.label)
                    .foregroundStyle(isSelected ? Palette.textPrimary : Palette.textSecondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, minHeight: 24)
                    .padding(.horizontal, Spacing.xs)
                    .contentShape(Rectangle())
            }
        }
        .buttonStyle(SegmentButtonStyle())
        .segmentFocusRing()
        // Appearance already says which tab is current; this is the same fact said out loud,
        // so a screen-reader user can tell the active section from the other three.
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// The raised pill behind the selected `SectionSwitch` label — mirrors
/// `SelectedPillBackground` from SegmentedControl.swift.
private struct SectionSwitchPill: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        RoundedRectangle(cornerRadius: 11, style: .continuous)
            .fill(scheme == .light ? Palette.card : Palette.surface)
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(Palette.hairline, lineWidth: 0.5)
            )
            .shadow(color: Color.black.opacity(0.10), radius: 1, x: 0, y: 0.5)
    }
}
