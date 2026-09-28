import Testing
import Foundation
@testable import TokiModels

@Suite("TokiModels")
struct TokiModelsTests {
    @Test("plugin version status distinguishes current, outdated, and unknown")
    func pluginVersionStatus() {
        func plugin(
            installed: String?,
            latest: String?,
            updateAvailable: Bool
        ) -> PluginInfo {
            PluginInfo(
                name: "example",
                marketplace: "test",
                version: installed,
                latestVersion: latest,
                updateAvailable: updateAvailable,
                enabled: true,
                installedAt: nil,
                lastUpdated: nil,
                description: nil,
                usageCount: nil,
                isFavorite: false
            )
        }

        #expect(plugin(installed: "1.2.0", latest: "1.2.0", updateAvailable: false).versionStatus == .upToDate)
        #expect(plugin(installed: "1.0.0", latest: "1.2.0", updateAvailable: true).versionStatus == .outdated)
        #expect(plugin(installed: "1.0.0", latest: "1.2.0", updateAvailable: false).versionStatus == .outdated)
        #expect(plugin(installed: "1.3.0", latest: "1.2.0", updateAvailable: false).versionStatus == .upToDate)
        #expect(plugin(installed: "build-a", latest: "build-b", updateAvailable: false).versionStatus == .unknown)
        #expect(plugin(installed: nil, latest: "1.2.0", updateAvailable: false).versionStatus == .unknown)
        #expect(plugin(installed: "1.2.0", latest: nil, updateAvailable: false).versionStatus == .unknown)
    }

    @Test("TokenUsage.zero has all-zero fields")
    func tokenUsageZero() {
        let zero = TokenUsage.zero
        #expect(zero.input == 0)
        #expect(zero.output == 0)
        #expect(zero.cacheRead == 0)
        #expect(zero.ephemeral5m == 0)
        #expect(zero.ephemeral1h == 0)
        #expect(zero.webSearch == 0)
        #expect(zero.webFetch == 0)
        #expect(zero.cacheCreationTotal == 0)
    }

    @Test("TokenUsage + sums each field")
    func tokenUsageAdd() {
        let a = TokenUsage(input: 10, output: 20, cacheRead: 5, ephemeral5m: 3, ephemeral1h: 2, webSearch: 1, webFetch: 1)
        let b = TokenUsage(input: 1, output: 2, cacheRead: 0, ephemeral5m: 0, ephemeral1h: 0, webSearch: 0, webFetch: 0)
        let sum = a + b
        #expect(sum.input == 11)
        #expect(sum.output == 22)
        #expect(sum.cacheCreationTotal == 5)
    }

    @Test("CostBreakdown.zero has zero total")
    func costBreakdownZero() {
        #expect(CostBreakdown.zero.total == 0)
    }

    @Test("CostBreakdown + sums correctly")
    func costBreakdownAdd() {
        let a = CostBreakdown(input: 1.0, output: 2.0, cacheWrite: 0.5, cacheRead: 0.1)
        let b = CostBreakdown(input: 0.5, output: 1.0, cacheWrite: 0.25, cacheRead: 0.05)
        let sum = a + b
        #expect(abs(sum.total - 5.40) < 0.001)
    }

    @Test("OAuthCredential.isExpired is true when expiry is in the past")
    func oauthCredentialExpired() {
        let past = Date(timeIntervalSinceNow: -3600)
        let cred = OAuthCredential(accessToken: "tok", refreshToken: nil, expiresAt: past)
        #expect(cred.isExpired)
    }

    @Test("OAuthCredential.isExpired is false when expiry is far in the future")
    func oauthCredentialValid() {
        let future = Date(timeIntervalSinceNow: 3600)
        let cred = OAuthCredential(accessToken: "tok", refreshToken: nil, expiresAt: future)
        #expect(!cred.isExpired)
    }

