import Testing
@testable import TokiDesign

/// Every background plane a piece of text can actually be painted on.
struct SurfaceCase: Sendable, CustomStringConvertible {
    let name: String
    let token: ColorToken
    var description: String { name }
}

let surfaces: [SurfaceCase] = [
    SurfaceCase(name: "bg", token: Tokens.bg),
    SurfaceCase(name: "surface", token: Tokens.surface),
    SurfaceCase(name: "card", token: Tokens.card),
    SurfaceCase(name: "raised", token: Tokens.raised),
]

/// Every token allowed to carry text, per the palette's own doc comments.
struct TextCase: Sendable, CustomStringConvertible {
    let name: String
    let token: ColorToken
    var description: String { name }
}

let textCarryingTokens: [TextCase] = [
    TextCase(name: "textPrimary", token: Tokens.textPrimary),
    TextCase(name: "textSecondary", token: Tokens.textSecondary),
    TextCase(name: "copper500", token: Tokens.copper500),
    TextCase(name: "copper700", token: Tokens.copper700),
    TextCase(name: "ok", token: Tokens.ok),
    TextCase(name: "warn", token: Tokens.warn),
    TextCase(name: "critical", token: Tokens.critical),
    TextCase(name: "textTertiary", token: Tokens.textTertiary),
]

/// Parameterised over every (text token) x (surface) pair, in both appearances, so a new
/// token or a new surface is automatically covered by this suite — no hand-written cases.
@Suite("Text-carrying tokens clear WCAG AA (4.5:1) on every surface they can land on")
struct TextContrastTests {
    @Test(
        "clears 4.5:1, light and dark",
        arguments: textCarryingTokens, surfaces
    )
    func clearsAA(text: TextCase, surface: SurfaceCase) {
        let light = Contrast.ratio(text.token.light, surface.token.light)
        #expect(light >= 4.5, "\(text.name) on \(surface.name), light: \(light)")

        let dark = Contrast.ratio(text.token.dark, surface.token.dark)
        #expect(dark >= 4.5, "\(text.name) on \(surface.name), dark: \(dark)")
    }
}

/// `copper300` is deliberately NOT in `textCarryingTokens` above — it must never carry text
/// (see its doc comment in `Tokens.swift`). This assertion exists to document and enforce
/// that restriction: if a future edit ever nudges it past 4.5:1, that is a signal the
/// "never use as text" comment needs revisiting, not a green light to start using it as text.
@Suite("Fill-only tokens stay below 4.5:1 (documents they must not carry text)")
struct RestrictedTokenContrastTests {
    @Test("copper300 (fill/chart-only) never reaches 4.5:1 as text", arguments: surfaces)
    func copper300StaysBelowAA(surface: SurfaceCase) {
        let light = Contrast.ratio(Tokens.copper300.light, surface.token.light)
        let dark = Contrast.ratio(Tokens.copper300.dark, surface.token.dark)
        #expect(light < 4.5, "copper300 on \(surface.name), light: \(light)")
        #expect(dark < 4.5, "copper300 on \(surface.name), dark: \(dark)")
    }
}

/// The accent FILL is the one background in the app that is not a surface plane, so the suite
/// above (which pairs text tokens against `surfaces`) cannot cover it. `onAccent` exists for
/// exactly this pairing — the filled accent button's label, the on-state switch knob — and it
/// inverts between appearances because `copper500` does.
@Suite("The accent fill can carry its own foreground")
struct AccentFillContrastTests {
    @Test("onAccent clears 4.5:1 on copper500, light and dark")
    func onAccentClearsAA() {
        let light = Contrast.ratio(Tokens.onAccent.light, Tokens.copper500.light)
        #expect(light >= 4.5, "onAccent on copper500, light: \(light)")

        let dark = Contrast.ratio(Tokens.onAccent.dark, Tokens.copper500.dark)
        #expect(dark >= 4.5, "onAccent on copper500, dark: \(dark)")
    }

    /// The reason `onAccent` is not simply white. Pinning the miss means "just use white on
    /// the accent" fails here rather than shipping a 2.89:1 label in dark mode.
    @Test("plain white would miss on the dark accent")
    func whiteMissesOnDarkAccent() {
        let white = Contrast.ratio(0xFFFFFF, Tokens.copper500.dark)
        #expect(white < 4.5, "white on copper500, dark: \(white)")
    }
}

