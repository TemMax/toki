/// IconSize+Modifier — maps `IconSize` onto a SwiftUI `Font` for SF Symbol glyphs.
///
/// Mirrors `Typography+Scale.swift`'s role→`Font` bridge, but for glyphs rather than text:
/// `IconSize` carries no design/digit-treatment (meaningless on a glyph), and weight is a
/// separate, explicit parameter here rather than baked into the case — glyphs at the same
/// point size legitimately want different weights (e.g. a plain row icon vs. an emphasized
/// pill icon), where text roles bind size+weight+design as one named thing on purpose.
import SwiftUI
import TokiDesign

extension View {
    /// The icon-scale entry point: `.iconSize(.hero)`, `.iconSize(.regular, weight: .medium)`,
    /// etc. Defaults to `.regular` weight — most glyphs in the app are unemphasized; pass
    /// `weight:` for the few that carry deliberate emphasis (e.g. a leading icon paired with
    /// bold text, or a pill's own icon).
    func iconSize(_ size: IconSize, weight: TypeScale.Weight = .regular) -> some View {
        let glyphFont = Font.system(size: size.pointSize, weight: weight.swiftUI)
        return font(glyphFont)
    }
}
