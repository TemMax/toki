/// SettingsSections — the scrollable Settings content, rendered as the dashboard's
/// Settings tab (there is no standalone Settings window).
///
/// Uses only design-system primitives (panelCard, Palette, SectionHeader,
/// Spacing, Radius). It is CONTENT ONLY: the floating toolbar, window background,
/// framing, and the top inset that starts the content below that toolbar (and lets it
/// scroll under) all come from `DashboardView`.
///
/// Sections:
///  - General      : Launch at Login toggle (SMAppService)
///  - Menu Bar     : one row — title, description, and a button that opens the dedicated
///                   editor (`MenuBarEditorView`, a `.sheet`) for `MenuBarConfiguration` /
///                   `MenuBarStyle`: the preview, indicator list and style controls all live
///                   there now, not inline in this list.
///  - Notifications: one row — the editor (`NotificationsEditorView`, a `.sheet`) that owns
///                   EVERY notification Toki sends: the rate-limit threshold rules and the
///                   four account events. Deliberately the only place any of them is switched
///                   on or off.
///  - About        : app identity, version/build
///  - Diagnostics  : log retention, the log-export/reveal buttons and the verbose-logging
///                   toggle. Its markup lives in `DiagnosticsSection.swift`.
///  - Data Sources : how live limits and analytics are sourced (Keychain + local files)
///  - Accounts     : auto-swap policy (off by default) — which windows to watch,
///                   thresholds, cooldown, and swap notifications
import AppKit
import SwiftUI
import TokiAutoSwap
import TokiCore
import TokiMenuBar

private let log = TokiLog.logger("settings")

// MARK: - SettingsSections

@MainActor
struct SettingsSections: View {

    /// Extra top padding for callers that render this section OUTSIDE the dashboard — the
    /// snapshot harness and the debug control channel, which give it a plain margin instead.
    /// As a dashboard tab it is 0: clearing the floating toolbar is `DashboardView`'s job
    /// now, done once for all four tabs (`Measure.dashboardContentTop`).
    var topInset: CGFloat = 0

    /// The single owner of the menu-bar indicator configuration and the live limits it
    /// resolves against — this section reads and writes through it rather than caching a
    /// second copy, the same way `MenuBarViewModel` itself forwards to
    /// `MenuBarConfigurationState` and `LiveLimits`.
    @Bindable var menuBar: MenuBarViewModel
    let providerAvailability: ProviderAvailability

    @EnvironmentObject private var updater: UpdaterController
    @State private var launchAtLogin = LaunchAtLogin()
    @State private var isVisible = false
    /// Whether the dedicated menu-bar editor sheet (`MenuBarEditorView`) is open — the only
    /// state this section owns for it; the editor reads and writes `menuBar.configuration`
    /// directly, the same single owner as everywhere else.
    @State private var isPresentingMenuBarEditor = false
    /// Whether the notifications editor sheet (`NotificationsEditorView`) is open. Same shape
    /// as the menu-bar editor above: this section owns nothing but the flag — the editor reads
    /// and writes `NotificationSettingsStore`, the single home of that value.
    @State private var isPresentingNotificationsEditor = false
    /// Auto-swap editors stay in this view hierarchy instead of using a system sheet so the
    /// selected compact card can morph into the editor and back with matched geometry.
    @State private var editingAutoSwapProvider: UsageProvider?
    /// The panel surface starts moving before its detailed controls appear. Keeping those
    /// phases separate makes the shared element read as one card changing bounds instead of
    /// two fully rendered layouts cross-fading through each other.
    @State private var isAutoSwapEditorContentVisible = false
    @Namespace private var autoSwapTransition
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// JSON-encoded `AutoSwapSettings`, defaulting to `AutoSwapSettings.default` when
    /// absent or corrupt. Read by `AutoSwapDriver` (via `ServiceContainer`) under the
    /// same key.
    @AppStorage("toki.autoSwapSettings") private var autoSwapSettingsJSON = ""
    /// Read by `StatuslineUsageDriver`, which installs or removes the tap as it flips.
    @AppStorage(StatuslineUsageDriver.enabledKey) private var isStatuslineUsageEnabled = true
    /// Absent in the snapshot harness and previews, which show the section's generic copy.
    @Environment(StatuslineUsageDriver.self) private var statuslineUsage: StatuslineUsageDriver?
    /// Codex has its own switch, thresholds and cooldown. It never inherits Claude's choice.
    @AppStorage("toki.codexAutoSwapSettings") private var codexAutoSwapSettingsJSON = ""

    // MARK: Diagnostics state
    // Not `private`, and `toggleRow`/`sourceRow` below are not private either, because the
    // DIAGNOSTICS section is an extension living in `DiagnosticsSection.swift` — Swift's
    // `private` stops at the file, so keeping that section's markup out of this 660-line
    // file costs exactly this much visibility and nothing else.

    /// Disables Export Logs… while one export is in flight, so a second panel cannot
    /// be opened on top of the first.
    @State var isExportingLogs = false
    /// The single owner of the verbosity setting is the `toki.verboseLogging` default itself:
    /// `TokiLog` observes `UserDefaults.didChangeNotification` and re-reads the key, so this
    /// toggle writes the value and nothing pushes it anywhere.
    @AppStorage(TokiLog.verboseDefaultsKey) var isVerboseLogging = false
    @State var logExport = LogExportService()
    @State private var notificationsUnavailable = false
    private let notifier = SwapNotifier()

    // MARK: Version info (read once; Bundle is safe on the main thread)
    private let appVersion: String = {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "\u{2014}"
    }()

    private let buildNumber: String = {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "\u{2014}"
    }()

