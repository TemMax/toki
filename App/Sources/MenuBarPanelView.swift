import AppKit
import SwiftUI
import TokiCore
import TokiAccounts

/// Popover panel displayed when the user clicks the Toki menu-bar item.
/// Shows live rate-limit gauges (5h / 7d / Opus / Sonnet) and provides
/// navigation to the dashboard. Uses the glass design system.
struct MenuBarPanelView: View {
    @Environment(\.openWindow) private var openWindow

    // Dismisses the menu-bar popover window (so opening the dashboard/settings closes it).
    @Environment(\.dismiss) private var dismiss

    var menuBar: MenuBarViewModel
    var dashboard: DashboardViewModel
    // Both of these used to be optional, justified by a comment saying the demo/snapshot
    // harness "never sets this up". It does. All four construction sites — TokiApp,
    // SnapshotRunner (twice) and the debug control channel — pass `container.accountsVM` and
    // `container.navigation`, and both are non-optional `let`s on `ServiceContainer`. The
    // optionality was unreachable, and it was not free: it bought two fallback branches in
    // the header that no run of this app could enter, so they could never be reviewed by
    // looking at the thing they drew.
    var accounts: AccountsViewModel
    var codexAccounts: CodexAccountsViewModel
    // Shared tab selection — the footer's Settings button routes into the dashboard's
    // Settings tab.
    var navigation: DashboardNavigation
    /// The one owner of Claude Code's service status (`ServiceContainer.serviceStatus`);
    /// this view observes it and draws nothing while the service is healthy.
    var serviceStatus: ServiceStatusStore
    var codexServiceStatus: ServiceStatusStore
    let providerAvailability: ProviderAvailability

    var body: some View {
        mainPanel
    }

