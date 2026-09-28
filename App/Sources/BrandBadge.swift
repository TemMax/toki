/// BrandBadge — squircle badge for the panel header.
///
/// A continuous rounded-rect filled with a warm gradient built from Palette.accent
/// (fired clay → accentSubtle), with a white gloss overlay and a white SF Symbol glyph.
/// Premium, warm, on-brand.
import SwiftUI

struct BrandBadge: View {
    var size: CGFloat = 28
    var symbolName: String = "chart.bar.fill"

    private var cornerRadius: CGFloat { size * 0.30 }
    private var symbolSize: CGFloat { size * 0.52 }

    var body: some View {
        ZStack {
            // Squircle background: warm gradient from Palette.accent to a deeper terracotta
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Palette.accent,
                            Palette.critical.opacity(0.85),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                // Subtle gloss highlight — top-left catches the light
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.18),
                                    Color.white.opacity(0.04),
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                )

            // SF Symbol glyph in Palette.bg (linen white) for warmth over pure white.
            // `symbolSize` is `size * 0.52` — a continuously proportional icon glyph tied to
            // this view's own `size` parameter (20/28/36/44 in practice), not one of the
            // ladder's fixed steps. Neither `TypeScale.Role` nor `IconSize` can express
            // "scales with a runtime container size"; both ladders are fixed-step, this is a
            // ratio — see `scripts/lint-type-scale.sh` for the exemption mechanism.
            Image(systemName: symbolName)
                // TYPE-SCALE EXEMPT: continuously proportional to `size`, not a ladder step.
                .font(.system(size: symbolSize, weight: .semibold))
                .foregroundStyle(Palette.bg)
                .symbolRenderingMode(.hierarchical)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Preview

#Preview("BrandBadge") {
    HStack(spacing: 16) {
        BrandBadge(size: 20)
        BrandBadge(size: 28)
        BrandBadge(size: 36)
        BrandBadge(size: 44, symbolName: "gauge.with.dots.needle.bottom.50percent")
    }
    .padding(24)
    .background(Palette.surface)
}
