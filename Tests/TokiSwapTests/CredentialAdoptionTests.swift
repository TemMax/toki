import Testing
import Foundation
import TokiAccounts
@testable import TokiSwap

// The bug these pin: Toki showed one account as active while Claude Code was signed into
// another, because that account's slot physically held the other account's refresh token.
// The only write that could put it there paired an identity read from `~/.claude.json`
// with bytes read from the Keychain, at a different moment, with no proof the two
// described the same account.

private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

private let accountAUuid = "aaaaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaaa"
private let accountBUuid = "bbbbbbbb-bbbb-4bbb-bbbb-bbbbbbbbbbbb"

/// The access token is derived from the refresh token so the oracle stub can answer
/// "who owns these bytes" from the same string the lineage is built on.
private func credential(_ refresh: String) -> Data {
    Data(#"{"claudeAiOauth":{"accessToken":"at-\#(refresh)","refreshToken":"\#(refresh)"}}"#.utf8)
}

private func identity(_ uuid: String, email: String? = nil) -> AccountIdentity {
    AccountIdentity(
        accountUuid: uuid, email: email, displayName: nil,
        organizationName: nil, organizationUuid: nil
    )
}

private func slot(
    _ uuid: String, refresh: String, previous: String? = nil, alias: String? = nil
) -> AccountSlot {
    AccountSlot(
        identity: identity(uuid),
        alias: alias,
        credentialJSON: credential(refresh),
        previousCredentialJSON: previous.map(credential),
        lineage: Lineage.fingerprint(refreshToken: refresh),
        addedAt: t0, lastActiveAt: nil, lastRefreshAt: nil, health: .ok
    )
}

/// Answers keyed on the access token, so a stub can be given one account's credential and
/// asked about another's without the test having to fake the network.
private final class FakeOracle: ProfileLookup, @unchecked Sendable {
    var owners: [String: AccountIdentity] = [:]
    var failure: Error?
    private(set) var calls: [String] = []

    func owner(ofToken token: String) async throws -> AccountIdentity {
        calls.append(token)
        if let failure { throw failure }
        guard let owner = owners[token] else { throw OracleUnreachable() }
        return owner
    }
}

private struct OracleUnreachable: Error {}

/// Successive `~/.claude.json` reads. The last value repeats, so a one-element stub is a
/// config that never changes; two elements model a swap landing between the two reads.
private final class ConfigStub: @unchecked Sendable {
    private let reads: [AccountIdentity?]
    private(set) var count = 0

    init(_ reads: AccountIdentity?...) { self.reads = reads }

    func next() -> AccountIdentity? {
        defer { count += 1 }
        if count < reads.count { return reads[count] }
        return reads.last ?? nil
    }
}

private func adoption(
    config: ConfigStub, live: Data?, oracle: FakeOracle
) -> CredentialAdoption {
    CredentialAdoption(
        signedInIdentity: { config.next() },
        readLive: { live },
        oracle: oracle,
        now: { t0 }
    )
}

@Suite("CredentialAdoption — adopting the live credential into the slot the config names")
struct CredentialAdoptionAdoptTests {

    @Test("refuses when the profile endpoint says the live credential is another account's")
    func refusesAForeignCredential() async {
        // The reported bug, reproduced: the config still names account A (it lags a swap, or
        // the cached copy does), Claude Code is really signed into accountB and has rotated
        // its refresh token past every generation either slot holds — so nothing matches on
        // bytes and the config is the only thing naming a slot.
        let accountA = slot(accountAUuid, refresh: "accountA-r1")
        let accountB = slot(accountBUuid, refresh: "accountB-r1")
        let live = credential("accountB-r3")
        let oracle = FakeOracle()
        oracle.owners["at-accountB-r3"] = identity(accountBUuid)

        let decision = await adoption(
            config: ConfigStub(identity(accountAUuid)), live: live, oracle: oracle
        ).adoptActive(slots: [accountA, accountB])

        #expect(decision == .refuse(.foreignCredential(slot: accountAUuid, owner: accountBUuid)))
        // The property that matters: nothing was handed back that would put accountB's
        // refresh token into account A's slot.
        #expect(adoptedLineage(decision) == nil)
    }

    @Test("adopts when the profile endpoint confirms the slot owns the rotated credential")
    func adoptsAConfirmedRotation() async throws {
        // The legitimate reason this path exists: the same account, rotated past both stored
        // generations. Nothing here may become collateral damage of the guard.
        let accountA = slot(accountAUuid, refresh: "accountA-r1", alias: "Work")
        let oracle = FakeOracle()
        oracle.owners["at-accountA-r2"] = identity(accountAUuid)

        let decision = await adoption(
            config: ConfigStub(identity(accountAUuid)), live: credential("accountA-r2"), oracle: oracle
        ).adoptActive(slots: [accountA, slot(accountBUuid, refresh: "accountB-r1")])

        guard case let .adopt(adopted) = decision else {
            Issue.record("expected an adoption, got \(decision)")
            return
        }
        #expect(adopted.identity.accountUuid == accountAUuid)
        #expect(adopted.lineage == Lineage.fingerprint(refreshToken: "accountA-r2"))
        #expect(adopted.previousCredentialJSON == credential("accountA-r1"))
        #expect(adopted.alias == "Work")
    }

    @Test("refuses when the config changes between the two reads around the credential")
    func refusesWhenTheConfigMovesUnderTheRead() async {
        // The swap window itself: the credential is written before the config, so a decision
        // that samples them at different moments can pair one account's identity with
        // another's bytes. The sandwich catches it locally, before any network call.
        let oracle = FakeOracle()
        oracle.owners["at-accountB-r3"] = identity(accountBUuid)
        let config = ConfigStub(identity(accountAUuid), identity(accountBUuid))

        let decision = await adoption(
            config: config, live: credential("accountB-r3"), oracle: oracle
        ).adoptActive(slots: [slot(accountAUuid, refresh: "accountA-r1"), slot(accountBUuid, refresh: "accountB-r1")])

        #expect(decision == .refuse(.configUnstable(before: accountAUuid, after: accountBUuid)))
        #expect(oracle.calls.isEmpty)
    }

    @Test("refuses while the live bytes already fingerprint to a different stored slot")
    func refusesOnAContradiction() async {
        // Both accounts are stored and the bytes provably belong to accountB, yet the config
        // names account A. Adopting again is what overwrites account A's cushion and destroys
        // the last copy of its refresh token.
        let accountA = slot(accountAUuid, refresh: "accountA-r1")
        let accountB = slot(accountBUuid, refresh: "accountB-r1")
        let oracle = FakeOracle()

        let decision = await adoption(
            config: ConfigStub(identity(accountAUuid)), live: credential("accountB-r1"), oracle: oracle
        ).adoptActive(slots: [accountA, accountB])

        #expect(decision == .refuse(.contradiction(ActiveAccountContradiction(
            byteMatchedUuid: accountBUuid, configNamedUuid: accountAUuid
        ))))
        #expect(oracle.calls.isEmpty)
    }

    @Test("an unreachable profile endpoint refuses rather than adopting on faith")
    func refusesWhenOwnershipCannotBeProven() async {
        let oracle = FakeOracle()
        oracle.failure = OracleUnreachable()

        let decision = await adoption(
            config: ConfigStub(identity(accountAUuid)), live: credential("accountA-r2"), oracle: oracle
        ).adoptActive(slots: [slot(accountAUuid, refresh: "accountA-r1")])

        #expect(decision == .refuse(.ownerUnconfirmed))
    }

    @Test("no network round trip when the bytes already match their slot")
    func staysLocalWhenThereIsNothingToAdopt() async {
        let oracle = FakeOracle()

        let decision = await adoption(
            config: ConfigStub(identity(accountAUuid)), live: credential("accountA-r1"), oracle: oracle
        ).adoptActive(slots: [slot(accountAUuid, refresh: "accountA-r1")])

        #expect(decision == .refuse(.nothingToAdopt))
        #expect(oracle.calls.isEmpty)
    }

    @Test("no credential, no decision")
    func refusesWithoutLiveBytes() async {
        let decision = await adoption(
            config: ConfigStub(identity(accountAUuid)), live: nil, oracle: FakeOracle()
        ).adoptActive(slots: [slot(accountAUuid, refresh: "accountA-r1")])

        #expect(decision == .refuse(.noLiveCredential))
    }

    private func adoptedLineage(_ decision: AdoptionDecision) -> String? {
        if case let .adopt(slot) = decision { return slot.lineage }
        return nil
    }
}

