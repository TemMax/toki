import SwiftUI
import TokiDesign
import TokiMenuBar

/// Draws `[ResolvedIndicator]` as the small strip `MenuBarStripRenderer` rasterizes into the
/// status item's label image.
///
/// Never used as a live view directly in the status bar — see `MenuBarStripRenderer`'s doc
/// comment for why the strip has to be rendered offscreen first.
struct MenuBarStripView: View {
    let indicators: [ResolvedIndicator]
    /// The strip's framing, spacing and sizes — see `MenuBarStyle`'s own doc comment for the
    /// clamping/reasoning behind every field. Colour is not part of this: the strip is always
    /// drawn as a template-safe solid black mask, and macOS retints it for light/dark/
    /// highlighted — see `MenuBarStripRenderer`.
    let style: MenuBarStyle

    /// `TypeScale.multiplier` composed onto every point size `style` supplies, so the user's
    /// own style choice and the accessibility text-size setting scale together rather than
    /// one silently overriding the other.
    private var scale: CGFloat { CGFloat(TypeScale.multiplier) }

    private var barWidth: CGFloat { CGFloat(style.barWidth) * scale }
    private var barHeight: CGFloat { CGFloat(style.barHeight) * scale }
    private var labelGap: CGFloat { CGFloat(style.labelGap) * scale }
    private var groupGap: CGFloat { CGFloat(style.groupGap) * scale }
    private var valuePointSize: CGFloat { CGFloat(style.valueSize) * scale }
    private var labelPointSize: CGFloat { CGFloat(style.labelSize) * scale }
    private var unitPointSize: CGFloat { valuePointSize * CGFloat(style.unitScale) }

    var body: some View {
        // Baseline, not centre. The strip mixes several sizes — the value digits, the label
        // and the unit sign — and centring each one vertically leaves the smaller pieces
        // floating in the middle of the digits' height. Sitting them on a shared baseline is
        // what makes the row read as one line of text rather than stacked scales. A bar has
        // no baseline of its own, so SwiftUI rests its bottom edge on the text's — which is
        // where a gauge filling upward should start anyway.
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            if !style.leading.isEmpty {
                punctuation(style.leading)
            }
            HStack(alignment: .firstTextBaseline, spacing: groupGap) {
                ForEach(Array(indicators.enumerated()), id: \.offset) { offset, indicator in
                    if offset > 0, !style.separator.isEmpty {
                        punctuation(style.separator)
                    }
                    indicatorView(indicator)
                }
            }
            if !style.trailing.isEmpty {
                punctuation(style.trailing)
            }
        }
        .fixedSize()
    }

    private func indicatorView(_ indicator: ResolvedIndicator) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: labelGap) {
            if indicator.showsLabel {
                label(indicator)
            }
            switch indicator.rendering {
            case .bar:
                bar(indicator)
            case .number:
                number(indicator)
            case .barAndNumber:
                bar(indicator)
                number(indicator)
            }
        }
    }

    /// The window's short name — `5h`, `7d`, `Opus` — or a `customLabel` override. Drawn
    /// quieter than the value: the label tells you *which* limit, and you only need to read
    /// it once, whereas the number is what changes and what the glance is for.
    private func label(_ indicator: ResolvedIndicator) -> some View {
        // The colon does real work at this size: without it `5h 34` reads as two loose
        // tokens, and several of those in a row are that many more things to parse. `5h:`
        // binds the name to the figure that follows it, so the strip scans as labelled
        // values rather than a wall of numbers.
        punctuation("\(indicator.title):")
    }

    /// `leading`/`trailing`/`separator` and per-indicator labels all render in the same
    /// register: punctuation/naming text, never the value's own weight or size. One shared
    /// primitive keeps that a fact about the code, not a convention callers have to remember,
    /// and keeps the raw-size call site (below) to one place for the type-scale lint.
    private func punctuation(_ text: String) -> some View {
        Text(text)
            // TYPE-SCALE EXEMPT: point size comes from the user's own `MenuBarStyle.labelSize`
            // (composed with `TypeScale.multiplier`), not a fixed `TypeScale.Role` — the whole
            // point of `MenuBarStyle` is that this size is user-configurable rather than
            // pinned to a ladder step. See `MenuBarStyle`'s doc comment for the clamp bounds.
            .font(.system(size: labelPointSize, weight: .regular))
            .foregroundStyle(labelColor)
            .fixedSize()
    }

    /// A vertical stroke filled from the bottom by `indicator.fraction`. The track (the full
    /// outline, `barWidth` by `barHeight`) is ALWAYS drawn, filled or not — an unavailable
    /// indicator draws it with no fill, present and obviously empty, so nothing shifts in
    /// width when data arrives.
    private func bar(_ indicator: ResolvedIndicator) -> some View {
        let fraction = (indicator.isUnavailable ? nil : indicator.fraction).map {
            min(max($0, 0), 1)
        }
        return ZStack(alignment: .bottom) {
            Rectangle()
                .fill(trackColor)
                .frame(width: barWidth, height: barHeight)
            if let fraction {
                Rectangle()
                    .fill(fillColor)
                    .frame(width: barWidth, height: barHeight * fraction)
            }
        }
        .frame(width: barWidth, height: barHeight, alignment: .bottom)
    }

    /// The percentage, monospaced so a ticking figure never reflows the item's width. An
    /// unavailable indicator shows an em dash instead — there is no percentage to display,
    /// and a dash keeps the same "present but empty" read as the bar.
    ///
    /// The `%` sits dimmer than the digits so it annotates the figure instead of competing
    /// with it; `unitScale` (part of `style`) controls its size relative to the value, down
    /// to 0 which hides it outright.
    private func number(_ indicator: ResolvedIndicator) -> some View {
        let fraction = indicator.isUnavailable ? nil : indicator.fraction
        let value = fraction.map { "\(Int(($0 * 100).rounded()))" }
        return HStack(alignment: .firstTextBaseline, spacing: 0.5) {
            Text(value ?? "—")
                // TYPE-SCALE EXEMPT: point size comes from the user's own
                // `MenuBarStyle.valueSize` (composed with `TypeScale.multiplier`), not a
                // fixed `TypeScale.Role` — see `MenuBarStyle`'s doc comment for the clamp
                // bounds this is guaranteed to fall inside.
                .font(.system(size: valuePointSize, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(fraction != nil ? fillColor : trackColor)
            if value != nil, style.unitScale > 0 {
                Text("%")
                    // TYPE-SCALE EXEMPT: a unit symbol, not interface text — read once, as a
                    // unit attached to a figure already understood. Sized as
                    // `MenuBarStyle.unitScale` of the resolved value size (itself already
                    // composed with `TypeScale.multiplier`), so it bypasses the ladder, not
                    // the multiplier, and stays proportional if either the user's style or
                    // the text-size multiplier moves.
                    .font(.system(size: unitPointSize, weight: .medium))
                    .foregroundStyle(percentColor)
            }
        }
        .fixedSize()
    }

    private var trackColor: Color {
        Color.black.opacity(0.25)
    }

    /// Template images are a mask: macOS keeps the alpha and throws the colour away, so a
    /// "dimmer" label has to be dimmer in ALPHA, not in shade. Grey here would come back as
    /// solid tint.
    private var labelColor: Color {
        Color.black.opacity(0.55)
    }

    /// Quieter than the digits it annotates, but louder than the window's name — the sign
    /// belongs to the number, and reading it at the same weight as `5h` would regroup the
    /// strip into the wrong pairs.
    private var percentColor: Color {
        Color.black.opacity(0.7)
    }

    private var fillColor: Color {
        Color.black
    }
}
