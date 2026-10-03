/// SpeedView — the generation speed page: header and per-day chart pinned under the toolbar,
/// group table and footnotes scrolling beneath them.
///
/// Observes `SpeedViewModel`, the one owner of the report and of which models the table leaves
/// out. Selection is view-local UI state, not a shared datum.
import AppKit
import Charts
import SwiftUI
import TokiAnalytics
import TokiCore

private let log = TokiLog.logger("speed")

// MARK: - Formatting

enum SpeedFormat {
    static func effort(_ raw: String?) -> String {
        switch raw {
        case nil: return "—"
        case "xhigh": return "Extra high"
        case let value?: return value.prefix(1).uppercased() + value.dropFirst()
        }
    }
    static func mode(_ isFast: Bool) -> String { isFast ? "Fast" : "Standard" }
    static func rate(_ value: Double) -> String { Int(value.rounded()).formatted() }
    static func range(_ lo: Double, _ hi: Double) -> String { "\(rate(lo))–\(rate(hi))" }
    static func groupLabel(_ g: GenerationSpeedReport.Group) -> String {
        [DisplayFormat.modelName(g.model), effort(g.effort) == "—" ? nil : effort(g.effort), g.isFast ? "Fast" : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }
}

// MARK: - Selection

/// Which groups are charted, and the colour slot each one owns. A slot is held until its group
/// is deselected, so deselecting one group never repaints the others (dataviz: colour follows
/// the entity, never its rank).
struct SpeedSelection: Equatable {
    static let maxCompared = 4
    private(set) var slots: [String: Int] = [:]   // group id → series slot
    private(set) var order: [String] = []         // selection order, for the legend

    var ids: [String] { order }
    func slot(of id: String) -> Int? { slots[id] }

    mutating func select(only id: String) { slots = [id: 0]; order = [id] }

    /// ⌘-click. Returns false when adding would exceed `maxCompared`.
    @discardableResult
    mutating func toggle(_ id: String) -> Bool {
        if slots[id] != nil {
            guard order.count > 1 else { return true }
            slots[id] = nil; order.removeAll { $0 == id }; return true
        }
        guard order.count < Self.maxCompared,
              let free = (0..<Self.maxCompared).first(where: { !slots.values.contains($0) }) else { return false }
        slots[id] = free; order.append(id); return true
    }

    /// Drops ids that left the report; falls back to the first group when nothing is left.
    mutating func reconcile(with groups: [GenerationSpeedReport.Group]) {
        let present = Set(groups.map(\.id))
        for id in order where !present.contains(id) { slots[id] = nil }
        order.removeAll { !present.contains($0) }
        if order.isEmpty, let first = groups.first { select(only: first.id) }
    }
}

// MARK: - Series identity

/// What tells two charted groups apart besides colour (`Tokens.chartSeries` is colour-blind
/// WARN, legal only with a second encoding): each slot owns a symbol, drawn on the line's
/// last point, in the legend swatch and on the table row.
enum SpeedSeries {
    static func color(_ slot: Int) -> Color { Palette.series[slot % Palette.series.count] }

    static func symbol(_ slot: Int) -> BasicChartSymbolShape {
        switch slot {
        case 0: return .circle
        case 1: return .square
        case 2: return .triangle
        default: return .diamond
        }
    }
}

/// A slot's symbol in its colour — the table row's marker while comparing.
private struct SeriesSymbol: View {
    let slot: Int
    var body: some View {
        SpeedSeries.symbol(slot).fill(SpeedSeries.color(slot)).frame(width: 7, height: 7)
    }
}

/// A slot's line, with its symbol on top while comparing — the legend and tooltip swatch.
private struct SeriesSwatch: View {
    let slot: Int
    let showsSymbol: Bool
    var body: some View {
        ZStack {
            Capsule().fill(SpeedSeries.color(slot)).frame(width: showsSymbol ? 14 : 8, height: 2)
            if showsSymbol { SeriesSymbol(slot: slot) }
        }
    }
}

// MARK: - Page

struct SpeedView: View {
    let model: SpeedViewModel
    var topInset: CGFloat = 0
    /// Snapshot harness only: how many of the report's top groups start out compared.
    var initialComparison: Int = 0
    /// Snapshot harness only: start with the pointer on the last plotted day, so the render
    /// has the chart's tooltip in it.
    var initialHoverOnLastDay = false

    var body: some View {
        if let report = model.report, !report.groups.isEmpty {
            // The pinned header, chart and column headings are not scroll content, so the dashboard's shared top
            // content margin does not reach them: they clear the floating toolbar themselves.
            // Same rule as `SettingsSections.autoSwapEditorOverlay`; Speed has no range row.
            SpeedContent(report: report,
                         hiddenModels: model.hiddenModels,
                         setModelHidden: { id, hidden in model.setModel(id, hidden: hidden) },
                         showAllModels: { model.showAllModels() },
                         refreshFailed: model.errorMessage != nil,
                         initialComparison: initialComparison,
                         initialHoverOnLastDay: initialHoverOnLastDay,
                         toolbarClearance: topInset == 0 ? Measure.dashboardContentTop : topInset)
        } else if model.report == nil && model.isComputing {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // Scroll content, so the dashboard's shared top content margin clears the floating
            // toolbar here too, exactly as it does for the populated page.
            ScrollView {
                Group {
                    if let message = model.errorMessage {
                        errorBanner(message)
                    } else {
                        emptyState
                    }
                }
                .padding(.horizontal, Spacing.xl)
                .padding(.top, topInset)
                .padding(.bottom, Spacing.xl)
            }
        }
    }

    // MARK: States

    private var emptyState: some View {
        VStack(spacing: Spacing.xs) {
            Text("No speed data yet")
                .textStyle(.title)
                .foregroundStyle(Palette.textPrimary)
            Text("Toki measures speed from transcripts as you work. It appears here after a few longer responses.")
                .textStyle(.body)
                .foregroundStyle(Palette.textSecondary)
                .multilineTextAlignment(.center)
                // Narrow enough that the break falls between the two sentences.
                .frame(maxWidth: 310)
        }
        .frame(maxWidth: .infinity, minHeight: 320, alignment: .center)
    }

    /// Same look as `StatisticsView.errorBanner`.
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

/// The populated page. Pure: renders `report` less the hidden models, and owns only the selection.
///
/// The header, the chart and the table's column headings stay put; only the table and the
/// footnotes scroll, so the chart is still in view when a row far down the table is selected
/// and a scrolled row still has its column names (spec §6.2a).
struct SpeedContent: View {
    static let compareLimitMessage = "Comparing \(SpeedSelection.maxCompared) already. Deselect one first."

