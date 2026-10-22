import SwiftUI
import TokiMenuBar

/// The compact label shown in the macOS status bar.
///
/// The user's configured indicator strip (bars and/or numbers), rasterized
/// offscreen by `MenuBarStripRenderer` — see its doc comment for why that indirection is
/// necessary rather than drawing the strip's shapes directly as the label.
///
/// The rendered image always ships as a template, so macOS tints it to match the bar's
/// light/dark/highlighted appearance, same as any other monochrome status-bar icon — colour
/// is not customisable (see `MenuBarConfiguration`'s doc comment).
struct MenuBarLabel: View {
    /// The configured list resolved against live data. See `MenuBarViewModel.resolvedIndicators`.
    let indicators: [ResolvedIndicator]
    /// The strip's framing, spacing and sizes — see `MenuBarStyle`'s own doc comment.
    var style: MenuBarStyle = .standard

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Image(nsImage: MenuBarStripRenderer.image(
            for: indicators,
            style: style,
            colorScheme: colorScheme,
            scale: displayScale
        ))
        .fixedSize()
        // Expose the rasterized strip as one accessible element with all indicator values.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(MenuBarLayout.accessibilityDescription(for: indicators))
    }
}