    @Test("ExtraUsage.amountString formats in the account's currency and precision")
    func extraUsageAmountStringUsesCurrency() {
        let en = Locale(identifier: "en_US")

        let eur = ExtraUsage(
            isEnabled: true, monthlyLimit: 1500, usedCredits: 1286.26, utilization: 0.8575,
            currency: "EUR", decimalPlaces: 2
        )
        #expect(eur.amountString(1286.26, locale: en) == "€1,286.26")

        // Zero-decimal currency: no fraction digits.
        let jpy = ExtraUsage(
            isEnabled: true, monthlyLimit: 5000, usedCredits: 1234, utilization: 0.2468,
            currency: "JPY", decimalPlaces: 0
        )
        #expect(jpy.amountString(1234, locale: en) == "¥1,234")

        // No currency reported → the historical USD default.
        let legacy = ExtraUsage(
            isEnabled: true, monthlyLimit: 1000, usedCredits: 743.98, utilization: 0.74398
        )
        #expect(legacy.amountString(743.98, locale: en) == "$743.98")
    }

    @Test("UsageLimits Codable round-trip preserves all fields")
    func usageLimitsCodableRoundTrip() throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_750_000_000)
        let resetsAt  = Date(timeIntervalSince1970: 1_750_010_000)

        let original = UsageLimits(
            windows: [
                RateLimitWindow(id: "session", title: "5-hour", utilization: 0.34, resetsAt: resetsAt, isAvailable: true),
                RateLimitWindow(id: "weekly_all", title: "7-day", utilization: 0.71, resetsAt: resetsAt, isAvailable: true),
                // At least one unavailable window so isAvailable round-trips both values.
                RateLimitWindow(id: "weekly_scoped:Sonnet", title: "7-day Sonnet", utilization: 0.22, resetsAt: nil, isAvailable: false),
            ],
            extra: ExtraUsage(
                isEnabled: true,
                monthlyLimit: 100_000,
                usedCredits: 74_398,
                utilization: 0.74398
            ),
            fetchedAt: fetchedAt,
            bankedResets: nil,
            claudeResets: ClaudeResetStatus(
                eligible: true,
                grants: [ClaudeResetGrant(id: "grant-1", resetsLeft: 2)]
            ),
            supplementalRateLimit: SupplementalRateLimit(retryAfter: 180)
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(UsageLimits.self, from: data)

        #expect(decoded.fetchedAt == original.fetchedAt)

        // Each window round-trips id / title / utilization / resetsAt / isAvailable.
        #expect(decoded.windows.count == 3)
        for (d, o) in zip(decoded.windows, original.windows) {
            #expect(d.id == o.id)
            #expect(d.title == o.title)
            #expect(d.utilization == o.utilization)
            #expect(d.resetsAt == o.resetsAt)
            #expect(d.isAvailable == o.isAvailable)
        }

        // Convenience accessors resolve to the canonical windows after decode.
        #expect(decoded.fiveHour?.utilization == 0.34)
        #expect(decoded.fiveHour?.resetsAt == resetsAt)
        #expect(decoded.sevenDay?.utilization == 0.71)
        // The unavailable scoped window preserved its flags.
        let scoped = try #require(decoded.windows.first { $0.id == "weekly_scoped:Sonnet" })
        #expect(scoped.isAvailable == false)
        #expect(scoped.resetsAt == nil)

        #expect(decoded.extra?.isEnabled == true)
        #expect(decoded.extra?.monthlyLimit == 100_000)
        #expect(decoded.extra?.usedCredits == 74_398)
        let extraUtil = try #require(decoded.extra?.utilization)
        #expect(abs(extraUtil - 0.74398) < 1e-9)
        #expect(decoded.claudeResets == original.claudeResets)
        #expect(decoded.supplementalRateLimit == original.supplementalRateLimit)
    }

    @Test("UsageLimits decodes cache data saved before banked resets were added")
    func usageLimitsDecodesLegacyCache() throws {
        let legacy = Data("""
        {
          "windows": [{
            "id": "session",
            "title": "5-hour",
            "utilization": 0.2,
            "resetsAt": null,
            "isAvailable": true
          }],
          "extra": null,
          "fetchedAt": 750000000,
          "account": null
        }
        """.utf8)

        let decoded = try JSONDecoder().decode(UsageLimits.self, from: legacy)

        #expect(decoded.windows.map(\.id) == ["session"])
        #expect(decoded.bankedResets == nil)
        #expect(decoded.claudeResets == nil)
        #expect(decoded.supplementalRateLimit == nil)
    }

    @Test("TokiError.localizedDescription is human-readable, not an opaque ordinal")
    func tokiErrorLocalizedDescription() {
        // Regression: a bare `enum Error` bridges to NSError with an opaque numeric code,
        // so `localizedDescription` rendered as "…(TokiCore.TokiError error 2.)" and the
        // real diagnostic was lost. LocalizedError conformance must surface the detail.
        let decoding = TokiError.decoding("bad resets_at")
        let message = (decoding as Error).localizedDescription
        #expect(message.contains("bad resets_at"))
        #expect(!message.contains("error 2"))

        let http = TokiError.httpError(503)
        #expect((http as Error).localizedDescription.contains("503"))
    }

    @Test("TranscriptRecord.projectName returns last path component")
    func transcriptRecordProjectName() {
        let record = TranscriptRecord(
            requestId: "r1",
            sessionId: "s1",
            cwd: "/Users/example/Developer/MyProject",
            model: "claude-opus-4-8",
            timestamp: Date(),
            usage: .zero,
            isSidechain: false
        )
        #expect(record.projectName == "MyProject")
    }
}