    let report: GenerationSpeedReport
    /// Model ids the user unchecked (spec §6.2b): none of their rows is in the table, in the
    /// keyboard order, in the default selection or in the comparison. Owned by `SpeedViewModel`.
    let hiddenModels: Set<String>
    let setModelHidden: (_ id: String, _ hidden: Bool) -> Void
    let showAllModels: () -> Void
    /// The last recompute failed; `report` is the one loaded before it.
    let refreshFailed: Bool
    /// How far the pinned region starts below the view's top, to clear the floating toolbar.
    let toolbarClearance: CGFloat
    /// Snapshot harness only: the day the chart starts out hovered on.
    private let initialHover: Date?
    @State private var selection: SpeedSelection
    @State private var showsModelPicker = false
    @State private var isVisible = false
    @State private var showsCompareLimit = false
    /// Bumped per flash; the `.task(id:)` it keys restarts, so only the latest flash clears the hint.
    @State private var compareLimitFlash = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Seeds the selection here rather than only in `onAppear`, which offscreen snapshot
    /// rendering never runs — the chart would otherwise come out empty.
    init(report: GenerationSpeedReport, hiddenModels: Set<String>,
         setModelHidden: @escaping (_ id: String, _ hidden: Bool) -> Void, showAllModels: @escaping () -> Void,
         refreshFailed: Bool = false, initialComparison: Int = 0, initialHoverOnLastDay: Bool = false,
         toolbarClearance: CGFloat) {
        self.report = report
        self.hiddenModels = hiddenModels
        self.setModelHidden = setModelHidden
        self.showAllModels = showAllModels
        self.refreshFailed = refreshFailed
        self.toolbarClearance = toolbarClearance
        let shown = Self.shownGroups(of: report, hiding: hiddenModels)
        var initial = SpeedSelection()
        // The fallback is the first shown group: the most responses overall (spec §6.2), not
        // the top row of the provider-sectioned table.
        initial.reconcile(with: shown)
        for g in shown.prefix(initialComparison).dropFirst() { initial.toggle(g.id) }
        _selection = State(initialValue: initial)
        initialHover = initialHoverOnLastDay
            ? shown.filter { initial.slot(of: $0.id) != nil }.compactMap(\.daily.last?.day).max()
            : nil
    }

    /// The report's groups less the hidden models, in the report's order (most responses first).
    static func shownGroups(of report: GenerationSpeedReport, hiding hidden: Set<String>) -> [GenerationSpeedReport.Group] {
        hidden.isEmpty ? report.groups : report.groups.filter { !hidden.contains($0.model) }
    }

    private var shownGroups: [GenerationSpeedReport.Group] { Self.shownGroups(of: report, hiding: hiddenModels) }

    /// The selected groups that are shown, in selection order: what the chart draws.
    private var chartedGroups: [GenerationSpeedReport.Group] {
        let shown = shownGroups
        return selection.ids.compactMap { id in shown.first { $0.id == id } }
    }

    /// How many of the report's models are hidden. Not `hiddenModels.count`: the set may hold
    /// ids this report does not have.
    private var hiddenModelCount: Int {
        Set(report.groups.map(\.model)).intersection(hiddenModels).count
    }

