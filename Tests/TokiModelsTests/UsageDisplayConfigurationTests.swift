import Foundation
import Testing
@testable import TokiModels

private func usageDisplayDefaults(_ name: String) -> UserDefaults {
    let suite = "toki.tests.usageDisplay.\(name).\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return defaults
}

private func usageDisplayLimits(
    extra: ExtraUsage? = nil,
    account: UsageAccount? = nil,
    bankedResets: BankedResets? = nil,
    claudeResets: ClaudeResetStatus? = nil,
    supplementalRateLimit: SupplementalRateLimit? = nil
) -> UsageLimits {
    UsageLimits(
        windows: [
            RateLimitWindow(
                id: "session", title: "5-hour", utilization: 0.2,
                resetsAt: nil, isAvailable: true
            ),
            RateLimitWindow(
                id: "weekly_all", title: "7-day", utilization: 0.6,
                resetsAt: nil, isAvailable: true
            ),
            RateLimitWindow(
                id: "weekly_scoped:Spark", title: "7-day · Spark", utilization: 0,
                resetsAt: nil, isAvailable: false
            ),
        ],
        extra: extra,
        fetchedAt: Date(timeIntervalSince1970: 1_750_000_000),
        account: account,
        bankedResets: bankedResets,
        claudeResets: claudeResets,
        supplementalRateLimit: supplementalRateLimit
    )
}

