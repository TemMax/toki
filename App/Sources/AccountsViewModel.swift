import Observation
import Foundation
import TokiCore
import TokiAccounts
import TokiKeychain
import TokiSwap
import TokiAutoSwap
import TokiFixtures

private let log = TokiLog.logger("accounts")

/// Drives the account list: gauges for every stored account, and the swap actions.
///
/// Sleeping accounts poll far less often than the active one — the usage endpoint rate
/// limits per account, so a busy account can 429 a poll, and a 429 must read as "unknown
/// headroom", never as "plenty".
@MainActor
@Observable
final class AccountsViewModel {
    /// Settable (not `private(set)`) so the demo/snapshot harness can inject mock rows,
    /// mirroring `LiveLimits.limits` and `SignedInAccount.identity`. Production code sets it
    /// only through `reload()`.
    var accounts: [AccountPresentation] = []
    /// See `accounts` above — same settable-for-fixtures rationale.
    var quarantined: [QuarantineEntry] = []
    /// The account a swap is currently moving to, for the row spinner.
    var swapInFlight: String? { swapClaim.current }
    var errorMessage: String?

    /// When not `.live`, load()/reload() are no-ops — used by the demo/snapshot harness to
    /// render injected mock data without touching the Keychain.
    var runMode: RunMode = .live

    /// One swap at a time, and only its own owner may clear it.
    private var swapClaim = SingleFlightSlot<String>()
    /// One gauge refresh at a time; extra callers await the run already going.
    private var gaugeRefresh = SingleFlightSlot<Task<Void, Never>>()

    private let store: any SlotStoring
    private let swapper: SwapService
    private let refresher: TokenRefresher
    private let usage: @Sendable (String) async throws -> UsageLimits
    private let live: @Sendable () async -> Data?
    /// Proves ownership before any live credential is written into a slot — see
    /// `TokiSwap.CredentialAdoption`. Both writes that pair the live Keychain credential
    /// with an identity read from `~/.claude.json` go through it.
    private let adoption: CredentialAdoption
    private let liveLimitsStore: LiveLimits
    private let signedInStore: SignedInAccount
    private let refreshController: UsageRefreshController

    private var limitsByAccount: [String: UsageLimits] = [:]
    private var staleAccounts: Set<String> = []
    private var staleReasons: [String: GaugeStaleReason] = [:]

    /// The signed-in account's limits from the shared store. The Accounts tab's active card
    /// reads this (not a per-account fetch), so it moves in lockstep with the popover and the
    /// Usage tab — one source, observed everywhere.
    var activeAccountLimits: UsageLimits? { liveLimitsStore.limits }

    /// The rows every surface renders: `accounts` with the active row joined to the
    /// shared live-limits store. Computed from two observed properties, so it
    /// re-derives whenever either the row list or the live snapshot changes.
    var presentedAccounts: [AccountPresentation] {
        AccountPresentation.overlayingLiveActiveLimits(
            accounts, live: activeAccountLimits,
            liveIsFresh: liveLimitsStore.state == .ok,
            liveStaleReason: activeStaleReason
        )
    }

    private var activeStaleReason: GaugeStaleReason? {
        switch liveLimitsStore.failure {
        case .authorization: .auth
        case .rateLimited: .rateLimited
        case .network: .network
        case nil: liveLimitsStore.state == .notLoggedIn ? .auth : nil
        }
    }

    init(
        store: any SlotStoring,
        swapper: SwapService,
        refresher: TokenRefresher,
        usage: @escaping @Sendable (String) async throws -> UsageLimits,
        live: @escaping @Sendable () async -> Data?,
        adoption: CredentialAdoption,
        liveLimits: LiveLimits,
        signedIn: SignedInAccount,
        refreshController: UsageRefreshController
    ) {
        self.store = store
        self.swapper = swapper
        self.refresher = refresher
        self.usage = usage
        self.live = live
        self.adoption = adoption
        self.liveLimitsStore = liveLimits
        self.signedInStore = signedIn
        self.refreshController = refreshController
    }

    func load() {
        Task { await reload() }
    }

    // MARK: Off-main Keychain access

    /// Every `SlotStoring` call is a synchronous IPC round trip to securityd (an index
    /// read, an enumeration repair pass, one exact read per slot). Run on the main actor
    /// they stall whatever is in flight — the tab's entrance animation visibly stutters —
    /// so all keychain reads/writes in this view model hop off through these helpers.
    /// One slot, read exactly. The gauge loop re-reads its target on every iteration (a
    /// swap or a refresh can land mid-loop), so this must not be `loadAll`: that would run
    /// a whole-keychain repair scan per account.
    private func slotOffMain(_ accountUuid: String) async -> AccountSlot? {
        let store = self.store
        return await Task.detached(priority: .userInitiated) {
            do {
                return try store.load(accountUuid: accountUuid)
            } catch {
                log.error("slotOffMain: failed to load a stored slot: \(error: error)")
                return nil
            }
        }.value
    }

