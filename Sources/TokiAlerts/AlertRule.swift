import Foundation
import TokiModels

/// One threshold the user asked to be told about: a window, and how full it may get.
public struct AlertRule: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var provider: UsageProvider
    public var window: WindowSelector
    /// Fraction in 0…1. Clamped on decode so a hand-edited or future-version value cannot
    /// produce a rule that fires constantly (<= 0) or never (> 1).
    public var threshold: Double
    public var isEnabled: Bool

    public init(
        id: UUID = UUID(),
        provider: UsageProvider = .claudeCode,
        window: WindowSelector,
        threshold: Double,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.provider = provider
        self.window = window
        self.threshold = min(max(threshold, 0.01), 1.0)
        self.isEnabled = isEnabled
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(UUID.self, forKey: .id),
            provider: try c.decodeIfPresent(UsageProvider.self, forKey: .provider) ?? .claudeCode,
            window: try c.decode(WindowSelector.self, forKey: .window),
            threshold: try c.decode(Double.self, forKey: .threshold),
            isEnabled: try c.decode(Bool.self, forKey: .isEnabled)
        )
    }
}