    var body: some View {
        let shown = shownGroups
        PinnedOverScroll(toolbarClearance: toolbarClearance) {
            pinned(hasRows: !shown.isEmpty)
            // Wraps the scroll view the rows are in: the arrow keys scroll the cursor row into view.
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.lg) {
                        Group {
                            if shown.isEmpty {
                                allHidden
                            } else {
                                SpeedTable(groups: shown, selection: $selection, scrollProxy: proxy,
                                           onCompareLimit: flashCompareLimit)
                            }
                        }
                        .staggerIn(index: 3, isVisible: isVisible)
                        footnotes(hasRows: !shown.isEmpty).staggerIn(index: 4, isVisible: isVisible)
                    }
                    .padding(.horizontal, Spacing.xl)
                    .padding(.bottom, Spacing.xl)
                }
                // The pinned region above has already spent the toolbar band, so this scroll
                // view OVERRIDES the inset the dashboard hands every tab instead of starting a
                // second toolbar's worth further down.
                .contentMargins(.top, Spacing.md, for: .scrollContent)
            }
        }
        .onAppear { selection.reconcile(with: shownGroups); isVisible = true }
        .onChange(of: report) { _, new in selection.reconcile(with: Self.shownGroups(of: new, hiding: hiddenModels)) }
        // A hidden model leaves the chart like a group that left the report: its rows are
        // dropped from the comparison, and the first shown group is charted if none is left.
        .onChange(of: hiddenModels) { _, new in selection.reconcile(with: Self.shownGroups(of: report, hiding: new)) }
        .task(id: compareLimitFlash) {
            guard showsCompareLimit else { return }
            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                log.debug("compare-limit hint timer cancelled \(error: error)")
                return
            }
            withAnimation(fade) { showsCompareLimit = false }
        }
    }

    private var fade: Animation? { reduceMotion ? nil : .easeInOut(duration: 0.15) }

    /// The header, the chart and the table's column headings, on an opaque page-colour backdrop
    /// that runs up under the toolbar. The scroll view starts at this region's bottom edge, so no row is ever behind
    /// or above it; the gradient hanging below that edge fades the rows out as they reach it
    /// instead of cutting them with a hard line.
    ///
    /// With every model hidden there is nothing to chart and no column to name: only the header
    /// stays, with the button that brings the models back.
    private func pinned(hasRows: Bool) -> some View {
        let charted = chartedGroups
        // Spacing.xxs, not the page's Spacing.lg: at the 540 pt minimum window the chart only
        // keeps its 110 pt floor inside the pinned half if the header and the column headings
        // sit close to the chart's card (and the card's title close to its plot, and its
        // padding thin, see `SpeedChartCard.body`).
        return VStack(alignment: .leading, spacing: Spacing.xxs) {
            header.staggerIn(index: 0, isVisible: isVisible)
            if hasRows {
                SpeedChartCard(groups: charted, selection: selection, initialHover: initialHover)
                    .staggerIn(index: 1, isVisible: isVisible)
                // Last, so it sits right above the fade edge and the table under it.
                SpeedColumnHeader()
                    .staggerIn(index: 2, isVisible: isVisible)
            }
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.top, toolbarClearance)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.bg)
        .overlay(alignment: .bottom) {
            LinearGradient(colors: [Palette.bg, Palette.bg.opacity(0)], startPoint: .top, endPoint: .bottom)
                .frame(height: Spacing.md)
                .offset(y: Spacing.md)
                .allowsHitTesting(false)
        }
        // The chart's tooltip, drawn here rather than in the chart: the card clips its content,
        // and a tooltip taller than the card's title row was cut by that clip. Out here it may
        // run past the card's edge and over the header text, which it is drawn after.
        .overlayPreferenceValue(SpeedTooltipAnchors.Key.self) { anchors in
            if let hover = anchors.hover {
                GeometryReader { geometry in
                    SpeedTooltipPlacement(rule: geometry[hover.rule], top: toolbarClearance,
                                          keepClear: anchors.modelButton.map { geometry[$0] }) {
                        SpeedTooltip(day: hover.day, groups: charted, selection: selection)
                    }
                }
                // A readout: the pointer keeps talking to the chart under it, and VoiceOver
                // already has each point's value from the chart's marks.
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
        // Above the scroll view, so the gradient is drawn over the rows.
        .zIndex(1)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            SectionHeader("GENERATION SPEED")
                .frame(maxWidth: .infinity, alignment: .leading)
                // An overlay, so the button is centred on the title's line without making that
                // line taller: every point the header gains is one the chart gives up.
                .overlay(alignment: .trailing) { modelPickerButton }
            Text("All time · output tokens per second, including time to first token")
                .textStyle(.detail)
                .foregroundStyle(Palette.textSecondary)
            if refreshFailed {
                Text("Couldn't refresh speed data. Showing the last loaded values.")
                    .textStyle(.detail)
                    .foregroundStyle(Palette.warn)
            }
        }
    }

    private var modelPickerButton: some View {
        Button { showsModelPicker.toggle() } label: {
            Image(systemName: "slider.horizontal.3")
                .iconSize(.regular, weight: .medium)
        }
        .buttonStyle(.tokiIcon)
        .foregroundStyle(Palette.textSecondary)
        .help("Choose models")
        .accessibilityLabel("Choose models to show")
        // Where the button is, so the chart's tooltip can stay off it.
        .anchorPreference(key: SpeedTooltipAnchors.Key.self, value: .bounds) { SpeedTooltipAnchors(modelButton: $0) }
        // The style pads the glyph for its hover surface; the glyph itself ends on the card's
        // trailing edge, as the title starts on its leading one.
        .padding(.trailing, -Spacing.xxs)
        .popover(isPresented: $showsModelPicker, arrowEdge: .bottom) {
            SpeedModelPicker(sections: SpeedTable.sections(of: report.groups), hidden: hiddenModels,
                             setHidden: setModelHidden, showAll: showAllModels)
        }
    }

    /// In place of the table when every model is unchecked.
    private var allHidden: some View {
        VStack(spacing: Spacing.sm) {
            Text("All models are hidden.")
                .textStyle(.body)
                .foregroundStyle(Palette.textSecondary)
            Button(action: showAllModels) {
                Text("Show all").textStyle(.body)
            }
            .buttonStyle(.tokiSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.xl)
        .padding(.horizontal, Column.cardInset)
        .panelCard()
    }

    private func footnotes(hasRows: Bool) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            if hasRows {
                // Both lines share one slot, so the swap cross-fades in place without a jump.
                ZStack(alignment: .leading) {
                    if showsCompareLimit {
                        footnote(Self.compareLimitMessage).transition(.opacity)
                    } else {
                        footnote("Click a row to chart it. ⌘-click to compare up to 4.").transition(.opacity)
                    }
                }
            }
            if hiddenModelCount > 0 {
                let n = hiddenModelCount
                footnote("\(n) \(n == 1 ? "model" : "models") hidden.")
            }
            if report.hiddenGroupCount > 0 {
                let n = report.hiddenGroupCount
                footnote("\(n) more \(n == 1 ? "group" : "groups") not shown: fewer than \(GenerationSpeedReport.minGroupSamples) measured responses.")
            }
            footnote("Measured from when a request is sent to when its last block is written, for responses of 200 tokens or more. Queueing and time to first token are included, so this reads lower than raw decoding speed.")
        }
    }

    private func footnote(_ text: String) -> some View {
        Text(text)
            .textStyle(.detail)
            .foregroundStyle(Palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// An add past the fourth series (⌘-click, ⇧-arrow or the VoiceOver action): say why
    /// nothing happened — on screen for 2 s, and aloud.
    private func flashCompareLimit() {
        withAnimation(fade) { showsCompareLimit = true }
        compareLimitFlash += 1
        AccessibilityNotification.Announcement(Self.compareLimitMessage).post()
    }
}

// MARK: - Pinned layout

/// The page's two regions, top to bottom: the pinned one, then the scroll view with what is left.
///
/// The pinned region is offered at most the toolbar clearance plus half of the height under
/// it, and takes what it needs of that. The page header and the column headings are fixed
/// height, so the chart between them gives up exactly their points: it flexes between its floor
/// and its ceiling (`SpeedChartCard.plotHeight`) in what they leave. The table keeps the other half. A layout
/// rather than a geometry reader: it is handed the page's height once per layout pass, never
/// per scroll frame, and it still has a natural height when none is offered. The offscreen
/// snapshot renderer measures exactly that, and gets the full chart above every table row.
private struct PinnedOverScroll: Layout {
    let toolbarClearance: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let pinned = subviews[0].sizeThatFits(pinnedProposal(width: proposal.width, height: proposal.height))
        guard let height = proposal.height, height.isFinite else {
            let scroll = subviews[1].sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
            return CGSize(width: proposal.width ?? max(pinned.width, scroll.width),
                          height: pinned.height + scroll.height)
        }
        return CGSize(width: proposal.width ?? pinned.width, height: max(height, pinned.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let pinned = subviews[0].sizeThatFits(pinnedProposal(width: bounds.width, height: bounds.height))
        subviews[0].place(at: bounds.origin,
                          proposal: ProposedViewSize(width: bounds.width, height: pinned.height))
        subviews[1].place(at: CGPoint(x: bounds.minX, y: bounds.minY + pinned.height),
                          proposal: ProposedViewSize(width: bounds.width,
                                                     height: max(bounds.height - pinned.height, 0)))
    }

    /// With no height to share, the pinned region is offered all it could want.
    private func pinnedProposal(width: CGFloat?, height: CGFloat?) -> ProposedViewSize {
        guard let height, height.isFinite else { return ProposedViewSize(width: width, height: .infinity) }
        return ProposedViewSize(width: width, height: toolbarClearance + max(height - toolbarClearance, 0) / 2)
    }
}

// MARK: - Chart

private struct SpeedChartCard: View {
    /// The chart's height: 220 pt when the window has room, down to 110 pt at its minimum
    /// height. `PinnedOverScroll` decides where in between.
    static let plotHeight: ClosedRange<CGFloat> = 110...220

    let groups: [GenerationSpeedReport.Group]   // the selected ones, in selection order
    let selection: SpeedSelection
    /// Where the pointer is, as `chartXSelection` reports it; read through `hoveredDay`.
    @State private var pointerDate: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// `initialHover` is for the snapshot harness: the day the pointer starts on.
    init(groups: [GenerationSpeedReport.Group], selection: SpeedSelection, initialHover: Date? = nil) {
        self.groups = groups
        self.selection = selection
        _pointerDate = State(initialValue: initialHover)
    }

    /// A run of consecutive days. `id` is the group plus its first day: stable across renders.
    private struct Segment: Identifiable {
        let id: String
        let points: [GenerationSpeedReport.DayPoint]
    }

    private var isComparing: Bool { groups.count > 1 }

    /// Snapped to the day, so the rule and tooltip sit on the day's points.
    private var hoveredDay: Date? { pointerDate.map { Calendar.current.startOfDay(for: $0) } }

    /// A group's daily points split wherever a day is missing, so the line breaks at a gap
    /// instead of drawing a value nobody measured.
    private func segments(_ g: GenerationSpeedReport.Group) -> [Segment] {
        var runs: [[GenerationSpeedReport.DayPoint]] = []
        let calendar = Calendar.current
        for point in g.daily {
            if let last = runs.last?.last,
               calendar.dateComponents([.day], from: last.day, to: point.day).day == 1 {
                runs[runs.count - 1].append(point)
            } else {
                runs.append([point])
            }
        }
        return runs.map { Segment(id: "\(g.id)#\($0[0].day.timeIntervalSinceReferenceDate)", points: $0) }
    }

    private var yMax: Double {
        let top = groups.flatMap { g in g.daily.map { isComparing ? $0.median : $0.p90 } }.max() ?? 1
        return (top * 1.1).rounded(.up)
    }

    private func slot(of g: GenerationSpeedReport.Group) -> Int { selection.slot(of: g.id) ?? 0 }

    /// Where each end label sits, in chart units: at its line's last value, nudged apart so
    /// two lines ending close together (heavy: 34 and 25 tok/s on a 0–200 scale) never
    /// stack their names on top of each other.
    private func endLabelY(chartHeight: CGFloat) -> [String: Double] {
        let ends = groups.compactMap { g in g.daily.last.map { (id: g.id, y: $0.median) } }
            .sorted { $0.y < $1.y }
        // One caption line in chart units: ~15 pt of the plot, which is the chart's height less
        // the ~30 pt its day labels take (~190 pt of the full 220).
        let gap = yMax * 15 / Double(max(chartHeight - 30, 15))
        var placed: [(id: String, y: Double)] = []
        for end in ends {
            placed.append((end.id, max(end.y, (placed.last?.y ?? -.infinity) + gap)))
        }
        // Pushed past the top: slide the stack back down, keeping the gaps.
        if let top = placed.last?.y, top > yMax - gap / 2 {
            let shift = top - (yMax - gap / 2)
            placed = placed.map { ($0.id, $0.y - shift) }
        }
        return Dictionary(uniqueKeysWithValues: placed.map { ($0.id, $0.y) })
    }

    /// Where a day's rule and points are drawn, from the plot's leading edge: the middle of
    /// the day's band, as every mark here is placed with `unit: .day`.
    private static func ruleX(of day: Date, in proxy: ChartProxy) -> CGFloat? {
        guard let start = proxy.position(forX: day) else { return nil }
        guard let nextDay = Calendar.current.date(byAdding: .day, value: 1, to: day),
              let end = proxy.position(forX: nextDay) else { return start }
        return (start + end) / 2
    }

    private func pointValue(_ p: GenerationSpeedReport.DayPoint) -> String {
        "\(p.day.formatted(.dateTime.month(.abbreviated).day())), \(SpeedFormat.rate(p.median)) tokens per second"
    }

    var body: some View {
        // Tight spacing and padding: with the column headings pinned under it, the region only
        // stays inside its half at a 540 pt window if the card spends no more than this.
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            HStack(alignment: .firstTextBaseline) {
                SectionHeader("MEDIAN BY DAY")
                Spacer()
                if isComparing { legend }
            }
            // The reader only tells the end labels how tall the chart came out. The chart is
            // pinned, so its geometry does not change while the table scrolls.
            GeometryReader { geometry in
                chart(endLabelY: endLabelY(chartHeight: geometry.size.height))
            }
            .frame(minHeight: Self.plotHeight.lowerBound, maxHeight: Self.plotHeight.upperBound)
        }
        .padding(.horizontal, Spacing.md)
        .padding(.top, Spacing.sm)
        .padding(.bottom, Spacing.xs)
        .panelCard()
    }

    private func chart(endLabelY: [String: Double]) -> some View {
        Chart {
            if let hoveredDay {
                // The rule only, and first, so the day's points are drawn over it. Its tooltip
                // is not an annotation here: this card clips its content, so the page draws it
                // instead, from the position reported below.
                RuleMark(x: .value("Day", hoveredDay, unit: .day))
                    .foregroundStyle(Palette.hairline)
            }
            ForEach(groups) { g in groupMarks(g, endLabelY: endLabelY) }
        }
        .chartYScale(domain: 0...yMax)
        .chartXSelection(value: $pointerDate)
        .chartOverlay { proxy in
            // The reader resolves the plot's frame once per hover change; the chart is pinned,
            // so nothing here runs while the table scrolls.
            GeometryReader { geometry in
                if let hoveredDay, let plot = proxy.plotFrame.map({ geometry[$0] }),
                   let x = Self.ruleX(of: hoveredDay, in: proxy) {
                    Color.clear
                        .frame(width: 1, height: plot.height)
                        .anchorPreference(key: SpeedTooltipAnchors.Key.self, value: .bounds) {
                            SpeedTooltipAnchors(hover: SpeedHover(day: hoveredDay, rule: $0))
                        }
                        .position(x: plot.minX + x, y: plot.midY)
                }
            }
            .allowsHitTesting(false)
        }
        .chartYAxis { AxisMarks(position: .leading) { _ in
            AxisGridLine(stroke: StrokeStyle(lineWidth: BorderWidth.card)).foregroundStyle(Palette.hairline)
            AxisValueLabel().foregroundStyle(Palette.textSecondary)
        } }
        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 6)) { _ in
            AxisGridLine(stroke: StrokeStyle(lineWidth: BorderWidth.card)).foregroundStyle(Palette.hairline)
            AxisValueLabel(format: .dateTime.month(.abbreviated).day(), centered: true)
                .foregroundStyle(Palette.textSecondary)
        } }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: selection)
        .accessibilityLabel("Median output tokens per second by day")
    }

    @ChartContentBuilder
    private func groupMarks(_ g: GenerationSpeedReport.Group, endLabelY: [String: Double]) -> some ChartContent {
        let slot = slot(of: g)
        let color = SpeedSeries.color(slot)
        ForEach(segments(g)) { segment in
            if !isComparing {
                ForEach(segment.points, id: \.day) { p in
                    AreaMark(x: .value("Day", p.day, unit: .day),
                             yStart: .value("p10", p.p10), yEnd: .value("p90", p.p90),
                             series: .value("Band", segment.id))
                        .foregroundStyle(color.opacity(0.12))
                        .interpolationMethod(.monotone)
                        .accessibilityHidden(true)
                }
            }
            ForEach(segment.points, id: \.day) { p in
                LineMark(x: .value("Day", p.day, unit: .day), y: .value("Median", p.median),
                         series: .value("Line", segment.id))
                    .foregroundStyle(color)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.monotone)
                    .accessibilityLabel(SpeedFormat.groupLabel(g))
                    .accessibilityValue(pointValue(p))
            }
            // A lone day still shows. While comparing, the last day's end mark below covers it.
            if segment.points.count == 1, let p = segment.points.first,
               !(isComparing && p.day == g.daily.last?.day) {
                PointMark(x: .value("Day", p.day, unit: .day), y: .value("Median", p.median))
                    .foregroundStyle(color)
                    .symbol(isComparing ? SpeedSeries.symbol(slot) : .circle)
                    .symbolSize(32)
                    .accessibilityLabel(SpeedFormat.groupLabel(g))
                    .accessibilityValue(pointValue(p))
            }
        }
        // Comparing: the slot's symbol and the group's name end each line, so no series
        // depends on colour alone.
        if isComparing, let last = g.daily.last {
            PointMark(x: .value("Day", last.day, unit: .day), y: .value("Median", last.median))
                .foregroundStyle(color)
                .symbol(SpeedSeries.symbol(slot))
                .symbolSize(44)
                .accessibilityLabel(SpeedFormat.groupLabel(g))
                .accessibilityValue(pointValue(last))
            // The label hangs off an invisible point at its de-collided height; VoiceOver
            // already has the name from the visible mark.
            PointMark(x: .value("Day", last.day, unit: .day),
                      y: .value("Median", endLabelY[g.id] ?? last.median))
                .symbolSize(0)
                .accessibilityHidden(true)
                .annotation(position: .trailing, alignment: .leading, spacing: 8,
                            overflowResolution: .init(x: .padScale, y: .fit(to: .chart))) {
                    Text(SpeedFormat.groupLabel(g))
                        .textStyle(.caption)
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(1)
                        .fixedSize()
                }
        }
    }

    /// One entry per charted group; the swatch carries the colour and symbol, the text never does.
    private var legend: some View {
        HStack(spacing: Spacing.sm) {
            ForEach(groups) { g in
                HStack(spacing: Spacing.xxs) {
                    SeriesSwatch(slot: slot(of: g), showsSymbol: true)
                    Text(SpeedFormat.groupLabel(g))
                        .textStyle(.caption)
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(1)
                }
            }
        }
    }
}

