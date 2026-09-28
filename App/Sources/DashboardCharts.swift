/// DashboardCharts — glass-aesthetic chart components for the Toki dashboard.
///
/// No Swift Charts dependency. All visualisations use the design-system
/// primitives: Sparkline, MiniBars, and inline capsule bars.
/// Pre-aggregates data in computed vars; no heavy work inside view bodies.
import AppKit
import TokiCore
import SwiftUI

// MARK: - Row appear/disappear transition

/// Light upward slide + fade for list rows (BY MODEL / TOP PROJECTS) appearing or
/// disappearing as the range changes: a row rises from just below into place and
/// fades in; on removal it reverses (drifts down + fades out).
private extension AnyTransition {
    static var rowAppear: AnyTransition {
        .modifier(
            active: RowAppearModifier(yOffset: 8, opacity: 0),
            identity: RowAppearModifier(yOffset: 0, opacity: 1)
        )
    }
}

private struct RowAppearModifier: ViewModifier {
    let yOffset: CGFloat
    let opacity: Double
    func body(content: Content) -> some View {
        content.opacity(opacity).offset(y: yOffset)
    }
}

// MARK: - Summary Cards Row

/// Four KPI cards at a fixed equal height so they always line up.
@MainActor
struct SummaryCardsRow: View {
    let summary: UsageSummary

    private var totalCalls: Int {
        summary.buckets.reduce(0) { $0 + $1.callCount }
    }

    var body: some View {
        HStack(spacing: Spacing.sm) {
            SummaryCard(
                label: "EST. API COST",
                valueText: summary.cost.map { $0.total.usdString } ?? "—",
                valueMagnitude: summary.cost?.total ?? 0,
                footnote: summary.cost.map { _ in
                    Text(summary.hasUnpricedUsage
                        ? "excludes unpriced models"
                        : "API-equivalent estimate")
                },
                valueColor: Palette.accent
            )

            // Tokens the models newly read or wrote. "In" is uncached input INCLUDING cache
            // writes: Claude reports a turn's new context as cache writes and Codex as plain
            // input, so only the sum counts both the same way (`TokenUsage.processedTokens`).
            SummaryCard(
                label: "TOKENS",
                valueText: summary.total.processedTokens.formatted(.tokenCount),
                valueMagnitude: Double(summary.total.processedTokens),
                footnote: Text(
                    "\(summary.total.uncachedInput.formatted(.tokenCount)) in · "
                    + "\(summary.total.output.formatted(.tokenCount)) out"
                ),
                valueColor: Palette.textPrimary
            )

            // Context re-read from cache — reported beside the tokens above, not inside them.
            SummaryCard(
                label: "CACHE READS",
                valueText: summary.total.cacheRead.formatted(.tokenCount),
                valueMagnitude: Double(summary.total.cacheRead),
                footnote: summary.total.cacheHitRate.map { rate in
                    Text("\(rate.formatted(.percent.precision(.fractionLength(0)))) of input from cache")
                },
                valueColor: Palette.textPrimary
            )

            SummaryCard(
                label: "API CALLS",
                valueText: totalCalls.groupedString,
                valueMagnitude: Double(totalCalls),
                footnote: nil,
                valueColor: Palette.textPrimary
            )
        }
        // Fixed height so all four cards are identical
        .frame(height: 104)
    }
}

@MainActor
struct SummaryCard: View {
    let label: String
    /// Already-formatted display string (e.g. "$12.34", "14.5K").
    let valueText: String
    /// The underlying numeric magnitude that drives roll direction in `.numericRoll`.
    let valueMagnitude: Double
    let footnote: Text?
    var valueColor: Color = Palette.textPrimary

    /// Line height reserved for the hero number so it never clips and — together
    /// with the always-present footnote row — keeps every card's number on the
    /// same baseline regardless of footnote or scale-to-fit.
    private let valueBand: CGFloat = 38

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            SectionHeader(label)

