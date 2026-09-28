import Foundation
import TokiLogging

private let log = TokiLog.logger("usage-display")

/// Which live usage values a provider is allowed to draw in the dashboard and popover.
///
/// Window ids come from the providers rather than from a closed enum: Claude and Codex can
/// add model-scoped buckets without requiring an app update. Unknown future windows start
/// visible while the provider is enabled, matching the all-visible default.
public struct ProviderUsageDisplayConfiguration: Codable, Equatable, Sendable {
    /// False is an explicit "show none" choice. Keeping it separately from the hidden-id set
    /// ensures a future window does not make a provider reappear after every current toggle
    /// was switched off.
    public var isEnabled: Bool
    public var hiddenWindowIDs: Set<String>
    public var showsExtraUsage: Bool

    public init(
        isEnabled: Bool = true,
        hiddenWindowIDs: Set<String> = [],
        showsExtraUsage: Bool = true
    ) {
        self.isEnabled = isEnabled
        self.hiddenWindowIDs = hiddenWindowIDs
        self.showsExtraUsage = showsExtraUsage
    }

    public func showsWindow(id: String) -> Bool {
        isEnabled && !hiddenWindowIDs.contains(id)
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled
        case hiddenWindowIDs
        case showsExtraUsage
    }

    /// Every field is additive so a configuration saved by an older app keeps the default
    /// behavior when a new preference is introduced.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        hiddenWindowIDs = try c.decodeIfPresent(Set<String>.self, forKey: .hiddenWindowIDs) ?? []
        showsExtraUsage = try c.decodeIfPresent(Bool.self, forKey: .showsExtraUsage) ?? true
    }
}

public struct UsageDisplayConfiguration: Codable, Equatable, Sendable {
    public var claudeCode: ProviderUsageDisplayConfiguration
    public var codex: ProviderUsageDisplayConfiguration

    public init(
        claudeCode: ProviderUsageDisplayConfiguration = .init(),
        codex: ProviderUsageDisplayConfiguration = .init()
    ) {
        self.claudeCode = claudeCode
        self.codex = codex
    }

    public static let standard = UsageDisplayConfiguration()

    public subscript(provider: UsageProvider) -> ProviderUsageDisplayConfiguration {
        get {
            switch provider {
            case .claudeCode: claudeCode
            case .codex: codex
            }
        }
        set {
            switch provider {
            case .claudeCode: claudeCode = newValue
            case .codex: codex = newValue
            }
        }
    }

    /// Applies one window toggle and maintains the provider-level all-off marker. When the
    /// provider is re-enabled, only the selected row comes back; the other currently known
    /// rows remain off.
    public mutating func setWindowVisible(
        _ isVisible: Bool,
        id windowID: String,
        provider: UsageProvider,
        availableWindowIDs: [String]
    ) {
        var providerConfiguration = self[provider]
        if isVisible {
            if !providerConfiguration.isEnabled {
                providerConfiguration.hiddenWindowIDs.formUnion(availableWindowIDs)
                providerConfiguration.showsExtraUsage = false
            }
            providerConfiguration.isEnabled = true
            providerConfiguration.hiddenWindowIDs.remove(windowID)
        } else {
            providerConfiguration.hiddenWindowIDs.insert(windowID)
            let hasVisibleWindow = availableWindowIDs.contains {
                !providerConfiguration.hiddenWindowIDs.contains($0)
            }
            let hasVisibleExtra = provider == .claudeCode
                && providerConfiguration.showsExtraUsage
            providerConfiguration.isEnabled = hasVisibleWindow || hasVisibleExtra
        }
        self[provider] = providerConfiguration
    }

    /// Applies Claude's extra-usage toggle with the same all-off semantics as window rows.
    public mutating func setExtraUsageVisible(
        _ isVisible: Bool,
        provider: UsageProvider,
        availableWindowIDs: [String]
    ) {
        var providerConfiguration = self[provider]
        if isVisible, !providerConfiguration.isEnabled {
            providerConfiguration.hiddenWindowIDs.formUnion(availableWindowIDs)
        }
        providerConfiguration.showsExtraUsage = isVisible
        let hasVisibleWindow = availableWindowIDs.contains {
            !providerConfiguration.hiddenWindowIDs.contains($0)
        }
        providerConfiguration.isEnabled = isVisible || hasVisibleWindow
        self[provider] = providerConfiguration
    }

    /// Returns a display-only copy of a limits snapshot. The live owner remains unchanged;
    /// both UI surfaces apply this same pure projection and therefore cannot drift apart.
    /// Nil means there is no visible tile for this provider, including its header.
    public func displayedLimits(
        from limits: UsageLimits?,
        provider: UsageProvider
    ) -> UsageLimits? {
        guard let limits else { return nil }
        let providerConfiguration = self[provider]
        guard providerConfiguration.isEnabled else { return nil }

        let windows = limits.windows.filter {
            providerConfiguration.showsWindow(id: $0.id)
        }
        let extra = providerConfiguration.showsExtraUsage ? limits.extra : nil
        let hasVisibleExtra = extra.map { $0.prominence != .hidden } ?? false
        guard !windows.isEmpty || hasVisibleExtra else { return nil }

        return UsageLimits(
            windows: windows,
            extra: extra,
            fetchedAt: limits.fetchedAt,
            account: limits.account,
            bankedResets: limits.bankedResets,
            claudeResets: limits.claudeResets,
            supplementalRateLimit: limits.supplementalRateLimit
        )
    }

    private enum CodingKeys: String, CodingKey {
        case claudeCode
        case codex
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        claudeCode = try c.decodeIfPresent(
            ProviderUsageDisplayConfiguration.self,
            forKey: .claudeCode
        ) ?? .init()
        codex = try c.decodeIfPresent(
            ProviderUsageDisplayConfiguration.self,
            forKey: .codex
        ) ?? .init()
    }
}

/// UserDefaults persistence for `UsageDisplayConfiguration`, injected for test isolation.
public struct UsageDisplayConfigurationStore: @unchecked Sendable {
    private static let key = "toki.usageDisplayConfiguration"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public func load() -> UsageDisplayConfiguration {
        guard let data = defaults.data(forKey: Self.key) else { return .standard }
        do {
            return try JSONDecoder().decode(UsageDisplayConfiguration.self, from: data)
        } catch {
            log.error("usage display configuration decode failed, reverting to standard \(error: error)")
            return .standard
        }
    }

    public func save(_ configuration: UsageDisplayConfiguration) {
        let data: Data
        do {
            data = try JSONEncoder().encode(configuration)
        } catch {
            log.error("usage display configuration encode failed \(error: error)")
            return
        }
        defaults.set(data, forKey: Self.key)
    }
}
