/// StatisticsView — a GitHub-style activity heatmap, streak/records tiles, and an
/// hour-by-weekday punchcard, all derived from the persistent `StatsRollup`.
///
/// Not a dashboard tab anymore: this content now lives on the Usage tab, on every range,
/// under an "All-time statistics" header (see `DashboardContent.statisticsSection` in
/// `DashboardView.swift`, which embeds `StatisticsContent` below directly). `StatisticsView`
/// itself — the type in this file that adds the loading/empty/error chrome around
/// `StatisticsContent` — is kept for the debug control channel's standalone `statistics`
/// comparison surface and the snapshot harness's `statistics` surface, both of which render
/// it outside any dashboard tab.
///
/// Renders INSIDE the Dashboard content area (no toolbar, no window background — the
/// dashboard supplies those). Uses only design-system primitives: panelCard,
/// SectionHeader, SummaryCard, Palette, Spacing.
import TokiCore
import SwiftUI

// MARK: - StatisticsView

@MainActor
struct StatisticsView: View {
    @Bindable var model: StatisticsViewModel
    var topInset: CGFloat = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                if let errorMessage = model.errorMessage {
                    errorBanner(errorMessage)
                }

                if let history = model.history, history.allTimeRequests > 0 {
                    StatisticsContent(history: history)
                } else if model.errorMessage == nil {
                    emptyState
                }
            }
            .padding(.horizontal, Spacing.xl)
            .padding(.bottom, Spacing.xl)
            .padding(.top, topInset)
        }
        .onAppear {
            model.load()
        }
    }

    // MARK: - States

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: Spacing.sm) {
            Image(systemName: "square.grid.3x3.fill")
                .iconSize(.hero)
                .foregroundStyle(Palette.textSecondary)
            Text("No activity recorded yet")
                .textStyle(.headline)
                .foregroundStyle(Palette.textSecondary)
            Text("Statistics build up as you use your coding tools.")
                .textStyle(.detail)
                .foregroundStyle(Palette.textSecondary.opacity(0.7))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 320, alignment: .center)
    }

    // MARK: - Error banner

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
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.xs)
        .panelCard()
    }
}

// MARK: - StatisticsContent

/// The tab's populated body — extracted so it can be rendered directly by ImageRenderer
/// (which cannot render inside a ScrollView) in SnapshotRunner.
@MainActor
struct StatisticsContent: View {
    let history: StatsHistory

    // Headless snapshots don't fire onAppear, so start visible in flat mode to skip the
    // entrance animation and render content immediately.
    @State private var isVisible = SnapshotConfig.flatSurfaces

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            activityCard
                .staggerIn(index: 0, isVisible: isVisible)

            tilesRow
                .staggerIn(index: 1, isVisible: isVisible)

            punchcardCard
                .staggerIn(index: 2, isVisible: isVisible)
        }
        .onAppear {
            isVisible = true
        }
    }

    // MARK: - Activity heatmap

    private var activityCard: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            // No all-time token/request total here (there used to be one): on the merged
            // Usage tab this card sits inches from the summary cards' own all-time total,
            // sourced from the OTHER data source (the live transcript index, not this
            // rollup) — the two disagree by roughly a percent on "today", and two all-time totals on
            // one screen that disagree reads as a bug, not as two sources. The summary cards
            // are the one place this number is shown now.
            SectionHeader("Activity")

            HeatmapGrid(weeks: history.heatmapWeeks)

            HStack(spacing: 4) {
                Spacer()
                HeatmapLegend()
            }
        }
        .padding(Spacing.md)
        .panelCard()
    }

    // MARK: - Tiles row

    private var tilesRow: some View {
        HStack(spacing: Spacing.sm) {
            SummaryCard(
                label: "CURRENT STREAK",
                valueText: "\(history.currentStreak)",
                valueMagnitude: Double(history.currentStreak),
                footnote: Text("days in a row")
            )

            SummaryCard(
                label: "LONGEST STREAK",
                valueText: "\(history.longestStreak)",
                valueMagnitude: Double(history.longestStreak),
                footnote: Text("best run")
            )

            SummaryCard(
                label: "BUSIEST DAY",
                valueText: history.busiestDay.map { $0.tokens.formatted(.tokenCount) } ?? "\u{2014}",
                valueMagnitude: Double(history.busiestDay?.tokens ?? 0),
                footnote: history.busiestDay.map { Text(Self.dayFormatter.string(from: $0.date)) }
            )

            SummaryCard(
                label: "ACTIVE DAYS",
                valueText: "\(history.activeDayCount)",
                valueMagnitude: Double(history.activeDayCount),
                footnote: history.firstActiveDay.map { Text("since \(Self.dayFormatter.string(from: $0))") }
            )
        }
        .frame(height: 104)
    }

    // MARK: - Punchcard

    private var punchcardCard: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            SectionHeader("When you work")
            PunchcardGrid(punchcard: history.punchcard, maxValue: history.punchcardMax)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.md)
        .panelCard()
    }

    // MARK: - Formatting

    static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter
    }()
}

// MARK: - Heatmap color scale

/// Level 0 (no activity) through 4 (top nonzero quartile) — shared between the grid
/// cells and the legend swatches so they never drift apart.
private func heatmapColor(level: Int) -> Color {
    switch level {
    case 0:  return Palette.textPrimary.opacity(0.06)
    case 1:  return Palette.accent.opacity(0.30)
    case 2:  return Palette.accent.opacity(0.55)
    case 3:  return Palette.accent.opacity(0.78)
    default: return Palette.accent.opacity(1.0)
    }
}

// MARK: - HeatmapGrid

