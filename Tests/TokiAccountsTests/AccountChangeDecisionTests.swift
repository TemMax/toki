import Testing
import TokiModels
@testable import TokiAccounts

@Suite("AccountChangeDecision")
struct AccountChangeDecisionTests {
    @Test("logout invalidates the previously signed-in account")
    func logoutReloads() {
        #expect(AccountChangeDecision.decide(
            newIdentity: nil,
            lastSeenIdentity: UsageAccount(accountUuid: "a", organizationUuid: "org-1"),
            storedUuids: ["a"]
        ) == .reloadOnly)
    }

    @Test("changing organization within the same account invalidates usage")
    func organizationChangeReloads() {
        #expect(AccountChangeDecision.decide(
            newIdentity: UsageAccount(accountUuid: "a", organizationUuid: "org-2"),
            lastSeenIdentity: UsageAccount(accountUuid: "a", organizationUuid: "org-1"),
            storedUuids: []
        ) == .reloadOnly)
    }

    @Test("the same account is ignored — the config is rewritten constantly for other reasons")
    func sameAccountIsIgnored() {
        #expect(
            AccountChangeDecision.decide(newUuid: "a", lastSeenUuid: "a", storedUuids: [])
                == .ignore
        )
    }

    @Test("a token rotation on the same account is ignored — dedup keys on the account, not the token")
    func rotationIsIgnored() {
        // The watcher only ever sees the account uuid; a token change on account "a" leaves
        // the uuid "a", so it must not read as a new account.
        #expect(
            AccountChangeDecision.decide(newUuid: "a", lastSeenUuid: "a", storedUuids: ["a"])
                == .ignore
        )
    }

    @Test("switching to a stored account refreshes but does not offer to save it")
    func storedAccountReloadsOnly() {
        #expect(
            AccountChangeDecision.decide(newUuid: "b", lastSeenUuid: "a", storedUuids: ["a", "b"])
                == .reloadOnly
        )
    }

    @Test("switching to an unstored account offers to save it")
    func unstoredAccountOffersSave() {
        #expect(
            AccountChangeDecision.decide(newUuid: "c", lastSeenUuid: "a", storedUuids: ["a"])
                == .offerSave("c")
        )
    }

    @Test("an unreadable identity is ignored, never mistaken for a change")
    func unreadableIsIgnored() {
        #expect(
            AccountChangeDecision.decide(newUuid: nil, lastSeenUuid: "a", storedUuids: [])
                == .ignore
        )
    }

    @Test("the first account seen from a nil baseline is offered when unstored")
    func firstSeenUnstored() {
        #expect(
            AccountChangeDecision.decide(newUuid: "a", lastSeenUuid: nil, storedUuids: [])
                == .offerSave("a")
        )
    }
}