    private func slotsOffMain() async -> [AccountSlot] {
        let store = self.store
        return await Task.detached(priority: .userInitiated) {
            do {
                return try store.loadAll()
            } catch {
                log.error("slotsOffMain: failed to load stored slots: \(error: error)")
                return []
            }
        }.value
    }

    private func quarantineOffMain() async -> [QuarantineEntry] {
        let store = self.store
        return await Task.detached(priority: .userInitiated) {
            do {
                return try store.loadQuarantine()
            } catch {
                log.error("quarantineOffMain: failed to load quarantined entries: \(error: error)")
                return []
            }
        }.value
    }

    private func saveOffMain(_ slot: AccountSlot) async throws {
        let store = self.store
        try await Task.detached(priority: .userInitiated) { try store.save(slot) }.value
    }

    private func deleteOffMain(accountUuid: String) async {
        let store = self.store
        await Task.detached(priority: .userInitiated) {
            do {
                try store.delete(accountUuid: accountUuid)
            } catch {
                log.error("deleteOffMain: failed to delete a stored slot: \(error: error)")
            }
        }.value
    }

    func reload() async {
        guard runMode.isLive else { return }
        var slots = await slotsOffMain()
        quarantined = await quarantineOffMain()
        let liveJSON = await live()
        let configIdentity = signedInStore.identity
        let active = ActiveAccountResolver.resolve(
            liveCredentialJSON: liveJSON, slots: slots,
            configAccountUuid: configIdentity?.accountUuid
        )
        // D1: the config names this account, but Claude Code has refreshed the live
        // credential past every generation the slot holds. Adopting those bytes moves the
        // slot's lineage forward, so the next resolution matches on bytes again and the
        // refresher keeps seeing this slot as the live one it must never touch.
        //
        // The decision is NOT made from the values above: `configIdentity` is a cached copy
        // that lags the config watcher's debounce, and the live bytes were read at yet
        // another moment — pairing them is exactly how one account's credential lands in
        // another account's slot. `CredentialAdoption` re-reads both itself and proves
        // ownership before it hands back anything to write. The cheap resolution here only
        // decides whether that (network-touching) path is worth entering at all.
        if case .slotNeedsAdoption = active,
           case let .adopt(adopted) = await adoption.adoptActive(slots: slots) {
            do {
                try await saveOffMain(adopted)
                slots = slots.map {
                    $0.identity.accountUuid == adopted.identity.accountUuid ? adopted : $0
                }
                log.info("reload: adopted the live credential into \(account: adopted.identity.accountUuid)")
            } catch {
                // Not worth interrupting the user for: the config still names the account,
                // so it still reads as active here and the next reload retries the adoption.
                log.error("reload: failed to persist an adopted slot; will retry on the next reload: \(error: error)")
            }
        }
        let activeUuid = AdoptionPlan.activeSlotUuid(active)
        var rows = slots.map { slot in
            AccountPresentation.make(
                slot: slot,
                active: activeUuid == slot.identity.accountUuid,
                limits: limitsByAccount[slot.identity.accountUuid],
                stale: staleAccounts.contains(slot.identity.accountUuid),
                staleReason: staleReasons[slot.identity.accountUuid]
            )
        }
        // The account Claude Code is signed into but Toki hasn't stored is shown first, so
        // the tab and the popover never look empty while the user is plainly signed in. It
        // reads as active and offers to be saved, not switched to.
        if let live = AdoptionPlan.liveUnstoredIdentity(configIdentity: configIdentity, slots: slots) {
            rows.insert(
                AccountPresentation.makeLiveUnstored(
                    identity: live,
                    limits: limitsByAccount[live.accountUuid],
                    stale: staleAccounts.contains(live.accountUuid),
                    staleReason: staleReasons[live.accountUuid]
                ),
                at: 0
            )
        }
        accounts = rows
    }

    /// Refreshes sleeping tokens where needed, then polls usage for every account.
    ///
    /// Single-flight across its three callers — the Accounts tab appearing, the dashboard's
    /// Refresh button, and the auto-swap tick. A second concurrent pass would hand
    /// `TokenRefresher` slots read before this pass rewrote them, and a dead-lineage answer
    /// writes that whole stale slot back: the account's credential rolls onto a generation
    /// already spent and a healthy account is marked `needsReauth`, with no in-app recovery.
    func refreshGauges() async {
        let claim = gaugeRefresh.beginOrJoin {
            Task { [weak self] in await self?.performGaugeRefresh() }
        }
        await claim.run.value
        if claim.isOwner { gaugeRefresh.end(claim.run) }
    }