    private var mainPanel: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            headerRow
            // Above the gauges: when Claude Code itself is down, that explains what the
            // user is actually experiencing, and no amount of remaining quota changes it.
            // The healthy case leaves no subview at all — a zero-height child would still
            // earn its share of this stack's spacing, i.e. an empty banner slot.
            if providerAvailability.claudeCode, serviceStatus.status.isDisrupted {
                ServiceStatusBannerCompact(status: serviceStatus.status, provider: .claudeCode)
            }
            if providerAvailability.codex, codexServiceStatus.status.isDisrupted {
                ServiceStatusBannerCompact(status: codexServiceStatus.status, provider: .codex)
            }
            if showsClaudeUsage || showsCodexUsage {
                bodyContent
            }
            footerRow
        }
        .padding(Spacing.md)
        .frame(width: 320, alignment: .top)
        .glassPanel()
        .background(GlassPanelWindow())   // transparent popover window + single clipped squircle corner
        .task {
            // Background polling is started at launch by ServiceContainer and
            // runs regardless of this popover. Opening it just refreshes now.
            if providerAvailability.claudeCode {
                menuBar.refreshNow()
                serviceStatus.refreshNow()
                dashboard.triggerInitialIndex()
                // Re-read the signed-in account so a switch shows up on next open.
                dashboard.refreshAccount()
                accounts.load()
            }
            if providerAvailability.codex {
                menuBar.refreshCodexNow()
                codexServiceStatus.refreshNow()
                codexAccounts.load()
            }
        }
    }

    /// Brings the dashboard window to the front even when it is already open but
    /// covered by other apps' windows. `openWindow` alone won't reorder an existing
    /// window, and an `.accessory` app won't come forward on its own.
    private func bringDashboardToFront() {
        activateAsRegularApp(orderingFrontWindowTitled: "Toki Dashboard")
    }

    // MARK: - Header

    private var headerRow: some View {
        // Account identity moved into provider-scoped rows below, leaving this line as the
        // stable app header and the existing Claude feed status at the trailing edge.
        HStack(spacing: Spacing.xs) {
            AppIconBadge(size: 30)

            Text("Toki")
                .textStyle(.title)
                .foregroundStyle(Palette.textPrimary)

            Spacer()

            if providerAvailability.claudeCode {
                statePill
            }
        }
    }

    @ViewBuilder
    private var statePill: some View {
        switch menuBar.state {
        case .loading:
            StatusPill(text: "Loading", color: Palette.accent, active: true)
        case .ok:
            // Healthy is the state this popover is in almost every time it opens, so a
            // "Live" pill is on permanently — an indicator that never changes carries no
            // signal, only noise. Silence here means the pill's *presence* is the signal.
            EmptyView()
        case .stale(let d):
            StatusPill(text: relativeAge(since: d), color: Palette.warn)
        case .notLoggedIn:
            StatusPill(text: "Offline", color: Palette.textSecondary)
        case .needsAccess:
            StatusPill(text: "Access needed", color: Palette.warn)
        case .error:
            StatusPill(text: "Error", color: Palette.critical)
        }
    }

    // MARK: - Body

    /// An explicit all-off selection removes the provider's entire usage group. While at
    /// least one value remains selected, loading/connection/error states still have a place
    /// to explain why the selected value is not currently available.
    private var showsClaudeUsage: Bool {
        providerAvailability.claudeCode
            && menuBar.usageDisplayConfiguration[.claudeCode].isEnabled
    }

    private var showsCodexUsage: Bool {
        providerAvailability.codex
            && menuBar.usageDisplayConfiguration[.codex].isEnabled
    }

    @ViewBuilder
    private var bodyContent: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            if showsClaudeUsage {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                    SectionHeader("Claude")
                    if let resets = menuBar.currentClaudeResetLimits {
                        ClaudeResetsView(
                            limits: resets,
                            allowsStaleDisplay: menuBar.allowsStaleClaudeResetDisplay
                        )
                    }
                    Spacer(minLength: Spacing.xs)
                    ClaudeAccountMenu(model: accounts, signedInLabel: dashboard.signedInLabel)
                        .frame(maxWidth: 175, alignment: .trailing)
                }
                if let message = accounts.errorMessage {
                    accountError(message)
                }
                claudeContent
            }

            if showsCodexUsage {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                    SectionHeader("Codex")
                    if let resets = menuBar.currentCodexResetLimits {
                        BankedResetsView(limits: resets)
                    }
                    Spacer(minLength: Spacing.xs)
                    CodexAccountMenu(model: codexAccounts)
                        .frame(maxWidth: 190, alignment: .trailing)
                }
                .padding(.top, showsClaudeUsage ? Spacing.xxs : 0)
                if let message = codexAccounts.errorMessage {
                    accountError(message)
                }
                codexContent
            }
        }
    }

    private func accountError(_ message: String) -> some View {
        Text(message)
            .textStyle(.caption)
            .foregroundStyle(Palette.critical)
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var claudeContent: some View {
        switch menuBar.state {
        case .loading:
            loadingState

        case .notLoggedIn:
            notLoggedInState
        case .needsAccess:
            keychainAccessState

        case .ok, .stale:
            claudeLimitsState

        case .error(let msg):
            errorState(message: msg)
        }
    }

    // Loading
    private var loadingState: some View {
        HStack {
            Spacer()
            VStack(spacing: Spacing.xs) {
                ProgressView()
                Text("Loading usage\u{2026}")
                    .textStyle(.detail)
                    .foregroundStyle(Palette.textSecondary)
            }
            Spacer()
        }
        .padding(.vertical, Spacing.lg)
    }

    // Not logged in
    private var notLoggedInState: some View {
        VStack(spacing: Spacing.sm) {
            Image(systemName: "lock.shield")
                .iconSize(.hero)
                .foregroundStyle(Palette.textSecondary)
            Text("Not connected")
                .textStyle(.headline)
                .foregroundStyle(Palette.textPrimary)
            Text("Open the Claude CLI to sign in. Toki picks up the session automatically.")
                .textStyle(.detail)
                .foregroundStyle(Palette.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(Spacing.md)
        .panelCard(rimBright: true)
    }

    // Error
    private var keychainAccessState: some View {
        VStack(spacing: Spacing.sm) {
            Image(systemName: "key.fill")
                .iconSize(.hero)
                .foregroundStyle(Palette.warn)
            Text("Claude access needed")
                .textStyle(.headline)
            Text("Toki needs permission to read your Claude session. Reconnect to restore live limits.")
                .textStyle(.detail)
                .foregroundStyle(Palette.textSecondary)
                .multilineTextAlignment(.center)
            Button("Reconnect Claude") {
                reconnectClaude()
            }
            .buttonStyle(.borderedProminent)
            .tint(Palette.accent)
        }
        .frame(maxWidth: .infinity)
        .padding(Spacing.md)
        .panelCard(rimBright: true)
    }

    private func errorState(message: String) -> some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(Palette.critical)
            Text(message)
                .textStyle(.detail)
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(3)
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelCard(rimBright: true)
    }

    // Limits (ok + stale share same layout)
    @ViewBuilder
    private var claudeLimitsState: some View {
        if let limits = menuBar.displayedLimits(for: .claudeCode) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                if !limits.windows.isEmpty {
                    limitsCard(limits)
                }

                extraUsageSection(extra: limits.extra)

                // Always distinguish retained values from live usage.
                if case .stale = menuBar.state {
                    outdatedWarning(provider: "Claude")
                    if menuBar.claudeNeedsReconnect {
                        Button("Reconnect Claude") {
                            reconnectClaude()
                        }
                    }
                }
            }
        }
    }

    // Codex is a separate feed: its failure state never replaces the Claude section above.
    @ViewBuilder
    private var codexContent: some View {
        switch menuBar.codexState {
        case .loading:
            HStack(spacing: Spacing.xs) {
                ProgressView()
                    .controlSize(.small)
                Text("Loading Codex usage…")
                    .textStyle(.detail)
                    .foregroundStyle(Palette.textSecondary)
            }
            .padding(Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .panelCard(rimBright: true)

        case .notLoggedIn, .needsAccess:
            codexConnectionState(
                icon: "terminal",
                title: "Codex isn’t connected",
                detail: "Run codex login and sign in with ChatGPT."
            )

        case .error(let message):
            errorState(message: message)

        case .ok, .stale:
            if let limits = menuBar.displayedLimits(for: .codex) {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    if !limits.windows.isEmpty {
                        limitsCard(limits, uppercaseTitles: false)
                    }
                    if case .stale(let fetchedAt) = menuBar.codexState,
                       Date().timeIntervalSince(fetchedAt) > 3600 {
                        outdatedWarning(provider: "Codex")
                    }
                }
            } else {
                codexConnectionState(
                    icon: "terminal",
                    title: "No Codex limits",
                    detail: "Open Codex once, then refresh Toki."
                )
            }
        }
    }

    private func codexConnectionState(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: Spacing.xs) {
            Image(systemName: icon)
                .foregroundStyle(Palette.textSecondary)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(title)
                    .textStyle(.label)
                    .foregroundStyle(Palette.textPrimary)
                Text(detail)
                    .textStyle(.detail)
                    .foregroundStyle(Palette.textSecondary)
            }
        }
        .padding(Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelCard(rimBright: true)
    }

    private func limitsCard(_ limits: UsageLimits, uppercaseTitles: Bool = true) -> some View {
        // Spacing.md keeps each reset countdown visually attached to its own gauge.
        VStack(spacing: Spacing.md) {
            ForEach(limits.windows) { window in
                if window.isAvailable {
                    CapsuleGauge(
                        title: window.title,
                        fraction: window.utilization,
                        detail: ResetCountdown.text(for: window.resetsAt),
                        uppercaseTitle: uppercaseTitles
                    )
                } else {
                    unavailableWindowRow(title: window.title)
                }
            }
        }
        .padding(Spacing.sm)
        .panelCard(rimBright: true)
    }

    /// A window the API reports no data for. It used to occupy a full gauge slot — an
    /// empty track under an "unavailable" pill — which spent a bar, a percentage slot and
    /// a caption slot to say one word. Collapsed to a single row inside the same card, it
    /// still carries both facts the gauge carried: which window it is, and that it has no
    /// data (there is no percentage and no reset time to lose — the gauge suppressed both).
    private func unavailableWindowRow(title: String) -> some View {
        HStack {
            Text(title)
                .textStyle(.label)
                .kerning(0.4)
                .foregroundStyle(Palette.textSecondary)
                .textCase(.uppercase)

            Spacer()

            Text("unavailable")
                .textStyle(.caption)
                .foregroundStyle(Palette.textSecondary)
        }
    }

    /// Extra usage, at the weight the situation deserves.
    ///
    /// A full header + card is worth a third of this popover, so it is reserved for when
    /// credits are actually in play: money has been spent, or the cap has been reached.
    /// Merely *enabled* — the standing state for anyone who turned it on and never hit the
    /// included limits — collapses to one row that still states the amounts the card's
    /// gauge detail would have shown.
    ///
    /// WHICH of the three forms is not decided here — `ExtraUsage.prominence` owns that rule,
    /// in `TokiModels`, where `swift test` can reach it. This view only draws what it is told.
    @ViewBuilder
    private func extraUsageSection(extra: ExtraUsage?) -> some View {
        if let extra {
            switch extra.prominence {
            case .card:
                SectionHeader("Extra Usage")
                    .padding(.top, Spacing.xxs)

                VStack(spacing: Spacing.sm) {
                    CapsuleGauge(
                        title: "Credits",
                        fraction: extra.utilization ?? 0,
                        detail: extraDetail(extra: extra)
                    )
                }
                .padding(Spacing.sm)
                .panelCard(rimBright: true)

            case .line:
                HStack {
                    Text("Extra usage")
                        .textStyle(.detail)
                        .foregroundStyle(Palette.textSecondary)

                    Spacer()

                    // "on" only when there are no amounts to report at all — the row must
                    // still say something true rather than collapse to a bare label.
                    Text(extraDetail(extra: extra) ?? "on")
                        .textStyle(.detail)
                        .foregroundStyle(Palette.textSecondary)
                }

            case .hidden:
                EmptyView()
            }
        }
    }

    private func outdatedWarning(provider: String) -> some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Palette.warn)
                .imageScale(.small)
            Text("\(provider) data may be outdated")
                .textStyle(.caption)
                .foregroundStyle(Palette.warn)
        }
        .padding(.horizontal, Spacing.xs)
        .padding(.top, Spacing.xxs)
    }

    // MARK: - Footer

    /// Explicit repair leaves the popover, routes through the dashboard-hosted onboarding
    /// UI, and foregrounds that window before the protected credential read begins.
    private func reconnectClaude() {
        dismiss()
        NotificationCenter.default.post(name: .tokiReconnectClaude, object: nil)
        activateAsRegularApp(orderingFrontWindowTitled: "Toki Dashboard")
    }

    private var footerRow: some View {
        // Dashboard / Settings / Quit in one row. The dashboard window hosts Usage,
        // Instances, Environment, Accounts, and Settings as tabs, so both buttons open
        // that one window — Settings just selects its Settings tab first.
        //
        // Not three equal thirds any more. Dashboard is where this popover sends you and
        // is the one affirmative action here, so it takes `.prominent` and leads the row;
        // Settings and Quit are `.secondary` and sized to their own labels. Quit in
        // particular is the rarest action and the only irreversible one — it has no
        // business weighing the same as Dashboard.
        HStack(spacing: Spacing.xxs) {
            Button {
                dismiss()   // close the popover first (it is the key window here)
                openWindow(id: "dashboard")
                activateAsRegularApp(orderingFrontWindowTitled: "Toki Dashboard")
            } label: {
                footerLabel("Dashboard", icon: "chart.bar.fill")
            }
            .buttonStyle(TokiButtonStyle(role: .prominent))

            Spacer(minLength: 0)

            Button {
                dismiss()   // close the popover first (it is the key window here)
                navigation.section = .settings
                openWindow(id: "dashboard")
                activateAsRegularApp(orderingFrontWindowTitled: "Toki Dashboard")
            } label: {
                footerLabel("Settings", icon: "gear")
            }
            .buttonStyle(TokiButtonStyle(role: .secondary))

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                footerLabel("Quit", icon: "power")
            }
            .buttonStyle(TokiButtonStyle(role: .secondary))
        }
    }

    private func footerLabel(_ label: String, icon: String) -> some View {
        HStack(spacing: Spacing.xxs) {
            Image(systemName: icon)
                .imageScale(.small)
            Text(label)
        }
        .textStyle(.label)
    }

    // MARK: - Helpers


    private func extraDetail(extra: ExtraUsage) -> String? {
        let amounts: String? = if let used = extra.usedCredits, let cap = extra.monthlyLimit {
            "\(extra.amountString(used)) of \(extra.amountString(cap))"
        } else if let used = extra.usedCredits {
            extra.amountString(used)
        } else {
            nil
        }
        guard extra.spendLimitReached else { return amounts }
        guard let amounts else { return "limit reached" }
        return "\(amounts) — limit reached"
    }

    private func relativeAge(since date: Date) -> String {
        let elapsed = Date().timeIntervalSince(date)
        let minutes = Int(elapsed / 60)
        if minutes < 1 { return "Just now" }
        if minutes == 1 { return "1m ago" }
        let hours = minutes / 60
        if hours < 1 { return "\(minutes)m ago" }
        let days = hours / 24
        if days < 1 { return "\(hours)h ago" }
        return "\(days)d ago"
    }
}