// MARK: - Tooltip

/// The hovered day and where its rule is.
private struct SpeedHover: Equatable {
    let day: Date
    /// One point wide at the rule's x; as tall as the plot.
    let rule: Anchor<CGRect>
}

/// What the page needs to place the chart's tooltip, handed up from where each thing is drawn.
/// The page draws the tooltip itself, outside the chart card's clip (`SpeedContent.pinned`).
private struct SpeedTooltipAnchors: Equatable {
    /// From the chart; `nil` while the pointer is off it.
    var hover: SpeedHover?
    /// From the header: the button the tooltip stays off.
    var modelButton: Anchor<CGRect>?

    struct Key: PreferenceKey {
        static var defaultValue: SpeedTooltipAnchors { SpeedTooltipAnchors() }
        static func reduce(value: inout SpeedTooltipAnchors, nextValue: () -> SpeedTooltipAnchors) {
            let next = nextValue()
            value.hover = next.hover ?? value.hover
            value.modelButton = next.modelButton ?? value.modelButton
        }
    }
}

/// The hover readout: the day, then one line per charted group that has a point on it.
/// Appears instantly — no animation on a hover readout.
private struct SpeedTooltip: View {
    let day: Date
    let groups: [GenerationSpeedReport.Group]   // the charted ones, in selection order
    let selection: SpeedSelection

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Text(day, format: .dateTime.month(.abbreviated).day())
                .textStyle(.caption)
                .foregroundStyle(Palette.textPrimary)
            ForEach(groups) { g in
                if let p = g.daily.first(where: { $0.day == day }) {
                    HStack(spacing: Spacing.xxs) {
                        SeriesSwatch(slot: selection.slot(of: g.id) ?? 0, showsSymbol: groups.count > 1)
                        Text("\(SpeedFormat.groupLabel(g)) · \(SpeedFormat.rate(p.median)) tok/s (\(SpeedFormat.range(p.p10, p.p90))) · \(p.count.formatted()) responses")
                            .textStyle(.caption)
                            .monospacedDigit()
                            .foregroundStyle(Palette.textSecondary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(.horizontal, Spacing.xs)
        .padding(.vertical, Spacing.xxs + 2)
        .background(
            RoundedRectangle(cornerRadius: Radius.element, style: .continuous)
                .fill(Palette.raised)
                .overlay(RoundedRectangle(cornerRadius: Radius.element, style: .continuous)
                    .strokeBorder(Palette.hairline))
        )
        .transaction { $0.animation = nil }
    }
}

/// Puts the tooltip where all of it is visible and none of it is on the hovered day's points.
///
/// Its place is above the plot, centred on the rule: over the card's title and the page header,
/// past the card's top edge if it needs to be. A tooltip too tall for that would reach under the
/// floating toolbar (three or four series), so it stops at `top`, the header's top edge. It then
/// hangs over the top of the plot, so it moves beside the rule: the points on the rule stay
/// clear at any plot height. It never leaves the pinned region sideways and stays off the
/// header's button; a tooltip wider than the room it has truncates its lines instead.
private struct SpeedTooltipPlacement: Layout {
    /// The hovered rule in this layout's space: its x, and the plot's top and bottom.
    let rule: CGRect
    /// Nothing is drawn above this line: the toolbar floats over what is.
    let top: CGFloat
    /// The header's model button, at the region's trailing edge.
    let keepClear: CGRect?

    /// Between the tooltip and the plot's top edge.
    static let plotGap: CGFloat = Spacing.xxs
    /// Between the rule and a tooltip beside it: clear of the point symbols, at most 7 pt wide.
    static let ruleGap: CGFloat = 10

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let tooltip = subviews.first else { return }
        let frame = Self.frame(ideal: tooltip.sizeThatFits(.unspecified), rule: rule, width: bounds.width,
                               top: top, keepClear: keepClear)
        tooltip.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                      proposal: ProposedViewSize(frame.size))
    }

    /// The tooltip's frame in a region `width` wide, for a tooltip that wants `ideal`.
    static func frame(ideal: CGSize, rule: CGRect, width: CGFloat, top: CGFloat, keepClear: CGRect?) -> CGRect {
        let above = rule.minY - plotGap - ideal.height
        let y = max(above, top)
        // The trailing limit: `inset` from the region's edge, or short of the button when the
        // tooltip is on the button's lines.
        func trailing(inset: CGFloat) -> CGFloat {
            guard let keepClear, y < keepClear.maxY, y + ideal.height > keepClear.minY else { return width - inset }
            return min(width - inset, keepClear.minX - Spacing.xxs)
        }
        if above >= top {
            // Kept between the card's edges, which the page's horizontal padding sets.
            let lo = Spacing.xl, hi = max(trailing(inset: Spacing.xl), lo)
            let fitted = min(ideal.width, hi - lo)
            return CGRect(x: min(max(rule.midX - fitted / 2, lo), hi - fitted), y: y,
                          width: fitted, height: ideal.height)
        }
        // Beside the rule: on the right when all of it fits there, else on the left, else on
        // the wider side, narrowed to the room that side has.
        let lo = Spacing.xs, hi = max(trailing(inset: Spacing.xs), lo)
        let left = rule.midX - ruleGap - lo, right = hi - rule.midX - ruleGap
        let onRight = right >= ideal.width || (left < ideal.width && right >= left)
        let fitted = max(min(ideal.width, onRight ? right : left), 0)
        return CGRect(x: onRight ? rule.midX + ruleGap : rule.midX - ruleGap - fitted, y: y,
                      width: fitted, height: ideal.height)
    }
}

// MARK: - Table

/// Fixed numeric columns, flexible model column; sizes hold at the 860 pt minimum window
/// (812 pt of content).
///
/// The one definition of where a column sits. The rows (`SpeedRow`) and the pinned column
/// headings (`SpeedColumnHeader`) both lay their cells out with `spacing` between them and
/// `leadingInset` / `trailingInset` before the first and after the last, so a heading is over
/// its column at every window width.
private enum Column {
    static let marker: CGFloat = 8
    static let effort: CGFloat = 76, mode: CGFloat = 70, responses: CGFloat = 78
    static let number: CGFloat = 62, range: CGFloat = 78, trend: CGFloat = 84
    /// Between two cells of a row.
    static let spacing: CGFloat = Spacing.sm
    /// The table card's padding, then the row's own padding inside it.
    static let cardInset: CGFloat = Spacing.md
    static let rowInset: CGFloat = Spacing.sm
    /// From the card's outer edge to the first cell (the selection-marker slot) of a row.
    static let leadingInset: CGFloat = cardInset + rowInset
    static let trailingInset: CGFloat = cardInset + rowInset
}

/// The table's column headings. Pinned under the chart rather than scrolling with the card, so a
/// scrolled row still says what its numbers are. Sits outside the card, so it adds the card's
/// padding itself and then lays out like a row.
private struct SpeedColumnHeader: View {
    var body: some View {
        HStack(spacing: Column.spacing) {
            Color.clear.frame(width: Column.marker, height: 1)
            heading("Model", nil, .leading)
            heading("Effort", Column.effort, .leading)
            heading("Mode", Column.mode, .leading)
            heading("Responses", Column.responses, .trailing)
            heading("Average", Column.number, .trailing)
            heading("Median", Column.number, .trailing)
            heading("p10–p90", Column.range, .trailing)
            heading("30 days", Column.trend, .leading)
        }
        .padding(.leading, Column.leadingInset)
        .padding(.trailing, Column.trailingInset)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func heading(_ text: String, _ width: CGFloat?, _ alignment: Alignment) -> some View {
        let label = Text(text).textStyle(.caption).foregroundStyle(Palette.textSecondary).lineLimit(1)
        if let width {
            label.frame(width: width, alignment: alignment)
        } else {
            label.frame(maxWidth: .infinity, alignment: alignment)
        }
    }
}

private struct SpeedTable: View {
    /// The rows' groups: the report's, less the hidden models.
    let groups: [GenerationSpeedReport.Group]
    @Binding var selection: SpeedSelection
    let scrollProxy: ScrollViewProxy?
    let onCompareLimit: () -> Void
    /// The table is one tab stop; a click lands focus here so the arrow keys work next.
    @FocusState private var isFocused: Bool
    /// Whether the user is moving through the table by keyboard: raised when focus arrives
    /// without a click (Tab) or on a handled key, lowered by a click. Only then does the cursor
    /// row draw its focus ring — the system ring around the whole card is disabled.
    @State private var isKeyboardNavigating = false
    /// Set by a row's action just before it focuses the table, so the focus change it causes
    /// is not mistaken for a Tab.
    @State private var focusIsFromClick = false
    /// The row the arrow keys move from: the last one clicked or reached by keyboard.
    @State private var cursor: String?