    private func performGaugeRefresh() async {
        log.debug("performGaugeRefresh: starting a background gauge refresh pass")
        errorMessage = nil

        // The signed-in account is owned by LiveLimits; saved accounts share the same
        // request controller, so an account switch cannot create a second rapid poll.
        let activeUuid = signedInStore.identity?.accountUuid

        for accountUuid in await slotsOffMain().map(\.identity.accountUuid) {
            if accountUuid == activeUuid { continue }   // polled with the live token below

            // Both the slot and the live lineage are re-read here, inside the loop, because
            // every iteration below makes a network round trip: a swap or one of Claude
            // Code's own refreshes landing during one leaves the pre-loop snapshot naming a
            // generation that has since been spent. Refreshing that would kill the lineage,
            // and refreshing what is by then the LIVE account would force a re-login — the
            // exact failure this whole feature exists to prevent.
            guard var current = await slotOffMain(accountUuid) else { continue }

            // A slot whose lineage is already dead makes no network call at all. Before
            // this guard only the pass that DISCOVERED the death skipped the poll (see
            // `case .deadLineage` below); every pass after it spent a guaranteed 401 and
            // a guaranteed-refused refresh, re-deriving a `needsReauth` the store already
            // held. The card is unaffected: it keeps its last-known gauge behind the
            // stale/auth banner and the "Sign in again" pill, both of which this branch
            // re-asserts on every pass.
            if GaugePollDecision.decide(slot: current) == .skipNeedsReauth {
                staleAccounts.insert(accountUuid)
                staleReasons[accountUuid] = .auth
                continue
            }

            switch await refresher.refreshIfNeeded(
                slot: current, activeLineage: await activeLineage(), activeAccountUuid: activeUuid
            ) {
            case let .refreshed(updated):
                current = updated
            case let .persistenceFailed(updated):
                // The grant is spent and its successor exists in memory only. Poll with it,
                // but never let that read as a healthy refresh — the account needs the user.
                current = updated
                errorMessage = """
                    \(updated.displayLabel) was renewed but couldn't be saved — sign in again \
                    if it stops working.
                    """
            case .deadLineage:
                // Only a fresh /login can revive this lineage — polling would spend a
                // guaranteed-401 request. The card already shows the re-login pill via
                // `health`; the gauge is unknown, not zero.
                staleAccounts.insert(accountUuid)
                staleReasons[accountUuid] = .auth
                continue
            case .skipped, .transientFailure:
                break
            }

            guard let token = Self.accessToken(of: current.credentialJSON) else { continue }
            guard let permit = await refreshController.begin(
                UsageRefreshKey(
                    provider: .claude,
                    accountID: current.identity.accountUuid,
                    organizationID: current.identity.organizationUuid
                )
            ) else { continue }
            var outcome: UsageRefreshController.Outcome = .failure
            do {
                let fetched = try await usage(token)
                outcome = recordGaugeResponse(fetched, for: current.identity.accountUuid)
            } catch TokiError.tokenExpired {
                // The 401 outranks the slot's own expiresAt: force one refresh (the
                // live-account guards still apply) and retry once. Two 401s in a row —
                // or a refusal to refresh — is an auth problem the user may need to see.
                log.notice("performGaugeRefresh: \(account: accountUuid) token expired mid-poll; forcing a refresh and retrying once")
                var renewed: AccountSlot?
                switch await refresher.refreshIfNeeded(
                    slot: current, activeLineage: await activeLineage(),
                    activeAccountUuid: activeUuid, force: true
                ) {
                case let .refreshed(updated):
                    renewed = updated
                case let .persistenceFailed(updated):
                    // The grant is already spent and its successor exists in memory only —
                    // poll with it rather than dropping it. Discarding the successor would
                    // leave the stored, already-dead token as the slot's only credential,
                    // and the next forced refresh would kill the lineage (invalid_grant →
                    // needsReauth). Same rule as the pre-poll switch above.
                    renewed = updated
                    errorMessage = """
                        \(updated.displayLabel) was renewed but couldn't be saved — sign in again \
                        if it stops working.
                        """
                case .skipped, .deadLineage, .transientFailure:
                    renewed = nil
                }
                if let renewed, let freshToken = Self.accessToken(of: renewed.credentialJSON) {
                    do {
                        let fetched = try await usage(freshToken)
                        outcome = recordGaugeResponse(fetched, for: renewed.identity.accountUuid)
                    } catch {
                        // no-log: markStale(_:error:) logs this error itself, below.
                        markStale(renewed.identity.accountUuid, error: error)
                        outcome = .error(error)
                    }
                } else {
                    log.notice("performGaugeRefresh: \(account: current.identity.accountUuid) forced refresh did not yield a usable token; marking as needing re-auth")
                    staleAccounts.insert(current.identity.accountUuid)
                    staleReasons[current.identity.accountUuid] = .auth
                }
            } catch {
                // Unknown headroom, not zero headroom.
                // no-log: markStale(_:error:) logs this error itself, below.
                markStale(current.identity.accountUuid, error: error)
                outcome = .error(error)
            }
            await refreshController.finish(permit, outcome: outcome)
        }

        // The active account is NOT polled here: its gauges come from the shared `LiveLimits`
        // store (see `activeAccountLimits`), which the view reads directly so the card tracks
        // the popover and Usage tab. Kicking that store is the container's job on a switch.
        await reload()
        // A pass that found nothing stale is the expected outcome and repeats on every poll,
        // so it belongs at `debug`; a pass that DID find stale accounts is the state change
        // worth keeping in the default log.
        if staleAccounts.isEmpty {
            log.debug("performGaugeRefresh: finished, nothing stale")
        } else {
            log.info("performGaugeRefresh: finished (\(staleAccounts.count) account(s) stale)")
        }
    }

