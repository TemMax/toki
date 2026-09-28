/// GlassSurface — adaptive glass panel and card surface modifiers.
///
/// Two surface levels:
///   - glassPanel()  — outer popover/window background. Uses real Liquid Glass on macOS 26+
///                     with a cool slate tint overlay (Palette.bg) so the glass reads as
///                     Quarried Slate; falls back to .regularMaterial + Palette.bg tint
///                     + Palette.hairline border on macOS 14–25.
///   - panelCard()   — inner card tray. Filled Palette.card with Palette.hairline strokeBorder.
///                     Always opaque fills — never Liquid Glass — so it reads as a solid surface.
import SwiftUI

/// Rendering config for the headless snapshot harness. When `flatSurfaces` is true,
/// glass surfaces draw as OPAQUE fills (not Liquid Glass / material) so ImageRenderer
/// snapshots show real layout — materials and Liquid Glass don't composite off-screen.
enum SnapshotConfig {
    nonisolated(unsafe) static var flatSurfaces = false

    /// Whether surfaces must be drawn OPAQUE instead of translucent.
    ///
    /// Two independent reasons, ORed here rather than re-tested at each call site. The
    /// snapshot harness needs it because materials and Liquid Glass do not composite
    /// offscreen. A user who switched on **Reduce Transparency** needs it because they asked
    /// the system for exactly this, and until now the app ignored that setting outright —
    /// every translucent surface already had an opaque path, and none of them consulted it.
    ///
    /// SwiftUI call sites pass `@Environment(\.accessibilityReduceTransparency)` so the
    /// surfaces re-render the moment the setting is toggled; AppKit ones read
    /// `NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency` instead.
    static func opaqueSurfaces(reduceTransparency: Bool) -> Bool {
        flatSurfaces || reduceTransparency
    }

    /// When true, entrance animations render in their settled state immediately.
    ///
    /// Offscreen rendering never fires `onAppear`, and every section raises its `isVisible`
    /// flag from there — so without this a snapshotted surface captures at opacity 0, i.e.
    /// as a blank canvas. See `staggerIn`.
    nonisolated(unsafe) static var staticEntrance = false
}

// MARK: - Glass Panel

private struct GlassPanelModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        Group {
            if SnapshotConfig.opaqueSurfaces(reduceTransparency: reduceTransparency) {
                content.background(Palette.bg)
            } else {
                content.background(panelMaterial)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Radius.panel, style: .continuous))
        .overlay(GlassRim(cornerRadius: Radius.panel, bright: true))
    }

    /// Frosted slate panel for the popover. More slate-opaque than the dashboard window
    /// (~0.78) because the popover sits over a darker backdrop (the menu-bar region): a
    /// lighter, stable panel keeps the glass tiles on it reading light — like the window's —
    /// instead of going dark. (The popover is NOT itself glassEffect — that would make its
    /// tiles glass-on-glass.)
    private var panelMaterial: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            LinearGradient(
                colors: [Palette.bg.opacity(0.76), Palette.surface.opacity(0.82)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }
}

// MARK: - Glass Rim

/// Soft additive (Plus Lighter) white rim for glass edges — dim in light, brighter in dark.
/// Plus Lighter ADDS light, so the same white reads far brighter than a normal stroke and
/// blows out on light surfaces; hence the low, appearance-adaptive alpha. In snapshot (flat)
/// mode it falls back to a plain hairline, since ImageRenderer can't composite blend modes.
private struct GlassRim: View {
    var cornerRadius: CGFloat = Radius.card
    /// Stronger edge for the popover; the dashboard keeps the subtler default.
    var bright: Bool = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        // The glow rim is an additive blend over whatever shows through the surface. With the
        // surface opaque there is nothing to blend with, so it becomes a plain hairline.
        if SnapshotConfig.opaqueSurfaces(reduceTransparency: reduceTransparency) {
            shape.strokeBorder(Palette.hairline, lineWidth: BorderWidth.card)
        } else if scheme == .dark {
            // Dark tiles: additive white edge — a soft luminous glass glow.
            shape
                .strokeBorder(Color.white.opacity(bright ? 0.18 : 0.12), lineWidth: 1)
                .blendMode(.plusLighter)
        } else {
            // Light tiles: additive white is invisible here, so a NORMAL-blend white edge at
            // real opacity gives a visible luminous rim (the edge lighter than the tile = glow).
            shape
                .strokeBorder(Color.white.opacity(bright ? 0.45 : 0.3), lineWidth: 1)
        }
    }
}

// MARK: - Panel Card

private struct PanelCardModifier: ViewModifier {
    var rimBright: Bool = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if SnapshotConfig.opaqueSurfaces(reduceTransparency: reduceTransparency) {
            content
                .background(Palette.card)
                .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                .overlay(GlassRim(bright: rimBright))
        } else {
            // Frosted slate tile: a material (close-to-glass frost) rather than .glassEffect,
            // so we can set an exact, small drop shadow — the system Liquid Glass shadow can't
            // be sized. Used identically by the dashboard cards and the popover sections.
            content
                .background(
                    ZStack {
                        RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                            .fill(.regularMaterial)
                        RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                            .fill(Palette.card.opacity(0.72))
                    }
                )
                // Clip content to the card shape so animating rows can't spill past
                // the rounded edges. (Shadow is applied after, so it stays rounded.)
                .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                .overlay(GlassRim(bright: rimBright))
                .shadow(color: .black.opacity(0.06), radius: 3, x: 0, y: 1)
        }
    }
}

// MARK: - View extensions

extension View {
    /// Applies the outer popover panel surface: a frosted translucent slate material
    /// (matching the dashboard window) with a soft glass rim. Opaque in snapshot mode.
    func glassPanel() -> some View {
        modifier(GlassPanelModifier())
    }

    /// Applies a real Liquid Glass content tile (macOS 26) — slate-tinted, with a soft
    /// Plus-Lighter rim — used by the dashboard cards and the popover sections.
    /// `rimBright` brightens the edge for the popover (it sits over a darker backdrop).
    func panelCard(rimBright: Bool = false) -> some View {
        modifier(PanelCardModifier(rimBright: rimBright))
    }
}

// MARK: - Preview

#Preview("GlassSurface") {
    ZStack {
        LinearGradient(
            colors: [Palette.bg, Palette.surface],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()

        VStack(spacing: 16) {
            VStack(spacing: 12) {
                Text("Panel Glass")
                    .textStyle(.headline)
                    .foregroundStyle(Palette.textPrimary)
                RoundedRectangle(cornerRadius: Radius.element, style: .continuous)
                    .fill(Palette.accentSubtle)
                    .frame(height: 40)
                    .panelCard()
            }
            .padding(16)
            .glassPanel()
        }
        .padding(32)
    }
    .frame(width: 300, height: 240)
}
