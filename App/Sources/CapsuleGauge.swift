/// CapsuleGauge — horizontal bar gauge primitive for rate-limit windows.
///
/// Renders a labeled header row (title left, percent right) above a 6pt-tall
/// capsule track with a filled indicator tinted via Palette.metric(). Optionally
/// shows a detail caption below (e.g. "resets in ~3h"). Fill animates with a
/// soft spring; percent text uses .numericText() content transition.
import SwiftUI
import TokiCore

struct CapsuleGauge: View {
    let title: String
    let fraction: Double     // 0...1
    var detail: String? = nil
    var isUnavailable: Bool = false
    /// Section labels use uppercase throughout Toki, but product names such as
    /// "GPT-5.3 Codex Spark" are proper names rather than labels.
    var uppercaseTitle: Bool = true
    /// How this window's usage compares with the clock. Draws a mark where even spending
    /// would be, and a warning line when the limit runs out before the reset at this rate.
    var pace: UsagePace? = nil

    private var clamped: Double { min(max(fraction, 0), 1) }
    private var percentText: String { "\(Int((clamped * 100).rounded()))%" }
    private var fillColor: Color { Palette.metric(clamped) }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            // Header row: title + percent (or unavailable tag)
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .textStyle(.label)
                    .kerning(0.4)
                    .foregroundStyle(isUnavailable ? Palette.textSecondary.opacity(0.5) : Palette.textSecondary)
                    .textCase(uppercaseTitle ? .uppercase : nil)
                Spacer()
                if isUnavailable {
                    UnavailableTag()
                } else {
                    Text(percentText)
                        .textStyle(.metricInline)
                        .foregroundStyle(fillColor)
                        .contentTransition(.numericText())
                        .animation(.spring(response: 0.45, dampingFraction: 0.72), value: clamped)
                }
            }

            // Track + fill bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    // Track
                    Capsule()
                        .fill(Palette.textPrimary.opacity(0.08))
                        .frame(height: 6)

                    if !isUnavailable {
                        // Fill — minimum 3pt so 0% isn't invisible
                        let fillWidth = max(clamped * geo.size.width, 3)
                        Capsule()
                            .fill(fillColor)
                            .frame(width: fillWidth, height: 6)
                    }

                    // Pace mark: where the fill would be with even spending. Fill past it
                    // means the limit runs out before the reset.
                    if !isUnavailable, let pace {
                        Capsule()
                            .fill(Palette.textPrimary.opacity(0.55))
                            .frame(width: 2, height: 10)
                            .offset(x: min(max(pace.expected * geo.size.width - 1, 0), geo.size.width - 2))
                            .accessibilityHidden(true)
                    }
                }
            }
            .frame(height: 6)
            .animation(isUnavailable ? nil : .spring(response: 0.45, dampingFraction: 0.72), value: fraction)

            // Optional detail caption (suppressed when unavailable).
            //
            // `Palette.textSecondary` at full strength, not dimmed to 0.8. Two reasons.
            // First, an ad-hoc `.opacity()` on a token invents a fourth text level nobody
            // measured — `Palette.textTertiary` already exists for a genuine third level
            // and is contrast-asserted, so a hand-dimmed secondary is an unaudited colour
            // pretending to be a token. Second, this caption is the reset countdown: after
            // the percentage it is the most useful thing on this surface, so it is exactly
            // the wrong text to render faintest.
            if !isUnavailable, let detail {
                Text(detail)
                    .textStyle(.detail)
                    .foregroundStyle(Palette.textSecondary)
            }
            if !isUnavailable, let warning = pace?.warningText() {
                Label(warning, systemImage: "arrow.up.right")
                    .labelStyle(.titleAndIcon)
                    .textStyle(.detail)
                    .foregroundStyle(Palette.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(paceAccessibilityText)
    }

    private var paceAccessibilityText: String {
        guard !isUnavailable, let pace else { return "" }
        switch pace.verdict {
        case .ahead: return pace.warningText() ?? "ahead of pace"
        case .onPace: return "on pace"
        case .under: return "under pace"
        }
    }
}

/// Compact muted pill shown in place of the percent text when a gauge's
/// window has no data to report.
private struct UnavailableTag: View {
    var body: some View {
        Text("unavailable")
            .textStyle(.caption)
            .foregroundStyle(Palette.textSecondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Palette.textPrimary.opacity(0.08))
            .clipShape(Capsule())
    }
}

// MARK: - Preview

#Preview("CapsuleGauge") {
    VStack(spacing: 16) {
        CapsuleGauge(title: "5-hour", fraction: 0.35, detail: "resets in ~2h 10m")
        CapsuleGauge(title: "7-day", fraction: 0.68, detail: "resets in ~4d",
                     pace: UsagePace(utilization: 0.68, resetsAt: Date().addingTimeInterval(4 * 86400),
                                     duration: 7 * 86400))
        CapsuleGauge(title: "7-day Opus", fraction: 0.91, detail: "resets in ~6d")
        CapsuleGauge(title: "Maxed out", fraction: 1.0)
        CapsuleGauge(title: "Empty", fraction: 0.0)
        CapsuleGauge(title: "7-day Fable", fraction: 0, isUnavailable: true)
    }
    .padding(20)
    .frame(width: 280)
    .background(Palette.surface)
}
