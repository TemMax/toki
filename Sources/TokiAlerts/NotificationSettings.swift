import Foundation
import TokiModels

/// Every notification Toki can send, in one value. There is deliberately no second place
/// where a notification is switched on or off.
public struct NotificationSettings: Codable, Equatable, Sendable {
    public var rules: [AlertRule]
    public var onSwap: Bool
    public var onAllExhausted: Bool
    public var onNeedsReauth: Bool
    public var onNewAccount: Bool
    /// Anthropic's status page reporting an incident that affects Claude Code.
    public var onServiceStatus: Bool
    /// OpenAI's status page reporting an incident that affects Codex.
    public var onCodexServiceStatus: Bool
    public var onBankedResets: Bool
    public var onOpenAIResets: Bool
    public var onClaudeResets: Bool

    public init(rules: [AlertRule], onSwap: Bool, onAllExhausted: Bool,
                onNeedsReauth: Bool, onNewAccount: Bool, onServiceStatus: Bool,
                onCodexServiceStatus: Bool = true, onBankedResets: Bool = true,
                onOpenAIResets: Bool = true, onClaudeResets: Bool = true) {
        self.rules = rules
        self.onSwap = onSwap
        self.onAllExhausted = onAllExhausted
        self.onNeedsReauth = onNeedsReauth
        self.onNewAccount = onNewAccount
        self.onServiceStatus = onServiceStatus
        self.onCodexServiceStatus = onCodexServiceStatus
        self.onBankedResets = onBankedResets
        self.onOpenAIResets = onOpenAIResets
        self.onClaudeResets = onClaudeResets
    }

    /// Every field decodes with a default, and that is load-bearing — not tidiness.
    ///
    /// `NotificationSettingsStore.load()` swallows a decode error by returning `.standard`.
    /// So a single strictly-decoded field added in a later version turns every EXISTING
    /// user's stored settings into a failed decode on first launch: their rules, their
    /// thresholds and their toggles are silently replaced by the defaults, with no error
    /// anyone would see. `decodeIfPresent ?? standard` makes a new field additive instead —
    /// old payloads keep everything they stored and inherit the new field's default.
    ///
    /// `NotificationSettingsTests` pins this by decoding `{}` and requiring exactly
    /// `.standard`, so a future field without a default fails CI rather than user data.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let standard = NotificationSettings.standard
        self.init(
            rules: try c.decodeIfPresent([AlertRule].self, forKey: .rules) ?? standard.rules,
            onSwap: try c.decodeIfPresent(Bool.self, forKey: .onSwap) ?? standard.onSwap,
            onAllExhausted: try c.decodeIfPresent(Bool.self, forKey: .onAllExhausted)
                ?? standard.onAllExhausted,
            onNeedsReauth: try c.decodeIfPresent(Bool.self, forKey: .onNeedsReauth)
                ?? standard.onNeedsReauth,
            onNewAccount: try c.decodeIfPresent(Bool.self, forKey: .onNewAccount)
                ?? standard.onNewAccount,
            onServiceStatus: try c.decodeIfPresent(Bool.self, forKey: .onServiceStatus)
                ?? standard.onServiceStatus,
            onCodexServiceStatus: try c.decodeIfPresent(Bool.self, forKey: .onCodexServiceStatus)
                ?? standard.onCodexServiceStatus,
            onBankedResets: try c.decodeIfPresent(Bool.self, forKey: .onBankedResets) ?? standard.onBankedResets,
            onOpenAIResets: try c.decodeIfPresent(Bool.self, forKey: .onOpenAIResets) ?? standard.onOpenAIResets,
            onClaudeResets: try c.decodeIfPresent(Bool.self, forKey: .onClaudeResets) ?? standard.onClaudeResets
        )
    }

    /// Three rules per provider at 90%, covering the session window, the weekly window and
    /// whichever per-model window is busiest. The editor hides rules for uninstalled tools;
    /// keeping both sets in the default means installing a provider later gives it the same
    /// useful day-one behavior without mutating the user's configuration behind their back.
    public static let standard = NotificationSettings(
        rules: [
            AlertRule(window: .fiveHour, threshold: 0.9),
            AlertRule(window: .sevenDay, threshold: 0.9),
            AlertRule(window: .highestScopedModel, threshold: 0.9),
            AlertRule(provider: .codex, window: .fiveHour, threshold: 0.9),
            AlertRule(provider: .codex, window: .sevenDay, threshold: 0.9),
            AlertRule(provider: .codex, window: .highestScopedModel, threshold: 0.9),
        ],
        onSwap: true, onAllExhausted: true, onNeedsReauth: true, onNewAccount: true,
        onServiceStatus: true, onCodexServiceStatus: true
    )
}