    private func markFresh(_ accountUuid: String) {
        staleAccounts.remove(accountUuid)
        staleReasons.removeValue(forKey: accountUuid)
    }

    private func recordGaugeResponse(
        _ fetched: UsageLimits, for accountUuid: String
    ) -> UsageRefreshController.Outcome {
        if let partial = fetched.supplementalRateLimit {
            // Ordinary usage succeeded, but reset metadata was rate limited. An older
            // complete snapshot remains the honest display history for this account.
            if limitsByAccount[accountUuid] == nil { limitsByAccount[accountUuid] = fetched }
            markStale(accountUuid, error: TokiError.rateLimited(retryAfter: partial.retryAfter))
            return .rateLimited(retryAfter: partial.retryAfter)
        }
        limitsByAccount[accountUuid] = fetched
        markFresh(accountUuid)
        return .success
    }

    private func markStale(_ accountUuid: String, error: Error) {
        staleAccounts.insert(accountUuid)
        switch error {
        case TokiError.tokenExpired: staleReasons[accountUuid] = .auth
        case TokiError.rateLimited: staleReasons[accountUuid] = .rateLimited
        default: staleReasons[accountUuid] = .network
        }
        log.notice("markStale: \(account: accountUuid) gauge marked stale: \(error: error)")
    }

    /// Returns true when the target is the account Claude Code is signed into once this
    /// returns — including the case where it already was, which is a success that changed
    /// nothing. Callers cannot infer that from `errorMessage`: the auto-swap driver stamps
    /// its cooldown and the popover posts its notification on this value alone.
    @discardableResult
    func swap(to accountUuid: String) async -> Bool {
        errorMessage = nil
        log.info("swap: requested switch to \(account: accountUuid)")
        // Refused, not queued: a queued swap would act on gauges that are already stale by
        // the time it ran. The claim is also what keeps the loser of a race from clearing
        // the winner's marker and re-enabling the UI mid-transaction.
        guard swapClaim.begin(accountUuid) else {
            log.notice("swap: refused, another switch is already in flight")
            errorMessage = "Another account switch is already running."
            return false
        }
        defer {
            swapClaim.end(accountUuid)
        }
        liveLimitsStore.accountWillChange()
        do {
            // `alreadyActive` reports that nothing was touched because the target was
            // already signed in — the caller asked to be on this account, and it is.
            _ = try await swapper.swap(to: accountUuid)
            // The config watcher is debounced. Resolve the newly written identity now,
            // before the shared feed can restore a last-known account snapshot.
            await signedInStore.refresh()
            await reload()
            liveLimitsStore.accountDidChange(expectedAccountID: accountUuid)
            log.info("swap: succeeded, now on \(account: accountUuid)")
            return true
        } catch SwapError.targetNeedsReauth {
            // The freshen step refused to activate a dead grant. The slot is already
            // flagged in the store, so reload before returning: the policy and the card
            // must both see it as unhealthy, otherwise the next tick picks it again.
            log.notice("swap: target \(account: accountUuid) needs re-auth; refused")
            await reload()
            errorMessage = SwapError.targetNeedsReauth.errorDescription
        } catch SwapError.claudeBusy {
            log.notice("swap: Claude Code was busy; refused")
            errorMessage = "Claude is busy right now — try again in a moment."
        } catch SwapError.freshenFailed {
            // Reachable now that the swap-in renewal is unconditional: no network, no
            // renewal, no activation. Surface the sentence on its own — the generic catch
            // below would nest it inside "Couldn't switch accounts: …" and read as two
            // stacked apologies.
            log.notice("swap: the target's token could not be renewed; refused")
            errorMessage = SwapError.freshenFailed.errorDescription
        } catch {
            log.error("swap: failed: \(error: error)")
            errorMessage = "Couldn't switch accounts: \(error.localizedDescription)"
        }
        await signedInStore.refresh()
        liveLimitsStore.accountDidChange()
        return false
    }

