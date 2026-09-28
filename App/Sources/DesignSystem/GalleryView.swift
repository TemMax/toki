/// GalleryView — the design-system component gallery.
///
/// Every reusable component in every meaningful state, grouped by kind, each specimen
/// labelled with the state it represents. This is an OBSERVING surface: it instantiates
/// components exactly as their own files do, with no restyling and no new tokens, so that
/// what ends up in the snapshotted PNG is the actual, unmodified component.
///
/// Two states could not be shown honestly and are called out where they occur rather than
/// silently rendered as something they are not — see the `SegmentedControl` and
/// `glassPanel()/panelCard()` sections below.
import SwiftUI
import TokiCore
import TokiMenuBar

struct GalleryView: View {
    var topInset: CGFloat = 0

    // Headless snapshots never fire onAppear; start settled in flat mode like every other
    // surface (see AccountsView, InstancesView, ...).
    @State private var isVisible = SnapshotConfig.flatSurfaces

    // SegmentedControl is hard-wired to DashboardViewModel.Range (not generic over an
    // option set — see the section below), so one @State per "option selected" specimen.
    @State private var rangeToday: DashboardViewModel.Range = .today
    @State private var range7Day: DashboardViewModel.Range = .last7Days
    @State private var range30Day: DashboardViewModel.Range = .last30Days
    @State private var rangeAllTime: DashboardViewModel.Range = .allTime

    // NumericRoll: lets a live viewer see the roll direction change; the static render
    // shows whatever this settles to.
    @State private var rollUp = false

    // glassPanel()/panelCard() read a single un-scoped global (SnapshotConfig.flatSurfaces),
    // not an environment value — there is no way to show both states of the SAME specimen
    // simultaneously without modifying GlassSurface.swift. This toggle is the closest honest
    // approximation: it drives the live global so a human can flip between the two, but the
    // headless --gallery/--snapshot capture always pins the global to `true` before
    // rendering (see SurfaceRenderer/SnapshotRunner), so the rendered PNG can only ever show
    // the flat stand-in for both cards. See the report for the full finding.
    @State private var liveFlatSurfaces = SnapshotConfig.flatSurfaces