@Suite("UsageDisplayConfiguration")
struct UsageDisplayConfigurationTests {
    @Test("standard configuration shows every provider window")
    func standardShowsEveryWindow() throws {
        let displayed = try #require(
            UsageDisplayConfiguration.standard.displayedLimits(
                from: usageDisplayLimits(),
                provider: .codex
            )
        )
        #expect(displayed.windows.map(\.id) == [
            "session", "weekly_all", "weekly_scoped:Spark",
        ])
    }

    @Test("hidden ids filter the same snapshot without mutating it")
    func hiddenIDsAreFiltered() throws {
        let source = usageDisplayLimits()
        let configuration = UsageDisplayConfiguration(
            codex: ProviderUsageDisplayConfiguration(
                hiddenWindowIDs: ["weekly_scoped:Spark"]
            )
        )

        let displayed = try #require(
            configuration.displayedLimits(from: source, provider: .codex)
        )
        #expect(displayed.windows.map(\.id) == ["session", "weekly_all"])
        #expect(source.windows.count == 3)
    }

    @Test("window filtering preserves account identity and banked reset metadata")
    func filteringPreservesSnapshotMetadata() throws {
        let credit = BankedResetCredit(
            id: "credit-1",
            grantedAt: Date(timeIntervalSince1970: 1_788_581_903),
            expiresAt: Date(timeIntervalSince1970: 1_791_173_903),
            status: "available",
            resetType: "codexRateLimits"
        )
        let source = usageDisplayLimits(
            account: UsageAccount(accountUuid: "account-123", organizationUuid: nil),
            bankedResets: BankedResets(availableCount: 2, credits: [credit]),
            claudeResets: ClaudeResetStatus(
                eligible: true,
                grants: [ClaudeResetGrant(id: "claude-1", resetsLeft: 2)]
            ),
            supplementalRateLimit: SupplementalRateLimit(retryAfter: 180)
        )
        let configuration = UsageDisplayConfiguration(
            codex: ProviderUsageDisplayConfiguration(hiddenWindowIDs: ["weekly_all"])
        )

        let displayed = try #require(
            configuration.displayedLimits(from: source, provider: .codex)
        )

        #expect(displayed.account == source.account)
        #expect(displayed.bankedResets == source.bankedResets)
        #expect(displayed.bankedResets?.availableCount == 2)
        #expect(displayed.bankedResets?.credits?.count == 1)
        #expect(displayed.claudeResets == source.claudeResets)
        #expect(displayed.supplementalRateLimit == source.supplementalRateLimit)
    }

    @Test("an explicitly disabled provider has no tile even when a new window arrives")
    func disabledProviderStaysHidden() {
        let configuration = UsageDisplayConfiguration(
            codex: ProviderUsageDisplayConfiguration(isEnabled: false)
        )
        #expect(configuration.displayedLimits(
            from: usageDisplayLimits(),
            provider: .codex
        ) == nil)
    }

    @Test("turning off the final selected value disables the whole provider")
    func finalToggleDisablesProvider() {
        let ids = ["session", "weekly_all"]
        var configuration = UsageDisplayConfiguration.standard
        configuration.setExtraUsageVisible(
            false,
            provider: .claudeCode,
            availableWindowIDs: ids
        )
        configuration.setWindowVisible(
            false,
            id: "session",
            provider: .claudeCode,
            availableWindowIDs: ids
        )
        configuration.setWindowVisible(
            false,
            id: "weekly_all",
            provider: .claudeCode,
            availableWindowIDs: ids
        )

        #expect(!configuration[.claudeCode].isEnabled)
        #expect(configuration.displayedLimits(
            from: usageDisplayLimits(),
            provider: .claudeCode
        ) == nil)
    }

    @Test("re-enabling one row from all-off does not enable its siblings")
    func reenableIsSpecific() {
        let ids = ["session", "weekly_all", "weekly_scoped:Spark"]
        var configuration = UsageDisplayConfiguration(
            codex: ProviderUsageDisplayConfiguration(isEnabled: false)
        )
        configuration.setWindowVisible(
            true,
            id: "weekly_all",
            provider: .codex,
            availableWindowIDs: ids
        )

        #expect(configuration[.codex].showsWindow(id: "weekly_all"))
        #expect(!configuration[.codex].showsWindow(id: "session"))
        #expect(!configuration[.codex].showsWindow(id: "weekly_scoped:Spark"))
    }

    @Test("extra usage can remain as the provider's only visible value")
    func extraCanStandAlone() throws {
        let extra = ExtraUsage(
            isEnabled: true,
            monthlyLimit: 100,
            usedCredits: 12,
            utilization: 0.12
        )
        let configuration = UsageDisplayConfiguration(
            claudeCode: ProviderUsageDisplayConfiguration(
                hiddenWindowIDs: ["session", "weekly_all", "weekly_scoped:Spark"],
                showsExtraUsage: true
            )
        )

        let displayed = try #require(configuration.displayedLimits(
            from: usageDisplayLimits(extra: extra),
            provider: .claudeCode
        ))
        #expect(displayed.windows.isEmpty)
        #expect(displayed.extra?.usedCredits == 12)
    }

    @Test("an invisible extra value does not leave an empty header and card")
    func invisibleExtraDoesNotLeaveEmptyTile() {
        let offExtra = ExtraUsage(
            isEnabled: false,
            monthlyLimit: nil,
            usedCredits: nil,
            utilization: nil
        )
        let configuration = UsageDisplayConfiguration(
            claudeCode: ProviderUsageDisplayConfiguration(
                hiddenWindowIDs: ["session", "weekly_all", "weekly_scoped:Spark"],
                showsExtraUsage: true
            )
        )
        #expect(configuration.displayedLimits(
            from: usageDisplayLimits(extra: offExtra),
            provider: .claudeCode
        ) == nil)
    }

    @Test("missing fields decode to the all-visible standard")
    func additiveDecodeDefaults() throws {
        let decoded = try JSONDecoder().decode(
            UsageDisplayConfiguration.self,
            from: Data("{}".utf8)
        )
        #expect(decoded == .standard)
    }

    @Test("store round-trips choices and falls back after corruption")
    func storeRoundTripAndFallback() {
        let defaults = usageDisplayDefaults("store")
        let store = UsageDisplayConfigurationStore(defaults: defaults)
        let custom = UsageDisplayConfiguration(
            claudeCode: ProviderUsageDisplayConfiguration(
                hiddenWindowIDs: ["weekly_all"],
                showsExtraUsage: false
            ),
            codex: ProviderUsageDisplayConfiguration(isEnabled: false)
        )

        store.save(custom)
        #expect(store.load() == custom)

        defaults.set(Data([0xFF, 0x00]), forKey: "toki.usageDisplayConfiguration")
        #expect(store.load() == .standard)
    }
}