    struct Section: Identifiable {
        let id: String
        let title: String?
        let blocks: [GenerationSpeedTableOrder.ModelBlock]
    }

    /// Provider sections in display order; one unnamed section when only one is present.
    /// Within a provider, one block per model (`GenerationSpeedTableOrder`).
    static func sections(of groups: [GenerationSpeedReport.Group]) -> [Section] {
        let claude = groups.filter { $0.provider == .claudeCode }
        let codex = groups.filter { $0.provider != .claudeCode }
        guard !claude.isEmpty, !codex.isEmpty else {
            return [Section(id: "all", title: nil, blocks: GenerationSpeedTableOrder.blocks(groups))]
        }
        return [Section(id: "claude", title: "CLAUDE", blocks: GenerationSpeedTableOrder.blocks(claude)),
                Section(id: "codex", title: "CODEX", blocks: GenerationSpeedTableOrder.blocks(codex))]
    }

    /// Every row top to bottom: the one visual order, drawn by `body` and walked by the arrow keys.
    static func rows(of groups: [GenerationSpeedReport.Group]) -> [GenerationSpeedReport.Group] {
        sections(of: groups).flatMap(\.blocks).flatMap(\.groups)
    }

    /// Every row id top to bottom, for the arrow keys.
    private var rowOrder: [String] { Self.rows(of: groups).map(\.id) }

