/// AppIconBadge — the app's own mark, shown wherever Toki identifies itself
/// (the popover header, the About panel).
///
/// Uses the `BrandMark` asset rather than `NSApp.applicationIconImage`: the Dock icon
/// carries the ~10% margins the macOS icon grid requires, which read as an undersized
/// badge inside a compact header. `BrandMark` is the same artwork with the rounded mask
/// but without those margins, so it fills the frame it is given. Both are generated from
/// `design/app-icon-source-1024.png`.
import SwiftUI

struct AppIconBadge: View {
    var size: CGFloat = 28

    var body: some View {
        Image("BrandMark")
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
    }
}

// MARK: - Preview

#Preview("AppIconBadge") {
    HStack(spacing: 16) {
        AppIconBadge(size: 20)
        AppIconBadge(size: 30)
        AppIconBadge(size: 44)
    }
    .padding(24)
    .background(Palette.surface)
}
