import Foundation

/// Strip-wide look: framing characters, spacing and the point sizes the strip draws with.
///
/// Lives on `MenuBarConfiguration` as a single value, not per-indicator: colour aside (fixed,
/// never customisable — see `MenuBarConfiguration`'s own doc comment on why `usesColour` was
/// removed rather than kept unreachable), everything HOW the strip looks is genuinely
/// strip-wide. Ten fields repeated across up to five `MenuBarIndicator` rows would be
/// unusable to present, and mixing bar heights or value sizes indicator-to-indicator would
/// read as broken, not as customised.
///
/// ## Clamping is the real work here
/// Every numeric field is bounded on BOTH ends, in the memberwise init AND in `Decodable` —
/// the `Decodable` initializer delegates to the memberwise one, so there is exactly one place
/// that enforces the bounds, not two copies that can drift apart.
///
/// **The menu bar is a fixed 22pt tall** (`NSStatusBar.system.thickness` on every macOS
/// version this app supports). Anything the strip draws taller than that is silently clipped
/// by the system rather than shrunk to fit — so a size the user can type but never actually
/// see on screen would be a trap, not a feature. Every size bound below ultimately traces
/// back to that one ceiling; each field's own bound documents the specific reasoning.
///
/// Free-text fields (`leading`, `trailing`, `separator`) get the same treatment for the same
/// underlying reason: nothing stops a preference file (or a future text field) from holding a
/// paragraph, and an oversized free-text field pushes every other menu-bar icon off screen
/// exactly the way an oversized point size would. They are also stripped of control
/// characters — the rasterizer lays the strip out as a single line of `Text`, and a literal
/// newline typed into `leading` has nowhere sane to go.
public struct MenuBarStyle: Sendable, Equatable, Codable {
    /// Wraps the whole strip, e.g. "[" and "]".
    public var leading: String
    /// Wraps the whole strip, e.g. "[" and "]".
    public var trailing: String
    /// Drawn between indicators, e.g. "·" or "|". Empty means spacing alone separates them.
    public var separator: String
    /// Points between an indicator's label and its value.
    public var labelGap: Double
    /// Points between one indicator and the next (in addition to any separator).
    public var groupGap: Double
    /// Point size of the value digits.
    public var valueSize: Double
    /// Point size of the label.
    public var labelSize: Double
    /// The unit sign's size as a fraction of valueSize. 0 hides the sign entirely.
    public var unitScale: Double
    public var barWidth: Double
    public var barHeight: Double

    // MARK: - Bounds

    /// Free text here is framing punctuation, not a caption — "[", "·", "»»" — so a handful
    /// of characters is already generous. Capped well short of
    /// `MenuBarIndicator.maximumCustomLabelLength` so a decorative field can never grow larger
    /// than an actual label.
    public static let maximumFreeTextLength = 4

    public static let minimumLabelGap: Double = 0
    /// Roughly the width of the widest value the strip ever draws ("100"); past this the
    /// label reads as a second, disconnected indicator rather than the name of the figure
    /// that follows it.
    public static let maximumLabelGap: Double = 12

    public static let minimumGroupGap: Double = 0
    /// Roughly one whole extra indicator's worth of dead space; past it the strip stops
    /// reading as one row and starts reading as unrelated icons scattered across the bar.
    public static let maximumGroupGap: Double = 24

    /// Below this the value digits — the one figure the whole strip exists to show — drop
    /// under the ~8.5pt floor `TypeScale.multiplier` already enforces for interface text in
    /// general (see `TypeScale.minimumMultiplier`'s doc comment); no reason for the strip's
    /// own floor to be more permissive than the rest of the app's text.
    public static let minimumValueSize: Double = 7
    /// System text sits in a line box roughly 1.2x its point size; at 16pt that's ~19.2pt,
    /// leaving a couple of points of margin inside the fixed 22pt status-bar height for the
    /// label/unit sharing the same baseline. The next whole point (17pt → ~20.4pt) leaves too
    /// little margin to stay clear of the system's own clipping.
    public static let maximumValueSize: Double = 16

    /// Same reasoning as `minimumValueSize`, applied to the smaller of the two texts on the
    /// row.
    public static let minimumLabelSize: Double = 6
    /// Kept under `maximumValueSize` even though nothing else enforces label < value at
    /// runtime: the label exists to stay subordinate to the figure it names (see
    /// `MenuBarStripView.label`'s doc comment) — letting it reach the value's own ceiling
    /// would both fight the value for attention and risk the same clipping on its own.
    public static let maximumLabelSize: Double = 14

    /// 0 is an explicit, documented feature (hides the sign outright — see the field's own
    /// doc comment), not just "very small", so the floor sits exactly there.
    public static let minimumUnitScale: Double = 0
    /// A unit sign at or above the value's own size stops annotating the figure and starts
    /// competing with it — the opposite of why `MenuBarStripView.number` shrinks it at all.
    public static let maximumUnitScale: Double = 1

    /// Below 1pt anti-aliasing washes a vertical stroke out at status-bar scale; it stops
    /// reading as a bar.
    public static let minimumBarWidth: Double = 1
    /// Past this a "bar" reads as a filled swatch rather than a gauge stroke — at multiple
    /// times today's 3pt width cost for no gain in how legible "how much is left" is.
    public static let maximumBarWidth: Double = 6

