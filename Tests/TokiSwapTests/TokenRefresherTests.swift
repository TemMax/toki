import Testing
import Foundation
import TokiAccounts
import TokiModels
@testable import TokiSwap

private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

private func credential(refresh: String, expiresIn: TimeInterval) -> Data {
    let ms = (t0.timeIntervalSince1970 + expiresIn) * 1000
    return Data(#"{"claudeAiOauth":{"accessToken":"a","refreshToken":"\#(refresh)","expiresAt":\#(ms)}}"#.utf8)
}

private func slot(refresh: String, expiresIn: TimeInterval, previous: String? = nil) -> AccountSlot {
    AccountSlot(
        identity: AccountIdentity(
            accountUuid: "uuid-1", email: nil, displayName: nil,
            organizationName: nil, organizationUuid: nil
        ),
        alias: nil,
        credentialJSON: credential(refresh: refresh, expiresIn: expiresIn),
        previousCredentialJSON: previous.map { credential(refresh: $0, expiresIn: 3600) },
        lineage: Lineage.fingerprint(refreshToken: refresh),
        addedAt: t0, lastActiveAt: nil, lastRefreshAt: nil, health: .ok
    )
}

private final class FakeEndpoint: TokenEndpoint, @unchecked Sendable {
    var result: Result<Data, Error> = .success(credential(refresh: "r-next", expiresIn: 28_800))
    private(set) var calls: [String] = []
    func refresh(refreshToken: String) async throws -> Data {
        calls.append(refreshToken)
        return try result.get()
    }
}

private struct StubStoreFailure: Error, Equatable {}

private final class RecordingStore: SlotStoring, @unchecked Sendable {
    var saved: [AccountSlot] = []
    /// Injected so tests can exercise the `try?`-shaped failure paths (F41) — a store
    /// that can never throw asserts nothing about what happens when persistence fails.
    var saveError: Error?
    /// Fails the next N saves and then behaves normally. Distinct from `saveError`, which
    /// fails every save: only a store that recovers can tell "the write was retried" apart
    /// from "the write was attempted once and happened to succeed".
    var saveFailuresRemaining = 0
    private(set) var saveAttempts = 0
    func loadAll() throws -> [AccountSlot] { saved }
    func load(accountUuid: String) throws -> AccountSlot? {
        saved.last { $0.identity.accountUuid == accountUuid }
    }
    func save(_ slot: AccountSlot) throws {
        saveAttempts += 1
        if saveFailuresRemaining > 0 {
            saveFailuresRemaining -= 1
            throw StubStoreFailure()
        }
        if let saveError { throw saveError }
        saved.append(slot)
    }
    func delete(accountUuid: String) throws {}
    func loadQuarantine() throws -> [QuarantineEntry] { [] }
    func saveQuarantine(_ entry: QuarantineEntry, now: Date) throws {}
    func deleteQuarantine(id: String) throws {}
}

@Suite("TokenRefresher")
struct TokenRefresherTests {

    @Test("the account Claude Code is using is NEVER refreshed")
    func neverRefreshesTheActiveAccount() async {
        // Rotating Claude Code's own single-use refresh token would leave the CLI holding
        // a dead credential and force the user to /login — the exact disaster this feature
        // exists to prevent.
        let endpoint = FakeEndpoint()
        let store = RecordingStore()
        let refresher = TokenRefresher(endpoint: endpoint, store: store, now: { t0 })
        let active = slot(refresh: "r-live", expiresIn: 60)

        let outcome = await refresher.refreshIfNeeded(
            slot: active, activeLineage: Lineage.fingerprint(refreshToken: "r-live")
        )

        #expect(outcome == .skipped)
        #expect(endpoint.calls.isEmpty)
        #expect(store.saved.isEmpty)
    }

    @Test("an unknown active account means refresh NOTHING")
    func refreshesNothingWhenTheActiveAccountIsUnknown() async {
        // The live-credential read fails routinely (a silent Keychain read that returns
        // nothing). Refreshing on that basis can rotate the account Claude Code is signed
        // into, which is the one outcome the feature must never produce.
        let endpoint = FakeEndpoint()
        let store = RecordingStore()
        let refresher = TokenRefresher(endpoint: endpoint, store: store, now: { t0 })

        let outcome = await refresher.refreshIfNeeded(
            slot: slot(refresh: "r-live", expiresIn: 60), activeLineage: nil
        )

        #expect(outcome == .skipped)
        #expect(endpoint.calls.isEmpty)
        #expect(store.saved.isEmpty)
    }

    @Test("a slot whose recovery cushion is the live credential is never refreshed")
    func neverRefreshesTheSlotHoldingTheLiveCushion() async {
        // Toki refreshed this slot forward while Claude Code still holds the older
        // generation, so the resolver reports the slot as active — the refresher has to
        // agree, or it rotates the live account's lineage out from under the CLI.
        let endpoint = FakeEndpoint()
        let store = RecordingStore()
        let refresher = TokenRefresher(endpoint: endpoint, store: store, now: { t0 })

        let outcome = await refresher.refreshIfNeeded(
            slot: slot(refresh: "r-new", expiresIn: 60, previous: "r-live"),
            activeLineage: Lineage.fingerprint(refreshToken: "r-live")
        )

        #expect(outcome == .skipped)
        #expect(endpoint.calls.isEmpty)
        #expect(store.saved.isEmpty)
    }

    @Test("the account the config names is never refreshed, even when no lineage matches")
    func neverRefreshesTheConfigNamedAccount() async {
        // While the live credential has rotated past every stored generation — or while
        // adoption is being refused because ownership could not be proven — `activeLineage`
        // matches nothing, and `~/.claude.json` is the only thing still naming the live
        // account. Refreshing that slot spends an older generation of the LIVE lineage.
        let endpoint = FakeEndpoint()
        let store = RecordingStore()
        let refresher = TokenRefresher(endpoint: endpoint, store: store, now: { t0 })

        let outcome = await refresher.refreshIfNeeded(
            slot: slot(refresh: "r-old", expiresIn: 60),
            activeLineage: Lineage.fingerprint(refreshToken: "r-rotated-past-everything"),
            activeAccountUuid: "uuid-1"
        )

        #expect(outcome == .skipped)
        #expect(endpoint.calls.isEmpty)
        #expect(store.saved.isEmpty)
    }

    @Test("a sleeping token far from expiry is left alone")
    func skipsHealthySleepingToken() async {
        let endpoint = FakeEndpoint()
        let refresher = TokenRefresher(endpoint: endpoint, store: RecordingStore(), now: { t0 })
        let outcome = await refresher.refreshIfNeeded(
            slot: slot(refresh: "r1", expiresIn: 7200), activeLineage: "other"
        )
        #expect(outcome == .skipped)
        #expect(endpoint.calls.isEmpty)
    }

    @Test("a sleeping token near expiry is refreshed and persisted immediately")
    func refreshesAndPersists() async {
        let endpoint = FakeEndpoint()
        let store = RecordingStore()
        let refresher = TokenRefresher(endpoint: endpoint, store: store, now: { t0 })

        let outcome = await refresher.refreshIfNeeded(
            slot: slot(refresh: "r1", expiresIn: 120), activeLineage: "other"
        )

        #expect(endpoint.calls == ["r1"])
        guard case let .refreshed(updated) = outcome else {
            Issue.record("expected .refreshed, got \(outcome)")
            return
        }
        #expect(updated.lineage == Lineage.fingerprint(refreshToken: "r-next"))
        // The grant already consumed a generation; not storing the successor kills the
        // lineage, so persistence must happen before anything else can fail.
        #expect(store.saved.count == 1)
        #expect(store.saved.first?.lineage == updated.lineage)
    }

    @Test("a refresh leaves the recovery cushion untouched")
    func refreshDoesNotShiftPreviousCredential() async {
        let endpoint = FakeEndpoint()
        let refresher = TokenRefresher(endpoint: endpoint, store: RecordingStore(), now: { t0 })
        let original = slot(refresh: "r1", expiresIn: 120, previous: "r0")

        guard case let .refreshed(updated) = await refresher.refreshIfNeeded(
            slot: original, activeLineage: "other"
        ) else {
            Issue.record("expected .refreshed")
            return
        }
        #expect(updated.previousCredentialJSON == original.previousCredentialJSON)
    }

    @Test("a successor that fails to persist is never reported as refreshed")
    func failedSaveIsNotReportedAsSuccess() async {
        // The grant is already spent by the endpoint call above this — if the successor
        // never makes it into the store, the lineage is dead and the only copy of the new
        // refresh token lived in memory for one tick. Reporting `.refreshed` here would
        // hide that from every caller.
        let endpoint = FakeEndpoint()
        let store = RecordingStore()
        store.saveError = StubStoreFailure()
        let refresher = TokenRefresher(endpoint: endpoint, store: store, now: { t0 })

        let outcome = await refresher.refreshIfNeeded(
            slot: slot(refresh: "r1", expiresIn: 120), activeLineage: "other"
        )

        guard case let .persistenceFailed(flagged) = outcome else {
            Issue.record("expected .persistenceFailed, got \(outcome)")
            return
        }
        // The failed generation never landed in the store — nothing to retry against.
        #expect(store.saved.isEmpty)
        // The slot carries the new (unsaved) credential and is flagged for attention so
        // the UI can tell the user this account needs to be looked at.
        #expect(flagged.lineage == Lineage.fingerprint(refreshToken: "r-next"))
        #expect(flagged.health == .needsReauth)
    }

    @Test("invalid_grant marks the lineage dead; a 500 does not")
    func classifiesFailures() async {
        let endpoint = FakeEndpoint()
        let store = RecordingStore()
        let refresher = TokenRefresher(endpoint: endpoint, store: store, now: { t0 })

        endpoint.result = .failure(TokenEndpointError.permanent("invalid_grant"))
        guard case let .deadLineage(dead) = await refresher.refreshIfNeeded(
            slot: slot(refresh: "r1", expiresIn: 120), activeLineage: "other"
        ) else {
            Issue.record("expected .deadLineage")
            return
        }
        #expect(dead.health == .needsReauth)
        #expect(store.saved.last?.health == .needsReauth)

        endpoint.result = .failure(TokiError.httpError(500))
        let transient = await refresher.refreshIfNeeded(
            slot: slot(refresh: "r2", expiresIn: 120), activeLineage: "other"
        )
        #expect(transient == .transientFailure)
    }

    @Test("force refreshes a slot far from expiry; without force the same slot is skipped")
    func forceBypassesOnlyTheExpiryWindow() async {
        // The motivating case: a usage poll already got a 401 while `expiresAt` still
        // claims plenty of validity — the expiry window is stale information here, so
        // `force` must be the only thing that overrides it.
        let endpoint = FakeEndpoint()
        let store = RecordingStore()
        let refresher = TokenRefresher(endpoint: endpoint, store: store, now: { t0 })
        let farFromExpiry = slot(refresh: "r1", expiresIn: 7200)

        let forced = await refresher.refreshIfNeeded(
            slot: farFromExpiry, activeLineage: "other", force: true
        )
        guard case .refreshed = forced else {
            Issue.record("expected .refreshed, got \(forced)")
            return
        }
        #expect(endpoint.calls == ["r1"])

        let defaulted = await refresher.refreshIfNeeded(
            slot: farFromExpiry, activeLineage: "other"
        )
        #expect(defaulted == .skipped)
        #expect(endpoint.calls == ["r1"])
    }

    @Test("force does not bypass the nil-activeLineage guard")
    func forceDoesNotBypassUnknownActiveLineage() async {
        let endpoint = FakeEndpoint()
        let store = RecordingStore()
        let refresher = TokenRefresher(endpoint: endpoint, store: store, now: { t0 })

        let outcome = await refresher.refreshIfNeeded(
            slot: slot(refresh: "r1", expiresIn: 7200), activeLineage: nil, force: true
        )

        #expect(outcome == .skipped)
        #expect(endpoint.calls.isEmpty)
        #expect(store.saved.isEmpty)
    }

    @Test("force does not bypass the lineage-equality guard")
    func forceDoesNotBypassLineageEquality() async {
        let endpoint = FakeEndpoint()
        let store = RecordingStore()
        let refresher = TokenRefresher(endpoint: endpoint, store: store, now: { t0 })
        let active = slot(refresh: "r-live", expiresIn: 7200)

        let outcome = await refresher.refreshIfNeeded(
            slot: active,
            activeLineage: Lineage.fingerprint(refreshToken: "r-live"),
            force: true
        )

        #expect(outcome == .skipped)
        #expect(endpoint.calls.isEmpty)
        #expect(store.saved.isEmpty)
    }

    @Test("force does not bypass the health guard")
    func forceDoesNotBypassHealthGuard() async {
        let endpoint = FakeEndpoint()
        let store = RecordingStore()
        let refresher = TokenRefresher(endpoint: endpoint, store: store, now: { t0 })
        var unhealthy = slot(refresh: "r1", expiresIn: 7200)
        unhealthy.health = .needsReauth

        let outcome = await refresher.refreshIfNeeded(
            slot: unhealthy, activeLineage: "other", force: true
        )

        #expect(outcome == .skipped)
        #expect(endpoint.calls.isEmpty)
        #expect(store.saved.isEmpty)
    }
}

/// Swap-in hands the target to Claude Code for a whole session, so the question is not
/// "is this about to expire" but "how much lifetime does Claude Code get". These tests
/// pin the difference between the two entry points, and pin that only the expiry window
/// is what `freshenForActivation` skips.
@Suite("TokenRefresher freshenForActivation")
struct TokenRefresherActivationTests {

    @Test("activation renews a token that is nowhere near expiry, where the gauge poll would not")
    func renewsAHealthyTokenTheGaugePollWouldSkip() async {
        let endpoint = FakeEndpoint()
        let store = RecordingStore()
        let refresher = TokenRefresher(endpoint: endpoint, store: store, now: { t0 })
        // Eight hours of life left: far outside the 600 s freshen window, which is exactly
        // the case that handed Claude Code a five-hour-old token on 2026-08-26.
        let target = slot(refresh: "r-target", expiresIn: 28_800)

        let polled = await refresher.refreshIfNeeded(slot: target, activeLineage: "live")
        #expect(polled == .skipped)
        #expect(endpoint.calls.isEmpty)

        let activated = await refresher.freshenForActivation(slot: target, activeLineage: "live")
        guard case let .refreshed(updated) = activated else {
            Issue.record("expected a refreshed slot, got \(activated)")
            return
        }
        #expect(endpoint.calls == ["r-target"])
        #expect(updated.lineage == Lineage.fingerprint(refreshToken: "r-next"))
        #expect(store.saved.count == 1)
    }

    @Test("activation still refuses to touch the live lineage")
    func neverRefreshesTheLiveLineage() async {
        let endpoint = FakeEndpoint()
        let refresher = TokenRefresher(endpoint: endpoint, store: RecordingStore(), now: { t0 })
        let live = slot(refresh: "r-live", expiresIn: 28_800)

        let outcome = await refresher.freshenForActivation(
            slot: live, activeLineage: Lineage.fingerprint(refreshToken: "r-live")
        )

        #expect(outcome == .skipped)
        #expect(endpoint.calls.isEmpty)
    }

    @Test("activation still refuses when no live lineage is known")
    func refusesWhenTheLiveCredentialIsUnreadable() async {
        // Restoring a stored account after a `/logout`: nothing live to compare against,
        // so nothing is renewed and the stored bytes are activated as before.
        let endpoint = FakeEndpoint()
        let refresher = TokenRefresher(endpoint: endpoint, store: RecordingStore(), now: { t0 })

        let outcome = await refresher.freshenForActivation(
            slot: slot(refresh: "r-target", expiresIn: 28_800), activeLineage: nil
        )

        #expect(outcome == .skipped)
        #expect(endpoint.calls.isEmpty)
    }

    @Test("activation still refuses to spend the recovery cushion's lineage")
    func refusesWhenTheCushionIsTheLiveOne() async {
        let endpoint = FakeEndpoint()
        let refresher = TokenRefresher(endpoint: endpoint, store: RecordingStore(), now: { t0 })
        let target = slot(refresh: "r-target", expiresIn: 28_800, previous: "r-cushion")

        let outcome = await refresher.freshenForActivation(
            slot: target, activeLineage: Lineage.fingerprint(refreshToken: "r-cushion")
        )

        #expect(outcome == .skipped)
        #expect(endpoint.calls.isEmpty)
    }

    @Test("a dead grant at activation is reported, so the swap can refuse to activate it")
    func reportsADeadGrant() async {
        let endpoint = FakeEndpoint()
        endpoint.result = .failure(TokenEndpointError.permanent("invalid_grant"))
        let refresher = TokenRefresher(endpoint: endpoint, store: RecordingStore(), now: { t0 })

        let outcome = await refresher.freshenForActivation(
            slot: slot(refresh: "r-target", expiresIn: 28_800), activeLineage: "live"
        )

        guard case let .deadLineage(dead) = outcome else {
            Issue.record("expected a dead lineage, got \(outcome)")
            return
        }
        #expect(dead.health == .needsReauth)
    }

    @Test("a network failure at activation is reported, not swallowed into a stale activation")
    func reportsATransientFailure() async {
        // The user's call: a swap that cannot renew does not happen. Swallowing this into
        // `.skipped` would hand Claude Code the very half-spent token this change exists
        // to stop handing it.
        struct Offline: Error {}
        let endpoint = FakeEndpoint()
        endpoint.result = .failure(Offline())
        let refresher = TokenRefresher(endpoint: endpoint, store: RecordingStore(), now: { t0 })

        let outcome = await refresher.freshenForActivation(
            slot: slot(refresh: "r-target", expiresIn: 28_800), activeLineage: "live"
        )

        #expect(outcome == .transientFailure)
    }
}

/// A spent grant whose successor is lost is an account that reads as healthy and is
/// already dead: the slot keeps a token the endpoint has just consumed, `health` stays
/// `.ok`, and only a `/login` brings it back. These tests pin that one transient write
/// failure does not cost that, and that the retry stops at two.
@Suite("TokenRefresher write retry")
struct TokenRefresherWriteRetryTests {

    @Test("a successor whose first write fails is written on the retry, not lost")
    func retriesTheWriteOnce() async {
        let endpoint = FakeEndpoint()
        let store = RecordingStore()
        store.saveFailuresRemaining = 1
        let refresher = TokenRefresher(endpoint: endpoint, store: store, now: { t0 })

        let outcome = await refresher.refreshIfNeeded(
            slot: slot(refresh: "r1", expiresIn: 120), activeLineage: "other"
        )

        guard case let .refreshed(updated) = outcome else {
            Issue.record("expected .refreshed, got \(outcome)")
            return
        }
        // The successor reached the store, so the caller is told the truth: this account
        // is fine. Reporting `.persistenceFailed` here would flag a healthy account.
        #expect(store.saveAttempts == 2)
        #expect(store.saved.count == 1)
        #expect(store.saved.first?.lineage == Lineage.fingerprint(refreshToken: "r-next"))
        #expect(updated.health == .ok)
        // One grant, one endpoint call: the retry must never reach the endpoint again.
        #expect(endpoint.calls == ["r1"])
    }

    @Test("a store that refuses twice gives up rather than looping")
    func stopsAtTwoAttempts() async {
        let endpoint = FakeEndpoint()
        let store = RecordingStore()
        store.saveFailuresRemaining = 2
        let refresher = TokenRefresher(endpoint: endpoint, store: store, now: { t0 })

        let outcome = await refresher.refreshIfNeeded(
            slot: slot(refresh: "r1", expiresIn: 120), activeLineage: "other"
        )

        guard case let .persistenceFailed(flagged) = outcome else {
            Issue.record("expected .persistenceFailed, got \(outcome)")
            return
        }
        #expect(store.saveAttempts == 2)
        #expect(store.saved.isEmpty)
        #expect(flagged.health == .needsReauth)
        #expect(endpoint.calls == ["r1"])
    }

    @Test("the swap-in renewal gets the same retry, since it is the same write")
    func activationSharesTheRetry() async {
        // The swap path is where a lost successor hurts most: the user asked to switch,
        // and losing the write there leaves the target dead with no in-app way back.
        let endpoint = FakeEndpoint()
        let store = RecordingStore()
        store.saveFailuresRemaining = 1
        let refresher = TokenRefresher(endpoint: endpoint, store: store, now: { t0 })

        let outcome = await refresher.freshenForActivation(
            slot: slot(refresh: "r-target", expiresIn: 28_800), activeLineage: "live"
        )

        guard case .refreshed = outcome else {
            Issue.record("expected .refreshed, got \(outcome)")
            return
        }
        #expect(store.saveAttempts == 2)
        #expect(store.saved.count == 1)
        #expect(endpoint.calls == ["r-target"])
    }
}
