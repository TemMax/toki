/// `IconSize` — a glyph point-size ladder for SF Symbols, deliberately separate from
/// `TypeScale.Role`.
///
/// Icons are not text. Several `TypeScale.Role`s bake in a rounded typeface design and
/// tabular-digit rendering — attributes that describe how numerals and prose should look,
/// and mean nothing applied to a glyph. Worse, `TypeScale.Role.hero` is semibold (see its
/// doc comment): reusing it for an SF Symbol makes every empty-state icon in the app read
/// heavier than it was ever meant to.
///
/// Pure data on purpose, like `TypeScale`: no SwiftUI/AppKit import, so it stays usable from
/// anywhere. `App/Sources/DesignSystem` maps a case onto an actual `Font`.
///
/// Not invented: derived from inventorying every `Image(systemName:)` call site under
/// `App/Sources` that carried a `TypeScale.Role` before this ladder existed. Five point
/// sizes covered all 27 of them:
/// - `small` (10pt) — inline status glyphs (chevrons, checkmarks, small badges).
/// - `regular` (11pt) — row-leading glyphs (list icons, favorite stars).
/// - `medium` (13pt) — toolbar-weight glyphs (refresh button, settings row icons).
/// - `large` (22pt) — a single illustrative dialog glyph (the mock keychain-prompt icon).
/// - `hero` (30pt) — empty-state glyphs.
public enum IconSize: CaseIterable, Sendable {
    case small
    case regular
    case medium
    case large
    case hero

    /// The glyph's point size. Fixed, unlike `TypeScale.Role.resolvedSize` — icons are not
    /// part of the text-scale multiplier; nothing here reads `TypeScale.multiplier`.
    public var pointSize: Double {
        switch self {
        case .small: 10
        case .regular: 11
        case .medium: 13
        case .large: 22
        case .hero: 30
        }
    }
}
