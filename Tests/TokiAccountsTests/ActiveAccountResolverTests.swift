import Testing
import Foundation
@testable import TokiAccounts

private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

private func credential(refresh: String) -> Data {
    Data(#"{"claudeAiOauth":{"accessToken":"a","refreshToken":"\#(refresh)"}}"#.utf8)
}

private func slot(_ uuid: String, refresh: String, previous: String? = nil) -> AccountSlot {
    AccountSlot(
        identity: AccountIdentity(
            accountUuid: uuid, email: nil, displayName: nil,
            organizationName: nil, organizationUuid: nil
        ),
        alias: nil,
        credentialJSON: credential(refresh: refresh),
        previousCredentialJSON: previous.map { credential(refresh: $0) },
        lineage: Lineage.fingerprint(refreshToken: refresh),
        addedAt: t0, lastActiveAt: nil, lastRefreshAt: nil, health: .ok
    )
}

@Suite("ActiveAccountResolver")
struct ActiveAccountResolverTests {

    @Test("matches the slot holding the live lineage")
    func matchesLiveLineage() {
        let slots = [slot("a", refresh: "r-a"), slot("b", refresh: "r-b")]
        #expect(
            ActiveAccountResolver.resolve(liveCredentialJSON: credential(refresh: "r-b"), slots: slots)
                == .slot("b")
        )
    }

    @Test("matches through the previous generation when the slot has moved ahead")
    func matchesPreviousGeneration() {
        // The ancestor case: Toki refreshed the slot forward, so the slot holds the
        // successor and keeps the still-live predecessor as its cushion.
        let slots = [slot("a", refresh: "r-new", previous: "r-old")]
        #expect(
            ActiveAccountResolver.resolve(liveCredentialJSON: credential(refresh: "r-old"), slots: slots)
                == .slot("a")
        )
    }

    @Test("a descendant lineage is matched by the config's account identity")
    func matchesDescendantByConfigIdentity() {
        // Claude Code refreshes on its own schedule, so after a swap the live credential
        // is a generation the slot has never seen. No lineage comparison can reach it;
        // `~/.claude.json` names the signed-in account outright.
        let slots = [slot("a", refresh: "r-1"), slot("b", refresh: "r-b")]
        #expect(
            ActiveAccountResolver.resolve(
                liveCredentialJSON: credential(refresh: "r-2"),
                slots: slots,
                configAccountUuid: "a"
            ) == .slotNeedsAdoption("a")
        )
    }

    @Test("a lineage match beats the config identity")
    func lineageWinsOverConfigIdentity() {
        // The config can lag a swap; the bytes cannot.
        let slots = [slot("a", refresh: "r-a"), slot("b", refresh: "r-b")]
        #expect(
            ActiveAccountResolver.resolve(
                liveCredentialJSON: credential(refresh: "r-b"),
                slots: slots,
                configAccountUuid: "a"
            ) == .slot("b")
        )
    }

    @Test("a config identity naming no stored slot stays unknown")
    func unknownWhenConfigNamesNoStoredSlot() {
        #expect(
            ActiveAccountResolver.resolve(
                liveCredentialJSON: credential(refresh: "stranger"),
                slots: [slot("a", refresh: "r-a")],
                configAccountUuid: "not-stored"
            ) == .unknown
        )
    }

    @Test("a credential belonging to no slot is unknown, not an error")
    func unknownWhenNoMatch() {
        // The user ran /login behind Toki' back. This must be a first-class state:
        // treating it as "slot A is active" would let the refresher burn A's token.
        #expect(
            ActiveAccountResolver.resolve(
                liveCredentialJSON: credential(refresh: "stranger"),
                slots: [slot("a", refresh: "r-a")]
            ) == .unknown
        )
    }

    @Test("no live credential at all resolves to none")
    func noneWhenNoCredential() {
        #expect(ActiveAccountResolver.resolve(liveCredentialJSON: nil, slots: []) == .none)
        #expect(
            ActiveAccountResolver.resolve(liveCredentialJSON: Data("{}".utf8), slots: [])
                == .unknown
        )
    }
}
