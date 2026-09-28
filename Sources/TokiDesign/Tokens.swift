/// The palette, as measured — see `Tests/TokiDesignTests/ContrastTests.swift` for the
/// contrast/lightness assertions that keep it honest. Do not hand-tune a value to make a
/// test pass; a failing assertion here means the palette itself needs re-measuring.
public enum Tokens {

    // MARK: - Surfaces

    /// The four background planes, from farthest back (`bg`) to nearest the user
    /// (`raised`). Each adjacent pair is separated by >= 3.0 ΔL* so the eye can tell them
    /// apart without relying on a hairline — see `Contrast.lightness`.
    public static let bg = ColorToken(light: 0xFBFAF9, dark: 0x0D1013)
    public static let surface = ColorToken(light: 0xF2F1EF, dark: 0x171B20)
    public static let card = ColorToken(light: 0xE9E7E4, dark: 0x212730)
    public static let raised = ColorToken(light: 0xFFFFFF, dark: 0x2A313B)
    public static let hairline = ColorToken(light: 0xD5D2CE, dark: 0x333B45)

    // MARK: - Copper ramp

    public static let copper100 = ColorToken(light: 0xF2E4DA, dark: 0x2A1C13)
    /// FILL/CHART colour only — must never carry text. It does not reach 4.5:1 on any
    /// surface (measured 2.31 light / 2.94 dark); see `ContrastTests` for the assertion
    /// that documents this restriction.
    public static let copper300 = ColorToken(light: 0xD79A6E, dark: 0x8A4F2A)
    public static let copper500 = ColorToken(light: 0x9C4D26, dark: 0xD8834A)
    public static let copper700 = ColorToken(light: 0x7A3A1B, dark: 0xE0996A)

    /// What text and glyphs are painted in when they sit ON `copper500` — a filled accent
    /// button, a switch that is on.
    ///
    /// Not a new measurement, and deliberately not a new hex: it is the palette's own paper
    /// (`raised.light`) in light and its own ink (`textPrimary.light`) in dark. The accent
    /// itself inverts between appearances — deep clay on a light background, bright clay on a
    /// dark one — so whatever is written on it has to invert too. Plain white would read at
    /// 2.89:1 on the dark accent, i.e. illegibly; `ContrastTests` asserts both directions of
    /// this pairing (and that white alone would miss), because it is the one text/background
    /// pair in the app whose background is not one of the four surface planes.
    public static let onAccent = ColorToken(light: raised.light, dark: textPrimary.light)

    // MARK: - Text

    public static let textPrimary = ColorToken(light: 0x15181B, dark: 0xEAEDF0)
    public static let textSecondary = ColorToken(light: 0x555C64, dark: 0xA3ADB7)
    /// A real third text level, and it clears AA on every surface — worst case 4.57 (light
    /// `card`) and 4.76 (dark `raised`).
    ///
    /// The light value is three steps darker than the obvious `0x646B73`, which measures
    /// 4.371 on light `card` and would have been the one combination out of eight that
    /// misses. That near-miss is exactly the kind of thing the eye cannot catch and the
    /// suite can, which is why these tests exist.
    ///
    /// Disabled controls are a separate concern: they are WCAG-exempt, and the codebase
    /// already expresses them by lowering the opacity of a text token rather than by
    /// reaching for a dimmer colour.
    public static let textTertiary = ColorToken(light: 0x616870, dark: 0x939DA7)

    // MARK: - Status

    public static let ok = ColorToken(light: 0x2F6B52, dark: 0x6FCBA2)
    public static let warn = ColorToken(light: 0x7D5A0C, dark: 0xE0B44E)
    public static let critical = ColorToken(light: 0x9E2B2B, dark: 0xE87A72)
}
