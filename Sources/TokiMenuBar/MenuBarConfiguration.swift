import Foundation
import TokiModels
import TokiLogging

private let log = TokiLog.logger("menubar")

/// The user's chosen set of menu-bar indicators, in display order, plus the strip's overall
/// look (`style`) and the compactness switch.
///
/// Colour used to be a third switch (`usesColour`) here. It is gone rather than merely
/// unreachable from Settings: colour is not customisable — status severity is the only thing
/// in the app allowed to be loud, and every other visual choice is monochrome — so a flag
/// nobody can reach still had to be modelled, persisted, tested and threaded through
/// rendering for no benefit. Removing it also makes the rasterised strip image
/// unconditionally a template, which is what lets macOS retint it for the light bar, the dark
/// bar and the highlighted state (see `MenuBarStripRenderer` in `App/Sources`). Decoding an
/// old configuration that still carries the `usesColour` key ignores it rather than throwing
/// — see the `CodingKeys` comment below.
/// What the strip collapses to when compact.
public enum CompactSelection: Sendable, Equatable, Codable, Hashable {
    /// Whichever configured window currently carries the highest fraction.
    case worstOf
    /// One window, always — even when another is closer to its limit.
    /// Kept for configurations written before provider-aware indicators existed.
    case pinned(WindowSelector)
    /// One exact configured indicator. Unlike the legacy window-only case, this can
    /// distinguish Claude 5-hour from Codex 5-hour (and two custom rows for one window).
    case pinnedIndicator(UUID)
}

public struct MenuBarConfiguration: Sendable, Equatable, Codable {
    /// Never more than `maximumIndicators` long — enforced by every entry point
    /// (memberwise init and `Decodable`), not left to callers to remember. A stale
    /// preference from a future version, or an API that starts reporting more
    /// scoped windows than the menu bar has room for, must truncate rather than
    /// overflow the status bar or trap.
    public static let maximumIndicators = 5

    public var indicators: [MenuBarIndicator]
    /// Strip-wide framing, spacing and sizes — see `MenuBarStyle`'s own doc comment.
    /// Colour is deliberately absent from this type: it stays fixed, not customisable (see
    /// this type's own doc comment for why the `usesColour` flag it used to carry was removed
    /// outright rather than left in place unreachable).
    public var style: MenuBarStyle
    /// nil means the full list is drawn.
    public var compact: CompactSelection?

    public init(indicators: [MenuBarIndicator], style: MenuBarStyle = .standard, compact: CompactSelection? = nil) {
        self.indicators = Self.clamped(indicators)
        self.style = style
        self.compact = compact
    }

    /// Bounds the list at BOTH ends.
    ///
    /// The upper bound is obvious. The lower one is the important half: an empty list draws
    /// an empty status item, and the status item is the only way into Settings. A user who
    /// deletes the last row would lose the menu-bar item and, with it, the way to get it
    /// back — so empty silently means the standard set, not nothing.
    static func clamped(_ indicators: [MenuBarIndicator]) -> [MenuBarIndicator] {
        indicators.isEmpty
            ? standardIndicators
            : Array(indicators.prefix(maximumIndicators))
    }

    /// Five named numbers covering both providers. Provider filtering in the app removes
    /// rows for tools that are not installed, so a Codex-only install starts with two rows
    /// and a Claude-only install starts with three.
    ///
    /// Bars were the first default. On real data they failed the job they exist for: at
    /// 11pt tall, the difference between 40% and 55% is under 2pt, so the strip answered
    /// "roughly how full" when the question is "how much is left, and on which window".
    /// Compactness is not worth an unreadable answer; anyone who wants the small version
    /// can switch to `.bar` per row.
    static let standardIndicators: [MenuBarIndicator] = [
        MenuBarIndicator(window: .fiveHour, rendering: .number, showsLabel: true),
        MenuBarIndicator(window: .sevenDay, rendering: .number, showsLabel: true),
        MenuBarIndicator(window: .highestScopedModel, rendering: .number, showsLabel: true),
        MenuBarIndicator(provider: .codex, window: .fiveHour, rendering: .number, showsLabel: true),
        MenuBarIndicator(provider: .codex, window: .sevenDay, rendering: .number, showsLabel: true),
    ]

