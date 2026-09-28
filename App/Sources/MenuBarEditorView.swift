/// MenuBarEditorView — the dedicated sheet for editing `MenuBarConfiguration`.
///
/// Presented from a single row in `SettingsSections` (see its `menuBarSection`). Everything
/// that used to be an inline Settings section — preview, indicator list, style controls,
/// compact mode, reset — lives here now, laid out as an EDITOR rather than a settings list:
/// the preview is pinned so it never scrolls out of view, and the controls are dense enough
/// that three indicators plus every style knob fit beside it with no scrolling at all.
///
/// Three bands, top to bottom:
///  - Header (pinned): light/dark preview tiles, reusing `MenuBarStripRenderer` — the exact
///    path `MenuBarLabel` rasterizes into the real status item — plus the strip's current
///    width in points, so a change's cost against the shared, finite menu-bar space is always
///    visible while making it.
///  - Body (scrolls): indicator list (left) and appearance controls (right), two columns —
///    width the single-column inline section wasted wholesale.
///  - Footer (pinned): Reset to Defaults / Done.
///
/// Only `body` fixes the WIDTH (760pt, matching the sheet). Height is left natural on
/// purpose: the `.sheet` call site in `SettingsSections` is what clamps it to 560pt, so the
/// debug control channel's `menuBarEditor` surface (which renders this view unclamped) reports
/// this view's true natural content height — the number the density requirement is checked
/// against, not a number `.frame(height:)` would silently force to whatever it's told.
import AppKit
import SwiftUI
import TokiCore
import TokiFixtures
import TokiMenuBar

@MainActor
struct MenuBarEditorView: View {

    /// The sheet's presented size — width is fixed on `body` below; height is applied by the
    /// `.sheet` call site in `SettingsSections`. `nonisolated`: plain constants, read from
    /// contexts (like `DebugControlChannel`'s `Surface.defaultWidth`) that aren't themselves
    /// main-actor isolated.
    nonisolated static let sheetWidth: CGFloat = 860
    nonisolated static let sheetHeight: CGFloat = 560

    /// Width of the indicators column. The two body columns are deliberately UNEQUAL: an
    /// indicator row carries six controls on one line and needs 392pt of content width for
    /// them (see `indicatorRow`), which an even split of the body (358pt each) does not give;
    /// the appearance column's paired steppers and short framing fields do fit in what is left.
    nonisolated static let indicatorsColumnWidth: CGFloat = 516
    private static let missingIndicatorID = UUID(
        uuidString: "00000000-0000-0000-0000-000000000000"
    )!

