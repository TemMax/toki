import Foundation

/// WCAG contrast/lightness arithmetic on plain sRGB hex values.
///
/// Two different measures exist here because they answer two different questions:
/// `ratio` is the WCAG formula for TEXT legibility — its `+0.05` "flare" term models
/// veiling glare and is calibrated for foreground-on-background reading. Applied to two
/// adjacent SURFACE planes (`bg`/`surface`/`card`/`raised`, both light and both far from
/// black) that flare term dominates and compresses every plausible pair toward the same
/// low ratio, so it cannot tell "these two planes are distinguishable" from "they're not".
/// `lightness` (CIE L*) has no such flare term, so ΔL* between adjacent planes is what
/// `ContrastTests` uses to judge plane separation instead.
public enum Contrast {

    /// WCAG 2.x relative luminance of an sRGB hex, 0...1.
    public static func relativeLuminance(_ hex: UInt32) -> Double {
        let r = channel(hex, shift: 16)
        let g = channel(hex, shift: 8)
        let b = channel(hex, shift: 0)
        return 0.2126 * linearize(r) + 0.7152 * linearize(g) + 0.0722 * linearize(b)
    }

    /// WCAG contrast ratio between two sRGB hexes, 1...21.
    public static func ratio(_ a: UInt32, _ b: UInt32) -> Double {
        let la = relativeLuminance(a)
        let lb = relativeLuminance(b)
        let lighter = max(la, lb)
        let darker = min(la, lb)
        return (lighter + 0.05) / (darker + 0.05)
    }

    /// CIE L* (perceptual lightness), 0...100.
    public static func lightness(_ hex: UInt32) -> Double {
        let y = relativeLuminance(hex)
        if y > 0.008856 {
            return 116 * pow(y, 1.0 / 3.0) - 16
        } else {
            return 903.3 * y
        }
    }

    private static func channel(_ hex: UInt32, shift: UInt32) -> Double {
        Double((hex >> shift) & 0xFF) / 255.0
    }

    private static func linearize(_ c: Double) -> Double {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }
}