    // StaggerIn: lets a live viewer replay the entrance; the static render always shows the
    // settled state (SnapshotConfig.staticEntrance is forced true for every offscreen render).
    @State private var staggerReplay = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                capsuleGaugeSection
                statusPillSection
                segmentedControlSection
                sparklineSection
                numericRollSection
                buttonSection
                surfaceSection
                typographySection
                sectionHeaderSection
                brandSection
                menuBarLabelSection
                staggerInSection
                summaryCardSection
                metricColorSection
            }
            .padding(.horizontal, Spacing.xl)
            .padding(.top, topInset + Spacing.xl)
            .padding(.bottom, Spacing.xl)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Palette.bg)
        .onAppear { isVisible = true }
    }

    // MARK: - CapsuleGauge

    private var capsuleGaugeSection: some View {
        GallerySection("CapsuleGauge") {
            FlowRow {
                Specimen("0%, no detail") {
                    CapsuleGauge(title: "5-hour", fraction: 0)
                }
                Specimen("34%, with detail") {
                    CapsuleGauge(title: "5-hour", fraction: 0.34, detail: "resets in ~2h 10m")
                }
                Specimen("60% — ok/warn threshold") {
                    CapsuleGauge(title: "7-day", fraction: 0.60, detail: "resets in ~4d")
                }
                Specimen("85% — warn/critical threshold") {
                    CapsuleGauge(title: "7-day Opus", fraction: 0.85, detail: "resets in ~6d")
                }
                Specimen("100%, no detail") {
                    CapsuleGauge(title: "5-hour", fraction: 1.0)
                }
                Specimen("unavailable") {
                    CapsuleGauge(title: "7-day Fable", fraction: 0, isUnavailable: true)
                }
                Specimen("long title truncates") {
                    CapsuleGauge(
                        title: "An extremely long window title that must truncate",
                        fraction: 0.5,
                        detail: "and this detail caption is long too"
                    )
                    .frame(width: 160)
                }
            }
        }
    }

    // MARK: - StatusPill

    private var statusPillSection: some View {
        GallerySection("StatusPill") {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                FlowRow {
                    ForEach(statusPillColors, id: \.name) { entry in
                        Specimen("\(entry.name), active") {
                            StatusPill(text: entry.name, color: entry.color, active: true)
                        }
                    }
                }
                FlowRow {
                    ForEach(statusPillColors, id: \.name) { entry in
                        Specimen("\(entry.name), inactive") {
                            StatusPill(text: entry.name, color: entry.color)
                        }
                    }
                }
            }
        }
    }

    /// Every Palette color StatusPill is actually instantiated with across the app
    /// (AccountsView, EnvironmentCards, MenuBarPanelView, and its own preview).
    private var statusPillColors: [(name: String, color: Color)] {
        [
            ("Accent", Palette.accent),
            ("OK", Palette.ok),
            ("Warn", Palette.warn),
            ("Critical", Palette.critical),
            ("Secondary", Palette.textSecondary),
        ]
    }

    // MARK: - SegmentedControl

    private var segmentedControlSection: some View {
        GallerySection("SegmentedControl") {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text(
                    "FINDING: SegmentedControl binds @Binding var selection: " +
                    "DashboardViewModel.Range, a fixed 4-case enum — it is not generic over " +
                    "an option set. A different option count cannot be shown without " +
                    "changing the component, so only the 4-option case it actually supports " +
                    "is shown below, one specimen per selected option."
                )
                .textStyle(.detail)
                .foregroundStyle(Palette.warn)
                .fixedSize(horizontal: false, vertical: true)

                FlowRow {
                    Specimen("\"Today\" selected") {
                        SegmentedControl(selection: $rangeToday).frame(width: 340)
                    }
                    Specimen("\"7 Days\" selected") {
                        SegmentedControl(selection: $range7Day).frame(width: 340)
                    }
                    Specimen("\"30 Days\" selected") {
                        SegmentedControl(selection: $range30Day).frame(width: 340)
                    }
                    Specimen("\"All Time\" selected") {
                        SegmentedControl(selection: $rangeAllTime).frame(width: 340)
                    }
                }
            }
        }
    }

    // MARK: - Sparkline / MiniBars

    private var sparklineSection: some View {
        GallerySection("Sparkline") {
            FlowRow {
                Specimen("many points") {
                    sparkBox { Sparkline(values: [12, 45, 28, 67, 50, 89, 72, 55, 91, 64, 38, 77]) }
                }
                Specimen("two points") {
                    sparkBox { Sparkline(values: [40, 88], color: Palette.ok) }
                }
                Specimen("one point") {
                    sparkBox { Sparkline(values: [55], color: Palette.warn) }
                }
                Specimen("all-equal, non-zero (flat line)") {
                    sparkBox { Sparkline(values: [50, 50, 50, 50, 50], color: Palette.critical) }
                }
                Specimen("all-equal, zero") {
                    sparkBox { Sparkline(values: [0, 0, 0, 0], color: Palette.critical) }
                }
                Specimen("empty") {
                    sparkBox { Sparkline(values: []) }
                }
                Specimen("MiniBars, many values") {
                    sparkBox { MiniBars(values: [12, 45, 28, 67, 50, 89, 72]) }
                }
            }
        }
    }

    private func sparkBox<V: View>(@ViewBuilder _ content: () -> V) -> some View {
        content()
            .frame(width: 180)
            .padding(Spacing.sm)
            .panelCard()
    }

    // MARK: - NumericRoll

    private var numericRollSection: some View {
        GallerySection("NumericRoll") {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                FlowRow {
                    Specimen("847") {
                        Text(847, format: .number)
                            .heroNumber()
                            .foregroundStyle(Palette.textPrimary)
                            .numericRoll(value: 847)
                    }
                    Specimen("$42.80") {
                        Text(verbatim: "$42.80")
                            .heroNumber()
                            .foregroundStyle(Palette.accent)
                            .numericRoll(value: 42.80)
                    }
                    Specimen("0") {
                        Text(0, format: .number)
                            .heroNumber()
                            .foregroundStyle(Palette.textSecondary)
                            .numericRoll(value: 0)
                    }
                    Specimen(rollUp ? "rolled up (tap to roll down)" : "rolled down (tap to roll up)") {
                        let value: Double = rollUp ? 1240 : 847
                        Text(value, format: .number)
                            .heroNumber()
                            .foregroundStyle(Palette.textPrimary)
                            .numericRoll(value: value)
                            .onTapGesture { rollUp.toggle() }
                    }
                }
            }
        }
    }

    // MARK: - Buttons

    private var buttonSection: some View {
        GallerySection("Buttons") {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text(
                    "FINDING: HoldToKillButton never reads @Environment(\\.isEnabled), so " +
                    "wrapping it in .disabled(true) — the standard SwiftUI way to express a " +
                    "disabled button — has NO visible or functional effect: the hold gesture " +
                    "still fires and nothing dims. The two specimens below are pixel-identical."
                )
                .textStyle(.detail)
                .foregroundStyle(Palette.warn)
                .fixedSize(horizontal: false, vertical: true)

                FlowRow {
                    Specimen("normal") {
                        HoldToKillButton(action: {})
                    }
                    Specimen(".disabled(true) — no effect, see finding") {
                        HoldToKillButton(action: {})
                            .disabled(true)
                    }
                }
            }
        }
    }

    // MARK: - Surfaces (glassPanel / panelCard)

    private var surfaceSection: some View {
        GallerySection("Surfaces — glassPanel() / panelCard()") {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text(
                    "FINDING: SnapshotConfig.flatSurfaces is a single un-scoped global, not " +
                    "an environment value, so the two states cannot both be rendered in one " +
                    "tree at once — this page cannot show \"flat next to real\" simultaneously " +
                    "the way the brief asks. The toggle below flips the live global for a " +
                    "human running the app, but SurfaceRenderer pins flatSurfaces = true " +
                    "before every headless render (see SnapshotRunner / DebugControlChannel), " +
                    "so the --gallery / --snapshot PNG of this section always shows the FLAT " +
                    "stand-in for both cards, never real Liquid Glass, regardless of this toggle."
                )
                .textStyle(.detail)
                .foregroundStyle(Palette.warn)
                .fixedSize(horizontal: false, vertical: true)

                Toggle("SnapshotConfig.flatSurfaces (live only — ignored by headless capture)", isOn: $liveFlatSurfaces)
                    .toggleStyle(.switch)
                    .textStyle(.detail)
                    .onChange(of: liveFlatSurfaces) { _, newValue in
                        SnapshotConfig.flatSurfaces = newValue
                    }

                FlowRow {
                    Specimen("glassPanel()") {
                        Text("Panel content")
                            .cardLabel()
                            .padding(Spacing.md)
                            .glassPanel()
                            .frame(width: 200)
                    }
                    Specimen("panelCard()") {
                        Text("Card content")
                            .cardLabel()
                            .padding(Spacing.md)
                            .panelCard()
                            .frame(width: 200)
                    }
                }
                .id(liveFlatSurfaces)
            }
        }
    }

    // MARK: - Typography

    private var typographySection: some View {
        GallerySection("Typography") {
            FlowRow {
                Specimen(".cardValue() + .cardLabel()") {
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        Text("1.2M").cardValue()
                        Text("Tokens (In+Out)").cardLabel()
                    }
                }
                Specimen(".heroNumber()") {
                    Text("87%")
                        .heroNumber()
                        .foregroundStyle(Palette.critical)
                }
            }
        }
    }

    // MARK: - SectionHeader

    private var sectionHeaderSection: some View {
        GallerySection("SectionHeader") {
            Specimen("uppercased, tracked caps") {
                SectionHeader("Current Usage")
            }
        }
    }

    // MARK: - BrandBadge / AppIconBadge

    private var brandSection: some View {
        GallerySection("BrandBadge / AppIconBadge") {
            FlowRow {
                Specimen("BrandBadge 20/28/36/44") {
                    HStack(spacing: Spacing.sm) {
                        BrandBadge(size: 20)
                        BrandBadge(size: 28)
                        BrandBadge(size: 36)
                        BrandBadge(size: 44, symbolName: "gauge.with.dots.needle.bottom.50percent")
                    }
                }
                Specimen("AppIconBadge 20/30/44") {
                    HStack(spacing: Spacing.sm) {
                        AppIconBadge(size: 20)
                        AppIconBadge(size: 30)
                        AppIconBadge(size: 44)
                    }
                }
            }
        }
    }

    // MARK: - MenuBarLabel

    private var menuBarLabelSection: some View {
        GallerySection("MenuBarLabel") {
            FlowRow {
                ForEach([0, 42, 87, 100], id: \.self) { percent in
                    Specimen("\(percent)%") {
                        MenuBarLabel(indicators: [
                            ResolvedIndicator(
                                title: "5h", fraction: Double(percent) / 100,
                                rendering: .bar, isUnavailable: false
                            ),
                        ])
                        .padding(.horizontal, Spacing.sm)
                        .padding(.vertical, Spacing.xxs)
                        .background(Palette.card)
                    }
                }
                Specimen("unavailable") {
                    MenuBarLabel(indicators: [
                        ResolvedIndicator(title: "5h", fraction: nil, rendering: .bar, isUnavailable: true),
                    ])
                    .padding(.horizontal, Spacing.sm)
                    .padding(.vertical, Spacing.xxs)
                    .background(Palette.card)
                }
                Specimen("bar + number") {
                    MenuBarLabel(indicators: [
                        ResolvedIndicator(
                            title: "5h", fraction: 0.63, rendering: .barAndNumber, isUnavailable: false
                        ),
                    ])
                    .padding(.horizontal, Spacing.sm)
                    .padding(.vertical, Spacing.xxs)
                    .background(Palette.card)
                }
                Specimen("extra-usage variant") {
                    MenuBarLabel(
                        indicators: [
                            ResolvedIndicator(
                                title: "Extra", fraction: 0.63, rendering: .number, isUnavailable: false
                            ),
                        ],
                        isExtraUsage: true
                    )
                    .padding(.horizontal, Spacing.sm)
                    .padding(.vertical, Spacing.xxs)
                    .background(Palette.card)
                }
            }
        }
    }

    // MARK: - StaggerIn

    private var staggerInSection: some View {
        GallerySection("StaggerIn") {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Button(staggerReplay ? "Reset (opacity 0, offset 8)" : "Replay entrance") {
                    staggerReplay.toggle()
                }
                .textStyle(.detail)

                Specimen("staggerIn(index: 0, isVisible:) — always settled under SnapshotConfig.staticEntrance") {
                    Text("Card content")
                        .cardLabel()
                        .padding(Spacing.md)
                        .panelCard()
                        .frame(width: 200)
                        .staggerIn(index: 0, isVisible: staggerReplay)
                }
            }
        }
    }

    // MARK: - SummaryCard (found by grep, NOT in the given inventory — used by both
    // DashboardView (via SummaryCardsRow) and StatisticsView, so it qualifies as a
    // cross-screen reusable component under the task's own rule.)

    private var summaryCardSection: some View {
        GallerySection("SummaryCard (missing from inventory — used by DashboardView & StatisticsView)") {
            FlowRow {
                Specimen("with footnote") {
                    SummaryCard(
                        label: "TOKENS",
                        valueText: "1.2M",
                        valueMagnitude: 1_200_000,
                        footnote: Text("850K in · 350K out"),
                        valueColor: Palette.textPrimary
                    )
                    .frame(width: 180, height: 104)
                }
                Specimen("without footnote") {
                    SummaryCard(
                        label: "EST. API COST",
                        valueText: "$42.80",
                        valueMagnitude: 42.80,
                        footnote: Text("API-equivalent estimate"),
                        valueColor: Palette.accent
                    )
                    .frame(width: 180, height: 104)
                }
            }
        }
    }

    // MARK: - MetricColor

    private var metricColorSection: some View {
        GallerySection("MetricColor — ok < 60%, warn 60–85%, critical ≥ 85%") {
            FlowRow {
                Specimen("ok") { swatch(Palette.ok) }
                Specimen("warn") { swatch(Palette.warn) }
                Specimen("critical") { swatch(Palette.critical) }
            }
        }
    }

    private func swatch(_ color: Color) -> some View {
        RoundedRectangle(cornerRadius: Radius.element, style: .continuous)
            .fill(color)
            .frame(width: 60, height: 24)
    }
}