// MARK: - Token definitions and billing

@Suite("TokenUsage definitions")
struct TokenUsageDefinitionTests {

    @Test("Claude-shaped and Codex-shaped usage of the same size count the same")
    func providersCompare() {
        // Claude reports a turn's new context as cache writes; Codex as plain input.
        let claude = TokenUsage(input: 3, output: 100, cacheRead: 50_000, ephemeral5m: 900, ephemeral1h: 97,
                                webSearch: 0, webFetch: 0)
        let codex = TokenUsage(input: 1000, output: 100, cacheRead: 50_000, ephemeral5m: 0, ephemeral1h: 0,
                               webSearch: 0, webFetch: 0)
        #expect(claude.uncachedInput == 1000)
        #expect(claude.processedTokens == codex.processedTokens)
        #expect(claude.processedTokens == 1100)
        #expect(claude.promptTokens == 51_000)
        #expect(abs((claude.cacheHitRate ?? 0) - 50_000.0 / 51_000.0) < 1e-12)
        #expect(TokenUsage.zero.cacheHitRate == nil)
    }
}

@Suite("Billing modifiers")
struct BillingModifierTests {

    private let opus = ModelPricing(inputPerMTok: 5, outputPerMTok: 25, cacheWrite5mPerMTok: 6.25,
                                    cacheWrite1hPerMTok: 10, cacheReadPerMTok: 0.50)

    @Test("Fast mode doubles every token category; US-only inference adds 10%; searches are flat")
    func modifiersScaleTokensOnly() {
        let usage = TokenUsage(input: 1_000_000, output: 1_000_000, cacheRead: 1_000_000,
                               ephemeral5m: 1_000_000, ephemeral1h: 0, webSearch: 2, webFetch: 0)
        let standard = opus.cost(for: usage)
        #expect(standard.webSearch == 0.02)
        // Typed up front: inside `#expect` this literal sum exceeds CI's type-check time limit.
        let expectedTotal: Double = 5 + 25 + 6.25 + 0.50 + 0.02
        #expect(standard.total == expectedTotal)

        let fast = standard.applying(.fastMode)
        // Published fast prices for Opus 5: $10 input / $50 output — exactly 2x.
        #expect(fast.input == 10)
        #expect(fast.output == 50)
        #expect(fast.cacheWrite == 12.50)
        #expect(fast.cacheRead == 1)
        #expect(fast.webSearch == 0.02)

        let us = standard.applying(.usOnlyInference)
        #expect(abs(us.input - 5.5) < 1e-12)
        #expect(abs(us.output - 27.5) < 1e-12)
        #expect(standard.applying([]).total == standard.total)
        #expect(abs(standard.applying([.fastMode, .usOnlyInference]).input - 11) < 1e-12)
    }
}