    /// Claude 5-hour/7-day/model plus Codex 5-hour/7-day — named numbers, standard style.
    /// `standard` (rather than `default`) avoids shadowing the Swift keyword.
    public static let standard = MenuBarConfiguration(
        indicators: standardIndicators,
        style: .standard,
        compact: nil
    )

    private enum CodingKeys: String, CodingKey {
        case indicators
        case style
        case compact
        // Legacy shape, decode-only: `compact` used to be a `Bool` named `isCompact`
        // (`true` = worst-of, `false`/absent = the full list). Kept in `CodingKeys` only so
        // `init(from:)` below can read it when the modern `compact` key is absent; `encode(to:)`
        // below never writes it because no stored property is named `isCompact` any more. (The
        // CodingKeys enum has to match stored properties 1:1 for Swift to synthesize
        // `encode(to:)` automatically, which is why this type now writes it by hand.)
        case isCompact
        // Deliberately NOT decoded: `usesColour` shipped, then colour customisation was
        // removed outright (see this type's own doc comment) rather than kept as an
        // unreachable flag. Omitting it from `CodingKeys` is enough for `JSONDecoder` to
        // silently ignore the key in old payloads instead of throwing — Swift's keyed
        // decoding container only rejects keys it is asked to decode, not extra ones sitting
        // in the JSON.
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedIndicators = try container.decode([MenuBarIndicator].self, forKey: .indicators)
        // Clamp, don't trap: a config saved by a future version (or a corrupted default)
        // with more entries than the current cap — or none at all — must still load.
        indicators = Self.clamped(decodedIndicators)
        // Missing keys default rather than throwing. These are preferences, and a
        // preference file that fails to decode means the menu bar silently reverts for a
        // reason the user cannot see; a key added in a later version must not do that.
        //
        // A PRESENT `style` whose own decode throws (a wrong-typed field inside it) is treated
        // the same as an absent one, via `try?` around the whole lookup rather than `try`: a
        // plain `decodeIfPresent` only returns nil when the KEY is missing — when the key
        // exists but `MenuBarStyle.init(from:)` throws, that error propagates uncaught, which
        // would fail this initializer and cost the user their whole configuration — the five
        // indicators and compact choice they carefully set up — over one corrupt style field.
        // `MenuBarConfigurationStore.load()`'s outer `.standard` fallback stays for a
        // configuration that is unreadable as a whole; this is the inner one, scoped to style.
        do {
            style = try container.decodeIfPresent(MenuBarStyle.self, forKey: .style) ?? .standard
        } catch {
            log.notice("stored menu bar style failed to decode, reverting to standard \(error: error)")
            style = .standard
        }
        if let decodedCompact = try container.decodeIfPresent(CompactSelection.self, forKey: .compact) {
            compact = decodedCompact
        } else {
            // A preference saved before `compact` existed: `isCompact: true` meant worst-of,
            // `false` or absent meant the full list.
            let legacyIsCompact = try container.decodeIfPresent(Bool.self, forKey: .isCompact) ?? false
            compact = legacyIsCompact ? .worstOf : nil
        }
    }

    /// Written by hand rather than synthesized: `CodingKeys` carries the decode-only legacy
    /// `isCompact` case (see its comment above), and Swift only auto-synthesizes `encode(to:)`
    /// when every `CodingKeys` case matches a stored property 1:1. Always writes the modern
    /// `compact` key, never `isCompact`.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(indicators, forKey: .indicators)
        try container.encode(style, forKey: .style)
        try container.encode(compact, forKey: .compact)
    }
}
