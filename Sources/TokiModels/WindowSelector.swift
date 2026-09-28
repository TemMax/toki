import Foundation

/// Which rate-limit window an indicator tracks.
public enum WindowSelector: Sendable, Equatable, Codable, Hashable {
    case fiveHour
    case sevenDay
    /// The scoped (per-model) window with the highest utilisation right now.
    /// Follows the leader as it changes rather than pinning a model name — the API
    /// reports whichever models the account is scoped on, and that set changes.
    case highestScopedModel
    /// One specific scoped window, pinned by the model name in its id.
    case scopedModel(String)
    /// Extra-usage credit consumption.
    case extraUsage
}

/// One window a `WindowSelector` picked out, flattened to what a caller needs.
public struct SelectedWindow: Equatable, Sendable {
    public let title: String
    public let utilization: Double
    public let resetsAt: Date?
    public let isAvailable: Bool

    public init(title: String, utilization: Double, resetsAt: Date?, isAvailable: Bool) {
        self.title = title
        self.utilization = utilization
        self.resetsAt = resetsAt
        self.isAvailable = isAvailable
    }
}

public extension WindowSelector {
    static let scopedModelPrefix = "weekly_scoped:"
    static let sessionScopedModelPrefix = "session_scoped:"

    /// The window this selector points at right now, or nil when there is nothing to point
    /// at — no data at all, or an account not scoped on the pinned model. nil means UNKNOWN,
    /// never zero: a caller must not read "no data" as "nothing used".
    func resolve(against limits: UsageLimits?) -> SelectedWindow? {
        guard let limits else { return nil }
        switch self {
        case .fiveHour:
            return limits.windows.first { $0.id == "session" }.map(Self.from)
        case .sevenDay:
            return limits.windows.first { $0.id == "weekly_all" }.map(Self.from)
        case .highestScopedModel:
            let scoped = limits.windows.filter(Self.isScopedModelWindow)
            return Self.leader(among: scoped).map(Self.from)
        case .scopedModel(let name):
            return limits.windows.first {
                $0.id == Self.scopedModelPrefix + name
                    || $0.id == Self.sessionScopedModelPrefix + name
            }.map(Self.from)
        case .extraUsage:
            guard let extra = limits.extra, let utilization = extra.utilization else { return nil }
            return SelectedWindow(title: "Extra usage", utilization: utilization,
                                  resetsAt: nil, isAvailable: extra.isEnabled)
        }
    }

    /// The scoped window with the greatest utilisation, or nil when `scoped` is empty.
    /// Available windows beat unavailable ones regardless of utilisation. An unavailable
    /// window can still carry a stale figure, and picking it because that stale 0.9 tops a
    /// live 0.5 would report the account's busiest model as one whose number is not live.
    private static func leader(among scoped: [RateLimitWindow]) -> RateLimitWindow? {
        var leader: RateLimitWindow?
        for window in scoped {
            guard let current = leader else {
                leader = window
                continue
            }
            if window.isAvailable != current.isAvailable {
                if window.isAvailable { leader = window }
            } else if window.utilization > current.utilization {
                leader = window
            }
        }
        return leader
    }

    private static func from(_ window: RateLimitWindow) -> SelectedWindow {
        SelectedWindow(
            title: modelName(fromScopedId: window.id) ?? window.title,
            utilization: window.utilization,
            resetsAt: window.resetsAt,
            isAvailable: window.isAvailable
        )
    }

    /// `"weekly_scoped:Fable"` -> `"Fable"`; nil for a window that is not scoped.
    private static func modelName(fromScopedId id: String) -> String? {
        if id.hasPrefix(scopedModelPrefix) {
            return String(id.dropFirst(scopedModelPrefix.count))
        }
        if id.hasPrefix(sessionScopedModelPrefix) {
            return String(id.dropFirst(sessionScopedModelPrefix.count))
        }
        return nil
    }

    private static func isScopedModelWindow(_ window: RateLimitWindow) -> Bool {
        window.id.hasPrefix(scopedModelPrefix)
            || window.id.hasPrefix(sessionScopedModelPrefix)
    }
}
