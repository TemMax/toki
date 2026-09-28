/// NotificationsEditorView — the one screen that owns every notification Toki sends.
///
/// Presented from a single row in `SettingsSections` (see its `notificationsSection`), the
/// same way `MenuBarEditorView` is, and deliberately built to the same three-band shape so the
/// two editors read as one app rather than two:
///  - Header (pinned): the permission state, then a preview of the notification the configured
///    rules would actually post — rendered through `ThresholdAlertCopy`, the exact wording
///    `SwapNotifier` sends. The wording is not user-editable (see the spec), so the preview is
///    the only thing that can explain what you will get.
///  - Body (scrolls): the rule list (left) and the four other notification types (right).
///  - Footer (pinned): Reset to Defaults / Done.
///
/// ## Where the settings live
/// `NotificationSettings` has exactly one home — `NotificationSettingsStore`, JSON in
/// `UserDefaults`. This screen holds a `@State` working copy and writes the whole value back
/// through the store on EVERY edit (`update(_:)`), so the store is authoritative the instant a
/// switch moves. Nothing else caches the value: `AlertDriver`, `AutoSwapDriver`,
/// `AccountSwitcher` and `ServiceContainer` each `load()` at the moment they need it, so there
/// is no second copy to drift out of sync.
///
/// ## Why the controls stay live when notifications are denied
/// A denied authorization makes everything this screen configures inert — the system drops
/// every notification Toki posts. That is stated at the top of the sheet and again on the
/// preview card itself ("Not delivered"), with a button that opens the System Settings pane
/// where it is fixed. The controls are NOT disabled: the settings still persist, and being
/// unable to set them up before (or after) granting permission would be a second, pointless
/// wall. What is unacceptable is a screen that looks like it works while the system discards
/// its output — hence saying it twice, loudly, rather than silently greying out.
import AppKit
import SwiftUI
import TokiAlerts
import TokiCore
import TokiMenuBar
import UserNotifications

@MainActor
struct NotificationsEditorView: View {

    /// The sheet's presented size — width is fixed on `body` below; height is applied by the
    /// `.sheet` call site in `SettingsSections`. `nonisolated`: plain constants, read from
    /// contexts (like `DebugControlChannel`'s `Surface.defaultWidth`) that aren't themselves
    /// main-actor isolated.
    nonisolated static let sheetWidth: CGFloat = 860
    nonisolated static let sheetHeight: CGFloat = 560

    /// Width of the rules column. Unequal columns, like the menu-bar editor's: a rule row is
    /// five controls on one line and needs its width in one piece, while the event toggles
    /// beside it are title + one line of detail and stay legible in what is left.
    nonisolated static let rulesColumnWidth: CGFloat = 472

    /// Read-only window onto the active account's limits, so the preview can show the REAL
    /// percentage a rule would fire at and the window picker can offer the models this account
    /// is actually scoped on.
    ///
    /// It is the `MenuBarViewModel` the Settings list already holds — not because this screen
    /// has anything to do with the menu bar, but because that view model is the app's existing
    /// forwarder onto `LiveLimits`, the single owner of this datum. Only
    /// `limits` is read here, and nothing is ever written back.
    let menuBar: MenuBarViewModel

    private let store: NotificationSettingsStore
    @State private var settings: NotificationSettings
    /// `.notDetermined` until the first read lands — the neutral state, which says macOS will
    /// ask rather than claiming either that everything works or that everything is blocked.
    @State private var authorization: UNAuthorizationStatus = .notDetermined