    var body: some View {
        ZStack {
            ScrollView {
                // A settings row is a label at one edge and a small control at the other, so one
                // column across the dashboard's ~880 pt leaves a few hundred points of nothing
                // between them. Two columns of cards fill that width with content instead of
                // margin — the same move the Usage tab makes with its side-by-side cards.
                //
                // There is deliberately NO narrow fallback. `DashboardView` pins the window at
                // `.frame(minWidth: 860, minHeight: 540)`, so the content area is never narrower
                // than 812 pt — two columns of ~398 pt always clear. A `ViewThatFits` collapse was
                // written here first and removed: it could not execute in the app at any reachable
                // size, which made it a safety net that had never once been exercised. If that
                // `minWidth` is ever lowered, this is the code that needs a fallback again.
                twoColumnLayout
                    .padding(.horizontal, Spacing.xl)
                    .padding(.bottom, Spacing.xl)
                    .padding(.top, topInset)
            }
            .blur(radius: editingAutoSwapProvider == nil ? 0 : 1.5)
            .allowsHitTesting(editingAutoSwapProvider == nil)
            .accessibilityHidden(editingAutoSwapProvider != nil)

            if let provider = editingAutoSwapProvider {
                Color.black.opacity(0.18)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { closeAutoSwapEditor() }
                    .transition(.opacity.animation(.easeOut(duration: 0.12)))

                autoSwapEditorOverlay(provider: provider)
                    .zIndex(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onExitCommand {
            guard editingAutoSwapProvider != nil else { return }
            closeAutoSwapEditor()
        }
        .onAppear {
            launchAtLogin.refresh()
            isVisible = true
        }
        // Both sheets clear the dashboard's shared content inset. `DashboardView` sets it as
        // a content margin on the whole content area, and sheet content inherits the
        // environment of the view that presents it — so without this each editor opened with
        // a toolbar-sized empty band above its first card, insetting for a toolbar that is
        // not on the sheet. A sheet is its own surface and starts at its own top.
        .sheet(isPresented: $isPresentingMenuBarEditor) {
            MenuBarEditorView(menuBar: menuBar)
                .frame(height: MenuBarEditorView.sheetHeight)
                .contentMargins(.top, 0, for: .scrollContent)
        }
        .sheet(isPresented: $isPresentingNotificationsEditor) {
            NotificationsEditorView(menuBar: menuBar)
                .frame(height: NotificationsEditorView.sheetHeight)
                .contentMargins(.top, 0, for: .scrollContent)
        }
    }

    // MARK: - Layouts

    /// Wide layout: two card columns, balanced by rendered height rather than by section count.
    /// ACCOUNTS is four rows tall — on its own it is close to the other six stacked — so it
    /// anchors the leading column and everything short goes trailing. Nothing about a section's
    /// internals changes with the column it sits in; each still fills the width it is handed.
    ///
    /// The entrance still reads as one sweep: index 0 is the top of the leading column, and
    /// 1–6 run down the trailing one — GENERAL, MENU BAR, NOTIFICATIONS, UPDATES, DIAGNOSTICS,
    /// ABOUT, one per index so no two cards arrive together. DATA SOURCES joins at 3 because
    /// that is roughly the band it occupies — the eye follows the cards in the order it would
    /// read them, not all at once.
    ///
    /// Both columns anchor to `.topLeading`, NOT `.leading`. `Alignment.leading` is
    /// `(horizontal: .leading, vertical: .center)` — the vertical half is silent, and it is the
    /// half that mattered. Each column is wrapped in a half-width flexible frame, and that frame
    /// does not always come out exactly as tall as the stack inside it: at the dashboard's real
    /// content width the leading column's box measured one wrapped text line (16 pt) taller than
    /// its cards. A `.center` guide then split that leftover evenly, pushing every card in that
    /// column — header included — 8 pt down, so ACCOUNTS sat below GENERAL and each card below
    /// its neighbour. `HStack(alignment: .top)` already says these columns start together; the
    /// columns have to say the same thing about their own contents, or any leftover height in
    /// one of them re-centres the whole column.
    private var twoColumnLayout: some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                if providerAvailability.claudeCode {
                    liveUsageSection
                        .staggerIn(index: 0, isVisible: isVisible)
                    autoSwapSection(provider: .claudeCode)
                        .staggerIn(index: 0, isVisible: isVisible)
                }
                if providerAvailability.codex {
                    autoSwapSection(provider: .codex)
                        .staggerIn(index: 1, isVisible: isVisible)
                }
                if providerAvailability.hasAnyProvider {
                    usageDisplaySection
                        .staggerIn(index: 2, isVisible: isVisible)
                }
                dataSourcesSection
                    .staggerIn(index: 3, isVisible: isVisible)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)

            VStack(alignment: .leading, spacing: Spacing.lg) {
                generalSection
                    .staggerIn(index: 1, isVisible: isVisible)
                menuBarSection
                    .staggerIn(index: 2, isVisible: isVisible)
                notificationsSection
                    .staggerIn(index: 3, isVisible: isVisible)
                updatesSection
                    .staggerIn(index: 4, isVisible: isVisible)
                diagnosticsSection
                    .staggerIn(index: 5, isVisible: isVisible)
                aboutSection
                    .staggerIn(index: 6, isVisible: isVisible)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }


    // MARK: General

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            SectionHeader("GENERAL")

            VStack(alignment: .leading, spacing: Spacing.sm) {
                HStack(alignment: .center, spacing: Spacing.md) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Launch at Login")
                            .textStyle(.body)
                            .foregroundStyle(Palette.textPrimary)
                        Text("Start Toki automatically when you log in.")
                            .cardLabel()
                    }
                    Spacer(minLength: Spacing.md)
                    Toggle("", isOn: Binding(
                        get: { launchAtLogin.isEnabled },
                        set: { _ in launchAtLogin.toggle() }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(Palette.accent)
                }

                if let errorMessage = launchAtLogin.lastError {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .iconSize(.regular)
                            .foregroundStyle(Palette.warn)
                        Text(errorMessage)
                            .textStyle(.detail)
                            .foregroundStyle(Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .panelCard()
        }
    }

    // MARK: Menu Bar

    /// One row: title, one-line description, and a button that opens the dedicated editor
    /// (`MenuBarEditorView`, presented as a `.sheet`). Everything the inline section used to
    /// hold — the preview, the indicator list, the style controls, compact mode, reset — lives
    /// in the editor now; this row is all that stays in the Settings list.
    private var menuBarSection: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            SectionHeader("MENU BAR")

            HStack(alignment: .center, spacing: Spacing.md) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Menu Bar")
                        .textStyle(.body)
                        .foregroundStyle(Palette.textPrimary)
                    Text("Choose which windows show in the status item, how they're drawn, and the strip's look.")
                        .cardLabel()
                }
                Spacer(minLength: Spacing.md)
                Button {
                    isPresentingMenuBarEditor = true
                } label: {
                    Text("Edit\u{2026}")
                        .textStyle(.body)
                }
                .buttonStyle(.tokiSecondary)
            }
            .padding(Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .panelCard()
        }
    }

