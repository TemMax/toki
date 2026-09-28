/// StatusPill — a small capsule chip for status indicators.
///
/// Contains a colored dot (with a subtle shadow when `active`) and a caption label.
/// The capsule fill is `color.opacity(~0.16)` so it sits lightly on any surface.
/// Text uses Palette.textPrimary for legibility over any palette color.
import SwiftUI

struct StatusPill: View {
    let text: String
    let color: Color
    var active: Bool = false

    var body: some View {
        HStack(spacing: 5) {
            // Status dot — tiny glow shadow only when active
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
                .shadow(color: active ? color.opacity(0.55) : .clear, radius: 3, x: 0, y: 0)

            Text(text)
                .textStyle(.label)
                .foregroundStyle(Palette.textPrimary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(color.opacity(0.16))
        )
    }
}

// MARK: - Preview

#Preview("StatusPill") {
    VStack(spacing: 12) {
        HStack(spacing: 8) {
            StatusPill(text: "Connected", color: Palette.ok, active: true)
            StatusPill(text: "Stale", color: Palette.warn)
            StatusPill(text: "Error", color: Palette.critical)
        }
        HStack(spacing: 8) {
            StatusPill(text: "Loading", color: Palette.accent, active: true)
            StatusPill(text: "Offline", color: Palette.textSecondary)
        }
    }
    .padding(20)
    .background(Palette.surface)
}
