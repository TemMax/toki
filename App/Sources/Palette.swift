/// Palette — resolves the app's colours from the measured `TokiDesign.Tokens` (adaptive
/// light/dark).
///
/// Single source of truth for color across the whole app (status-bar label,
/// popover, dashboard, settings). Each token is an appearance-adaptive Color
/// (resolves automatically in light/dark via an NSColor dynamic provider), so
/// call sites never thread a ColorScheme.
///
/// The numbers themselves live in `Sources/TokiDesign/Tokens.swift`, where a contrast
/// suite (`Tests/TokiDesignTests/ContrastTests.swift`) asserts every text/background
/// pairing clears WCAG AA. This file only maps those tokens onto the names the rest of
/// the app already depends on — the public surface (`Palette.bg`, `.card`,
/// `.textPrimary`, `.metric(_:)`, …) is unchanged, so no call site has to change.
import SwiftUI
import AppKit
import TokiDesign

enum Palette {
    static let bg            = adaptive(Tokens.bg)
    static let surface       = adaptive(Tokens.surface)
    static let card          = adaptive(Tokens.card)
    static let textPrimary   = adaptive(Tokens.textPrimary)
    static let textSecondary = adaptive(Tokens.textSecondary)
    static let hairline      = adaptive(Tokens.hairline)
    static let accent        = adaptive(Tokens.copper500)
    static let accentSubtle  = adaptive(Tokens.copper100)
    /// Foreground for anything drawn ON `accent` (filled button label, on-state switch knob).
    /// See `Tokens.onAccent` for why it inverts and `ContrastTests` for the measured pair.
    static let onAccent      = adaptive(Tokens.onAccent)
    static let ok            = adaptive(Tokens.ok)
    static let warn          = adaptive(Tokens.warn)
    static let critical      = adaptive(Tokens.critical)

    /// Nearest-to-user background plane (above `card`). Not yet used by any call site —
    /// exposed so a later wave can reach it without re-deriving it from `Tokens`.
    static let raised = adaptive(Tokens.raised)

    /// FILL/CHART colour only — must never carry text. It does not reach 4.5:1 on any
    /// surface (measured 2.31 light / 2.94 dark); see `TokiDesignTests/ContrastTests` for
    /// the assertion that documents this restriction. Not yet used by any call site.
    static let copper300 = adaptive(Tokens.copper300)

    /// Categorical colours for chart series — FILL/LINE ONLY, never text. See `Tokens.chartSeries` for validation details.
    static let series: [Color] = Tokens.chartSeries.map(adaptive)

    /// Deepest copper step. Not yet used by any call site.
    static let copper700 = adaptive(Tokens.copper700)

    /// A real third text level, and it clears AA on every surface — worst case 4.57
    /// (light `card`) and 4.76 (dark `raised`), a thin margin. Not yet used by any call
    /// site.
    ///
    /// Disabled controls are a separate concern: they are WCAG-exempt, and the codebase
    /// already expresses them by lowering the opacity of a text token rather than by
    /// reaching for a dimmer colour.
    static let textTertiary = adaptive(Tokens.textTertiary)

    /// Gauge colour by utilization — and deliberately NO colour below `Tokens.warnThreshold`.
    ///
    /// A gauge at 34% is not news. Painting it green says "look here" about the one thing on
    /// screen that needs no attention, and with three gauges visible at once every screen
    /// ended up shouting: green, gold and red side by side is three loud signals, which is
    /// the same as none. Below the warn threshold the fill is neutral, so any colour in the
    /// app means something actually wants the user.
    ///
    /// This retires green from *gauges* only. `ok` still marks discrete yes/no states —
    /// "Live", "Connected", plugin enabled, version current — where green means a state, not
    /// a level.
    ///
    /// The threshold rule itself lives in `TokiDesign.Tokens.level(for:)`, where it's testable
    /// without going through `App/Sources` (not a SwiftPM target); this is just the mapping
    /// from the resulting `MetricLevel` to the `Color` it has always resolved to.
    static func metric(_ fraction: Double) -> Color {
        switch Tokens.level(for: fraction) {
        case .nominal:  return textSecondary
        case .warning:  return warn
        case .critical: return critical
        }
    }

    /// Builds an appearance-adaptive Color from a `TokiDesign.ColorToken`'s light/dark
    /// sRGB hex pair.
    private static func adaptive(_ token: ColorToken) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return rgb(isDark ? token.dark : token.light)
        })
    }

    private static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: Double((hex >> 16) & 0xFF) / 255,
                green:    Double((hex >> 8) & 0xFF) / 255,
                blue:     Double(hex & 0xFF) / 255,
                alpha:    1)
    }
}
