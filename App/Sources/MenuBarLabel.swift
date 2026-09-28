import SwiftUI
import TokiMenuBar

/// The compact label shown in the macOS status bar.
///
/// Normal mode: the user's configured indicator strip (bars and/or numbers), rasterized
/// offscreen by `MenuBarStripRenderer` — see its doc comment for why that indirection is
/// necessary rather than drawing the strip's shapes directly as the label.
/// Extra-usage mode: a "creditcard" glyph (a native SwiftUI `Image`, which — unlike shapes —
/// draws fine directly in the label) beside a single rendered `.number` indicator for the
/// extra-usage budget. The configured strip is replaced rather than shown alongside it: the
/// 5-hour/7-day/scoped windows it tracks are meaningless while spending pay-as-you-go extra
/// usage, so showing them would read as live data that in fact froze the moment extra usage
/// kicked in.
///
/// The rendered image always ships as a template, so macOS tints it to match the bar's
/// light/dark/highlighted appearance, same as any other monochrome status-bar icon — colour
/// is not customisable (see `MenuBarConfiguration`'s doc comment).
struct MenuBarLabel: View {
    /// What the strip currently shows — the configured list resolved against live data, or
    /// (in extra-usage mode) the single extra-usage indicator. See
    /// `MenuBarViewModel.resolvedIndicators` / `.extraUsageIndicator`.
    let indicators: [ResolvedIndicator]
    var isExtraUsage: Bool = false
    /// The strip's framing, spacing and sizes — see `MenuBarStyle`'s own doc comment.
    var style: MenuBarStyle = .standard

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        HStack(spacing: 2) {
            if isExtraUsage {
                Image(systemName: "creditcard.fill")
            }
            Image(nsImage: MenuBarStripRenderer.image(
                for: indicators,
                style: style,
                colorScheme: colorScheme,
                scale: displayScale
            ))
        }
        .fixedSize()
        // ONE element for the whole label, not one per drawn piece: everything here is either a
        // rasterized strip or a glyph, none of which speaks for itself, so without this the
        // status item announces nothing at all (before Phase 2 the label was `Text`, which did).
        // `children: .ignore` because there is nothing worth stopping on twice — the extra-usage
        // path's own single resolved indicator ("Extra: 78 percent") already says what the
        // creditcard glyph beside it means, so the same description covers that path too.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(MenuBarLayout.accessibilityDescription(for: indicators))
    }
}
