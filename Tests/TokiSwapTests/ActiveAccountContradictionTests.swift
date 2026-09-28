import Testing
import Foundation
import TokiAccounts
@testable import TokiSwap

// `ActiveAccountResolver.contradiction` and `AdoptionPlan.adoptedActiveSlot` live in
// TokiAccounts, but they are exercised here, alongside `CredentialAdoption` — the guarded
// caller that consumes both. TokiAccountsTests reaches the real Keychain (SlotStore), so a
// suite kept there could not be run on its own.

private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

private let accountAUuid = "aaaaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaaa"
private let accountBUuid = "bbbbbbbb-bbbb-4bbb-bbbb-bbbbbbbbbbbb"

private func credential(_ refresh: String) -> Data {
    Data(#"{"claudeAiOauth":{"accessToken":"at-\#(refresh)","refreshToken":"\#(refresh)"}}"#.utf8)
}

private func slot(_ uuid: String, refresh: String, previous: String? = nil) -> AccountSlot {
    AccountSlot(
        identity: AccountIdentity(
            accountUuid: uuid, email: nil, displayName: nil,
            organizationName: nil, organizationUuid: nil
        ),
        alias: nil,
        credentialJSON: credential(refresh),
        previousCredentialJSON: previous.map(credential),
        lineage: Lineage.fingerprint(refreshToken: refresh),
        addedAt: t0, lastActiveAt: nil, lastRefreshAt: nil, health: .ok
    )
}

@Suite("ActiveAccountResolver — the config-versus-bytes contradiction")
struct ActiveAccountContradictionTests {

    @Test("two stored slots claiming the live credential is a contradiction")
    func detectsTwoClaimants() {
        let contradiction = ActiveAccountResolver.contradiction(
            liveCredentialJSON: credential("accountB-r1"),
            slots: [slot(accountAUuid, refresh: "accountA-r1"), slot(accountBUuid, refresh: "accountB-r1")],
            configAccountUuid: accountAUuid
        )

        #expect(contradiction == ActiveAccountContradiction(
            byteMatchedUuid: accountBUuid, configNamedUuid: accountAUuid
        ))
    }

    @Test("a slot claimed through its recovery cushion counts too")
    func detectsThroughTheCushion() {
        // The cushion is a real generation of that account's lineage, so bytes matching it
        // identify the owner just as surely as the current one.
        let accountB = slot(accountBUuid, refresh: "accountB-r2", previous: "accountB-r1")

        let contradiction = ActiveAccountResolver.contradiction(
            liveCredentialJSON: credential("accountB-r1"),
            slots: [slot(accountAUuid, refresh: "accountA-r1"), accountB],
            configAccountUuid: accountAUuid
        )

        #expect(contradiction?.byteMatchedUuid == accountBUuid)
    }

    @Test("no contradiction when the config names the slot the bytes match")
    func agreementIsNotAContradiction() {
        #expect(ActiveAccountResolver.contradiction(
            liveCredentialJSON: credential("accountA-r1"),
            slots: [slot(accountAUuid, refresh: "accountA-r1")],
            configAccountUuid: accountAUuid
        ) == nil)
    }

    @Test("no contradiction when the bytes match no stored slot")
    func rotationIsNotAContradiction() {
        // The ordinary reason adoption exists: Claude Code rotated past every stored
        // generation. Nothing disagrees — nothing is known.
        #expect(ActiveAccountResolver.contradiction(
            liveCredentialJSON: credential("accountA-r7"),
            slots: [slot(accountAUuid, refresh: "accountA-r1")],
            configAccountUuid: accountAUuid
        ) == nil)
    }

    @Test("no contradiction when the config names an account Toki does not store")
    func anUnstoredConfigAccountIsNotAContradiction() {
        #expect(ActiveAccountResolver.contradiction(
            liveCredentialJSON: credential("accountA-r1"),
            slots: [slot(accountAUuid, refresh: "accountA-r1")],
            configAccountUuid: "an-account-toki-has-never-seen"
        ) == nil)
    }

    @Test("the display rule is unchanged: the byte-matched slot still resolves as active")
    func resolveStillLetsTheBytesWin() {
        // A swap in flight produces this exact shape for a few hundred milliseconds, so the
        // contradiction must stay a detector and never turn `resolve` into an error state.
        let active = ActiveAccountResolver.resolve(
            liveCredentialJSON: credential("accountB-r1"),
            slots: [slot(accountAUuid, refresh: "accountA-r1"), slot(accountBUuid, refresh: "accountB-r1")],
            configAccountUuid: accountAUuid
        )

        #expect(active == .slot(accountBUuid))
    }
}

@Suite("AdoptionPlan — the local half of the write veto")
struct AdoptionPlanVetoTests {

    @Test("refuses to adopt bytes that fingerprint to a different stored slot")
    func refusesToPoisonASlot() {
        // `active` is an input the caller resolved earlier — here from a config read that
        // the bytes now contradict. Without the veto this returns account A's slot carrying
        // accountB's refresh token, and from then on the resolver byte-matches account A first
        // and reports the wrong account as active forever.
        let accountA = slot(accountAUuid, refresh: "accountA-r1")
        let accountB = slot(accountBUuid, refresh: "accountB-r1")

        let adopted = AdoptionPlan.adoptedActiveSlot(
            active: .slotNeedsAdoption(accountAUuid),
            slots: [accountA, accountB],
            liveCredentialJSON: credential("accountB-r1"),
            now: t0
        )

        #expect(adopted == nil)
    }

    @Test("still adopts the ordinary rotation it exists for")
    func adoptsARotation() throws {
        let accountA = slot(accountAUuid, refresh: "accountA-r1")

        let adopted = try #require(AdoptionPlan.adoptedActiveSlot(
            active: .slotNeedsAdoption(accountAUuid),
            slots: [accountA, slot(accountBUuid, refresh: "accountB-r1")],
            liveCredentialJSON: credential("accountA-r2"),
            now: t0
        ))

        #expect(adopted.identity.accountUuid == accountAUuid)
        #expect(adopted.lineage == Lineage.fingerprint(refreshToken: "accountA-r2"))
        #expect(adopted.previousCredentialJSON == credential("accountA-r1"))
    }
}