            Text(verbatim: valueText)
                .heroNumber()
                .foregroundStyle(valueColor)
                .numericRoll(value: valueMagnitude)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .frame(maxWidth: .infinity, minHeight: valueBand, alignment: .bottomLeading)

            // Footnote row is ALWAYS reserved (a space placeholder when absent) so
            // all four cards share the same vertical rhythm and their numbers align.
            // Full-strength secondary (no extra dimming) + medium weight so the
            // in/out and read/write splits stay legible against the hero number.
            (footnote ?? Text(verbatim: " "))
                .textStyle(.metricInline)
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(Spacing.md)
        .panelCard()
    }
}

// MARK: - Daily Trend Card

@MainActor
struct TrendCard: View {
    let buckets: [UsageBucket]
    let bucketSize: BucketSize

    // Pre-aggregated: cost values if any bucket has cost, else total tokens
    private var hasCost: Bool {
        buckets.contains { $0.cost != nil }
            && !buckets.contains { $0.hasUnpricedUsage }
    }

    private var sparkValues: [Double] {
        if hasCost {
            return buckets.map { $0.cost?.total ?? 0 }
        } else {
            return buckets.map { Double($0.usage.processedTokens) }
        }
    }

    /// "HOURLY COST" on a single-day range, "DAILY COST" otherwise — the header has to name
    /// the bucket, or the same card silently means two different things.
    private var title: String {
        switch (bucketSize, hasCost) {
        case (.hour, true):  return "HOURLY COST"
        case (.hour, false): return "HOURLY TOKENS"
        case (.day, true):   return "DAILY COST"
        case (.day, false):  return "DAILY TOKENS"
        }
    }

    private var allZero: Bool { sparkValues.allSatisfy { $0 == 0 } }

    private var minValue: Double { sparkValues.min() ?? 0 }
    private var maxValue: Double { sparkValues.max() ?? 0 }

    private var minLabel: String {
        hasCost ? minValue.usdString : Int(minValue).formatted(.tokenCount)
    }

    private var maxLabel: String {
        hasCost ? maxValue.usdString : Int(maxValue).formatted(.tokenCount)
    }

