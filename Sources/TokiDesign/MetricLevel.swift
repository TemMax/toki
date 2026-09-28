/// The gauge-colour rule: how far into its cap a metric is before it starts carrying
/// colour at all.
///
/// Pure data + a pure function, like `TypeScale` and `IconSize` — no SwiftUI/AppKit import,
/// so the rule is testable on its own and `App/Sources/Palette.swift` only maps a
/// `MetricLevel` onto the `Color` it already returns.
public enum MetricLevel: Sendable, Equatable {
    case nominal
    case warning
    case critical
}

public extension Tokens {
    /// Utilization at which a gauge starts carrying colour at all.
    static let warnThreshold = 0.60
    /// Utilization at which a gauge escalates from warning to critical.
    static let criticalThreshold = 0.85

    /// Gauge colour level by utilization — and deliberately `.nominal` (no colour) below
    /// `warnThreshold`.
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
    static func level(for fraction: Double) -> MetricLevel {
        switch fraction {
        case ..<warnThreshold:     return .nominal
        case ..<criticalThreshold: return .warning
        default:                   return .critical
        }
    }
}
