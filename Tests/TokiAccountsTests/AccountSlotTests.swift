import Testing
import Foundation
@testable import TokiAccounts

private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

private func credential(access: String, refresh: String) -> Data {
    Data(#"{"claudeAiOauth":{"accessToken":"\#(access)","refreshToken":"\#(refresh)"}}"#.utf8)
}

private func slot(refresh: String = "r1") -> AccountSlot {
    AccountSlot(
        identity: AccountIdentity(
            accountUuid: "uuid-1", email: "a@b.c", displayName: "A",
            organizationName: nil, organizationUuid: nil
        ),
        alias: nil,
        credentialJSON: credential(access: "a1", refresh: refresh),
        previousCredentialJSON: nil,
        lineage: Lineage.fingerprint(refreshToken: refresh),
        addedAt: t0, lastActiveAt: nil, lastRefreshAt: nil, health: .ok
    )
}

@Suite("AccountSlot")
struct AccountSlotTests {

    @Test("identity parses the fields we show and ignores the rest")
    func identityParses() {
        let oauth: [String: Any] = [
            "accountUuid": "uuid-9", "emailAddress": "x@y.z", "displayName": "Xy",
            "organizationName": "Org", "organizationUuid": "org-1",
            "billingType": "max", "hasExtraUsageEnabled": true,
        ]
        let id = AccountIdentity.parse(oauthAccount: oauth)
        #expect(id?.accountUuid == "uuid-9")
        #expect(id?.email == "x@y.z")
        #expect(id?.organizationName == "Org")
    }

    @Test("identity without an accountUuid is not an identity")
    func identityRequiresUuid() {
        #expect(AccountIdentity.parse(oauthAccount: ["emailAddress": "x@y.z"]) == nil)
    }

    @Test("lineage follows the refresh token, not the access token")
    func lineageTracksRefreshToken() {
        let a = Lineage.fingerprint(credentialJSON: credential(access: "a1", refresh: "same"))
        let b = Lineage.fingerprint(credentialJSON: credential(access: "a2", refresh: "same"))
        let c = Lineage.fingerprint(credentialJSON: credential(access: "a1", refresh: "other"))
        #expect(a == b, "an access-token rotation must not look like a new lineage")
        #expect(a != c)
        #expect(Lineage.fingerprint(credentialJSON: Data("{}".utf8)) == nil)
    }

    @Test("replacing a credential with a new lineage keeps one previous generation")
    func replaceKeepsPreviousGeneration() {
        let original = slot(refresh: "r1")
        let replaced = original.replacingCredential(credential(access: "a2", refresh: "r2"), now: t0)
        #expect(replaced.lineage == Lineage.fingerprint(refreshToken: "r2"))
        #expect(replaced.previousCredentialJSON == original.credentialJSON)
    }

    @Test("replacing with the SAME lineage does not consume the recovery cushion")
    func sameLineageDoesNotShiftPrevious() {
        let original = slot(refresh: "r1")
        let replaced = original.replacingCredential(credential(access: "a9", refresh: "r1"), now: t0)
        #expect(replaced.previousCredentialJSON == nil)
        #expect(replaced.credentialJSON == credential(access: "a9", refresh: "r1"))
    }

    @Test("replacing with a credential that carries no refresh token changes nothing")
    func replaceIgnoresTokenlessCredential() {
        // Claude Code empties `claudeAiOauth` on invalid_grant. Storing those bytes would
        // overwrite the slot's only refresh token with nothing and report the account
        // healthy — the recovery path erased by the failure it exists to survive.
        var original = slot(refresh: "r1")
        original.health = .needsReauth
        let wiped = Data(#"{"claudeAiOauth":{"accessToken":"a9"}}"#.utf8)
        #expect(original.replacingCredential(wiped, now: t0) == original)
    }

    @Test("a refresh never disturbs previousCredential")
    func refreshLeavesPreviousAlone() {
        // The cushion exists to survive a bad refresh; rotating it on every refresh
        // would destroy it with the very operation it protects against.
        let original = slot(refresh: "r1")
            .replacingCredential(credential(access: "a2", refresh: "r2"), now: t0)
        let refreshed = original.refreshingCredential(credential(access: "a3", refresh: "r3"), now: t0)
        #expect(refreshed.previousCredentialJSON == original.previousCredentialJSON)
        #expect(refreshed.lineage == Lineage.fingerprint(refreshToken: "r3"))
        #expect(refreshed.lastRefreshAt == t0)
    }

    @Test("round-trips through JSON")
    func codableRoundTrip() throws {
        let s = slot()
        let decoded = try JSONDecoder().decode(AccountSlot.self, from: try JSONEncoder().encode(s))
        #expect(decoded == s)
    }
}