    /// Short enough to still visibly distinguish filled from empty; shorter and the fill
    /// fraction stops being legible at all.
    public static let minimumBarHeight: Double = 4
    /// Same 22pt-status-bar ceiling as `maximumValueSize`: the bar sits on the same baseline
    /// as the value text, so it cannot outgrow the room the value itself is capped to without
    /// visibly overflowing the row.
    public static let maximumBarHeight: Double = 16

    public init(
        leading: String = "",
        trailing: String = "",
        separator: String = "",
        labelGap: Double = 3,
        groupGap: Double = 7,
        valueSize: Double = 11,
        labelSize: Double = 10,
        unitScale: Double = 0.72,
        barWidth: Double = 3,
        barHeight: Double = 11
    ) {
        self.leading = Self.sanitizedFreeText(leading)
        self.trailing = Self.sanitizedFreeText(trailing)
        self.separator = Self.sanitizedFreeText(separator)
        self.labelGap = Self.clamp(labelGap, Self.minimumLabelGap, Self.maximumLabelGap, default: 3)
        self.groupGap = Self.clamp(groupGap, Self.minimumGroupGap, Self.maximumGroupGap, default: 7)
        self.valueSize = Self.clamp(valueSize, Self.minimumValueSize, Self.maximumValueSize, default: 11)
        self.labelSize = Self.clamp(labelSize, Self.minimumLabelSize, Self.maximumLabelSize, default: 10)
        self.unitScale = Self.clamp(unitScale, Self.minimumUnitScale, Self.maximumUnitScale, default: 0.72)
        self.barWidth = Self.clamp(barWidth, Self.minimumBarWidth, Self.maximumBarWidth, default: 3)
        self.barHeight = Self.clamp(barHeight, Self.minimumBarHeight, Self.maximumBarHeight, default: 11)
    }

    /// Exactly today's hardcoded appearance — see `App/Sources/MenuBarStripView.swift`
    /// before this type existed: `labelGap` was `gap + 1` (2 + 1), `groupGap` 7, the value
    /// 11pt via `TypeScale.Role.label`, the label 10pt via `.caption`, the unit sign scaled
    /// 0.72 off the value, bars 3pt wide by 11pt tall. This is the regression guard for
    /// "nobody who ignores Settings sees a change" — every field here must equal the default
    /// parameter above it.
    public static let standard = MenuBarStyle()

    /// `min`/`max` both propagate NaN (every comparison against NaN is false, so neither
    /// picks the other operand), so a NaN `value` would otherwise sail straight through this
    /// "bounded on both ends" gate and hand SwiftUI a NaN point size. `.infinity` and
    /// `-.infinity` need no special case: they compare correctly against finite bounds and
    /// clamp to `upper`/`lower` exactly like any other out-of-range value — only NaN is
    /// singled out, via `isNaN` rather than `!isFinite`. Falls back to `defaultValue` — the
    /// field's own documented default — rather than either bound, since neither bound is a
    /// more "correct" stand-in for a value that was never a real number to begin with.
    private static func clamp(_ value: Double, _ lower: Double, _ upper: Double, default defaultValue: Double) -> Double {
        guard !value.isNaN else { return defaultValue }
        return min(max(value, lower), upper)
    }

    /// Strips control characters (newlines, tabs, …) first, then trims leading/trailing
    /// whitespace, then caps the length. A separator or bracket typed as pure whitespace
    /// collapses to empty this way, which is exactly the documented meaning of an empty
    /// `separator` (spacing alone) or empty `leading`/`trailing` (no framing) — not a
    /// distinct "blank but present" state.
    private static func sanitizedFreeText(_ raw: String) -> String {
        let noControlCharacters = String(raw.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
        let trimmed = noControlCharacters.trimmingCharacters(in: .whitespaces)
        return String(trimmed.prefix(maximumFreeTextLength))
    }

    private enum CodingKeys: String, CodingKey {
        case leading, trailing, separator, labelGap, groupGap, valueSize, labelSize, unitScale, barWidth, barHeight
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = Self.standard
        // Delegates to the memberwise init so decoded values go through the exact same
        // sanitizing/clamping as any other construction path — one gate, not two. Missing
        // keys (a config saved by an older build, before a field existed) fall back to
        // `standard`'s own value rather than throwing.
        self.init(
            leading: try container.decodeIfPresent(String.self, forKey: .leading) ?? fallback.leading,
            trailing: try container.decodeIfPresent(String.self, forKey: .trailing) ?? fallback.trailing,
            separator: try container.decodeIfPresent(String.self, forKey: .separator) ?? fallback.separator,
            labelGap: try container.decodeIfPresent(Double.self, forKey: .labelGap) ?? fallback.labelGap,
            groupGap: try container.decodeIfPresent(Double.self, forKey: .groupGap) ?? fallback.groupGap,
            valueSize: try container.decodeIfPresent(Double.self, forKey: .valueSize) ?? fallback.valueSize,
            labelSize: try container.decodeIfPresent(Double.self, forKey: .labelSize) ?? fallback.labelSize,
            unitScale: try container.decodeIfPresent(Double.self, forKey: .unitScale) ?? fallback.unitScale,
            barWidth: try container.decodeIfPresent(Double.self, forKey: .barWidth) ?? fallback.barWidth,
            barHeight: try container.decodeIfPresent(Double.self, forKey: .barHeight) ?? fallback.barHeight
        )
    }
}
