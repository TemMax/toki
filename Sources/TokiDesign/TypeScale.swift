/// The type scale, as data: a fixed six-step size ladder plus ten named roles binding
/// size + weight + design + digit treatment. See the doc comments below for why each step
/// and role exists — this is a deliberate reduction from 148 call sites hand-picking among
/// 12 sizes, not an arbitrary new list.
///
/// Pure data on purpose: `TokiDesign` has no SwiftUI/AppKit dependency, so `Weight` and
/// `Design` are small mirrors of `Font.Weight`/`Font.Design` rather than the real types —
/// the app target maps a `Role` onto an actual `Font`.
public enum TypeScale {

    // MARK: - The ladder

    /// The six fixed sizes, strictly ascending. Not arbitrary: 10, 13 and 22 are what
    /// `NSFont.preferredFont(forTextStyle:)` reports on macOS for `caption1`, `body` and
    /// `title1`; 11, 15 and 30 are the sizes already carrying the most weight in the app.
    /// 8pt and 9pt are deliberately gone — below anything defensible for interface text.
    public enum Step: Double, CaseIterable, Sendable {
        case caption = 10
        case label = 11
        case body = 13
        case title = 15
        case metric = 22
        case hero = 30
    }

    /// Named weight, independent of `Font.Weight` so this module stays import-free.
    public enum Weight: Sendable, Equatable {
        case light
        case regular
        case medium
        case semibold
    }

    /// Named font design, mirroring `Font.Design` without importing SwiftUI.
    public enum Design: Sendable, Equatable {
        case `default`
        case rounded
        case monospaced
    }

    /// Everything a call site needs to build a `Font` for a role, before the scale
    /// multiplier is applied to `step`.
    public struct RoleSpec: Sendable, Equatable {
        public let step: Step
        public let weight: Weight
        public let design: Design
        /// Tabular/monospaced-digit rendering — distinct from `design == .monospaced`,
        /// which is a full monospaced typeface. Numeric displays (hero/metric) want digits
        /// that don't shift width as they tick over even though the surrounding face is
        /// proportional-rounded.
        public let monospacedDigits: Bool

        public init(step: Step, weight: Weight, design: Design, monospacedDigits: Bool) {
            self.step = step
            self.weight = weight
            self.design = design
            self.monospacedDigits = monospacedDigits
        }
    }

    // MARK: - Roles

    /// The ten named roles in use across the app. A size alone is not enough: the same
    /// size carries several weights in real use (11pt appears as regular, medium,
    /// semibold, bold, rounded and monospaced today), so a role binds the whole
    /// size+weight+design+digit-treatment combination as one named thing.
    public enum Role: CaseIterable, Sendable {
        /// Largest display numeral (e.g. a hero spend figure). Deliberately LIGHT, not
        /// semibold: the weight contrast against the semibold caps `SectionHeader` label
        /// beside it is the hierarchy device — see `heroNumber()` in `SectionHeader.swift`.
        case hero
        /// Primary metric display (e.g. a gauge's headline number).
        case metric
        /// A metric-style numeral at title size, for secondary/compact numeric displays.
        case metricSmall
        /// A metric-style numeral inline with label-size text (e.g. a gauge's percent
        /// figure sitting beside its title). `label` step, not `title`: `metricSmall`
        /// already owns 15pt, and growing an 11pt figure to 15pt inside a 320pt popover
        /// is a redesign, not a type migration.
        case metricInline
        /// Section/card titles.
        case title
        /// Emphasized body text, e.g. a card's lead line.
        case headline
        /// Running text.
        case body
        /// Form/field labels.
        case label
        /// The workhorse: secondary text at label size, unemphasized.
        case detail
        /// Smallest text: captions, footnotes, timestamps.
        case caption
        /// Paths, versions, ids — anything that benefits from a monospaced typeface.
        case mono

