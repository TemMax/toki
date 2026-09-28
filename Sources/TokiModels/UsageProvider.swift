import Foundation

/// A provider whose independent account and quota domain Toki can observe.
///
/// This is deliberately a value in persisted indicator/alert rules. A 5-hour Claude
/// window and a 5-hour Codex window are not interchangeable, even when they share the
/// same visual label.
public enum UsageProvider: String, Codable, CaseIterable, Hashable, Sendable {
    case claudeCode
    case codex

    public var displayName: String {
        switch self {
        case .claudeCode: "Claude"
        case .codex: "Codex"
        }
    }
}
