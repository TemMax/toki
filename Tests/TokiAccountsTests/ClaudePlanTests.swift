import Foundation
import Testing
@testable import TokiAccounts

@Suite("Claude plan names")
struct ClaudePlanTests {
    @Test("Claude Code's own display name wins")
    func displayNameWins() {
        #expect(ClaudePlan.displayName(planDisplayName: "Ultra", rateLimitTier: "default_claude_max_5x") == "Ultra")
    }

    @Test("rate-limit tiers map to the names Anthropic uses since 2026-10-30", arguments: [
        ("default_claude_max_20x", "Ultra"),
        ("default_claude_max_5x", "Max"),
        ("default_claude_pro", "Pro"),
    ])
    func tiers(tier: String, expected: String) {
        #expect(ClaudePlan.displayName(rateLimitTier: tier, organizationType: "claude_max") == expected)
    }

    @Test("organization and subscription types are the last resort", arguments: [
        ("claude_max", "Max"), ("max", "Max"), ("claude_pro", "Pro"), ("claude_team", "Team"),
        ("claude_enterprise", "Enterprise"), ("free", "Free"), ("claude_something_new", "Something New"),
    ])
    func types(kind: String, expected: String) {
        #expect(ClaudePlan.displayName(organizationType: kind) == expected)
        #expect(ClaudePlan.displayName(subscriptionType: kind) == expected)
    }

    @Test("nothing known names no plan")
    func unknown() {
        #expect(ClaudePlan.displayName() == nil)
        #expect(ClaudePlan.displayName(planDisplayName: "  ", rateLimitTier: "") == nil)
    }

    @Test("a stored credential names its plan without its tokens being read")
    func credential() {
        let json = Data(#"{"claudeAiOauth":{"accessToken":"a","subscriptionType":"max","rateLimitTier":"default_claude_max_20x"}}"#.utf8)
        #expect(ClaudePlan.displayName(credentialJSON: json) == "Ultra")
        #expect(ClaudePlan.displayName(credentialJSON: Data(#"{"claudeAiOauth":{}}"#.utf8)) == nil)
        #expect(ClaudePlan.displayName(credentialJSON: Data("nope".utf8)) == nil)
    }

    @Test("oauthAccount parsing carries the plan, and old stored identities still decode")
    func identity() throws {
        let parsed = AccountIdentity.parse(oauthAccount: [
            "accountUuid": "u", "emailAddress": "me@x.y",
            "organizationType": "claude_max", "organizationRateLimitTier": "default_claude_max_20x",
            "planDisplayName": "Ultra",
        ])
        #expect(parsed?.plan == "Ultra")
        #expect(AccountIdentity.parse(oauthAccount: ["accountUuid": "u", "organizationType": "claude_max",
                                                     "organizationRateLimitTier": "default_claude_max_20x"])?.plan == "Ultra")

        let old = Data(#"{"accountUuid":"u","email":"me@x.y"}"#.utf8)
        let decoded = try JSONDecoder().decode(AccountIdentity.self, from: old)
        #expect(decoded.plan == nil)
        #expect(decoded.email == "me@x.y")
    }
}
