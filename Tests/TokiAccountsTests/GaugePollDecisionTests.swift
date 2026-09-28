import Testing
import Foundation
@testable import TokiAccounts

private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

private func credential(expiresAt: Date?) -> Data {
    guard let expiresAt else {
        return Data(#"{"claudeAiOauth":{"accessToken":"a1","refreshToken":"r1"}}"#.utf8)
    }
    let ms = expiresAt.timeIntervalSince1970 * 1000
    return Data(#"{"claudeAiOauth":{"accessToken":"a1","refreshToken":"r1","expiresAt":\#(ms)}}"#.utf8)
}

private func slot(health: AccountHealth, expiresAt: Date?) -> AccountSlot {
    AccountSlot(
        identity: AccountIdentity(
            accountUuid: "uuid-1", email: "a@b.c", displayName: "A",
            organizationName: nil, organizationUuid: nil
        ),
        alias: nil,
        credentialJSON: credential(expiresAt: expiresAt),
        previousCredentialJSON: nil,
        lineage: Lineage.fingerprint(refreshToken: "r1"),
        addedAt: t0, lastActiveAt: nil, lastRefreshAt: nil, health: health
    )
}

@Suite("GaugePollDecision")
struct GaugePollDecisionTests {

    @Test("a healthy account is polled")
    func healthyIsPolled() {
        #expect(GaugePollDecision.decide(
            slot: slot(health: .ok, expiresAt: t0.addingTimeInterval(28_800))
        ) == .poll)
    }

    @Test("a healthy account with an expired token is still polled")
    func healthyButExpiredIsStillPolled() {
        // The poll's own 401-and-force-refresh path is what rescues this one; skipping it
        // here would break the recovery it exists for.
        #expect(GaugePollDecision.decide(
            slot: slot(health: .ok, expiresAt: t0.addingTimeInterval(-3600))
        ) == .poll)
    }

    @Test("an account needing re-auth is not polled")
    func deadLineageIsNotPolled() {
        #expect(GaugePollDecision.decide(
            slot: slot(health: .needsReauth, expiresAt: t0.addingTimeInterval(-3600))
        ) == .skipNeedsReauth)
    }

    @Test("health outranks a token that still looks current")
    func healthOutranksExpiry() {
        // The 2026-08-26 shape: the stored access token's `expiresAt` says nothing about
        // whether the refresh token behind it is still a valid grant.
        #expect(GaugePollDecision.decide(
            slot: slot(health: .needsReauth, expiresAt: t0.addingTimeInterval(28_800))
        ) == .skipNeedsReauth)
    }

    @Test("a credential with no expiry at all does not change the answer")
    func missingExpiryIsIrrelevant() {
        #expect(GaugePollDecision.decide(slot: slot(health: .ok, expiresAt: nil)) == .poll)
        #expect(GaugePollDecision.decide(
            slot: slot(health: .needsReauth, expiresAt: nil)
        ) == .skipNeedsReauth)
    }
}
