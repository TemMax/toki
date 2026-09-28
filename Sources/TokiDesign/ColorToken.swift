/// A colour with its light- and dark-appearance values, as sRGB hex.
///
/// Plain data on purpose: `TokiDesign` has no SwiftUI/AppKit dependency, so a token is just
/// two `UInt32`s the arithmetic in `Contrast` can chew on directly, and the pairing (light
/// stored next to dark) is what makes "did I forget the dark value" a compile error rather
/// than a runtime gap.
public struct ColorToken: Sendable, Equatable {
    public let light: UInt32
    public let dark: UInt32

    public init(light: UInt32, dark: UInt32) {
        self.light = light
        self.dark = dark
    }
}
