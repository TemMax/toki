/// Theme — shared formatting, color helpers, and design tokens for the Toki UI.
import SwiftUI

// MARK: - Design Tokens

/// Spacing scale used throughout the UI.
enum Spacing {
    static let xxs: CGFloat = 4
    static let xs:  CGFloat = 8
    static let sm:  CGFloat = 12
    static let md:  CGFloat = 16
    static let lg:  CGFloat = 20
    static let xl:  CGFloat = 24
}

/// Corner-radius tokens. All consumers use `RoundedRectangle(style: .continuous)`
/// (Apple squircle / superellipse), so these values control how round, not the shape.
enum Radius {
    /// Small controls — pills, buttons, segmented control (14 pt).
    static let element: CGFloat = 14
    /// Inner content cards and grouping trays (20 pt).
    static let card:  CGFloat = 20
    /// Outer panel/popover/window surface (28 pt).
    static let panel: CGFloat = 28
}

/// Width measurements that a layout decision is made against.
///
/// A settings row is a label at the leading edge and one small control at the trailing edge, so
/// a single column of them across the whole dashboard leaves several hundred points of dead
/// space in the middle. The fix is to fill that width with CONTENT — a second column of cards —
/// not with margin, which is why there is no page-width cap here: charts, heatmaps and the
/// Accounts tab's three side-by-side gauges all use every point they are given.
enum Measure {

    /// Width of a macOS notification banner, used by anything that draws a stand-in for one
    /// (the notifications editor's PREVIEW card). A preview only does its job at the size of
    /// the thing it previews — stretched to the sheet width it stops resembling it.
    static let notificationBanner: CGFloat = 360

    /// Height of the dashboard's floating toolbar — the title row, the account row and
    /// the tab strip, plus the padding around them. It is drawn OVER the tabs rather than
    /// above them (content scrolls under its progressive blur), so it reserves no space of
    /// its own and every tab has to be told how tall it is.
    static let dashboardToolbar: CGFloat = 118

    /// Where every dashboard tab's content starts, measured from the top of the window: clear
    /// of the toolbar above, plus one step of air.
    ///
    /// THE single owner of that distance. It used to be spelled `toolbarHeight + Spacing.sm`
    /// at each of the five tab call sites, which is five numbers that only happened to agree
    /// — the same defect the page width had before `Measure` existed. `DashboardView` now
    /// applies this once, to the whole content area, so no tab can start at a different
    /// height from its neighbours.
    ///
    /// The toolbar overlay ignores the top safe area, so its rows are laid out from the very
    /// top of the window. `DashboardView.contentArea` ignores it too, so this value is measured
    /// from that same origin; before that, the hidden title bar's 32 pt safe area was added on
    /// top and the gap under the last toolbar row was 16 pt (this constant minus the rows) plus
    /// 32 pt of inset. Now it is exactly `Spacing.lg` + the 4 pt the toolbar's own bottom
    /// padding reaches past its last row — 24 pt, half of what it was.
    static let dashboardContentTop: CGFloat = dashboardToolbar + Spacing.lg

    /// The Usage tab's range picker, on its own row under the tab strip (30 pt + one step).
    /// Only Usage has it, so only Usage's toolbar — and content top — is taller.
    static let dashboardRangeRow: CGFloat = 30 + Spacing.sm

    static func dashboardToolbar(showsRangeRow: Bool) -> CGFloat {
        dashboardToolbar + (showsRangeRow ? dashboardRangeRow : 0)
    }

    static func dashboardContentTop(showsRangeRow: Bool) -> CGFloat {
        dashboardToolbar(showsRangeRow: showsRangeRow) + Spacing.lg
    }
}

/// Hairline border widths.
enum BorderWidth {
    /// Panel outer strokeBorder (~0.8 pt).
    static let panel: CGFloat = 0.8
    /// Card inner strokeBorder (~0.7 pt).
    static let card:  CGFloat = 0.7
}

// MARK: - Currency

extension Double {
    /// USD with 2 fraction digits, e.g. "$12.34".
    ///
    /// Goes through `DisplayFormat.locale`, not the machine's — see `DisplayFormat`.
    var usdString: String { currencyString() }
}

// MARK: - Model color scale

/// A stable, deterministic warm palette for charting per-model breakdowns.
/// All colors derive from Palette.accent (fired clay) with opacity/hue steps —
/// no cool hues (blue/purple/teal). The view applies a rank-based opacity cascade
/// on top of the returned color.
enum ModelPalette {
    /// Per-rank color table: accent at full opacity, then warm siblings stepping
    /// slightly toward amber and toward deeper terracotta.
    private static let palette: [Color] = [
        Palette.accent,                           // fired clay — primary
        Palette.warn,                             // warm amber — second rank
        Palette.critical,                         // deep terracotta — third
        Palette.accent.opacity(0.70),             // faded clay — fourth
        Palette.warn.opacity(0.65),               // faded amber — fifth
        Palette.textSecondary,                    // neutral warm — sixth
    ]

    /// Returns parallel (domain, range) arrays for `chartForegroundStyleScale`,
    /// assigning a stable warm color to each model by sorted order.
    static func scale(for models: [String]) -> (domain: [String], range: [Color]) {
        let domain = Array(Set(models)).sorted()
        let range = domain.enumerated().map { palette[$0.offset % palette.count] }
        return (domain, range)
    }

    /// Color for a single model id (stable by hash into the palette).
    static func color(for model: String) -> Color {
        let idx = abs(model.hashValue) % palette.count
        return palette[idx]
    }
}
