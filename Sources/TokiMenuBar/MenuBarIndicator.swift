/// The configurable, ordered list of indicators drawn in the macOS status item.
///
/// Today the status item shows a single number (5-hour utilisation, or the
/// extra-usage percentage while extra usage is active). Reading the 7-day window or
/// the per-model weekly window requires opening the popover. This module makes
/// which windows are shown, in what order, and how each is drawn a first-class,
/// testable configuration — `App/Sources` only draws what `MenuBarLayout.resolve`
/// hands it.
import Foundation
import TokiModels

/// How one indicator is drawn.
public enum IndicatorRendering: String, Sendable, Codable, CaseIterable {
    case bar
    case number
    case barAndNumber
}

/// One entry in a `MenuBarConfiguration`: which window it tracks and how to draw it.
public struct MenuBarIndicator: Sendable, Equatable, Codable, Identifiable {
    public let id: UUID
    /// Which independent quota domain supplies this indicator.
    public var provider: UsageProvider
    public var window: WindowSelector
    public var rendering: IndicatorRendering

    /// Whether to prefix the indicator with its window's short name — `5h`, `7d`, `Opus`.
    ///
    /// A separate switch rather than more `IndicatorRendering` cases on purpose. Folding it
    /// in would turn three renderings into six (`number`, `labelAndNumber`, `bar`,
    /// `labelAndBar`, …), and the settings screen would have to present that as one long
    /// list of near-identical options. Two independent switches are both smaller to model
    /// and easier to explain: *what* is drawn, and *whether it is named*.
    ///
    /// Named by default: three bare numbers do not say which limit is which, and the whole
    /// reason the list exists is that the user reads several windows at a glance.
    public var showsLabel: Bool

    /// Overrides the label derived from the window (`5h`, `7d`, the model's name).
    /// nil means "use the derived one" — so a user who never touches this keeps getting
    /// a sensible name when the scoped model changes underneath them.
    public var customLabel: String?

    /// The longest a `customLabel` may be. Generous next to the derived labels it replaces
    /// (`5h`, `7d`, a model name — realistically ≤ 12 characters) so a genuine short name
    /// fits with room to spare, but far short of the point where one label would dominate
    /// the strip: five indicators at the cap is already ~120 characters of menu-bar width,
    /// which is the ceiling this exists to defend, not a target to reach.
    public static let maximumCustomLabelLength = 24

    public init(
        id: UUID = UUID(),
        provider: UsageProvider = .claudeCode,
        window: WindowSelector,
        rendering: IndicatorRendering,
        showsLabel: Bool = true,
        customLabel: String? = nil
    ) {
        self.id = id
        self.provider = provider
        self.window = window
        self.rendering = rendering
        self.showsLabel = showsLabel
        self.customLabel = Self.sanitizedCustomLabel(customLabel)
    }

    /// Trims whitespace, strips control characters (a newline pasted into a label has nowhere
    /// sane to go — the strip is one line of `Text`) and caps the length. A label that is
    /// only whitespace after trimming collapses to nil rather than an empty-but-present
    /// string, so it resolves to the derived label instead of blanking the indicator out.
    private static func sanitizedCustomLabel(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let noControlCharacters = String(raw.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
        let trimmed = noControlCharacters.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(maximumCustomLabelLength))
    }

    private enum CodingKeys: String, CodingKey {
        case id, provider, window, rendering, showsLabel, customLabel
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        // Every configuration written before Codex support described Claude limits.
        provider = try container.decodeIfPresent(UsageProvider.self, forKey: .provider) ?? .claudeCode
        window = try container.decode(WindowSelector.self, forKey: .window)
        rendering = try container.decode(IndicatorRendering.self, forKey: .rendering)
        // Absent in configurations written before labels existed; those predate any release,
        // but a preference that fails to decode costs the user their menu-bar setup.
        showsLabel = try container.decodeIfPresent(Bool.self, forKey: .showsLabel) ?? true
        // Absent in every configuration written before this field existed; sanitized the same
        // way the memberwise init sanitizes it, so a hand-edited preferences file can't smuggle
        // in an overlong or control-character-laden label past the init's guard.
        let decodedCustomLabel = try container.decodeIfPresent(String.self, forKey: .customLabel)
        customLabel = Self.sanitizedCustomLabel(decodedCustomLabel)
    }
}