/// `textTertiary` clears AA by a thin margin — 4.57 at its worst (light `card`). The obvious
/// value one shade lighter measures 4.371 there and would miss on exactly one of the eight
/// surface/appearance combinations. Pinning the margin means a future "let's lighten the
/// tertiary text a touch" fails here rather than shipping.
@Suite("textTertiary keeps its AA margin")
struct TertiaryTextMarginTests {
    @Test("stays at or above 4.5:1 with no more than a small margin to spare", arguments: surfaces)
    func marginIsRealButThin(surface: SurfaceCase) {
        let light = Contrast.ratio(Tokens.textTertiary.light, surface.token.light)
        let dark = Contrast.ratio(Tokens.textTertiary.dark, surface.token.dark)
        #expect(light >= 4.5, "textTertiary on \(surface.name), light: \(light)")
        #expect(dark >= 4.5, "textTertiary on \(surface.name), dark: \(dark)")
    }

    /// Third level must stay visibly quieter than second, or it is not a level.
    @Test("is lower contrast than textSecondary on every surface", arguments: surfaces)
    func staysQuieterThanSecondary(surface: SurfaceCase) {
        let tertiaryLight = Contrast.ratio(Tokens.textTertiary.light, surface.token.light)
        let secondaryLight = Contrast.ratio(Tokens.textSecondary.light, surface.token.light)
        let tertiaryDark = Contrast.ratio(Tokens.textTertiary.dark, surface.token.dark)
        let secondaryDark = Contrast.ratio(Tokens.textSecondary.dark, surface.token.dark)
        #expect(tertiaryLight < secondaryLight, "\(surface.name) light: \(tertiaryLight) vs \(secondaryLight)")
        #expect(tertiaryDark < secondaryDark, "\(surface.name) dark: \(tertiaryDark) vs \(secondaryDark)")
    }
}

/// The four background planes must each read as a visually distinct plane. Contrast ratio's
/// `+0.05` flare term compresses everything at the light end (see `Contrast`'s doc comment),
/// so plane separation is judged by ΔL* instead.
@Suite("Adjacent surfaces are separated by at least 3.0 ΔL*")
struct PlaneSeparationTests {
    private static let adjacentPairs: [(SurfaceCase, SurfaceCase)] = [
        (surfaces[0], surfaces[1]),  // bg -> surface
        (surfaces[1], surfaces[2]),  // surface -> card
        (surfaces[2], surfaces[3]),  // card -> raised
    ]

    @Test("light", arguments: Self.adjacentPairs)
    func separationLight(pair: (SurfaceCase, SurfaceCase)) {
        let deltaL = abs(Contrast.lightness(pair.1.token.light) - Contrast.lightness(pair.0.token.light))
        #expect(deltaL >= 3.0, "\(pair.0.name) -> \(pair.1.name), light: ΔL*=\(deltaL)")
    }

    @Test("dark", arguments: Self.adjacentPairs)
    func separationDark(pair: (SurfaceCase, SurfaceCase)) {
        let deltaL = abs(Contrast.lightness(pair.1.token.dark) - Contrast.lightness(pair.0.token.dark))
        #expect(deltaL >= 3.0, "\(pair.0.name) -> \(pair.1.name), dark: ΔL*=\(deltaL)")
    }
}

/// Chart series are graphics, not text: WCAG 1.4.11 asks 3:1 against the card they are
/// drawn on. Their categorical separation (lightness band, chroma floor, CVD ΔE) was checked
/// with the dataviz palette validator — see the doc comment on `Tokens.chartSeries`.
@Suite("Chart series tokens clear 3:1 on the card, light and dark")
struct ChartSeriesContrastTests {
    @Test("four slots")
    func fourSlots() { #expect(Tokens.chartSeries.count == 4) }

    @Test("each clears 3:1", arguments: Array(Tokens.chartSeries.indices))
    func clears(slot: Int) {
        let token = Tokens.chartSeries[slot]
        #expect(Contrast.ratio(token.light, Tokens.card.light) >= 3, "slot \(slot + 1) light")
        #expect(Contrast.ratio(token.dark, Tokens.card.dark) >= 3, "slot \(slot + 1) dark")
    }
}

@Suite("Formula sanity")
struct FormulaSanityTests {
    @Test("white on black is 21.0")
    func whiteOnBlack() {
        #expect(abs(Contrast.ratio(0xFFFFFF, 0x000000) - 21.0) <= 0.01)
    }

    @Test("identical colours are 1.0")
    func identical() {
        #expect(abs(Contrast.ratio(0x4A90D9, 0x4A90D9) - 1.0) <= 0.01)
    }

    @Test("lightness of white is 100")
    func whiteLightness() {
        #expect(abs(Contrast.lightness(0xFFFFFF) - 100.0) <= 0.1)
    }
}