    /// The cursor if it is still a row, else the most recently charted group.
    private var current: String? {
        let order = rowOrder
        if let cursor, order.contains(cursor) { return cursor }
        return selection.ids.last
    }

    var body: some View {
        let sections = Self.sections(of: groups)
        let current = current
        VStack(alignment: .leading, spacing: Spacing.sm) {
            SectionHeader("BY MODEL, EFFORT AND MODE")
            // Not lazy, on purpose. With the row trend a plain shape, a scroll frame touches
            // none of these rows, so building them all once is the cheapest thing to do; a
            // `LazyVStack` measured slower in the tail, because rows are then created while
            // scrolling.
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                ForEach(sections) { section in
                    if let title = section.title {
                        SectionHeader(title)
                            .padding(.horizontal, Column.rowInset)
                            .padding(.top, section.id == sections.first?.id ? Spacing.xxs : Spacing.sm)
                    }
                    ForEach(section.blocks) { block in
                        // Rows touch inside a block; a block starts Spacing.sm below the last one.
                        VStack(alignment: .leading, spacing: Spacing.xxs) {
                            ForEach(block.groups) { g in
                                SpeedRow(group: g,
                                         isFirstInBlock: g.id == block.groups.first?.id,
                                         slot: selection.slot(of: g.id),
                                         showsSymbol: selection.ids.count > 1,
                                         isCursor: isFocused && current == g.id,
                                         showsFocusRing: isFocused && isKeyboardNavigating && current == g.id,
                                         onSelect: { additive in
                                             isKeyboardNavigating = false
                                             if !isFocused {
                                                 focusIsFromClick = true
                                                 isFocused = true
                                             }
                                             select(g.id, additive: additive)
                                         },
                                         onToggle: { select(g.id, additive: true) })
                                    .id(g.id)
                            }
                        }
                        .padding(.top, block.id == section.blocks.first?.id ? 0 : Spacing.sm)
                    }
                }
            }
            .focusable()
            // The system ring would outline the whole card on every click; keyboard focus is
            // drawn on the cursor row instead (`SpeedRow.showsFocusRing`).
            .focusEffectDisabled()
            .focused($isFocused)
            .onChange(of: isFocused) { _, focused in
                // A click can focus the table twice over: the row's action asks for it, and
                // the system may already have moved focus on mouse-down. Neither is a Tab.
                if focused { isKeyboardNavigating = !focusIsFromClick && !Self.isHandlingMouseClick }
                focusIsFromClick = false
            }
            .onKeyPress(keys: [.upArrow, .downArrow], phases: [.down, .repeat]) { press in
                isKeyboardNavigating = true
                move(by: press.key == .upArrow ? -1 : 1, extending: press.modifiers.contains(.shift))
                return .handled
            }
        }
        .padding(Column.cardInset)
        .panelCard()
    }