    // MARK: Notifications

    /// One row, matching the Menu Bar row above: every notification Toki can send — the
    /// rate-limit threshold alerts, the account events and the service-incident alert — is
    /// configured in the editor this opens, and nowhere else. A notification switched on or off in two places is how
    /// "I turned notifications off and still got one" happens.
    private var notificationsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            SectionHeader("NOTIFICATIONS")

            HStack(alignment: .center, spacing: Spacing.md) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Notifications")
                        .textStyle(.body)
                        .foregroundStyle(Palette.textPrimary)
                    Text("Choose which rate-limit thresholds warn you, which account events Toki tells you about, and whether service incidents notify you.")
                        .cardLabel()
                }
                Spacer(minLength: Spacing.md)
                Button {
                    isPresentingNotificationsEditor = true
                } label: {
                    Text("Edit\u{2026}")
                        .textStyle(.body)
                }
                .buttonStyle(.tokiSecondary)
            }
            .padding(Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .panelCard()
        }
    }

    // MARK: Accounts (auto-swap)

    private func autoSwapSection(provider: UsageProvider) -> some View {
        let settings = autoSwapSettings(for: provider)
        return VStack(alignment: .leading, spacing: Spacing.xs) {
            SectionHeader("\(provider.displayName.uppercased()) AUTO-SWAP")

            if editingAutoSwapProvider == provider {
                // Retain the collapsed card's exact layout slot while its matched counterpart
                // is expanded above the page. Removing the row would pull every card upward
                // halfway through the morph and make the return animation land in mid-air.
                autoSwapSummaryCard(
                    provider: provider,
                    settings: settings,
                    participatesInTransition: false
                )
                    .hidden()
                    .accessibilityHidden(true)
            } else {
                Button {
                    openAutoSwapEditor(provider)
                } label: {
                    autoSwapSummaryCard(provider: provider, settings: settings)
                }
                .buttonStyle(.plain)
                .help("Edit \(provider.displayName) auto-swap")
            }
        }
    }

    private func autoSwapSummaryCard(
        provider: UsageProvider,
        settings: AutoSwapSettings,
        participatesInTransition: Bool = true
    ) -> some View {
        ZStack {
            autoSwapMorphSurface(
                provider: provider,
                rimBright: false,
                castsEditorShadow: false,
                participatesInTransition: participatesInTransition
            )

            HStack(spacing: Spacing.sm) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(settings.enabled ? Palette.accentSubtle : Palette.raised)
                        .frame(width: 36, height: 36)
                    Image(systemName: "arrow.left.arrow.right")
                        .iconSize(.medium, weight: .semibold)
                        .foregroundStyle(settings.enabled ? Palette.accent : Palette.textSecondary)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(settings.enabled ? "Automatic switching is on" : "Automatic switching is off")
                        .textStyle(.body)
                        .foregroundStyle(Palette.textPrimary)
                    Text(autoSwapSummary(settings))
                        .cardLabel()
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer(minLength: Spacing.xs)

                Text(settings.enabled ? "ON" : "OFF")
                    .textStyle(.caption)
                    .foregroundStyle(settings.enabled ? Palette.accent : Palette.textSecondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(
                        Capsule().fill(
                            settings.enabled
                                ? Palette.accentSubtle
                                : Palette.textSecondary.opacity(0.08)
                        )
                    )

                Image(systemName: "chevron.right")
                    .iconSize(.small, weight: .semibold)
                    .foregroundStyle(Palette.textSecondary.opacity(0.75))
            }
            .padding(Spacing.md)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // 36 pt icon + the standard 16 pt vertical padding: the same 68 pt compact height as
        // neighbouring two-line settings cards.
        .frame(height: 68)
        .contentShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
    }

    /// Positions the destination without adding layout modifiers to the matched surface.
    /// The surface therefore owns the exact compact and expanded rectangles that SwiftUI
    /// interpolates in window space; the surrounding layout only chooses the final location.
    private func autoSwapEditorOverlay(provider: UsageProvider) -> some View {
        GeometryReader { geometry in
            let toolbarClearance = topInset == 0 ? Measure.dashboardContentTop : topInset
            let editorWidth = max(
                320,
                min(560, geometry.size.width - (Spacing.xl * 2))
            )
            let editorHeight = max(
                280,
                min(430, geometry.size.height - toolbarClearance - Spacing.md)
            )

            VStack(spacing: 0) {
                Color.clear
                    .frame(height: toolbarClearance)

                Spacer(minLength: 0)

                autoSwapEditor(
                    provider: provider,
                    width: editorWidth,
                    height: editorHeight
                )

                Spacer(minLength: 0)

                Color.clear
                    .frame(height: Spacing.md)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func autoSwapEditor(
        provider: UsageProvider,
        width: CGFloat,
        height: CGFloat
    ) -> some View {
        ZStack {
            // Match only the persistent card surface. The compact and expanded content have
            // different layout, so trying to match the whole hierarchy makes the labels warp
            // while an opacity transition hides the boundary motion.
            autoSwapMorphSurface(
                provider: provider,
                rimBright: true,
                castsEditorShadow: true,
                participatesInTransition: true
            )

            VStack(spacing: 0) {
                HStack(spacing: Spacing.sm) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(Palette.accentSubtle)
                            .frame(width: 40, height: 40)
                        Image(systemName: "arrow.left.arrow.right")
                            .iconSize(.medium, weight: .semibold)
                            .foregroundStyle(Palette.accent)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(provider.displayName) Auto-Swap")
                            .textStyle(.headline)
                            .foregroundStyle(Palette.textPrimary)
                        Text("Choose when Toki moves to another stored account.")
                            .cardLabel()
                    }

                    Spacer(minLength: Spacing.md)

                    Button {
                        closeAutoSwapEditor()
                    } label: {
                        Image(systemName: "xmark")
                            .iconSize(.regular, weight: .semibold)
                    }
                    .buttonStyle(.tokiIcon)
                    // Bind Escape to the actual close action. `onExitCommand` alone is not
                    // guaranteed to receive the event while a slider or picker owns focus.
                    .keyboardShortcut(.cancelAction)
                    .foregroundStyle(Palette.textSecondary)
                    .help("Close")
                    .accessibilityLabel("Close \(provider.displayName) auto-swap editor")
                }
                .padding(Spacing.md)

                divider

                ScrollView {
                    autoSwapControls(provider: provider)
                        .padding(Spacing.md)
                }
                // DashboardView's toolbar clearance is an inherited scroll-content margin.
                // This nested scroll view is inside that dashboard, but its content starts at
                // the editor divider, so explicitly override the inherited 130 pt inset.
                .contentMargins(.top, 0, for: .scrollContent)
            }
            .opacity(isAutoSwapEditorContentVisible ? 1 : 0)
            .allowsHitTesting(isAutoSwapEditorContentVisible)
        }
        .frame(width: width, height: height)
    }

    @ViewBuilder
    private func autoSwapMorphSurface(
        provider: UsageProvider,
        rimBright: Bool,
        castsEditorShadow: Bool,
        participatesInTransition: Bool
    ) -> some View {
        let surface = Color.clear
            .panelCard(rimBright: rimBright)
            .shadow(
                color: castsEditorShadow ? .black.opacity(0.20) : .clear,
                radius: castsEditorShadow ? 28 : 0,
                y: castsEditorShadow ? 12 : 0
            )

        if participatesInTransition {
            surface.matchedGeometryEffect(
                id: autoSwapTransitionID(provider),
                in: autoSwapTransition,
                properties: .frame,
                anchor: .center
            )
        } else {
            surface
        }
    }

    private func autoSwapControls(provider: UsageProvider) -> some View {
        let settings = autoSwapSettings(for: provider)
        return VStack(alignment: .leading, spacing: Spacing.md) {
            toggleRow(
                title: "Switch accounts automatically",
                detail: "Move to another stored account before the active one hits its limit. Off by default.",
                isOn: autoSwapEnabledBinding(provider)
            )

            if settings.isSilentlyDisarmed {
                warningRow("""
                    No window is being watched, so accounts will never switch. \
                    Turn on the 5-hour or the weekly window below.
                    """)
            }

            if notificationsUnavailable {
                warningRow("Notifications are turned off for Toki in System Settings.")
            }

            divider

            watchedWindowRow(
                title: "Watch the 5-hour window",
                isOn: watchFiveHourBinding(provider),
                threshold: fiveHourThresholdBinding(provider),
                settingsEnabled: settings.enabled
            )

            divider

            watchedWindowRow(
                title: "Watch the weekly window",
                isOn: watchWeeklyBinding(provider),
                threshold: weeklyThresholdBinding(provider),
                settingsEnabled: settings.enabled
            )

            divider

            HStack(alignment: .center, spacing: Spacing.md) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Cooldown between swaps")
                        .textStyle(.body)
                        .foregroundStyle(Palette.textPrimary)
                    Text("Wait at least this long before swapping again.")
                        .cardLabel()
                }
                Spacer(minLength: Spacing.md)
                Picker("", selection: cooldownBinding(provider)) {
                    Text("5 min").tag(TimeInterval(300))
                    Text("10 min").tag(TimeInterval(600))
                    Text("30 min").tag(TimeInterval(1800))
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 100)
            }
            .opacity(settings.enabled ? 1 : 0.5)
            .disabled(!settings.enabled)
        }
    }

    private func autoSwapSummary(_ settings: AutoSwapSettings) -> String {
        guard settings.enabled else { return "Configure thresholds and cooldown." }
        var watched: [String] = []
        if settings.watchFiveHour {
            watched.append("5h \(Int((settings.fiveHourThreshold * 100).rounded()))%")
        }
        if settings.watchWeekly {
            watched.append("7d \(Int((settings.weeklyThreshold * 100).rounded()))%")
        }
        let windows = watched.isEmpty ? "No windows selected" : watched.joined(separator: " · ")
        return "\(windows) · \(Int(settings.cooldown / 60)) min cooldown"
    }

    private var autoSwapAnimation: Animation {
        reduceMotion
            ? .easeOut(duration: 0.12)
            : .spring(response: 0.32, dampingFraction: 0.93)
    }

    private func autoSwapTransitionID(_ provider: UsageProvider) -> String {
        "auto-swap-\(provider.rawValue)"
    }

    private func openAutoSwapEditor(_ provider: UsageProvider) {
        if reduceMotion {
            editingAutoSwapProvider = provider
            isAutoSwapEditorContentVisible = true
            return
        }

        isAutoSwapEditorContentVisible = false
        withAnimation(autoSwapAnimation) {
            editingAutoSwapProvider = provider
        }
        // Let SwiftUI insert the expanded surface at opacity zero before starting the detail
        // fade. If both state writes land in one update, the controls have no rendered zero
        // state and pop in over the bounds animation instead of following it.
        DispatchQueue.main.async {
            guard editingAutoSwapProvider == provider else { return }
            withAnimation(.easeOut(duration: 0.14).delay(0.06)) {
                isAutoSwapEditorContentVisible = true
            }
        }
    }

    private func closeAutoSwapEditor() {
        if reduceMotion {
            isAutoSwapEditorContentVisible = false
            editingAutoSwapProvider = nil
            return
        }

        guard let provider = editingAutoSwapProvider else { return }
        withAnimation(.easeOut(duration: 0.06)) {
            isAutoSwapEditorContentVisible = false
        }
        // Start the collapse after the dense editor controls have receded. The shared surface
        // remains fully visible, so the eye can follow its four edges back into the source card.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            guard editingAutoSwapProvider == provider else { return }
            withAnimation(autoSwapAnimation) {
                editingAutoSwapProvider = nil
            }
        }
    }

    // MARK: Usage display

    private struct UsageWindowOption: Identifiable {
        let id: String
        let title: String
    }

    private var usageDisplaySection: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            SectionHeader("USAGE DISPLAY")

            VStack(alignment: .leading, spacing: Spacing.md) {
                if providerAvailability.claudeCode {
                    usageDisplayProvider(.claudeCode)
                }

                if providerAvailability.claudeCode, providerAvailability.codex {
                    divider
                }

                if providerAvailability.codex {
                    usageDisplayProvider(.codex)
                }
            }
            .padding(Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .panelCard()
        }
    }

    private func usageDisplayProvider(_ provider: UsageProvider) -> some View {
        let options = usageWindowOptions(for: provider)
        return VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(alignment: .center, spacing: Spacing.sm) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Palette.accentSubtle)
                        .frame(width: 32, height: 32)
                    Image(systemName: provider == .claudeCode ? "sparkles" : "terminal")
                        .iconSize(.regular, weight: .semibold)
                        .foregroundStyle(Palette.accent)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.displayName)
                        .textStyle(.body)
                        .foregroundStyle(Palette.textPrimary)
                    Text("Shown in the Usage tab and menu-bar popover.")
                        .cardLabel()
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            UsageChipFlow(spacing: 6, lineSpacing: 6) {
                ForEach(options) { option in
                    usageDisplayChip(
                        title: option.title,
                        isSelected: usageWindowBinding(
                            provider: provider,
                            windowID: option.id,
                            availableWindowIDs: options.map(\.id)
                        )
                    )
                }

                if provider == .claudeCode {
                    usageDisplayChip(
                        title: "Extra usage",
                        isSelected: extraUsageBinding(
                            provider: provider,
                            availableWindowIDs: options.map(\.id)
                        )
                    )
                }
            }
        }
    }

    private func usageDisplayChip(
        title: String,
        isSelected: Binding<Bool>
    ) -> some View {
        let selected = isSelected.wrappedValue
        return Button {
            withAnimation(.easeOut(duration: 0.14)) {
                isSelected.wrappedValue.toggle()
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: selected ? "eye" : "eye.slash")
                    .iconSize(.small, weight: .semibold)
                    .frame(width: 13)

                Text(title)
                    .textStyle(.detail)
                    .lineLimit(1)
            }
            .foregroundStyle(selected ? Palette.accent : Palette.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(selected ? Palette.accentSubtle : Palette.raised)
            )
            .overlay(
                Capsule().strokeBorder(
                    selected ? Palette.accent.opacity(0.32) : Palette.hairline,
                    lineWidth: BorderWidth.card
                )
            )
            .contentShape(Capsule())
        }
        .buttonStyle(UsageChipButtonStyle())
        .contentShape(.focusEffect, Capsule())
        .accessibilityLabel(title)
        .accessibilityValue(selected ? "Shown" : "Hidden")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .help(selected ? "Hide \(title)" : "Show \(title)")
    }

    /// Live titles make model-specific Codex plans understandable (and preserve their stable
    /// semantic ids for persistence). Before the first response, canonical rows keep the
    /// section editable rather than showing a blank card.
    private func usageWindowOptions(for provider: UsageProvider) -> [UsageWindowOption] {
        let limits = provider == .claudeCode ? menuBar.limits : menuBar.codexLimits
        guard let windows = limits?.windows, !windows.isEmpty else {
            return [
                UsageWindowOption(id: "session", title: "5-hour"),
                UsageWindowOption(id: "weekly_all", title: "7-day"),
            ]
        }

        var seen: Set<String> = []
        return windows.compactMap { window in
            guard seen.insert(window.id).inserted else { return nil }
            return UsageWindowOption(id: window.id, title: window.title)
        }
    }

    private func usageWindowBinding(
        provider: UsageProvider,
        windowID: String,
        availableWindowIDs: [String]
    ) -> Binding<Bool> {
        Binding(
            get: {
                menuBar.usageDisplayConfiguration[provider].showsWindow(id: windowID)
            },
            set: { isVisible in
                var configuration = menuBar.usageDisplayConfiguration
                configuration.setWindowVisible(
                    isVisible,
                    id: windowID,
                    provider: provider,
                    availableWindowIDs: availableWindowIDs
                )
                menuBar.usageDisplayConfiguration = configuration
            }
        )
    }

    private func extraUsageBinding(
        provider: UsageProvider,
        availableWindowIDs: [String]
    ) -> Binding<Bool> {
        Binding(
            get: {
                let providerConfiguration = menuBar.usageDisplayConfiguration[provider]
                return providerConfiguration.isEnabled && providerConfiguration.showsExtraUsage
            },
            set: { isVisible in
                var configuration = menuBar.usageDisplayConfiguration
                configuration.setExtraUsageVisible(
                    isVisible,
                    provider: provider,
                    availableWindowIDs: availableWindowIDs
                )
                menuBar.usageDisplayConfiguration = configuration
            }
        )
    }

    private func warningRow(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .iconSize(.regular)
                .foregroundStyle(Palette.warn)
            Text(message)
                .textStyle(.detail)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Palette.hairline)
            .frame(height: 1)
            .opacity(0.6)
    }

    /// Title, the sentence the threshold appears in, the threshold itself and the switch on one
    /// line — and the bar on its own line UNDER that one, inside the same row.
    ///
    /// Not at the bottom of the card: this card has two of these rows (5-hour and weekly), and a
    /// single bar parked below both would not say which window it set. And only while the window
    /// is watched — an off row is one line again, so the card does not carry a bar for a number
    /// nothing reads.
    ///
    /// The percentage keeps its place at the trailing edge of the top line, where the stepper
    /// used to show it. A bar with no number cannot be read to the precision the sentence beside
    /// it quotes.
    private func watchedWindowRow(
        title: String,
        isOn: Binding<Bool>,
        threshold: Binding<Int>,
        settingsEnabled: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(alignment: .center, spacing: Spacing.md) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .textStyle(.body)
                        .foregroundStyle(Palette.textPrimary)
                    Text("Swap once utilization reaches \(threshold.wrappedValue)%.")
                        .cardLabel()
                }
                Spacer(minLength: Spacing.md)
                Text("\(threshold.wrappedValue)%")
                    .textStyle(.metricInline)
                    .foregroundStyle(Palette.textPrimary)
                    .frame(width: 36, alignment: .trailing)
                Toggle("", isOn: isOn)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(Palette.accent)
            }
            if isOn.wrappedValue {
                TokiSlider(
                    value: threshold,
                    range: 50...99,
                    step: 1,
                    label: "\(title) threshold"
                )
            }
        }
        .opacity(settingsEnabled ? 1 : 0.5)
        .disabled(!settingsEnabled)
    }

    // MARK: Accounts settings storage

    /// Decodes the `@AppStorage`-backed JSON, falling back to `AutoSwapSettings.default`
    /// when the stored value is absent or corrupt.
    private func autoSwapSettings(for provider: UsageProvider) -> AutoSwapSettings {
        let json = provider == .claudeCode ? autoSwapSettingsJSON : codexAutoSwapSettingsJSON
        guard !json.isEmpty, let data = json.data(using: .utf8) else { return .default }
        do {
            return try JSONDecoder().decode(AutoSwapSettings.self, from: data)
        } catch {
            log.error("auto-swap settings decode failed, reverting to default \(error: error)")
            return .default
        }
    }

    private func writeAutoSwapSettings(
        for provider: UsageProvider,
        _ mutate: (inout AutoSwapSettings) -> Void
    ) {
        var settings = autoSwapSettings(for: provider)
        mutate(&settings)
        let data: Data
        do {
            data = try JSONEncoder().encode(settings)
        } catch {
            log.error("auto-swap settings encode failed \(error: error)")
            return
        }
        guard let json = String(data: data, encoding: .utf8) else { return }
        if provider == .claudeCode {
            autoSwapSettingsJSON = json
        } else {
            codexAutoSwapSettingsJSON = json
        }
    }

    /// Turning auto-swap (or swap notifications) on is what asks for notification
    /// authorization — never requested at launch, only on explicit opt-in.
    private func requestNotificationAuthorizationIfNeeded() {
        Task {
            let granted = await notifier.requestAuthorization()
            notificationsUnavailable = !granted
        }
    }

    private func autoSwapEnabledBinding(_ provider: UsageProvider) -> Binding<Bool> {
        Binding(
            get: { autoSwapSettings(for: provider).enabled },
            set: { newValue in
                writeAutoSwapSettings(for: provider) { $0.enabled = newValue }
                guard newValue else { return }
                requestNotificationAuthorizationIfNeeded()
                // The driver otherwise finishes its current 3-minute sleep first, so an
                // account already over its threshold keeps burning until then.
                NotificationCenter.default.post(name: .tokiAutoSwapEnabled, object: nil)
            }
        )
    }

    private func watchFiveHourBinding(_ provider: UsageProvider) -> Binding<Bool> {
        Binding(
            get: { autoSwapSettings(for: provider).watchFiveHour },
            set: { newValue in writeAutoSwapSettings(for: provider) { $0.watchFiveHour = newValue } }
        )
    }

    private func fiveHourThresholdBinding(_ provider: UsageProvider) -> Binding<Int> {
        Binding(
            get: { Int((autoSwapSettings(for: provider).fiveHourThreshold * 100).rounded()) },
            set: { newValue in writeAutoSwapSettings(for: provider) { $0.fiveHourThreshold = Double(newValue) / 100 } }
        )
    }

    private func watchWeeklyBinding(_ provider: UsageProvider) -> Binding<Bool> {
        Binding(
            get: { autoSwapSettings(for: provider).watchWeekly },
            set: { newValue in writeAutoSwapSettings(for: provider) { $0.watchWeekly = newValue } }
        )
    }

    private func weeklyThresholdBinding(_ provider: UsageProvider) -> Binding<Int> {
        Binding(
            get: { Int((autoSwapSettings(for: provider).weeklyThreshold * 100).rounded()) },
            set: { newValue in writeAutoSwapSettings(for: provider) { $0.weeklyThreshold = Double(newValue) / 100 } }
        )
    }

    private func cooldownBinding(_ provider: UsageProvider) -> Binding<TimeInterval> {
        Binding(
            get: { autoSwapSettings(for: provider).cooldown },
            set: { newValue in writeAutoSwapSettings(for: provider) { $0.cooldown = newValue } }
        )
    }

    // MARK: About

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            SectionHeader("ABOUT")

            VStack(alignment: .leading, spacing: Spacing.md) {
                HStack(alignment: .top, spacing: Spacing.md) {
                    AppIconBadge(size: 44)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Toki")
                            .textStyle(.title)
                            .foregroundStyle(Palette.textPrimary)
                        Text("Usage limits for AI coding tools in your menu bar.")
                            .cardLabel()
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Version \(appVersion)  \u{00B7}  Build \(buildNumber)")
                            .textStyle(.mono)
                            .foregroundStyle(Palette.textSecondary.opacity(0.85))
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button {
                    updater.checkForUpdates()
                } label: {
                    Text("Check for Updates\u{2026}")
                        .textStyle(.body)
                }
                .buttonStyle(.bordered)
                .tint(Palette.accent)
                .disabled(!updater.canCheckForUpdates)
            }
            .padding(Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .panelCard()
        }
    }

    // MARK: Updates

    private var updatesSection: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            SectionHeader("UPDATES")

            VStack(alignment: .leading, spacing: Spacing.md) {
                toggleRow(
                    title: "Automatic Updates",
                    detail: "Periodically check for new versions in the background.",
                    isOn: $updater.automaticallyChecksForUpdates
                )

                Rectangle()
                    .fill(Palette.hairline)
                    .frame(height: 1)
                    .opacity(0.6)

                toggleRow(
                    title: "Download & Install Automatically",
                    detail: "Fetch and install updates without asking. Requires automatic updates.",
                    isOn: $updater.automaticallyDownloadsUpdates,
                    isEnabled: updater.automaticallyChecksForUpdates
                )
            }
            .padding(Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .panelCard()
        }
    }

    /// A title + subtitle row with a trailing switch, matching the General
    /// section's Launch-at-Login layout.
    func toggleRow(
        title: String,
        detail: String,
        isOn: Binding<Bool>,
        isEnabled: Bool = true
    ) -> some View {
        HStack(alignment: .center, spacing: Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .textStyle(.body)
                    .foregroundStyle(Palette.textPrimary)
                Text(detail)
                    .cardLabel()
                    // Wrap rather than truncate. In the two-column layout these rows are half
                    // the window wide, and a subtitle is the only place a toggle explains what
                    // it does — "Best turned off again once you've captured the problem"
                    // clipped to "Best turne…" is the sentence and the advice both gone. The
                    // card has vertical room; it does not have horizontal room.
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Spacing.md)
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(Palette.accent)
                .disabled(!isEnabled)
        }
        .opacity(isEnabled ? 1 : 0.5)
    }

    // MARK: Live Usage

    private var liveUsageSection: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            SectionHeader("LIVE USAGE")

            VStack(alignment: .leading, spacing: Spacing.sm) {
                HStack(alignment: .top, spacing: Spacing.md) {
                    sourceRow(
                        icon: "bolt.fill",
                        title: "Instant updates from Claude Code",
                        detail: liveUsageDetail
                    )
                    Spacer(minLength: 0)
                    Toggle("Instant updates from Claude Code", isOn: $isStatuslineUsageEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .tint(Palette.accent)
                        .accessibilityIdentifier("settings.liveUsage.toggle")
                }

                if isStatuslineUsageEnabled, let lastSampleAt = statuslineUsage?.lastSampleAt {
                    TimelineView(.periodic(from: .now, by: 30)) { _ in
                        Text("Last update from Claude Code \(lastSampleAt, format: .relative(presentation: .named))")
                            .textStyle(.detail)
                            .foregroundStyle(Palette.textSecondary)
                    }
                    .padding(.leading, 30 + Spacing.sm)
                }

                if let backups = statuslineUsage?.backupsURL,
                   FileManager.default.fileExists(atPath: backups.path) {
                    Button("Show Settings Backups") {
                        NSWorkspace.shared.activateFileViewerSelecting([backups])
                    }
                    .buttonStyle(.link)
                    .textStyle(.detail)
                    .padding(.leading, 30 + Spacing.sm)
                    .help("Copies of ~/.claude/settings.json saved before each change Toki made")
                }
            }
            .padding(Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .panelCard()
        }
    }

    private var liveUsageDetail: String {
        guard isStatuslineUsageEnabled else {
            return "Off. Usage updates every 90 seconds instead."
        }
        switch statuslineUsage?.status ?? .unknown {
        case .wrappingUserCommand:
            return "After every reply, Claude Code passes your 5-hour and 7-day usage to your status line. Toki reads it on the way, and your status line looks the same."
        case .silentStatusLine:
            return "Toki added a status line that shows nothing, so Claude Code passes your 5-hour and 7-day usage to Toki after every reply. While any status line is set, Claude Code hides its \u{201C}? for shortcuts\u{201D}, \u{201C}esc to interrupt\u{201D} and \u{201C}hold space to speak\u{201D} hints."
        case .unsupported:
            return "Your Claude Code status line isn\u{2019}t a command, so Toki can\u{2019}t read from it. Usage updates every 90 seconds instead."
        case .failed:
            return "Toki couldn\u{2019}t update ~/.claude/settings.json. Usage updates every 90 seconds instead."
        case .unknown, .off:
            return "After every reply, Claude Code passes your 5-hour and 7-day usage to its status line. Toki reads it there, so the gauges move as you work."
        }
    }

    // MARK: Data Sources

    private var dataSourcesSection: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            SectionHeader("DATA SOURCES")

            VStack(alignment: .leading, spacing: Spacing.md) {
                if providerAvailability.claudeCode {
                    sourceRow(
                        icon: "bolt.horizontal.fill",
                        title: "Anthropic API (Claude limits)",
                        detail: "Live rate-window utilization uses your Claude session. Toki keeps a secure copy of its token. If access changes after signing in again, reconnect using the button below."
                    )
                    dataSourceDivider
                }

                if providerAvailability.codex {
                    sourceRow(
                        icon: "bolt.horizontal.fill",
                        title: "Codex App Server (Codex limits)",
                        detail: "Live ChatGPT-plan limits and account identity come from the local Codex App Server. Codex remains the owner of authentication."
                    )
                    dataSourceDivider
                }

                sourceRow(
                    icon: "doc.text.magnifyingglass",
                    title: "Local transcript files (analytics)",
                    detail: transcriptSourceDetail
                )

                if providerAvailability.claudeCode {
                    dataSourceDivider
                    HStack {
                        Spacer()
                        Button {
                            NotificationCenter.default.post(name: .tokiPresentKeychainSetup, object: nil)
                        } label: {
                            Text("Set up Claude Keychain access\u{2026}")
                                .textStyle(.body)
                        }
                        .buttonStyle(.bordered)
                        .tint(Palette.accent)
                        Spacer()
                    }
                }
            }
            .padding(Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .panelCard()
        }
    }

    private var dataSourceDivider: some View {
        Rectangle()
            .fill(Palette.hairline)
            .frame(height: 1)
            .opacity(0.6)
    }

    private var transcriptSourceDetail: String {
        switch (providerAvailability.claudeCode, providerAvailability.codex) {
        case (true, true):
            "Historical analytics are computed from local JSONL files in ~/.claude and Codex's active and archived sessions. No transcript content leaves your device."
        case (true, false):
            "Historical analytics are computed from local JSONL files in ~/.claude. No transcript content leaves your device."
        case (false, true):
            "Historical analytics are computed from Codex's active and archived local sessions. No transcript content leaves your device."
        case (false, false):
            "Historical analytics stay local on this Mac."
        }
    }

    func sourceRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Palette.accentSubtle)
                    .frame(width: 30, height: 30)
                Image(systemName: icon)
                    .iconSize(.medium, weight: .semibold)
                    .foregroundStyle(Palette.accent)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Palette.textPrimary)
                Text(detail)
                    .textStyle(.detail)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A compact, left-aligned row that wraps usage chips at their intrinsic widths. A fixed grid
