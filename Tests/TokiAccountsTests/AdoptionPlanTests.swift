import Testing
import Foundation
@testable import TokiAccounts

private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

private func credential(refresh: String?, access: String = "at") -> Data {
    guard let refresh else {
        return Data(#"{"claudeAiOauth":{"accessToken":"\#(access)"}}"#.utf8)
    }
    return Data(#"{"claudeAiOauth":{"accessToken":"\#(access)","refreshToken":"\#(refresh)"}}"#.utf8)
}

private func slot(_ uuid: String, refresh: String) -> AccountSlot {
    AccountSlot(
        identity: AccountIdentity(
            accountUuid: uuid, email: "\(uuid)@example.com", displayName: nil,
            organizationName: nil, organizationUuid: nil
        ),
        alias: nil,
        credentialJSON: credential(refresh: refresh),
        previousCredentialJSON: nil,
        lineage: Lineage.fingerprint(refreshToken: refresh),
        addedAt: t0, lastActiveAt: nil, lastRefreshAt: nil, health: .ok
    )
}

@Suite("AdoptionPlan")
struct AdoptionPlanTests {

    @Test("an adoption-pending slot is the active account")
    func adoptionPendingCountsAsActive() {
        #expect(AdoptionPlan.activeSlotUuid(.slot("a")) == "a")
        // Until this returned "a", the account the config names read as sleeping: the row
        // showed no active marker and the auto-swap policy saw no active account at all.
        #expect(AdoptionPlan.activeSlotUuid(.slotNeedsAdoption("a")) == "a")
        #expect(AdoptionPlan.activeSlotUuid(.unknown) == nil)
        #expect(AdoptionPlan.activeSlotUuid(.none) == nil)
    }

    @Test("adoption moves the named slot's lineage onto the live credential")
    func adoptsLiveCredential() {
        let stored = slot("a", refresh: "r-1")
        let live = credential(refresh: "r-2")
        let adopted = AdoptionPlan.adoptedActiveSlot(
            active: .slotNeedsAdoption("a"), slots: [stored, slot("b", refresh: "r-b")],
            liveCredentialJSON: live, now: t0
        )
        #expect(adopted?.identity.accountUuid == "a")
        #expect(adopted?.lineage == Lineage.fingerprint(refreshToken: "r-2"))
        #expect(adopted?.credentialJSON == live)
        // The generation the slot held becomes the recovery cushion, and the resolver then
        // matches this slot on bytes again from either side.
        #expect(adopted?.previousCredentialJSON == stored.credentialJSON)
        #expect(adopted?.lastActiveAt == t0)
    }

    @Test("nothing is adopted for any other resolution")
    func onlyAdoptsWhenAsked() {
        let stored = [slot("a", refresh: "r-1")]
        let live = credential(refresh: "r-2")
        for active: ActiveAccount in [.slot("a"), .unknown, .none] {
            #expect(AdoptionPlan.adoptedActiveSlot(
                active: active, slots: stored, liveCredentialJSON: live, now: t0
            ) == nil)
        }
        // A slot that is no longer stored, and bytes with no live credential at all.
        #expect(AdoptionPlan.adoptedActiveSlot(
            active: .slotNeedsAdoption("gone"), slots: stored, liveCredentialJSON: live, now: t0
        ) == nil)
        #expect(AdoptionPlan.adoptedActiveSlot(
            active: .slotNeedsAdoption("a"), slots: stored, liveCredentialJSON: nil, now: t0
        ) == nil)
    }

    @Test("a wiped live credential is never adopted")
    func refusesWipedCredential() {
        // Claude Code empties the credential on `invalid_grant`. Adopting those bytes would
        // destroy the slot's only refresh token and mark it healthy while doing so.
        #expect(AdoptionPlan.adoptedActiveSlot(
            active: .slotNeedsAdoption("a"), slots: [slot("a", refresh: "r-1")],
            liveCredentialJSON: credential(refresh: nil), now: t0
        ) == nil)
    }

    @Test("a quarantined credential is adopted without the profile endpoint")
    func adoptsQuarantineWithoutOracle() {
        let entry = QuarantineEntry(
            id: "abc123", credentialJSON: credential(refresh: "r-q"),
            foundAt: t0, ownerLabel: "someone@example.com"
        )
        // The oracle answers on the ACCESS token, which has almost always expired by the
        // time the user clicks Add — requiring it left the only recovery path closed.
        let adopted = AdoptionPlan.adoptedQuarantineSlot(entry: entry, confirmed: nil, now: t0)
        #expect(adopted?.identity.accountUuid == "abc123")
        #expect(adopted?.displayLabel == "someone@example.com")
        #expect(adopted?.credentialJSON == entry.credentialJSON)
        #expect(adopted?.lineage == Lineage.fingerprint(refreshToken: "r-q"))
        #expect(adopted?.lastActiveAt == t0)
        #expect(adopted?.health == .ok)
    }

    @Test("a confirmed identity wins over the entry's provisional one")
    func confirmedIdentityWins() {
        let entry = QuarantineEntry(
            id: "abc123", credentialJSON: credential(refresh: "r-q"),
            foundAt: t0, ownerLabel: "stale@example.com"
        )
        let confirmed = AccountIdentity(
            accountUuid: "real-uuid", email: "real@example.com", displayName: nil,
            organizationName: nil, organizationUuid: nil
        )
        let adopted = AdoptionPlan.adoptedQuarantineSlot(
            entry: entry, confirmed: confirmed, now: t0
        )
        #expect(adopted?.identity.accountUuid == "real-uuid")
        #expect(adopted?.displayLabel == "real@example.com")
    }

    @Test("a quarantined credential with no refresh token is not adoptable")
    func refusesTokenlessQuarantineEntry() {
        let entry = QuarantineEntry(
            id: "abc123", credentialJSON: credential(refresh: nil), foundAt: t0, ownerLabel: nil
        )
        #expect(AdoptionPlan.adoptedQuarantineSlot(entry: entry, confirmed: nil, now: t0) == nil)
    }
}

@Suite("liveUnstoredIdentity")
struct LiveUnstoredIdentityTests {
    private func identity(_ uuid: String) -> AccountIdentity {
        AccountIdentity(
            accountUuid: uuid, email: "\(uuid)@example.com", displayName: nil,
            organizationName: nil, organizationUuid: nil
        )
    }

    @Test("the signed-in account is surfaced when Toki has stored nothing")
    func surfacedWhenNothingStored() {
        // The exact first-run complaint: signed in, but the Accounts tab shows nobody.
        let result = AdoptionPlan.liveUnstoredIdentity(configIdentity: identity("live"), slots: [])
        #expect(result?.accountUuid == "live")
    }

    @Test("the signed-in account is surfaced alongside unrelated stored accounts")
    func surfacedAlongsideStored() {
        let result = AdoptionPlan.liveUnstoredIdentity(
            configIdentity: identity("live"), slots: [slot("other", refresh: "r")]
        )
        #expect(result?.accountUuid == "live")
    }

    @Test("a stored account is not doubled — its slot row already represents it")
    func notDoubledWhenStored() {
        let result = AdoptionPlan.liveUnstoredIdentity(
            configIdentity: identity("live"), slots: [slot("live", refresh: "r")]
        )
        #expect(result == nil)
    }

    @Test("no config identity means nothing extra to show")
    func nilWhenNoConfigIdentity() {
        #expect(AdoptionPlan.liveUnstoredIdentity(configIdentity: nil, slots: []) == nil)
    }
}