    /// Whether the event being dispatched right now is a mouse button going down or up.
    private static var isHandlingMouseClick: Bool {
        switch NSApp.currentEvent?.type {
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp: return true
        default: return false
        }
    }

    /// Plain = chart only this row; additive = toggle it in the comparison (limit 4).
    private func select(_ id: String, additive: Bool) {
        cursor = id
        if additive {
            if !selection.toggle(id) { onCompareLimit() }
        } else {
            selection.select(only: id)
        }
    }

    /// ↑/↓ select the neighbouring row; ⇧↑/⇧↓ toggle it into the comparison instead.
    private func move(by step: Int, extending: Bool) {
        let order = rowOrder
        guard !order.isEmpty else { return }
        let from = current.flatMap { order.firstIndex(of: $0) }
        let next = from.map { min(max($0 + step, 0), order.count - 1) } ?? 0
        let id = order[next]
        if extending {
            guard next != from else { return }
            guard selection.toggle(id) else { onCompareLimit(); return }
            cursor = id
        } else {
            select(id, additive: false)
        }
        scrollProxy?.scrollTo(id)
    }
}

// MARK: - Model picker

/// The popover behind the header's button: every model of the report under its provider, in
/// the table's block order, each with a checkbox. Unchecking one hides all of its rows.
/// `SpeedViewModel` owns the hidden set; this only reads it and asks for changes.
private struct SpeedModelPicker: View {
    static let width: CGFloat = 280
    /// About ten models; a longer list scrolls.
    static let maxListHeight: CGFloat = 300

    /// Of the whole report, hidden models included.
    let sections: [SpeedTable.Section]
    let hidden: Set<String>
    let setHidden: (_ id: String, _ hidden: Bool) -> Void
    let showAll: () -> Void