/// GitHub-style contribution grid: 53 columns (weeks, Monday-first) x 7 rows, with month
/// labels above and weekday labels (Mon/Wed/Fri only) to the left.
private struct HeatmapGrid: View {
    let weeks: [[StatsHistory.HeatmapCell?]]

    private let cellSize: CGFloat = 11
    private let gap: CGFloat = 3
    private let weekdayColumnWidth: CGFloat = 28
    private let monthRowHeight: CGFloat = 14

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: gap) {
                Color.clear.frame(width: weekdayColumnWidth, height: monthRowHeight)
                ForEach(weeks.indices, id: \.self) { col in
                    // `.fixedSize()` so the label renders at its natural width and can
                    // overflow the narrow per-column slot rather than being truncated to "…".
                    Text(monthLabel(for: col) ?? "")
                        .textStyle(.caption)
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize()
                        .frame(width: cellSize, height: monthRowHeight, alignment: .leading)
                }
            }

            HStack(alignment: .top, spacing: gap) {
                VStack(alignment: .leading, spacing: gap) {
                    ForEach(0..<7, id: \.self) { row in
                        Text(weekdayLabel(row))
                            .textStyle(.caption)
                            .foregroundStyle(Palette.textSecondary)
                            .frame(width: weekdayColumnWidth, height: cellSize, alignment: .leading)
                    }
                }

                ForEach(weeks.indices, id: \.self) { col in
                    VStack(spacing: gap) {
                        ForEach(0..<7, id: \.self) { row in
                            cellView(weeks[col][row])
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func cellView(_ cell: StatsHistory.HeatmapCell?) -> some View {
        if let cell {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(heatmapColor(level: cell.level))
                .frame(width: cellSize, height: cellSize)
                .help(tooltip(for: cell))
        } else {
            Color.clear.frame(width: cellSize, height: cellSize)
        }
    }

    private func tooltip(for cell: StatsHistory.HeatmapCell) -> String {
        let dateText = StatisticsContent.dayFormatter.string(from: cell.date)
        guard cell.tokens > 0 else { return "\(dateText) \u{2014} no activity" }
        let tokensText = cell.tokens.formatted(.tokenCount)
        return "\(dateText) \u{2014} \(tokensText) tokens · \(cell.requests.groupedString) requests"
    }

    /// The short month name over `col`, shown only when its Monday falls in a different
    /// month than the previous column's Monday (immediate repeats are skipped).
    private func monthLabel(for col: Int) -> String? {
        guard let date = weeks[col].first.flatMap({ $0?.date }) else { return nil }
        let month = Self.monthFormatter.string(from: date)
        guard col > 0, let prevDate = weeks[col - 1].first.flatMap({ $0?.date }) else {
            return month
        }
        let prevMonth = Self.monthFormatter.string(from: prevDate)
        return month == prevMonth ? nil : month
    }

    private func weekdayLabel(_ row: Int) -> String {
        switch row {
        case 0: return "Mon"
        case 2: return "Wed"
        case 4: return "Fri"
        default: return ""
        }
    }

    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM"
        return formatter
    }()
}

// MARK: - HeatmapLegend

private struct HeatmapLegend: View {
    var body: some View {
        HStack(spacing: 4) {
            Text("Less")
                .textStyle(.caption)
                .foregroundStyle(Palette.textSecondary)
            ForEach(0..<5, id: \.self) { level in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(heatmapColor(level: level))
                    .frame(width: 9, height: 9)
            }
            Text("More")
                .textStyle(.caption)
                .foregroundStyle(Palette.textSecondary)
        }
    }
}

// MARK: - PunchcardGrid

/// Hour-by-weekday punchcard: 7 rows (Monday-first) x 24 hour columns of dots sized by
/// relative token volume, with weekday labels to the left and hour labels (0/6/12/18)
/// beneath.
private struct PunchcardGrid: View {
    let punchcard: [[Int]]
    let maxValue: Int

    private let cellWidth: CGFloat = 16
    private let rowHeight: CGFloat = 16
    private let weekdayColumnWidth: CGFloat = 28

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(0..<7, id: \.self) { row in
                HStack(spacing: 0) {
                    Text(weekdayLabel(row))
                        .textStyle(.caption)
                        .foregroundStyle(Palette.textSecondary)
                        .frame(width: weekdayColumnWidth, alignment: .leading)
                    ForEach(0..<24, id: \.self) { hour in
                        dot(value: punchcard[row][hour])
                            .frame(width: cellWidth, height: rowHeight)
                    }
                }
            }

            HStack(spacing: 0) {
                Color.clear.frame(width: weekdayColumnWidth)
                ForEach(0..<24, id: \.self) { hour in
                    Text(hourLabel(hour))
                        .textStyle(.caption)
                        .foregroundStyle(Palette.textSecondary)
                        .frame(width: cellWidth, alignment: .leading)
                }
            }
        }
    }

    @ViewBuilder
    private func dot(value: Int) -> some View {
        let diameter = diameter(for: value)
        Circle()
            .fill(value > 0 ? Palette.accent.opacity(0.85) : Palette.textPrimary.opacity(0.06))
            .frame(width: diameter, height: diameter)
    }

    private func diameter(for value: Int) -> CGFloat {
        guard value > 0 else { return 2 }
        let ratio = Double(value) / Double(max(maxValue, 1))
        return min(2 + 10 * CGFloat(ratio.squareRoot()), 12)
    }

    private func weekdayLabel(_ row: Int) -> String {
        ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"][row]
    }

    private func hourLabel(_ hour: Int) -> String {
        [0, 6, 12, 18].contains(hour) ? "\(hour)" : ""
    }
}