/// would stretch short labels such as "7-day" into controls that no longer read as chips.
private struct UsageChipFlow: Layout {
    let spacing: CGFloat
    let lineSpacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let maximumWidth = proposal.width ?? .infinity
        let rows = rows(for: subviews, maximumWidth: maximumWidth)
        let contentWidth = rows.map(\.width).max() ?? 0
        let contentHeight = rows.reduce(CGFloat(0)) { $0 + $1.height }
            + lineSpacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: min(contentWidth, maximumWidth), height: contentHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var y = bounds.minY
        for row in rows(for: subviews, maximumWidth: bounds.width) {
            var x = bounds.minX
            for item in row.items {
                item.subview.place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(item.size)
                )
                x += item.size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Item {
        let subview: LayoutSubview
        let size: CGSize
    }

    private struct Row {
        let items: [Item]
        let width: CGFloat
        let height: CGFloat
    }

    private func rows(for subviews: Subviews, maximumWidth: CGFloat) -> [Row] {
        var result: [Row] = []
        var items: [Item] = []
        var width: CGFloat = 0

        func flush() {
            guard !items.isEmpty else { return }
            result.append(Row(
                items: items,
                width: width,
                height: items.map(\.size.height).max() ?? 0
            ))
            items = []
            width = 0
        }

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let nextWidth = width + (items.isEmpty ? 0 : spacing) + size.width
            if !items.isEmpty, nextWidth > maximumWidth {
                flush()
            }
            width += (items.isEmpty ? 0 : spacing) + size.width
            items.append(Item(subview: subview, size: size))
        }
        flush()
        return result
    }
}

/// Preserves native button semantics while giving chips a restrained press response.
private struct UsageChipButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(.easeOut(duration: 0.10), value: configuration.isPressed)
    }
}


// MARK: - Preview

#Preview("SettingsSections \u{2014} two columns") {
    let container = ServiceContainer(prewarm: false)
    container.apply(.fixture(.singleAccount))
    return SettingsSections(
        topInset: Spacing.xl,
        menuBar: container.menuBarVM,
        providerAvailability: container.providerAvailability
    )
        .environmentObject(UpdaterController())
        .frame(width: 880, height: 800)
        .background(Palette.bg)
}