    func addCurrentAccount() async {
        errorMessage = nil
        log.info("addCurrentAccount: capturing the live credential as a new stored slot")
        do {
            // Same proof as the adoption path: the identity comes from `~/.claude.json` and
            // the credential from the Keychain, so without it a capture taken inside a swap
            // window would create a slot named after one account holding another's refresh
            // token. Passing the current slots also lets the capture merge into an existing
            // slot instead of overwriting it — a fresh slot would drop its recovery cushion.
            try await saveOffMain(try await adoption.captureCurrent(slots: await slotsOffMain()))
            await reload()
            log.info("addCurrentAccount: succeeded")
        } catch let refusal as AdoptionRefusal {
            log.notice("addCurrentAccount: refused: \(error: refusal)")
            errorMessage = refusal.errorDescription
        } catch {
            log.error("addCurrentAccount: failed: \(error: error)")
            errorMessage = "Couldn't add this account: \(error.localizedDescription)"
        }
    }

    func remove(accountUuid: String) async {
        await deleteOffMain(accountUuid: accountUuid)
        await reload()
    }

    func rename(accountUuid: String, alias: String?) async {
        guard var slot = await slotOffMain(accountUuid) else { return }
        slot.alias = alias
        do {
            try await saveOffMain(slot)
        } catch {
            log.error("rename: failed to save the alias for \(account: accountUuid): \(error: error)")
        }
        await reload()
    }

    func snapshotsForPolicy() -> [AccountSnapshot] {
        let raw = accounts.map {
            AccountSnapshot(
                accountUuid: $0.accountUuid, label: $0.label,
                fiveHour: $0.fiveHour, weekly: $0.weekly,
                isActive: $0.isActive, isHealthy: $0.health == .ok,
                gaugesAreStale: $0.gaugesAreStale
            )
        }
        // The active account is never polled per-account, so `limitsByAccount` — and every
        // presentation built from it — holds nothing for it. Its usage lives in the shared
        // live-limits store (the same one the cards read), and without this overlay the
        // policy sees `nil` for the signed-in account and can never raise a trigger.
        return AccountSnapshot.withLiveActiveLimits(
            raw,
            activeFiveHour: AccountPresentation.fiveHour(from: activeAccountLimits),
            activeWeekly: AccountPresentation.weekly(from: activeAccountLimits),
            liveIsFresh: liveLimitsStore.state == .ok,
            liveAccountUuid: activeAccountLimits?.account?.accountUuid
        )
    }

    private func activeLineage() async -> String? {
        guard let json = await live() else { return nil }
        return Lineage.fingerprint(credentialJSON: json)
    }


    private static func accessToken(of json: Data) -> String? {
        do {
            guard
                let root = try JSONSerialization.jsonObject(with: json) as? [String: Any],
                let oauth = root["claudeAiOauth"] as? [String: Any],
                let token = oauth["accessToken"] as? String, !token.isEmpty
            else { return nil }
            return token
        } catch {
            log.error("accessToken: stored credential JSON failed to parse: \(error: error)")
            return nil
        }
    }
}

/// Bridges `CredentialStore`'s ladder to the swap layer's `LiveCredentialAccess`.
struct CredentialStoreLiveAccess: LiveCredentialAccess {
    let store: CredentialStore

    func readLive() async -> (json: Data, ref: KeychainItemRef)? {
        do {
            return try await store.readRawCredential()
        } catch {
            log.notice("live credentials unavailable for account management: \(error: error)")
            return nil
        }
    }
}

// `AccountCapture` used to live here: it paired `~/.claude.json`'s identity with the live
// Keychain bytes and saved the result as a brand-new slot, with no check that the two
// described the same account and no regard for an existing slot's recovery cushion. Both
// jobs now belong to `TokiSwap.CredentialAdoption.captureCurrent`, where the proof is
// testable without a Keychain.