// MARK: - Gallery scaffolding

/// A titled group of specimens. Reuses SectionHeader (dogfooding the design system rather
/// than inventing a second label style).
private struct GallerySection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            SectionHeader(title)
            content()
        }
        .padding(Spacing.md)
        .panelCard()
    }
}

/// One example of a component plus a caption naming the state it demonstrates.
private struct Specimen<Content: View>: View {
    let label: String
    @ViewBuilder let content: () -> Content

    init(_ label: String, @ViewBuilder content: @escaping () -> Content) {
        self.label = label
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            content()
            Text(label)
                .textStyle(.caption)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 220, alignment: .leading)
        }
    }
}

/// A left-aligned wrapping row. SwiftUI's `Layout` protocol (macOS 13+) rather than a
/// fixed-column grid, since specimens vary widely in intrinsic width.
private struct FlowRow: Layout {
    var spacing: CGFloat = Spacing.md
    var lineSpacing: CGFloat = Spacing.md

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = layout(subviews: subviews, maxWidth: width)
        let height = rows.reduce(CGFloat(0)) { $0 + $1.height } + lineSpacing * CGFloat(max(rows.count - 1, 0))
        let contentWidth = rows.map(\.width).max() ?? 0
        return CGSize(width: min(contentWidth, width), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = layout(subviews: subviews, maxWidth: bounds.width)
        var y = bounds.minY
        for row in rows {
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

    private struct RowItem {
        let subview: LayoutSubview
        let size: CGSize
    }

    private struct Row {
        let items: [RowItem]
        let width: CGFloat
        let height: CGFloat
    }

    private func layout(subviews: Subviews, maxWidth: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current: [RowItem] = []
        var currentWidth: CGFloat = 0

        func flush() {
            guard !current.isEmpty else { return }
            let width = current.reduce(CGFloat(0)) { $0 + $1.size.width } + spacing * CGFloat(current.count - 1)
            let height = current.map(\.size.height).max() ?? 0
            rows.append(Row(items: current, width: width, height: height))
            current = []
            currentWidth = 0
        }

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if !current.isEmpty, currentWidth + spacing + size.width > maxWidth {
                flush()
            }
            current.append(RowItem(subview: subview, size: size))
            currentWidth += (current.count > 1 ? spacing : 0) + size.width
        }
        flush()
        return rows
    }
}
