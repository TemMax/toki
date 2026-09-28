import Testing
import Foundation
import TokiAccounts
@testable import TokiSwap

private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

private func credential(refresh: String?) -> Data {
    guard let refresh else { return Data(#"{"claudeAiOauth":{"accessToken":""}}"#.utf8) }
    return Data(#"{"claudeAiOauth":{"accessToken":"a","refreshToken":"\#(refresh)"}}"#.utf8)
}

private func slot(refresh: String, previous: String? = nil) -> AccountSlot {
    AccountSlot(
        identity: AccountIdentity(
            accountUuid: "uuid-1", email: "me@x.y", displayName: nil,
            organizationName: nil, organizationUuid: nil
        ),
        alias: nil,
        credentialJSON: credential(refresh: refresh),
        previousCredentialJSON: previous.map { credential(refresh: $0) },
        lineage: Lineage.fingerprint(refreshToken: refresh),
        addedAt: t0, lastActiveAt: nil, lastRefreshAt: nil, health: .ok
    )
}

private func identity(_ uuid: String) -> AccountIdentity {
    AccountIdentity(
        accountUuid: uuid, email: nil, displayName: nil,
        organizationName: nil, organizationUuid: nil
    )
}

@Suite("OwnershipClassifier")
struct OwnershipClassifierTests {

    @Test("an identical lineage is the slot's own credential")
    func identicalLineageIsOwn() {
        #expect(
            OwnershipClassifier.classify(
                liveCredentialJSON: credential(refresh: "r1"),
                slot: slot(refresh: "r1"), oracleIdentity: nil
            ) == .own
        )
    }

    @Test("the slot's previous generation means Claude Code rotated it")
    func previousGenerationIsRotation() {
        #expect(
            OwnershipClassifier.classify(
                liveCredentialJSON: credential(refresh: "r-old"),
                slot: slot(refresh: "r-new", previous: "r-old"), oracleIdentity: nil
            ) == .ownRotated
        )
    }

    @Test("a different lineage confirmed by the oracle as the same account is a rotation")
    func oracleConfirmsRotation() {
        // Claude Code rotated the token since the last sync-back and the predecessor is
        // already gone from the slot; only the profile endpoint can settle it.
        #expect(
            OwnershipClassifier.classify(
                liveCredentialJSON: credential(refresh: "r-unknown"),
                slot: slot(refresh: "r1"), oracleIdentity: identity("uuid-1")
            ) == .ownRotated
        )
    }

    @Test("a different lineage owned by another account is foreign")
    func oracleRejectsForeign() {
        #expect(
            OwnershipClassifier.classify(
                liveCredentialJSON: credential(refresh: "r-other"),
                slot: slot(refresh: "r1"), oracleIdentity: identity("uuid-2")
            ) == .foreign
        )
    }

    @Test("an unknown lineage with no oracle answer is unresolved, never assumed own")
    func noOracleIsUnresolved() {
        // Assuming ownership here is exactly how the prior art destroyed a slot's only
        // refresh token; the caller must treat this as "do not overwrite".
        #expect(
            OwnershipClassifier.classify(
                liveCredentialJSON: credential(refresh: "r-unknown"),
                slot: slot(refresh: "r1"), oracleIdentity: nil
            ) == .unresolved
        )
    }

    @Test("an emptied credential is wiped and must never overwrite a live slot")
    func emptiedCredentialIsWiped() {
        // Claude Code empties the token fields in place when a refresh returns
        // invalid_grant. Copying that over the slot would erase its surviving token.
        #expect(
            OwnershipClassifier.classify(
                liveCredentialJSON: credential(refresh: nil),
                slot: slot(refresh: "r1"), oracleIdentity: identity("uuid-1")
            ) == .wiped
        )
    }
}

/// Pins the profile-endpoint field mapping to the shape the live endpoint actually
/// returned on 2026-08-07, so a future guess cannot silently blank the account label.
@Suite("ProfileOracle normalization")
struct ProfileOracleNormalizationTests {

    @Test("maps the real response shape onto oauthAccount field names")
    func mapsLiveShape() {
        let account: [String: Any] = [
            "uuid": "acct-uuid", "email": "me@example.com",
            "full_name": "Full Name", "display_name": "Display",
            "has_claude_max": true, "created_at": "2026-01-01",
        ]
        let root: [String: Any] = [
            "account": account,
            "organization": ["uuid": "org-uuid", "name": "Org", "rate_limit_tier": "x"],
        ]
        let mapped = ProfileOracle.normalize(account, root: root)
        let identity = AccountIdentity.parse(oauthAccount: mapped)

        #expect(identity?.accountUuid == "acct-uuid")
        #expect(identity?.email == "me@example.com")
        #expect(identity?.displayName == "Full Name")
        #expect(identity?.organizationName == "Org")
        #expect(identity?.organizationUuid == "org-uuid")
    }

    @Test("still maps the snake_case email spelling Claude Code's binary carries")
    func acceptsAlternateEmailSpelling() {
        let account: [String: Any] = ["uuid": "u", "email_address": "alt@example.com"]
        let identity = AccountIdentity.parse(
            oauthAccount: ProfileOracle.normalize(account, root: ["account": account])
        )
        #expect(identity?.email == "alt@example.com")
    }

    @Test("a profile without an account uuid yields no identity")
    func requiresAccountUuid() {
        let account: [String: Any] = ["email": "me@example.com"]
        #expect(
            AccountIdentity.parse(
                oauthAccount: ProfileOracle.normalize(account, root: ["account": account])
            ) == nil
        )
    }
}