    private var dateRangeLabel: String {
        DisplayFormat.bucketRangeLabel(
            first: buckets.first?.date, last: buckets.last?.date, size: bucketSize
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            SectionHeader(title)

            if allZero {
                let tokenVals = buckets.map { Double($0.usage.processedTokens) }
                MiniBars(values: tokenVals, color: Palette.accent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Sparkline(values: sparkValues, color: Palette.accent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            // Min / max captions — roll when the range switch changes the underlying values.
            HStack {
                Text("min \(minLabel)")
                    .cardLabel()
                    .foregroundStyle(Palette.textSecondary)
                    .numericRoll(value: minValue)
                Spacer()
                Text(dateRangeLabel)
                    .cardLabel()
                    .foregroundStyle(Palette.textSecondary)
                Spacer()
                Text("max \(maxLabel)")
                    .cardLabel()
                    .foregroundStyle(Palette.textSecondary)
                    .numericRoll(value: maxValue)
            }
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .panelCard()
    }
}

// MARK: - By-Model Card

@MainActor
struct ByModelCard: View {

    struct ModelRow: Identifiable {
        let id: String      // model identifier
        let displayName: String
        let barOpacity: Double   // ranked opacity cascade
        let value: Double
        let fraction: Double   // relative to max
        let label: String
    }

    let byModel: [ModelUsage]

    private var hasCost: Bool { byModel.contains { $0.cost != nil } }
    private var hasMissingPricing: Bool {
        byModel.contains { $0.hasUnpricedUsage || $0.cost == nil }
    }
    private var usesCost: Bool { hasCost && !hasMissingPricing }

    private var rows: [ModelRow] {
        let sorted: [ModelUsage]
        if usesCost {
            sorted = byModel.sorted { ($0.cost?.total ?? 0) > ($1.cost?.total ?? 0) }
        } else {
            sorted = byModel.sorted { $0.usage.processedTokens > $1.usage.processedTokens }
        }
        let top = Array(sorted.prefix(5))
        let maxVal: Double = {
            if usesCost { return top.map { $0.cost?.total ?? 0 }.max() ?? 1 }
            return top.map { Double($0.usage.processedTokens) }.max() ?? 1
        }()
        let safeMax = maxVal == 0 ? 1 : maxVal

        // Ranked opacity cascade: top bar = 1.0, each next ≈ 72% of previous
        // 1.0, 0.72, 0.52, 0.37, 0.27
        let opacities: [Double] = (0..<top.count).map { i in
            pow(0.72, Double(i))
        }

        return top.enumerated().map { idx, m in
            let val: Double = usesCost
                ? (m.cost?.total ?? 0)
                : Double(m.usage.processedTokens)
            let lbl: String = usesCost ? val.usdString : Int(val).formatted(.tokenCount)
            return ModelRow(
                id: m.model,
                displayName: DisplayFormat.modelName(m.model),
                barOpacity: opacities[idx],
                value: val,
                fraction: val / safeMax,
                label: lbl
            )
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            SectionHeader("BY MODEL")

            if rows.isEmpty {
                Text("No model data")
                    .cardLabel()
                    .foregroundStyle(Palette.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer()
            } else {
                VStack(spacing: 0) {
                    ForEach(rows) { row in
                        ModelBarRow(row: row)
                            .frame(height: 32)
                            .transition(.rowAppear)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(.tokiPrimary, value: rows.map(\.id))
            }

            if hasMissingPricing {
                Text("* some usage has no public API pricing")
                    .textStyle(.detail)
                    .foregroundStyle(Palette.textSecondary)
            }
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .panelCard()
    }

}

@MainActor
private struct ModelBarRow: View {
    let row: ByModelCard.ModelRow

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            // Name (left) + value (right), above the full-width bar.
            HStack(spacing: Spacing.xs) {
                Circle()
                    .fill(Palette.accent.opacity(row.barOpacity))
                    .frame(width: 6, height: 6)
                Text(row.displayName)
                    .textStyle(.body)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    // The pretty name drops the vendor prefix and reshapes the version, so
                    // the exact model id stays one hover away.
                    .help(row.id)
                Spacer(minLength: Spacing.xs)
                Text(row.label)
                    .textStyle(.metricInline)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .numericRoll(value: row.value)
            }

            // Full-width proportional capsule bar below — ranked opacity cascade.
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Palette.textPrimary.opacity(0.08))
                        .frame(height: 5)
                    let fillWidth = max(row.fraction * geo.size.width, 3)
                    Capsule()
                        .fill(Palette.accent.opacity(row.barOpacity))
                        .frame(width: fillWidth, height: 5)
                        .animation(.tokiPrimary, value: fillWidth)
                        .animation(.tokiPrimary, value: row.barOpacity)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 5)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Top Projects Card

@MainActor
struct TopProjectsCard: View {

    struct ProjectRow: Identifiable {
        let id: String
        let name: String
        let path: String
        let barOpacity: Double   // ranked opacity cascade
        let value: Double
        let fraction: Double
        let label: String
    }

    let byProject: [ProjectUsage]

    private var hasCost: Bool { byProject.contains { $0.cost != nil } }
    private var hasMissingPricing: Bool {
        byProject.contains { $0.hasUnpricedUsage || $0.cost == nil }
    }
    private var usesCost: Bool { hasCost && !hasMissingPricing }

    private var rows: [ProjectRow] {
        let sorted: [ProjectUsage]
        if usesCost {
            sorted = byProject.sorted { ($0.cost?.total ?? 0) > ($1.cost?.total ?? 0) }
        } else {
            sorted = byProject.sorted { $0.usage.processedTokens > $1.usage.processedTokens }
        }
        let top = Array(sorted.prefix(8))
        let maxVal: Double = {
            if usesCost { return top.map { $0.cost?.total ?? 0 }.max() ?? 1 }
            return top.map { Double($0.usage.processedTokens) }.max() ?? 1
        }()
        let safeMax = maxVal == 0 ? 1 : maxVal

        return top.enumerated().map { idx, p in
            let val: Double = usesCost
                ? (p.cost?.total ?? 0)
                : Double(p.usage.processedTokens)
            let lbl: String = usesCost ? val.usdString : Int(val).formatted(.tokenCount)
            return ProjectRow(
                id: p.path.isEmpty ? p.project : p.path,
                name: p.project,
                path: p.path,
                barOpacity: pow(0.72, Double(idx)),
                value: val,
                fraction: val / safeMax,
                label: lbl
            )
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            SectionHeader("TOP PROJECTS")

            if rows.isEmpty {
                Text("No project data")
                    .cardLabel()
                    .foregroundStyle(Palette.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(spacing: Spacing.xs) {
                    ForEach(rows) { row in
                        ProjectBarRow(row: row)
                            .frame(height: 46)
                            .transition(.rowAppear)
                    }
                }
                .animation(.tokiPrimary, value: rows.map(\.id))
            }

            if hasMissingPricing {
                Text("* some usage has no public API pricing")
                    .textStyle(.detail)
                    .foregroundStyle(Palette.textSecondary)
            }
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity)
        .panelCard()
    }
}

@MainActor
private struct ProjectBarRow: View {
    let row: TopProjectsCard.ProjectRow

    /// True when the project's directory still exists on disk (paths from another
    /// machine, or moved/deleted projects, are not revealable).
    private var pathExists: Bool {
        !row.path.isEmpty && FileManager.default.fileExists(atPath: row.path)
    }

    /// Home-abbreviated path for display, e.g. `~/dev/personal/alpha`.
    private var displayPath: String {
        (row.path as NSString).abbreviatingWithTildeInPath
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Name (left) + value (right).
            HStack(spacing: Spacing.xs) {
                Text(row.name)
                    .textStyle(.body)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: Spacing.xs)
                Text(row.label)
                    .textStyle(.metricInline)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .numericRoll(value: row.value)
            }

            // Path (left, dim) + reveal-in-Finder button (right).
            if !row.path.isEmpty {
                HStack(spacing: Spacing.xs) {
                    Text(displayPath)
                        .textStyle(.detail)
                        .foregroundStyle(Palette.textSecondary.opacity(0.75))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(row.path)
                    Spacer(minLength: Spacing.xs)
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: row.path)])
                    } label: {
                        Image(systemName: "folder")
                            .iconSize(.small)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Palette.textSecondary.opacity(pathExists ? 0.9 : 0.3))
                    .disabled(!pathExists)
                    .help(pathExists ? "Reveal in Finder" : "Location not found")
                }
            }

            // Full-width proportional capsule bar below — ranked opacity cascade.
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Palette.textPrimary.opacity(0.08))
                        .frame(height: 5)
                    let fillWidth = max(row.fraction * geo.size.width, 3)
                    Capsule()
                        .fill(Palette.accent.opacity(row.barOpacity))
                        .frame(width: fillWidth, height: 5)
                        .animation(.tokiPrimary, value: fillWidth)
                        .animation(.tokiPrimary, value: row.barOpacity)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 5)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Compact Limits Strip

@MainActor
struct LimitsStrip: View {
    let limits: UsageLimits
    var uppercaseTitles: Bool = true

    /// One block in the strip — a rate-limit gauge or the extra-usage tile.
    private enum Item: Identifiable {
        case gauge(RateLimitWindow)
        case extra(ExtraUsage)

        var id: String {
            switch self {
            case let .gauge(window): return window.id
            case .extra: return "extra"
            }
        }
    }

    private var items: [Item] {
        var result: [Item] = limits.windows.map { .gauge($0) }
        // Also shown when the spend cap is hit: the API may flip is_enabled off at
        // the cap, and silently dropping the tile would hide *why* usage stopped.
        if let extra = limits.extra, extra.isEnabled || extra.spendLimitReached {
            result.append(.extra(extra))
        }
        return result
    }

    var body: some View {
        // Use a plain HStack (not ScrollView) so GeometryReader inside CapsuleGauge
        // receives a concrete size from the layout pass. ScrollView(.horizontal) passes
        // zero height to its content in ImageRenderer, causing the gauge bars to vanish.
        // A faint, edge-fading hairline separates each block.
        let blocks = items
        // Top-align: the EXTRA tile has 2 rows (title + bar) vs the gauges' 3 (title +
        // bar + "resets in …"), so .center would drop it lower than the others.
        HStack(alignment: .top, spacing: Spacing.sm) {
            ForEach(blocks.indices, id: \.self) { index in
                if index > 0 {
                    LimitsDivider()
                }
                content(for: blocks[index])
                    .frame(maxWidth: .infinity)
            }
        }
    }

    @ViewBuilder
    private func content(for item: Item) -> some View {
        switch item {
        case let .gauge(window):
            CapsuleGauge(
                title: window.title,
                fraction: window.utilization,
                detail: window.isAvailable ? relativeReset(window.resetsAt) : nil,
                isUnavailable: !window.isAvailable,
                uppercaseTitle: uppercaseTitles
            )
        case let .extra(extra):
            ExtraUsageTile(extra: extra)
        }
    }

    private func relativeReset(_ date: Date?) -> String {
        guard let date else { return "" }
        let diff = date.timeIntervalSinceNow
        guard diff > 0 else { return "resets now" }
        let hours = Int(diff / 3600)
        let minutes = Int((diff.truncatingRemainder(dividingBy: 3600)) / 60)
        if hours >= 24 {
            let days = hours / 24
            return "resets in ~\(days)d"
        } else if hours > 0 {
            return "resets in ~\(hours)h \(minutes)m"
        } else {
            return "resets in ~\(minutes)m"
        }
    }
}

/// Faint vertical separator between blocks in the limits strip: a 1pt hairline that
/// fades out at the top and bottom — barely there, but enough to parcel the metrics.
private struct LimitsDivider: View {
    var body: some View {
        LinearGradient(
            colors: [
                Palette.hairline.opacity(0),
                Palette.hairline.opacity(0.8),
                Palette.hairline.opacity(0)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(width: 1)
        .frame(maxHeight: 44)
    }
}

@MainActor
private struct ExtraUsageTile: View {
    let extra: ExtraUsage

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text("EXTRA")
                    .textStyle(.label)
                    .kerning(0.4)
                    .foregroundStyle(Palette.textSecondary)
                Spacer()
                if let used = extra.usedCredits, let limit = extra.monthlyLimit {
                    Text("\(extra.amountString(used)) / \(extra.amountString(limit))")
                        .textStyle(.metricInline)
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                } else if let used = extra.usedCredits {
                    Text(extra.amountString(used))
                        .textStyle(.metricInline)
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            }

            if let util = extra.utilization {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Palette.textPrimary.opacity(0.08))
                            .frame(height: 6)
                        let fillWidth = max(util * geo.size.width, 3)
                        Capsule()
                            .fill(Palette.metric(util))
                            .frame(width: fillWidth, height: 6)
                    }
                }
                .frame(height: 6)
            } else {
                Capsule()
                    .fill(Palette.textPrimary.opacity(0.08))
                    .frame(height: 6)
            }

            if extra.spendLimitReached {
                Text("Limit reached")
                    .textStyle(.caption)
                    .foregroundStyle(Palette.critical)
            }
        }
    }
}
