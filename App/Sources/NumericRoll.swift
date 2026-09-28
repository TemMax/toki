/// NumericRoll — reusable "rolling counter" modifier for KPI/hero numbers.
///
/// Wraps SwiftUI's native `.contentTransition(.numericText(value:))` (macOS 14+),
/// which rolls digits up when the underlying value increases and down when it
/// decreases — driven by a spring so it matches the rest of the dashboard's motion
/// language (primary spring: response 0.45, damping 0.82).
///
/// Additionally applies a very subtle motion-blur pulse on change: radius animates
/// 0 -> ~1.5 -> 0 as `value` changes, composed so the RESTING state is always
/// radius 0 — under `SnapshotConfig.flatSurfaces` (headless ImageRenderer snapshots,
/// no animation pump) the view therefore always renders pixel-sharp, satisfying the
/// "must render correctly with flatSurfaces" requirement.
///
/// Usage: `Text(formattedString).heroNumber().numericRoll(value: theUnderlyingDouble)`
/// — `Text` shows the already-formatted display string; `value` is the raw magnitude
/// that drives roll direction (and the blur pulse trigger).
import SwiftUI

// MARK: - Shared spring

extension Animation {
    /// Primary motion spring used across dashboard data transitions (numbers, charts, bars).
    static var tokiPrimary: Animation {
        .spring(response: 0.45, dampingFraction: 0.82)
    }
}

// MARK: - NumericRoll modifier

private struct NumericRollModifier: ViewModifier {
    let value: Double

    /// Transient blur radius for the motion-blur pulse. Always settles back to 0,
    /// so the resting/snapshot state is sharp.
    @State private var blurRadius: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .contentTransition(.numericText(value: value))
            .animation(.tokiPrimary, value: value)
            .blur(radius: SnapshotConfig.flatSurfaces ? 0 : blurRadius)
            .onChange(of: value) { _, _ in
                guard !SnapshotConfig.flatSurfaces else { return }
                // Quick pulse up, then spring back to sharp — reads as a brief
                // motion-blur on the roll without leaving any lingering softness
                // or shifting layout (blur doesn't affect frame size).
                withAnimation(.easeOut(duration: 0.09)) {
                    blurRadius = 1.5
                }
                withAnimation(.tokiPrimary.delay(0.09)) {
                    blurRadius = 0
                }
            }
    }
}

extension View {
    /// Animates a `Text` (or any view) like a rolling counter when `value` changes:
    /// digits transition directionally (up for larger, down for smaller) via the
    /// native `.numericText` content transition, driven by the shared dashboard
    /// spring. Adds a brief, layout-neutral motion-blur pulse that always resolves
    /// to sharp — safe under `SnapshotConfig.flatSurfaces`.
    ///
    /// - Parameter value: the underlying numeric magnitude (not the display string)
    ///   that determines roll direction.
    func numericRoll(value: Double) -> some View {
        modifier(NumericRollModifier(value: value))
    }

    /// Convenience overload for integer-valued counters (e.g. raw token counts).
    func numericRoll(value: Int) -> some View {
        numericRoll(value: Double(value))
    }
}

// MARK: - Preview

private struct NumericRollPreview: View {
    @State private var big = false

    var body: some View {
        let value: Double = big ? 1240 : 847
        VStack(spacing: Spacing.lg) {
            Text(value, format: .number)
                .heroNumber()
                .foregroundStyle(Palette.textPrimary)
                .numericRoll(value: value)

            Button(big ? "Roll down" : "Roll up") {
                big.toggle()
            }
        }
        .padding(Spacing.xl)
        .background(Palette.surface)
    }
}

#Preview("NumericRoll") {
    NumericRollPreview()
}