    @Bindable var menuBar: MenuBarViewModel
    /// Rasterization scale for the preview images — the same value `MenuBarLabel` reads to
    /// rasterize the real status item, so the preview is pixel-exact on the developer's
    /// actual display, not a fixed guess.
    @Environment(\.displayScale) private var displayScale

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
    }

    private var divider: some View {
        Rectangle()
            .fill(Palette.hairline)
            .frame(height: 1)
            .opacity(0.6)
    }

    // MARK: - Header (pinned) — preview + width

    private var header: some View {
        // Rasterized once and used twice: as the light tile's picture AND as the source of the
        // width figure beside it. The two appearances differ only in tint, never in size, so
        // the width the light image already carries is the strip's width — asking the renderer
        // for a third image to read one number off it was a third of this header's cost, paid
        // again on every re-render (every stepper tick, every keystroke in a label field).
        let light = previewImage(appearance: .light)
        return HStack(alignment: .center, spacing: Spacing.lg) {
            HStack(spacing: Spacing.sm) {
                previewTile(image: light, appearance: .light, caption: "Light")
                previewTile(image: previewImage(appearance: .dark), appearance: .dark, caption: "Dark")
            }
            Spacer(minLength: Spacing.md)
            VStack(alignment: .trailing, spacing: 2) {
                Text("STRIP WIDTH")
                    .textStyle(.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .kerning(0.3)
                Text("\(Int(light.size.width.rounded())) pt")
                    .textStyle(.metricInline)
                    .foregroundStyle(Palette.textPrimary)
            }
        }
    }

    private func previewTile(image: NSImage, appearance: ColorScheme, caption: String) -> some View {
        VStack(spacing: 3) {
            // The background and clip shape are sized BY the image's content (padding, not a
            // fixed frame) — a fixed width clipped a wider strip's edges off in earlier builds
            // of this tile. The strip's own natural width is exactly the thing this screen
            // exists to show honestly (see the header's "STRIP WIDTH" figure right beside it).
            Image(nsImage: image)
                .renderingMode(.template)
                // The real status item's tint: macOS paints a template image's alpha mask
                // black on the light bar and white on the dark one. Reproducing both side by
                // side (rather than reading the app's own current appearance) answers "does
                // this work in both?" without making the user switch their system theme to
                // check.
                .foregroundStyle(appearance == .light ? Color.black : Color.white)
                .padding(.horizontal, 10)
                .frame(minWidth: 60, minHeight: 30)
                .background(appearance == .light ? previewLightBackground : previewDarkBackground)
                .clipShape(RoundedRectangle(cornerRadius: Radius.element, style: .continuous))
            Text(caption)
                .textStyle(.caption)
                .foregroundStyle(Palette.textSecondary)
        }
    }

    private var previewLightBackground: Color { Color(white: 0.90) }
    private var previewDarkBackground: Color { Color(white: 0.15) }

    /// The live resolved indicators when limits are loaded, or a representative fallback
    /// (`TokiFixtures`' `singleAccount` scenario) when they are not yet — a blank preview in
    /// the first seconds after launch would read as broken, not as "still loading".
    private var previewLimits: UsageLimits? {
        menuBar.limits ?? Self.placeholderLimits
    }

    /// The stand-in shown until live limits arrive, built ONCE for the process.
    ///
    /// It used to be `Fixtures.bundle(for:now:).limits`, evaluated inside `body`: that builds
    /// the entire scenario — summary, accounts, instances, a 140-day statistics history —
    /// to read one field off it, measured at 7.9ms a call, once per preview tile per pass.
    ///
    /// **This did not fix the editor's slow presentation, and should not be read as having.**
    /// It was measured against that and made no difference (683ms vs 643ms), because the path
    /// is only taken while `menuBar.limits` is still nil — the first seconds after launch.
    /// It is kept because throwing away a 140-day history to read one field is waste wherever
    /// it happens; the presentation cost lies elsewhere, in how many times the sheet's body is
    /// evaluated.
    ///
    /// `nonisolated(unsafe)` and eager: a `let` on the enclosing struct would rebuild with
    /// every view value, which is the thing being fixed.
    private nonisolated(unsafe) static let placeholderLimits: UsageLimits? =
        Fixtures.bundle(for: .singleAccount, now: Date()).limits

    private var previewIndicators: [ResolvedIndicator] {
        guard !visibleIndicators.isEmpty else { return [] }
        let visibleConfiguration = MenuBarConfiguration(
            indicators: visibleIndicators,
            style: menuBar.configuration.style,
            compact: menuBar.configuration.compact
        )
        return MenuBarLayout.resolve(
            visibleConfiguration,
            claudeLimits: menuBar.limits ?? previewLimits,
            codexLimits: menuBar.codexLimits ?? Self.placeholderCodexLimits
        )
    }

    /// Provider rows remain persisted so reinstalling a CLI can restore its setup, but an
    /// unavailable provider never appears in this editor or consumes its visible row count.
    private var visibleIndicators: [MenuBarIndicator] {
        menuBar.configuration.indicators.filter {
            menuBar.availableProviders.contains($0.provider)
        }
    }

    private nonisolated(unsafe) static let placeholderCodexLimits = UsageLimits(
        windows: [
            RateLimitWindow(
                id: "session", title: "5-hour", utilization: 0.28,
                resetsAt: Date().addingTimeInterval(10_800), isAvailable: true
            ),
            RateLimitWindow(
                id: "weekly_all", title: "7-day", utilization: 0.52,
                resetsAt: Date().addingTimeInterval(345_600), isAvailable: true
            ),
        ],
        extra: nil,
        fetchedAt: Date()
    )

    /// The exact `NSImage` `MenuBarStripRenderer` hands `MenuBarLabel` for the real status
    /// item — see this file's doc comment for why nothing here re-derives that drawing.
    private func previewImage(appearance: ColorScheme) -> NSImage {
        MenuBarStripRenderer.image(
            for: previewIndicators,
            style: menuBar.configuration.style,
            colorScheme: appearance,
            scale: displayScale
        )
    }

    // MARK: - Body (scrolls) — two columns

    private var bodyColumns: some View {
        HStack(alignment: .top, spacing: Spacing.lg) {
            indicatorsColumn
                .frame(width: Self.indicatorsColumnWidth, alignment: .leading)
            appearanceColumn
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Body — indicators (left column)

    private var indicatorsColumn: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(alignment: .center) {
                Text("Indicators")
                    .textStyle(.label)
                    .foregroundStyle(Palette.textPrimary)
                Spacer(minLength: Spacing.sm)
                Button {
                    addIndicator()
                } label: {
                    Image(systemName: "plus")
                        .iconSize(.regular)
                }
                .buttonStyle(.tokiIcon)
                .foregroundStyle(Palette.accent)
                .disabled(
                    visibleIndicators.count >= MenuBarConfiguration.maximumIndicators
                        || menuBar.availableProviders.isEmpty
                )
                .help(
                    visibleIndicators.count >= MenuBarConfiguration.maximumIndicators
                        ? "The strip holds at most \(MenuBarConfiguration.maximumIndicators) indicators."
                        : "Add an indicator"
                )
            }
            Text("Drag to reorder.")
                .textStyle(.caption)
                .foregroundStyle(Palette.textSecondary)

            VStack(alignment: .leading, spacing: Spacing.xs) {
                ForEach(Array(visibleIndicators.enumerated()), id: \.element.id) { offset, indicator in
                    if offset > 0 { divider }
                    indicatorRow(indicator)
                }
            }
            .padding(.top, 2)
        }
        .padding(Spacing.sm)
        .panelCard()
    }

    /// One indicator, one line, read left to right as the sentence it is: WHICH window, whether
    /// its name is shown and what that name is, HOW it is drawn, and remove.
    ///
    /// It used to take two lines (window + rendering, then the label switch + field). Measured
    /// off the rendered `menuBarEditor` surface: 56pt of row pitch then, 39pt now — the
    /// indicators card for three indicators falls from 220pt to 169pt, so the list no longer
    /// grows towards the space the editor has. (Re-measured after the controls moved onto the
    /// app's own chrome: the wells are 2pt taller per row than the stock controls were, which
    /// takes the whole editor from 512pt of natural content height to 522pt — still well
    /// inside the 560pt sheet.)
    ///
    /// The trade is the left column's width: these six controls need the 392pt of content
    /// width `indicatorsColumnWidth` gives them, which an even split of the body (358pt each)
    /// does not — hence the deliberately unequal columns. The appearance column's paired
    /// steppers and short framing fields stay legible in what is left; an indicator row would
    /// not.
    private func indicatorRow(_ indicator: MenuBarIndicator) -> some View {
        let canRemove = visibleIndicators.count > 1
        return HStack(spacing: Spacing.xxs) {
            Image(systemName: "line.3.horizontal")
                .iconSize(.small)
                .foregroundStyle(Palette.textSecondary)
                .help("Drag to reorder")
                .draggable(indicator.id.uuidString)

            providerPicker(selection: providerBinding(indicator.id))
                .frame(width: 76, alignment: .leading)

            windowPicker(
                selection: windowBinding(indicator.id),
                currentSelection: indicator.window,
                provider: indicator.provider
            )
                .frame(width: 116, alignment: .leading)

            Toggle("", isOn: showsLabelBinding(indicator.id))
                .labelsHidden()
                .toggleStyle(.tokiSwitch)
                .help("Show this indicator's name on the strip")

            TextField(derivedLabel(for: indicator), text: customLabelBinding(indicator.id))
                .textStyle(.caption)
                .foregroundStyle(Palette.textPrimary)
                .tokiField()
                .frame(minWidth: 56)

            TokiSegmentedPicker(
                selection: renderingBinding(indicator.id),
                options: [
                    .init(.bar, "Bar"),
                    .init(.number, "Num"),
                    .init(.barAndNumber, "Both"),
                ],
                name: "Rendering"
            )
            .frame(width: 104)

            Button {
                removeIndicator(indicator.id)
            } label: {
                Image(systemName: "trash")
                    .iconSize(.small)
            }
            .buttonStyle(.tokiIcon)
            .foregroundStyle(canRemove ? Palette.textSecondary : Palette.textSecondary.opacity(0.4))
            .disabled(!canRemove)
            .help(canRemove ? "Remove" : "At least one indicator is required")
        }
        .dropDestination(for: String.self) { items, _ in
            guard let raw = items.first, let draggedID = UUID(uuidString: raw) else { return false }
            moveIndicator(id: draggedID, before: indicator.id)
            return true
        }
    }

    /// The fixed windows plus one entry per model the account is actually scoped on right
    /// now (`MenuBarLayout.scopedModelNames`) — never an unbounded free-text field, and never
    /// a picker offering a model that doesn't exist. `currentSelection` is kept in the list
    /// even if it has since dropped out of scope, so a row/binding pointing at it still shows
    /// its real current state instead of a blank picker.
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
                // nothing: an empty picker with no explanation reads as broken, and a
                // free-text field would let someone type a model name the account was never
                // scoped on.
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
    }

    /// The name the strip would show with no custom override — `5h`, `7d`, the model's own
    /// name — resolved through the real `MenuBarLayout`, not a second hand-rolled copy of its
    /// fallback rules.
    private func derivedLabel(for indicator: MenuBarIndicator) -> String {
        let bare = MenuBarIndicator(
            id: indicator.id, provider: indicator.provider,
            window: indicator.window, rendering: indicator.rendering,
            showsLabel: indicator.showsLabel, customLabel: nil
        )
        let config = MenuBarConfiguration(indicators: [bare])
        return MenuBarLayout.resolve(
            config,
            claudeLimits: menuBar.limits,
            codexLimits: menuBar.codexLimits
        ).first?.title ?? ""
    }

    // MARK: - Body — indicator mutation

    /// Every indicator edit funnels through here, which always reconstructs the whole
    /// `MenuBarConfiguration` via its memberwise init — the one gate that clamps the list
    /// length and, for whichever indicator changed, re-sanitizes its custom label — rather
    /// than mutating stored fields directly and skipping that gate (see
    /// `MenuBarConfiguration`'s and `MenuBarIndicator`'s own doc comments).
    private func mutateIndicators(_ change: (inout [MenuBarIndicator]) -> Void) {
        var indicators = menuBar.configuration.indicators
        change(&indicators)
        let current = menuBar.configuration
        menuBar.configuration = MenuBarConfiguration(indicators: indicators, style: current.style, compact: current.compact)
    }

    private func updateIndicator(_ id: UUID, _ transform: (inout MenuBarIndicator) -> Void) {
        mutateIndicators { indicators in
            guard let index = indicators.firstIndex(where: { $0.id == id }) else { return }
            transform(&indicators[index])
        }
    }

    private func addIndicator() {
        let available = menuBar.availableProviders
        mutateIndicators { indicators in
            // Hidden rows for an uninstalled provider must not make the visible editor look
            // stuck at fewer than five rows. Reclaim those persisted slots only when the
            // user actually asks to add a visible row.
            while indicators.count >= MenuBarConfiguration.maximumIndicators,
                  let hidden = indicators.lastIndex(where: { !available.contains($0.provider) }) {
                indicators.remove(at: hidden)
            }
            guard indicators.count < MenuBarConfiguration.maximumIndicators else { return }
            let provider = available.contains(.claudeCode)
                ? UsageProvider.claudeCode
                : .codex
            indicators.append(MenuBarIndicator(provider: provider, window: .fiveHour, rendering: .number))
        }
    }

    /// Never removes the last row — `MenuBarConfiguration.clamped` would silently spring an
    /// empty list back to the standard set, which would look like a bug rather than a rule.
    /// The row's own trash button is already disabled at count 1 (see `indicatorRow`); this
    /// guard is the second, defensive half of the same rule.
    private func removeIndicator(_ id: UUID) {
        guard visibleIndicators.count > 1 else { return }
        mutateIndicators { indicators in
            indicators.removeAll { $0.id == id }
        }
        if case let .pinnedIndicator(pinnedID) = menuBar.configuration.compact,
           pinnedID == id,
           let replacement = visibleIndicators.first?.id {
            menuBar.configuration.compact = .pinnedIndicator(replacement)
        }
    }

    private func moveIndicator(id: UUID, before targetID: UUID) {
        guard id != targetID else { return }
        mutateIndicators { indicators in
            guard let fromIndex = indicators.firstIndex(where: { $0.id == id }) else { return }
            let item = indicators.remove(at: fromIndex)
            let insertIndex = indicators.firstIndex(where: { $0.id == targetID }) ?? indicators.count
            indicators.insert(item, at: insertIndex)
        }
    }

    private func windowBinding(_ id: UUID) -> Binding<WindowSelector> {
        Binding(
            get: { menuBar.configuration.indicators.first { $0.id == id }?.window ?? .fiveHour },
            set: { newValue in updateIndicator(id) { $0.window = newValue } }
        )
    }

    private func providerBinding(_ id: UUID) -> Binding<UsageProvider> {
        Binding(
            get: {
                menuBar.configuration.indicators.first { $0.id == id }?.provider
                    ?? .claudeCode
            },
            set: { newValue in
                updateIndicator(id) { indicator in
                    indicator.provider = newValue
                    if newValue == .codex, indicator.window == .extraUsage {
                        indicator.window = .fiveHour
                    }
                }
            }
        )
    }

    private func renderingBinding(_ id: UUID) -> Binding<IndicatorRendering> {
        Binding(
            get: { menuBar.configuration.indicators.first { $0.id == id }?.rendering ?? .number },
            set: { newValue in updateIndicator(id) { $0.rendering = newValue } }
        )
    }

    private func showsLabelBinding(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { menuBar.configuration.indicators.first { $0.id == id }?.showsLabel ?? true },
            set: { newValue in updateIndicator(id) { $0.showsLabel = newValue } }
        )
    }

    /// Caps the live-typed length to match `MenuBarIndicator.maximumCustomLabelLength` — a
    /// live cap rather than routing every keystroke through the model's full sanitizer, which
    /// also trims whitespace and would delete a space the moment someone typed it, breaking a
    /// multi-word label like "extra usage" as they type it. An emptied field clears back to
    /// the derived label, matching `MenuBarIndicator`'s own "blank means nil" rule.
    private func customLabelBinding(_ id: UUID) -> Binding<String> {
        Binding(
            get: { menuBar.configuration.indicators.first { $0.id == id }?.customLabel ?? "" },
            set: { newValue in
                let capped = String(newValue.prefix(MenuBarIndicator.maximumCustomLabelLength))
                updateIndicator(id) { $0.customLabel = capped.isEmpty ? nil : capped }
            }
        )
    }

    // MARK: - Body — appearance (right column)

    private var appearanceColumn: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            groupHeader("Framing")
            HStack(spacing: Spacing.sm) {
                framingField("Leading", binding: styleTextBinding(\.leading))
                framingField("Separator", binding: styleTextBinding(\.separator))
                framingField("Trailing", binding: styleTextBinding(\.trailing))
            }

            groupHeader("Spacing & size")
            HStack(spacing: Spacing.sm) {
                compactStepper(
                    "Label gap", value: styleDoubleBinding(\.labelGap),
                    range: MenuBarStyle.minimumLabelGap...MenuBarStyle.maximumLabelGap, unit: "pt"
                )
                compactStepper(
                    "Group gap", value: styleDoubleBinding(\.groupGap),
                    range: MenuBarStyle.minimumGroupGap...MenuBarStyle.maximumGroupGap, unit: "pt"
                )
            }
            HStack(spacing: Spacing.sm) {
                compactStepper(
                    "Value size", value: styleDoubleBinding(\.valueSize),
                    range: MenuBarStyle.minimumValueSize...MenuBarStyle.maximumValueSize, unit: "pt"
                )
                compactStepper(
                    "Label size", value: styleDoubleBinding(\.labelSize),
                    range: MenuBarStyle.minimumLabelSize...MenuBarStyle.maximumLabelSize, unit: "pt"
                )
            }
            HStack(spacing: Spacing.sm) {
                compactStepper(
                    "Unit scale", value: styleDoubleBinding(\.unitScale),
                    range: MenuBarStyle.minimumUnitScale...MenuBarStyle.maximumUnitScale, step: 0.05, format: "%.2f"
                )
                compactStepper(
                    "Bar width", value: styleDoubleBinding(\.barWidth),
                    range: MenuBarStyle.minimumBarWidth...MenuBarStyle.maximumBarWidth, unit: "pt"
                )
            }
            compactStepper(
                "Bar height", value: styleDoubleBinding(\.barHeight),
                range: MenuBarStyle.minimumBarHeight...MenuBarStyle.maximumBarHeight, unit: "pt"
            )

            groupHeader("Compact mode")
            TokiSegmentedPicker(
                selection: compactModeBinding,
                options: [
                    .init(CompactModeOption.off, "Off"),
                    .init(CompactModeOption.worstOf, "Worst of"),
                    .init(CompactModeOption.pinned, "Pinned"),
                ],
                name: "Compact mode",
                role: .label
            )
            Text(compactModeDetail)
                .textStyle(.caption)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if compactModeOption == .pinned {
                pinnedIndicatorPicker
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(Spacing.sm)
        .panelCard()
    }

    private func groupHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .textStyle(.caption)
            .foregroundStyle(Palette.textSecondary)
            .kerning(0.3)
    }

    private var pinnedIndicatorPicker: some View {
        Picker("", selection: pinnedIndicatorBinding) {
            ForEach(visibleIndicators) { indicator in
                Text("\(indicator.provider.displayName) · \(derivedLabel(for: indicator))")
                    .tag(indicator.id)
            }
        }
        .labelsHidden()
        .controlSize(.small)
        .tokiMenuPicker()
        .accessibilityLabel("Pinned indicator")
    }

    private func framingField(_ title: String, binding: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .textStyle(.caption)
                .foregroundStyle(Palette.textSecondary)
            TextField("", text: binding)
                .textStyle(.detail)
                .foregroundStyle(Palette.textPrimary)
                .controlSize(.small)
                .multilineTextAlignment(.center)
                .frame(width: 48)
                .tokiField()
        }
    }

    private func compactStepper(
        _ title: String, value: Binding<Double>, range: ClosedRange<Double>,
        step: Double = 1, format: String = "%.0f", unit: String = ""
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .textStyle(.caption)
                .foregroundStyle(Palette.textSecondary)
            HStack(spacing: Spacing.xxs) {
                Text(String(format: format, value.wrappedValue) + unit)
                    .textStyle(.detail)
                    .foregroundStyle(Palette.textPrimary)
                    .frame(minWidth: 34, alignment: .leading)
                Stepper("", value: value, in: range, step: step)
                    .labelsHidden()
                    .controlSize(.small)
            }
            .tokiStepperWell()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Routes every keystroke through `MenuBarStyle`'s own memberwise init (see
    /// `mutateStyle`), which sanitizes AND caps free text to
    /// `MenuBarStyle.maximumFreeTextLength` — trimming on every keystroke is exactly right
    /// here (unlike the custom-label field above): these fields are framing punctuation
    /// ("[", "·"), not multi-word text, and the model's own documented meaning of a
    /// whitespace-only value is "collapse to empty", not "blank but present".
    private func styleTextBinding(_ keyPath: WritableKeyPath<MenuBarStyle, String>) -> Binding<String> {
        Binding(
            get: { menuBar.configuration.style[keyPath: keyPath] },
            set: { newValue in mutateStyle { $0[keyPath: keyPath] = newValue } }
        )
    }

    private func styleDoubleBinding(_ keyPath: WritableKeyPath<MenuBarStyle, Double>) -> Binding<Double> {
        Binding(
            get: { menuBar.configuration.style[keyPath: keyPath] },
            set: { newValue in mutateStyle { $0[keyPath: keyPath] = newValue } }
        )
    }

    /// Reconstructs `MenuBarStyle` via its memberwise init after every edit — the one gate
    /// that clamps every numeric field and sanitizes the free-text ones — rather than
    /// mutating the stored struct's fields directly and bypassing it (see `MenuBarStyle`'s
    /// own doc comment, "Clamping is the real work here"). The steppers above already keep
    /// values inside bounds on their own, so this is defense in depth for them; for the
    /// free-text fields it is the ONLY place the cap and sanitizing are enforced.
    private func mutateStyle(_ change: (inout MenuBarStyle) -> Void) {
        var style = menuBar.configuration.style
        change(&style)
        let rebuilt = MenuBarStyle(
            leading: style.leading, trailing: style.trailing, separator: style.separator,
            labelGap: style.labelGap, groupGap: style.groupGap, valueSize: style.valueSize,
            labelSize: style.labelSize, unitScale: style.unitScale,
            barWidth: style.barWidth, barHeight: style.barHeight
        )
        let current = menuBar.configuration
        menuBar.configuration = MenuBarConfiguration(indicators: current.indicators, style: rebuilt, compact: current.compact)
    }

    // MARK: - Body — compact mode

    /// What the strip collapses to — off (draws every configured indicator), worst-of (one
    /// indicator, whichever is currently worst), or pinned (one indicator, always the same
    /// window). Mirrors `CompactSelection` one-to-one; kept as its own type only because a
    /// segmented `Picker` needs a flat, `Hashable` tag set and `.pinned` carries an associated
    /// `WindowSelector` the segments themselves don't need to distinguish.
    private enum CompactModeOption: Hashable {
        case off, worstOf, pinned
    }

    private var compactModeOption: CompactModeOption {
        switch menuBar.configuration.compact {
        case nil: .off
        case .worstOf: .worstOf
        case .pinned, .pinnedIndicator: .pinned
        }
    }

    private var compactModeDetail: String {
        switch compactModeOption {
        case .off: "Draw every configured indicator."
        case .worstOf: "Collapse to whichever configured indicator is currently worst."
        case .pinned: "Collapse to one indicator, always."
        }
    }

    private var compactModeBinding: Binding<CompactModeOption> {
        Binding(
            get: { compactModeOption },
            set: { newValue in
                switch newValue {
                case .off:
                    menuBar.configuration.compact = nil
                case .worstOf:
                    menuBar.configuration.compact = .worstOf
                case .pinned:
                    // Pin the exact row, including its provider. A window-only pin cannot
                    // distinguish Claude 5-hour from Codex 5-hour.
                    if let fallback = visibleIndicators.first?.id {
                        menuBar.configuration.compact = .pinnedIndicator(fallback)
                    }
                }
            }
        )
    }

    private var pinnedIndicatorBinding: Binding<UUID> {
        Binding(
            get: {
                switch menuBar.configuration.compact {
                case .pinnedIndicator(let id) where visibleIndicators.contains(where: { $0.id == id }):
                    return id
                case .pinned(let window):
                    return visibleIndicators.first(where: { $0.window == window })?.id
                        ?? visibleIndicators.first?.id
                        ?? Self.missingIndicatorID
                default:
                    return visibleIndicators.first?.id ?? Self.missingIndicatorID
                }
            },
            set: { newValue in menuBar.configuration.compact = .pinnedIndicator(newValue) }
        )
    }

    // MARK: - Footer (pinned)

    private var footer: some View {
        HStack {
            Button {
                menuBar.configuration = .standard
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

/// The editor's Done button, and the ONE place that reads `\.dismiss`.
///
/// It is its own view purely to contain that dependency. `DismissAction` is republished
/// several times while a sheet is being presented — measured on this screen: five separate
/// `_dismiss changed` invalidations between the click and the sheet settling — so a
/// `@Environment(\.dismiss)` on `MenuBarEditorView` itself made SwiftUI rebuild the entire
/// editor (both columns, every picker, three strip rasterisations) once per republish, for a
/// value only this button ever calls. Scoped here, those invalidations rebuild one button.
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

#Preview("MenuBarEditorView") {
    let container = ServiceContainer(prewarm: false)
    container.apply(.fixture(.singleAccount))
    return MenuBarEditorView(menuBar: container.menuBarVM)
        .frame(height: MenuBarEditorView.sheetHeight)
}