        /// The role's size/weight/design/digit-treatment, before the scale multiplier.
        public var spec: RoleSpec {
            switch self {
            case .hero:
                RoleSpec(step: .hero, weight: .light, design: .rounded, monospacedDigits: true)
            case .metric:
                RoleSpec(step: .metric, weight: .semibold, design: .rounded, monospacedDigits: true)
            case .metricSmall:
                RoleSpec(step: .title, weight: .semibold, design: .rounded, monospacedDigits: true)
            case .metricInline:
                RoleSpec(step: .label, weight: .semibold, design: .rounded, monospacedDigits: true)
            case .title:
                RoleSpec(step: .title, weight: .semibold, design: .default, monospacedDigits: false)
            case .headline:
                RoleSpec(step: .body, weight: .semibold, design: .default, monospacedDigits: false)
            case .body:
                RoleSpec(step: .body, weight: .regular, design: .default, monospacedDigits: false)
            case .label:
                RoleSpec(step: .label, weight: .medium, design: .default, monospacedDigits: false)
            case .detail:
                RoleSpec(step: .label, weight: .regular, design: .default, monospacedDigits: false)
            case .caption:
                RoleSpec(step: .caption, weight: .regular, design: .default, monospacedDigits: false)
            case .mono:
                RoleSpec(step: .label, weight: .regular, design: .monospaced, monospacedDigits: false)
            }
        }

        /// The role's point size at an explicit scale — pure, so the arithmetic can be
        /// reasoned about and tested without touching process-wide state.
        ///
        /// Kept separate from `resolvedSize` deliberately. When the only way to ask "what
        /// is `label` at 1.25?" was to assign the global and read it back, the tests raced
        /// each other: swift-testing runs in parallel, so one case set the multiplier while
        /// another was mid-read. Separating the computation from the ambient value removes
        /// the race at its source instead of serialising around it.
        public func size(multiplier: Double) -> Double {
            spec.step.rawValue * TypeScale.clamped(multiplier)
        }

        /// The role's point size at the app's current ambient scale. This is the ONE place
        /// call sites read, so a future text-size setting is one assignment to `multiplier`
        /// rather than 148 call-site edits.
        public var resolvedSize: Double {
            size(multiplier: TypeScale.multiplier)
        }
    }

    // MARK: - Scale multiplier

    /// Backing storage for `multiplier`. `nonisolated(unsafe)`: this is a rarely-written,
    /// process-wide scale factor (set once from a future settings screen, read on every
    /// text render), not a value under contended concurrent mutation — the same tradeoff
    /// the codebase already makes for other simple global state.
    private nonisolated(unsafe) static var storedMultiplier: Double = 1.0

    /// Scales every role's resolved size. The app owns text scaling because macOS does not
    /// provide it (measured on macOS 26/Xcode 26.6: SwiftUI ignores `dynamicTypeSize`
    /// entirely — `.font(.body)`, `.system(.body, design:)` and
    /// `Font.custom(_:relativeTo:)` all render at identical heights across every
    /// `DynamicTypeSize` from `xSmall` to `accessibility5`).
    ///
    /// Clamped to `0.85...1.6`:
    /// - **lower bound 0.85** — below it the smallest ladder step (`caption`, 10pt) drops
    ///   under 8.5pt, past the point of readable interface text;
    /// - **upper bound 1.6** — above it the app's fixed-height rows and controls, sized for
    ///   today's scale, start clipping their own text.
    public static var multiplier: Double {
        get { storedMultiplier }
        set { storedMultiplier = clamped(newValue) }
    }

    /// The lower bound of `multiplier`. Below it the smallest ladder step drops under 8.5pt.
    public static let minimumMultiplier: Double = 0.85
    /// The upper bound of `multiplier`. Above it fixed-height rows clip their own text.
    public static let maximumMultiplier: Double = 1.6

    /// Clamping lives here rather than in the setter so `Role.size(multiplier:)` enforces the
    /// same bounds without going through the global — one rule, two callers.
    public static func clamped(_ value: Double) -> Double {
        min(max(value, minimumMultiplier), maximumMultiplier)
    }
}