    init(
        menuBar: MenuBarViewModel,
        store: NotificationSettingsStore = NotificationSettingsStore(defaults: .standard)
    ) {
        self.menuBar = menuBar
        self.store = store
        _settings = State(initialValue: store.load())
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(Spacing.md)
            divider
            ScrollView {
                bodyColumns
                    .padding(Spacing.sm)
            }
            divider
            footer
                .padding(Spacing.md)
        }
        .frame(width: Self.sheetWidth)
        .background(Palette.bg)
        .task { await refreshAuthorization() }
        // The user can revoke (or grant) the permission in System Settings while this sheet is
        // open — most likely via the button right here — so the state is re-read every time the
        // app comes back to the front rather than once, at presentation.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refreshAuthorization() }
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Palette.hairline)
            .frame(height: 1)
            .opacity(0.6)
    }

    // MARK: - Header (pinned) — permission state + preview

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            permissionRow
            previewRow
        }
    }

    // MARK: Header — permission

    private var isDenied: Bool { authorization == .denied }

    /// The macOS authorization status, stated plainly. Denied is the only state that gets a
    /// tinted banner and a button, because it is the only one where everything below it is
    /// already decided: the system drops every notification Toki posts.
    @ViewBuilder
    private var permissionRow: some View {
        if isDenied {
            HStack(alignment: .center, spacing: Spacing.sm) {
                Image(systemName: "bell.slash.fill")
                    .iconSize(.regular)
                    .foregroundStyle(Palette.warn)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Notifications are turned off for Toki")
                        .textStyle(.body)
                        .foregroundStyle(Palette.textPrimary)
                    Text("macOS discards everything on this screen until you turn them back on in System Settings.")
                        .textStyle(.detail)
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Spacing.sm)
                Button {
                    openNotificationSettings()
                } label: {
                    Text("Open System Settings\u{2026}")
                        .textStyle(.body)
                }
                .buttonStyle(.tokiSecondary)
            }
            .padding(Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Radius.element, style: .continuous)
                    .fill(Palette.warn.opacity(0.12))
            )
        } else {
            HStack(spacing: Spacing.xxs) {
                Image(systemName: permissionIcon)
                    .iconSize(.small)
                    .foregroundStyle(authorization == .notDetermined ? Palette.textSecondary : Palette.ok)
                Text(permissionDetail)
                    .textStyle(.caption)
                    .foregroundStyle(Palette.textSecondary)
            }
        }
    }

    private var permissionIcon: String {
        authorization == .notDetermined ? "bell" : "bell.fill"
    }

    private var permissionDetail: String {
        switch authorization {
        case .notDetermined:
            "macOS will ask for permission the first time Toki has something to tell you."
        case .provisional:
            "Notifications are delivered quietly, without a banner \u{2014} change that in System Settings."
        default:
            "Notifications are allowed for Toki."
        }
    }

    private func openNotificationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") else { return }
        NSWorkspace.shared.open(url)
    }

    private func refreshAuthorization() async {
        authorization = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    // MARK: Header — preview

    /// The whole PREVIEW group — heading, card, caption — is held to the width of a real
    /// notification banner (`Measure.notificationBanner`) and pinned to the leading edge, so
    /// the heading and the caption stay tied to the card they describe instead of running the
    /// full sheet away from it.
    private var previewRow: some View {
        // The caption sits BESIDE the card, not under it. Holding the card to a real banner's
        // width left the right half of this band empty — the same "stretched with nothing in
        // it" problem the width cap was introduced to fix, just rotated. Putting the caption
        // in that space uses it for the one text that explains the card, and buys back the
        // vertical the header was spending on a wrapped line.
        HStack(alignment: .top, spacing: Spacing.md) {
            VStack(alignment: .leading, spacing: 3) {
                Text("PREVIEW")
                    .textStyle(.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .kerning(0.3)
                previewCard
            }
            .frame(width: Measure.notificationBanner, alignment: .leading)

            Text(previewCaption)
                .textStyle(.caption)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                // Capped so the caption wraps into a readable block instead of running the
                // rest of the sheet; it is a footnote to the card, not a paragraph.
                .frame(maxWidth: Measure.notificationBanner, alignment: .leading)
                // Baseline-ish with the card's title rather than the PREVIEW label above it.
                .padding(.top, Spacing.lg)

            Spacer(minLength: 0)
        }
    }

    /// A stand-in for the real notification banner: Toki's own mark, the title and the body
    /// `SwapNotifier` would post, in that order. It is deliberately not pixel-faithful to the
    /// system banner (which Toki cannot draw) — what has to be exact is the TEXT, which comes
    /// from `ThresholdAlertCopy` and nowhere else, and the WIDTH, set by `previewRow` to
    /// `Measure.notificationBanner`: a preview stretched to the sheet wraps its copy where the
    /// real banner would not, which is the one thing this card exists to show.
    private var previewCard: some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            AppIconBadge(size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(previewTitle)
                    .textStyle(.body)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
                Text(previewBody)
                    .textStyle(.detail)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Spacing.sm)
            Text(isDenied ? "Not delivered" : "now")
                .textStyle(.caption)
                .foregroundStyle(isDenied ? Palette.warn : Palette.textSecondary)
        }
        .padding(Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Radius.element, style: .continuous)
                .fill(Palette.raised)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.element, style: .continuous)
                .strokeBorder(Palette.hairline, lineWidth: BorderWidth.card)
        )
        .opacity(isDenied ? 0.55 : 1)
    }

    private var previewCaption: String {
        if previewAlert == nil {
            return "No limit alert is enabled, so Toki will not warn you before a window fills."
        }
        return isDenied
            ? "What Toki would send if every enabled rule tripped at once \u{2014} while notifications are off, it is not delivered."
            : "What Toki sends if every enabled rule trips at once. The wording is not editable."
    }

    private var previewTitle: String {
        guard let alert = previewAlert else { return "Nothing to preview" }
        return ThresholdAlertCopy.title(for: alert)
    }

    private var previewBody: String {
        guard let alert = previewAlert else { return "Turn on a limit alert to see what it says." }
        return ThresholdAlertCopy.body(for: alert)
    }

    /// The alert the enabled rules would produce, built from the SAME `ThresholdAlert` the
    /// policy hands `SwapNotifier` — so what is drawn here cannot drift from what is posted.
    ///
    /// A rule's percentage is the live one when the window is already past its threshold (that
    /// is the number a notification sent right now would carry), and the threshold itself
    /// otherwise (the number the notification will carry when it fires).
    private var previewAlert: ThresholdAlert? {
        let entries = settings.rules
            .filter { $0.isEnabled && menuBar.availableProviders.contains($0.provider) }
            .map { rule -> ThresholdAlert.Entry in
                let limits = rule.provider == .claudeCode
                    ? menuBar.limits
                    : menuBar.codexLimits
                let selected = rule.window.resolve(against: limits)
                return ThresholdAlert.Entry(
                    title: "\(rule.provider.displayName) · \(selected?.title ?? Self.fallbackTitle(for: rule.window))",
                    utilization: max(selected?.utilization ?? 0, rule.threshold),
                    threshold: rule.threshold
                )
            }
        return entries.isEmpty ? nil : ThresholdAlert(entries: entries)
    }

    /// The name to show for a window that resolves to nothing right now — no limits loaded
    /// yet, or a model this account is not scoped on. Matches the picker's own labels, so a
    /// row and the preview never disagree about what a rule is called.
    private static func fallbackTitle(for window: WindowSelector) -> String {
        switch window {
        case .fiveHour: "5-hour"
        case .sevenDay: "7-day"
        case .highestScopedModel: "Busiest model"
        case .scopedModel(let name): name
        case .extraUsage: "Extra usage"
        }
    }

    // MARK: - Body (scrolls) — two columns

    private var bodyColumns: some View {
        HStack(alignment: .top, spacing: Spacing.lg) {
            rulesColumn
                .frame(width: Self.rulesColumnWidth, alignment: .leading)
            eventsColumn
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Body — limit alerts (left column)

    private var rulesColumn: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(alignment: .center) {
                Text("Limit alerts")
                    .textStyle(.label)
                    .foregroundStyle(Palette.textPrimary)
                Spacer(minLength: Spacing.sm)
                Button {
                    addRule()
                } label: {
                    Image(systemName: "plus")
                        .iconSize(.regular)
                }
                .buttonStyle(.tokiIcon)
                .foregroundStyle(Palette.accent)
                .accessibilityLabel("Add a limit alert")
                .help("Add a limit alert")
                .disabled(menuBar.availableProviders.isEmpty)
            }
            Text("Tell me when a window reaches this much. Drag to reorder.")
                .textStyle(.caption)
                .foregroundStyle(Palette.textSecondary)

            if visibleRules.isEmpty {
                Text("No limit alerts. Toki will not warn you before a window fills.")
                    .textStyle(.detail)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Spacing.xxs)
            } else {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    ForEach(Array(visibleRules.enumerated()), id: \.element.id) { offset, rule in
                        if offset > 0 { divider }
                        ruleRow(rule)
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(Spacing.sm)
        .panelCard()
    }

    private var visibleRules: [AlertRule] {
        settings.rules.filter { menuBar.availableProviders.contains($0.provider) }
    }

    /// One rule, one line, read left to right as the sentence it is: WHICH window, at what
    /// percentage, on or off, and remove. Same pitch and the same controls as the menu-bar
    /// editor's indicator row, minus the two that only a strip needs (label + rendering).
    ///
    /// Under that line, and only while the rule is on, the same line's threshold gets a
    /// `TokiSlider` spanning the card. It belongs to THIS rule's row rather than to the card,
    /// because the card holds a list of rules and a bar below all of them would name none of
    /// them; a rule that is off collapses back to its single line.
    private func ruleRow(_ rule: AlertRule) -> some View {
        let name = Self.fallbackTitle(for: rule.window)
        return VStack(alignment: .leading, spacing: Spacing.xxs) {
            ruleHeaderRow(rule, name: name)
            if rule.isEnabled {
                TokiSlider(
                    value: thresholdBinding(rule.id),
                    range: 5...100,
                    step: 5,
                    label: "\(name) alert threshold"
                )
            }
        }
        .dropDestination(for: String.self) { items, _ in
            guard let raw = items.first, let draggedID = UUID(uuidString: raw) else { return false }
            moveRule(id: draggedID, before: rule.id)
            return true
        }
    }

    private func ruleHeaderRow(_ rule: AlertRule, name: String) -> some View {
        HStack(spacing: Spacing.xxs) {
            Image(systemName: "line.3.horizontal")
                .iconSize(.small)
                .foregroundStyle(Palette.textSecondary)
                .help("Drag to reorder")
                .draggable(rule.id.uuidString)

            providerPicker(selection: providerBinding(rule.id))
                .frame(width: 76, alignment: .leading)

            windowPicker(
                selection: windowBinding(rule.id),
                currentSelection: rule.window,
                provider: rule.provider
            )
                .frame(width: 128, alignment: .leading)

            thresholdReadout(rule)

            // The row's controls are narrower than the column (a rule is two controls where an
            // indicator is four), so the switch and the trash button are pushed to the trailing
            // edge — where they line up with the event toggles in the column beside them
            // instead of floating mid-row.
            Spacer(minLength: Spacing.xs)

            Toggle("", isOn: enabledBinding(rule.id))
                .labelsHidden()
                .toggleStyle(.tokiSwitch)
                .accessibilityLabel("\(name) alert enabled")
                .help("Send this alert")

            Button {
                removeRule(rule.id)
            } label: {
                Image(systemName: "trash")
                    .iconSize(.small)
            }
            .buttonStyle(.tokiIcon)
            .foregroundStyle(Palette.textSecondary)
            .accessibilityLabel("Remove the \(name) alert")
            .help("Remove")
        }
    }

    /// The threshold stays a NUMBER on the line, in the slot the stepper well used to occupy,
    /// so the row still reads "5-hour … 60% … on". The bar under the line moves it; this is what
    /// says by how much, to the 5% the rule is actually stored at — a fill length alone is not a
    /// value anyone can quote. (5% steps: finer than that is a distinction nobody makes about a
    /// rate limit, and `AlertRule`'s own init clamps to 1…100% regardless, so this control
    /// cannot produce a rule that never fires.)
    private func thresholdReadout(_ rule: AlertRule) -> some View {
        Text("\(Self.percent(rule.threshold))%")
            .textStyle(.detail)
            .foregroundStyle(Palette.textPrimary)
            .frame(minWidth: 30, alignment: .leading)
            .accessibilityLabel("\(Self.fallbackTitle(for: rule.window)) alert threshold")
    }

    /// The fixed windows plus one entry per model the account is actually scoped on right now
    /// (`MenuBarLayout.scopedModelNames`) — never an unbounded free-text field, and never a
    /// picker offering a model that doesn't exist. `currentSelection` is kept in the list even
    /// if it has since dropped out of scope, so a rule pointing at it still shows its real
    /// state instead of a blank picker. Same control, same reasoning, as the menu-bar editor's.
    private func providerPicker(selection: Binding<UsageProvider>) -> some View {
        Picker("", selection: selection) {
            if menuBar.availableProviders.contains(.claudeCode) {
                Text("Claude").tag(UsageProvider.claudeCode)
            }
            if menuBar.availableProviders.contains(.codex) {
                Text("Codex").tag(UsageProvider.codex)
            }
        }
        .labelsHidden()
        .controlSize(.small)
        .tokiMenuPicker()
        .accessibilityLabel("Provider")
    }

    private func windowPicker(
        selection: Binding<WindowSelector>,
        currentSelection: WindowSelector,
        provider: UsageProvider
    ) -> some View {
        let limits = provider == .claudeCode ? menuBar.limits : menuBar.codexLimits
        var modelNames = MenuBarLayout.scopedModelNames(in: limits)
        if case let .scopedModel(name) = currentSelection, !modelNames.contains(name) {
            modelNames.append(name)
        }
        return Picker("", selection: selection) {
            Text("5-hour").tag(WindowSelector.fiveHour)
            Text("7-day").tag(WindowSelector.sevenDay)
            Text("Busiest model").tag(WindowSelector.highestScopedModel)
            if provider == .claudeCode {
                Text("Extra usage").tag(WindowSelector.extraUsage)
            }
            if modelNames.isEmpty {
                // Say so right here, in the same control, rather than silently offering
                // nothing: an empty picker with no explanation reads as broken.
                Text("No scoped models yet")
                    .tag(currentSelection)
                    .disabled(true)
            } else {
                ForEach(modelNames, id: \.self) { name in
                    Text(name).tag(WindowSelector.scopedModel(name))
                }
            }
        }
        .labelsHidden()
        .controlSize(.small)
        .tokiMenuPicker()
        .accessibilityLabel("Window to watch")
    }

    // MARK: - Body — the other notifications (right column)

    private var eventsColumn: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text("Other notifications")
                .textStyle(.label)
                .foregroundStyle(Palette.textPrimary)
            Text("Everything else Toki can tell you about.")
                .textStyle(.caption)
                .foregroundStyle(Palette.textSecondary)

            VStack(alignment: .leading, spacing: Spacing.xs) {
                eventToggle(
                    "Accounts switched",
                    detail: "Toki moved to another stored account.",
                    isOn: eventBinding(\.onSwap)
                )
                divider
                eventToggle(
                    "Every account is at its limit",
                    detail: "There is no account left with headroom to switch to.",
                    isOn: eventBinding(\.onAllExhausted)
                )
                divider
                eventToggle(
                    "An account needs signing in again",
                    detail: "A stored account's session expired and cannot be used until you sign in.",
                    isOn: eventBinding(\.onNeedsReauth)
                )
                divider
                eventToggle(
                    "A new account signed in",
                    detail: "A coding tool signed into an account that Toki does not store yet.",
                    isOn: eventBinding(\.onNewAccount)
                )
                divider
                if menuBar.availableProviders.contains(.codex) {
                    eventToggle(
                        "A Codex reset is available",
                        detail: "A banked reset becomes available for your account, with its expiry when known.",
                        isOn: eventBinding(\.onBankedResets)
                    )
                    divider
                    eventToggle(
                        "OpenAI announces a reset",
                        detail: "A confirmed announcement of a regular Codex reset. Eligibility depends on the announcement.",
                        isOn: eventBinding(\.onOpenAIResets)
                    )
                    divider
                }
                if menuBar.availableProviders.contains(.claudeCode) {
                    eventToggle(
                        "Anthropic announces a reset",
                        detail: "A confirmed Claude reset announcement, including the affected plans when known.",
                        isOn: eventBinding(\.onClaudeResets)
                    )
                    divider
                    eventToggle(
                        "Claude has an incident",
                        detail: "Anthropic reports a problem affecting Claude — and again when it's resolved.",
                        isOn: eventBinding(\.onServiceStatus)
                    )
                }
                if menuBar.availableProviders.contains(.claudeCode),
                   menuBar.availableProviders.contains(.codex) {
                    divider
                }
                if menuBar.availableProviders.contains(.codex) {
                    eventToggle(
                        "Codex has an incident",
                        detail: "OpenAI reports a problem affecting Codex — and again when it's resolved.",
                        isOn: eventBinding(\.onCodexServiceStatus)
                    )
                }
            }
            .padding(.top, 2)
        }
        .padding(Spacing.sm)
        .panelCard()
    }

    /// Title + one line of detail with a trailing switch. The label goes INSIDE the `Toggle`
    /// (rather than beside it) so the whole row is the control's hit area and its spoken name
    /// — `TokiSwitchToggleStyle` lays the label out and hands it to the accessibility
    /// representation.
    private func eventToggle(_ title: String, detail: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .textStyle(.body)
                    .foregroundStyle(Palette.textPrimary)
                Text(detail)
                    .textStyle(.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.tokiSwitch)
    }

    // MARK: - Mutation

    /// Every edit funnels through here: mutate the working copy, then write the WHOLE value
    /// back to the store. `AlertDriver` and the swap paths re-`load()` on every use, so a
    /// switch moved here is live on the next poll with nothing to invalidate.
    private func update(_ change: (inout NotificationSettings) -> Void) {
        change(&settings)
        store.save(settings)
    }

    /// Rebuilds the edited rule through `AlertRule`'s memberwise init rather than leaving the
    /// mutated fields in place — that init is the one gate that clamps the threshold, and
    /// setting the stored property directly walks straight past it (the same reasoning as
    /// `MenuBarEditorView.mutateIndicators`). The stepper's own 5…100 range already keeps the
    /// value in bounds, so this is the defensive half of the rule, not the only half.
    private func updateRule(_ id: UUID, _ transform: (inout AlertRule) -> Void) {
        update { settings in
            guard let index = settings.rules.firstIndex(where: { $0.id == id }) else { return }
            var rule = settings.rules[index]
            transform(&rule)
            settings.rules[index] = AlertRule(
                id: rule.id,
                provider: rule.provider,
                window: rule.window,
                threshold: rule.threshold,
                isEnabled: rule.isEnabled
            )
        }
    }

    private func addRule() {
        let provider = menuBar.availableProviders.contains(.claudeCode)
            ? UsageProvider.claudeCode
            : .codex
        update {
            $0.rules.append(AlertRule(provider: provider, window: .fiveHour, threshold: 0.9))
        }
    }

    private func removeRule(_ id: UUID) {
        update { $0.rules.removeAll { $0.id == id } }
    }

    private func moveRule(id: UUID, before targetID: UUID) {
        guard id != targetID else { return }
        update { settings in
            guard let fromIndex = settings.rules.firstIndex(where: { $0.id == id }) else { return }
            let rule = settings.rules.remove(at: fromIndex)
            let insertIndex = settings.rules.firstIndex(where: { $0.id == targetID }) ?? settings.rules.count
            settings.rules.insert(rule, at: insertIndex)
        }
    }

    private func windowBinding(_ id: UUID) -> Binding<WindowSelector> {
        Binding(
            get: { settings.rules.first { $0.id == id }?.window ?? .fiveHour },
            set: { newValue in updateRule(id) { $0.window = newValue } }
        )
    }

    private func providerBinding(_ id: UUID) -> Binding<UsageProvider> {
        Binding(
            get: { settings.rules.first { $0.id == id }?.provider ?? .claudeCode },
            set: { newValue in
                updateRule(id) { rule in
                    rule.provider = newValue
                    if newValue == .codex, rule.window == .extraUsage {
                        rule.window = .fiveHour
                    }
                }
            }
        )
    }

    /// Whole percentage points, because that is what the row shows and what the copy says —
    /// keeping the fraction as the control's own value would round-trip 0.9 into 90.00000001%
    /// after a few steps.
    private func thresholdBinding(_ id: UUID) -> Binding<Int> {
        Binding(
            get: { Self.percent(settings.rules.first { $0.id == id }?.threshold ?? 0.9) },
            set: { newValue in updateRule(id) { $0.threshold = Double(newValue) / 100 } }
        )
    }

    private func enabledBinding(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { settings.rules.first { $0.id == id }?.isEnabled ?? false },
            set: { newValue in updateRule(id) { $0.isEnabled = newValue } }
        )
    }

    private func eventBinding(_ keyPath: WritableKeyPath<NotificationSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { settings[keyPath: keyPath] },
            set: { newValue in update { $0[keyPath: keyPath] = newValue } }
        )
    }

    private static func percent(_ fraction: Double) -> Int {
        Int((fraction * 100).rounded())
    }

    // MARK: - Footer (pinned)

    private var footer: some View {
        HStack {
            Button {
                update { $0 = .standard }
            } label: {
                Text("Reset to Defaults")
                    .textStyle(.body)
            }
            .buttonStyle(.tokiSecondary)

            Spacer()

            DoneButton()
        }
    }
}

/// The editor's Done button, and the ONE place that reads `\.dismiss` — for the same measured
/// reason `MenuBarEditorView` scopes its own: `DismissAction` is republished several times
/// while a sheet is being presented, and an `@Environment(\.dismiss)` on the editor itself
/// rebuilds the whole screen once per republish for a value only this button ever calls.
private struct DoneButton: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Button {
            dismiss()
        } label: {
            Text("Done")
                .textStyle(.body)
        }
        .buttonStyle(.tokiProminent)
        .keyboardShortcut(.defaultAction)
    }
}

// MARK: - Preview

#Preview("NotificationsEditorView") {
    let container = ServiceContainer(prewarm: false)
    container.apply(.fixture(.nearLimit))
    return NotificationsEditorView(menuBar: container.menuBarVM)
        .frame(height: NotificationsEditorView.sheetHeight)
}