@Suite("CredentialAdoption — capturing the account Claude Code is signed into")
struct CredentialAdoptionCaptureTests {

    @Test("refuses to file the live credential under an account that does not own it")
    func refusesToCaptureAForeignCredential() async {
        // "Add current account" clicked inside a swap window: the config still names
        // account A while the Keychain already holds accountB's credential. The old capture
        // built a account A slot around those bytes and saved it.
        let oracle = FakeOracle()
        oracle.owners["at-accountB-r3"] = identity(accountBUuid)
        let subject = adoption(
            config: ConfigStub(identity(accountAUuid)), live: credential("accountB-r3"), oracle: oracle
        )

        await #expect(throws: AdoptionRefusal.foreignCredential(slot: accountAUuid, owner: accountBUuid)) {
            try await subject.captureCurrent(slots: [])
        }
    }

    @Test("refuses when the live bytes belong to a slot other than the one being captured")
    func refusesWhenTheBytesBelongToAnotherStoredSlot() async {
        // Purely local: accountB is stored and its lineage matches the live bytes, so no
        // network is needed to know the config's name for them is wrong.
        let oracle = FakeOracle()
        let subject = adoption(
            config: ConfigStub(identity(accountAUuid)), live: credential("accountB-r1"), oracle: oracle
        )

        await #expect(throws: AdoptionRefusal.foreignCredential(slot: accountAUuid, owner: accountBUuid)) {
            try await subject.captureCurrent(slots: [slot(accountBUuid, refresh: "accountB-r1")])
        }
        #expect(oracle.calls.isEmpty)
    }

    @Test("re-capturing a stored account keeps its recovery cushion and alias")
    func mergesIntoTheExistingSlot() async throws {
        // The old capture saved a brand-new slot with `previousCredentialJSON: nil`, so
        // re-adding an account silently threw away the one prior generation standing
        // between a failed refresh and a forced /login.
        let oracle = FakeOracle()
        oracle.owners["at-accountA-r2"] = identity(accountAUuid)
        let stored = slot(accountAUuid, refresh: "accountA-r1", alias: "Work")

        let captured = try await adoption(
            config: ConfigStub(identity(accountAUuid, email: "account-a@example.com")),
            live: credential("accountA-r2"),
            oracle: oracle
        ).captureCurrent(slots: [stored])

        #expect(captured.identity.accountUuid == accountAUuid)
        #expect(captured.identity.email == "account-a@example.com")
        #expect(captured.alias == "Work")
        #expect(captured.previousCredentialJSON == credential("accountA-r1"))
        #expect(captured.lineage == Lineage.fingerprint(refreshToken: "accountA-r2"))
        #expect(captured.addedAt == t0)
    }

    @Test("captures a first-time account the endpoint confirms")
    func capturesAConfirmedNewAccount() async throws {
        let oracle = FakeOracle()
        oracle.owners["at-accountA-r1"] = identity(accountAUuid)

        let captured = try await adoption(
            config: ConfigStub(identity(accountAUuid)), live: credential("accountA-r1"), oracle: oracle
        ).captureCurrent(slots: [slot(accountBUuid, refresh: "accountB-r1")])

        #expect(captured.identity.accountUuid == accountAUuid)
        #expect(captured.credentialJSON == credential("accountA-r1"))
        #expect(captured.previousCredentialJSON == nil)
    }

    @Test("refuses when the config moves under the credential read")
    func refusesOnAnUnstableConfig() async {
        let subject = adoption(
            config: ConfigStub(identity(accountAUuid), identity(accountBUuid)),
            live: credential("accountB-r3"),
            oracle: FakeOracle()
        )

        await #expect(
            throws: AdoptionRefusal.configUnstable(before: accountAUuid, after: accountBUuid)
        ) {
            try await subject.captureCurrent(slots: [])
        }
    }

    @Test("refuses when ownership cannot be proven")
    func refusesWhenTheOracleIsUnreachable() async {
        let oracle = FakeOracle()
        oracle.failure = OracleUnreachable()
        let subject = adoption(
            config: ConfigStub(identity(accountAUuid)), live: credential("accountA-r1"), oracle: oracle
        )

        await #expect(throws: AdoptionRefusal.ownerUnconfirmed) {
            try await subject.captureCurrent(slots: [])
        }
    }

    @Test("refuses when Claude Code is not signed in")
    func refusesWithoutAConfigIdentity() async {
        let subject = adoption(
            config: ConfigStub(nil), live: credential("accountA-r1"), oracle: FakeOracle()
        )

        await #expect(throws: AdoptionRefusal.notSignedIn) {
            try await subject.captureCurrent(slots: [])
        }
    }
}