    private var hidesAny: Bool {
        sections.contains { $0.blocks.contains { hidden.contains($0.id) } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("Models in table")
                .textStyle(.label)
                .foregroundStyle(Palette.textPrimary)
            // Sized by its rows up to `maxListHeight`, so a short list makes a short popover.
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    ForEach(sections) { section in
                        if let title = section.title {
                            SectionHeader(title)
                                .padding(.top, section.id == sections.first?.id ? 0 : Spacing.xs)
                        }
                        ForEach(section.blocks) { block in row(block) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Opts out of the dashboard's toolbar margin, which reaches popovers through the environment.
            .contentMargins(.top, 0, for: .scrollContent)
            .frame(maxHeight: Self.maxListHeight)
            Button(action: showAll) {
                Text("Show all").textStyle(.body)
            }
            .buttonStyle(.tokiSecondary)
            .disabled(!hidesAny)
        }
        .padding(Spacing.md)
        .frame(width: Self.width, alignment: .leading)
    }

    private func row(_ block: GenerationSpeedTableOrder.ModelBlock) -> some View {
        let name = DisplayFormat.modelName(block.id)
        let responses = block.groups.reduce(0) { $0 + $1.count }.formatted()
        return Toggle(isOn: Binding(get: { !hidden.contains(block.id) },
                                    set: { setHidden(block.id, !$0) })) {
            HStack(spacing: Spacing.xs) {
                Text(name).textStyle(.body).foregroundStyle(Palette.textPrimary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                Text(responses).textStyle(.detail).monospacedDigit()
                    .foregroundStyle(Palette.textSecondary)
            }
        }
        .toggleStyle(.checkbox)
        .help(block.id)
        .accessibilityLabel("\(name), \(responses) responses")
    }
}

private struct SpeedRow: View {
    let group: GenerationSpeedReport.Group
    let isFirstInBlock: Bool  // the first row of its model's block names the model in full colour
    let slot: Int?            // nil = not charted
    let showsSymbol: Bool     // ≥ 2 groups charted
    let isCursor: Bool        // where the arrow keys move from, while the table has focus
    let showsFocusRing: Bool  // the cursor row, while the user navigates by keyboard
    let onSelect: (_ additive: Bool) -> Void
    let onToggle: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button { onSelect(NSEvent.modifierFlags.contains(.command)) } label: {
            HStack(spacing: Column.spacing) {
                marker.frame(width: Column.marker, height: 18, alignment: .leading)
                // Every row names its model, so a row is identifiable wherever the table is
                // scrolled to; the name is dimmed on a block's later rows.
                Text(DisplayFormat.modelName(group.model)).textStyle(.body).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(modelColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(group.model)
                cell(SpeedFormat.effort(group.effort), Column.effort, .leading)
                cell(SpeedFormat.mode(group.isFast), Column.mode, .leading)
                cell(group.count.formatted(), Column.responses, .trailing)
                cell(SpeedFormat.rate(group.weightedAverage), Column.number, .trailing)
                cell(SpeedFormat.rate(group.median), Column.number, .trailing, primary: true)
                cell(SpeedFormat.range(group.p10, group.p90), Column.range, .trailing)
                trend.frame(width: Column.trend, height: 18)
            }
            .padding(.horizontal, Column.rowInset)
            .frame(minHeight: 32)
            .background(RoundedRectangle(cornerRadius: Radius.element, style: .continuous).fill(fill))
            .overlay {
                if showsFocusRing {
                    RoundedRectangle(cornerRadius: Radius.element, style: .continuous)
                        .strokeBorder(Palette.accent, lineWidth: 1.5)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The table container is the one tab stop; the arrow keys move between rows.
        .focusable(false)
        // Instant, like any pointer readout.
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(SpeedFormat.groupLabel(group)), median \(SpeedFormat.rate(group.median)) tokens per second, \(group.count) responses")
        .accessibilityValue("average \(SpeedFormat.rate(group.weightedAverage)) tokens per second, p10 to p90 \(SpeedFormat.rate(group.p10)) to \(SpeedFormat.rate(group.p90)), \(SpeedFormat.mode(group.isFast))")
        .accessibilityAddTraits(slot != nil ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: slot == nil ? "Add to comparison" : "Remove from comparison", onToggle)
    }

    /// Primary on the first row of a block and on any charted row; tertiary on the rest.
    private var modelColor: Color {
        isFirstInBlock || slot != nil ? Palette.textPrimary : Palette.textTertiary
    }

    private var fill: Color {
        if slot != nil { return Palette.textPrimary.opacity(0.06) }
        return isHovered || isCursor ? Palette.textPrimary.opacity(0.04) : .clear
    }

    /// The slot's symbol while comparing; otherwise the 3-pt colour stripe.
    @ViewBuilder private var marker: some View {
        if let slot, showsSymbol {
            SeriesSymbol(slot: slot)
        } else {
            Capsule().fill(slot.map(SpeedSeries.color) ?? .clear).frame(width: 3, height: 18)
        }
    }

    private func cell(_ text: String, _ width: CGFloat, _ alignment: Alignment, primary: Bool = false) -> some View {
        Text(text).textStyle(.body).monospacedDigit()
            .foregroundStyle(primary ? Palette.textPrimary : Palette.textSecondary)
            .lineLimit(1).frame(width: width, alignment: alignment)
    }

    @ViewBuilder private var trend: some View {
        let points = Array(group.daily.suffix(30))
        if points.count >= 2 {
            SpeedTrend(points: points)
        } else {
            Text("—").textStyle(.body).foregroundStyle(Palette.textTertiary)
        }
    }
}

/// The 30-day trend: an 18 pt line scaled to the row's own min…max, so its shape reads at
/// row height without squashing the stroke.
///
/// A `Shape`, not a Swift Charts `Chart`. A chart reads its own position (a geometry reader
/// and an anchor preference), so every row's chart was re-evaluated on every scroll frame and
/// took the table's hit-testing tree with it: about 1,750 view-graph updates per frame against
/// about 80 without them. A shape's path
/// depends on its size alone. Same scales as the chart it replaces: time on x, the row's
/// min…max on y.
private struct SpeedTrend: View {
    let points: [GenerationSpeedReport.DayPoint]   // ≥ 2, oldest first

    var body: some View {
        TrendLine(points: points)
            .stroke(Palette.textSecondary, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            .frame(height: 18)
            .accessibilityHidden(true)
    }
}

private struct TrendLine: Shape {
    let points: [GenerationSpeedReport.DayPoint]   // ≥ 2, oldest first

    func path(in rect: CGRect) -> Path {
        guard let first = points.first, let last = points.last else { return Path() }
        let start = first.day.timeIntervalSinceReferenceDate
        let span = last.day.timeIntervalSinceReferenceDate - start
        let values = points.map(\.median)
        let lo = values.min() ?? 0, hi = values.max() ?? 0
        let range = hi > lo ? hi - lo : 1
        return Self.monotonePath(through: points.map { point in
            let fx = span > 0 ? (point.day.timeIntervalSinceReferenceDate - start) / span : 0
            let fy = (point.median - lo) / range
            return CGPoint(x: rect.minX + CGFloat(fx) * rect.width, y: rect.maxY - CGFloat(fy) * rect.height)
        })
    }

    /// A monotone cubic through `points` (x ascending): the same character as the main chart's
    /// `.monotone` lines. The tangents are Fritsch–Carlson's, so between two neighbouring points
    /// the curve never leaves the band between their two values: no overshoot above the row's
    /// maximum or below its minimum, and a flat run stays flat.
    static func monotonePath(through points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count > 2 else {
            if points.count == 2 { path.addLine(to: points[1]) }
            return path
        }
        let last = points.count - 1
        let widths = (0..<last).map { points[$0 + 1].x - points[$0].x }
        // Two points at one x have no slope: nothing to smooth, so the segments stay straight.
        guard widths.allSatisfy({ $0 > 0 }) else {
            for point in points.dropFirst() { path.addLine(to: point) }
            return path
        }
        let secants = (0..<last).map { (points[$0 + 1].y - points[$0].y) / widths[$0] }
        // Tangents: the secant at each end, the mean of the two secants inside, and flat at a
        // peak, a trough or the end of a flat run.
        var tangents = (0...last).map { i -> CGFloat in
            if i == 0 { return secants[0] }
            if i == last { return secants[last - 1] }
            return secants[i - 1] * secants[i] > 0 ? (secants[i - 1] + secants[i]) / 2 : 0
        }
        // Fritsch–Carlson: a segment is monotone when its two tangents, measured in secants,
        // lie inside the circle of radius 3; outside it they are scaled back onto it.
        for i in 0..<last {
            guard secants[i] != 0 else {
                tangents[i] = 0
                tangents[i + 1] = 0
                continue
            }
            let a = tangents[i] / secants[i], b = tangents[i + 1] / secants[i]
            let length = (a * a + b * b).squareRoot()
            if length > 3 {
                tangents[i] = 3 / length * a * secants[i]
                tangents[i + 1] = 3 / length * b * secants[i]
            }
        }
        // Each Hermite segment as a Bézier: control points a third of the way along the tangents.
        for i in 0..<last {
            let third = widths[i] / 3
            path.addCurve(to: points[i + 1],
                          control1: CGPoint(x: points[i].x + third, y: points[i].y + tangents[i] * third),
                          control2: CGPoint(x: points[i + 1].x - third, y: points[i + 1].y - tangents[i + 1] * third))
        }
        return path
    }
}
