/// Proving a live credential belongs to a slot before it is written into one.
import Foundation
import TokiAccounts
import TokiLogging

private let log = TokiLog.logger("swap")

/// Why a credential was not written into a slot.
///
/// Every case is a refusal to write, never an error the user must clear: the state that
/// caused it is transient (a swap in flight, the network down) and the next reload retries.
public enum AdoptionRefusal: Error, Equatable, Sendable {
    /// Nothing was pending: the bytes already match a slot, no slot is named, or the
    /// credential is unchanged.
    case nothingToAdopt
    /// No readable credential — Claude Code is signed out, or the Keychain read failed.
    case noLiveCredential
    /// `~/.claude.json` names no account.
    case notSignedIn
    /// The config changed while the credential was being read, so the pair may describe
    /// two different accounts. A swap or a `/login` is in flight; retry after it lands.
    case configUnstable(before: String?, after: String?)
    /// The live bytes already fingerprint to a different stored slot
    /// (`ActiveAccountResolver.contradiction`) — one of the two slots is already wrong,
    /// and writing again would spread it.
    case contradiction(ActiveAccountContradiction)
    /// The profile endpoint could not say who owns the credential (offline, or the access
    /// token has expired). Unproven ownership is treated exactly like foreign ownership.
    case ownerUnconfirmed
    /// The credential provably belongs to another account.
    case foreignCredential(slot: String, owner: String)
}

extension AdoptionRefusal: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .nothingToAdopt:
            return "That account is already saved and up to date."
        case .noLiveCredential:
            return "Couldn't read the current Claude sign-in."
        case .notSignedIn:
            return "Claude isn't signed in to an account right now."
        case .configUnstable:
            return "Claude was switching accounts just then — try again in a moment."
        case .contradiction:
            return "Toki's saved accounts disagree with Claude about who is signed in, "
                + "so nothing was saved. Check the Accounts list."
        case .ownerUnconfirmed:
            return "Couldn't confirm which account this sign-in belongs to — check your "
                + "connection and try again."
        case .foreignCredential:
            return "That sign-in belongs to a different account than Claude's "
                + "configuration names, so nothing was saved."
        }
    }
}

extension AdoptionRefusal {
    /// The case name alone, as a `StaticString` — never the associated values, which are
    /// account identifiers. `\(error:)` would render those; this is what the log gets.
    fileprivate var logLabel: StaticString {
        switch self {
        case .nothingToAdopt: return "nothingToAdopt"
        case .noLiveCredential: return "noLiveCredential"
        case .notSignedIn: return "notSignedIn"
        case .configUnstable: return "configUnstable"
        case .contradiction: return "contradiction"
        case .ownerUnconfirmed: return "ownerUnconfirmed"
        case .foreignCredential: return "foreignCredential"
        }
    }
}

public enum AdoptionDecision: Equatable, Sendable {
    case adopt(AccountSlot)
    case refuse(AdoptionRefusal)
}

/// The ownership proof for the two writes that pair the LIVE Keychain credential with an
/// identity taken from `~/.claude.json`: adopting a rotated credential into its slot (D1),
/// and capturing the signed-in account as a new slot.
///
/// Both writes used to trust the config's account uuid as proof that the live bytes belong
/// to that account. They are read from two different places at two different times, so that
/// is a hypothesis, not proof — and it is false in an ordinary, self-inflicted window: a
/// swap writes the Keychain first and the config second, so for the hundreds of milliseconds
/// between them the config still names the OUTGOING account while the bytes are the incoming
/// one's. A write in that window puts one account's refresh token into another account's
/// slot; from then on the resolver byte-matches the wrong slot first and reports the wrong
/// account as active, permanently, because the poisoned lineage keeps matching.
///
/// The proof applied here is the one the swap path has always applied to the symmetric write
/// (`OwnershipClassifier` + `ProfileOracle` in `SwapService.planSyncBack`), in three layers,
/// cheapest first:
///
/// 1. **Consistency sandwich.** The config is read *inside* this decision — never from a
///    cached copy — before and after the credential read. A disagreement means an account
///    change happened between them; refuse and let the next reload retry.
/// 2. **Contradiction veto.** Refuse while the live bytes fingerprint to a different stored
///    slot. Local and free, and it stops a poisoned slot from being poisoned twice — the
///    second adoption is what overwrites the cushion and destroys the real refresh token.
/// 3. **Oracle proof.** Ask the profile endpoint who the live access token belongs to and
///    require its account uuid to equal the slot's. `.unresolved` is treated as foreign.
///    One round trip, on the rare adoption path only, never under a Claude Code lock.
///
/// A refusal is always safe: the slot keeps the credential it has, the config still names
/// the account so it still reads as active, and the refresher already declines to touch the
/// slot the config names.
public struct CredentialAdoption: Sendable {
    private let signedInIdentity: @Sendable () async -> AccountIdentity?
    private let readLive: @Sendable () async -> Data?
    private let oracle: any ProfileLookup
    private let now: @Sendable () -> Date

    public init(
        signedInIdentity: @escaping @Sendable () async -> AccountIdentity?,
        readLive: @escaping @Sendable () async -> Data?,
        oracle: any ProfileLookup,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.signedInIdentity = signedInIdentity
        self.readLive = readLive
        self.oracle = oracle
        self.now = now
    }

    /// Reads `oauthAccount` straight from `~/.claude.json` on every call — the whole point
    /// of the sandwich is that this is not a cached value.
    public init(
        configURL: URL,
        readLive: @escaping @Sendable () async -> Data?,
        oracle: any ProfileLookup,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.init(
            // Off-main: `~/.claude.json` is ~120 KB of the user's own config and this parses
            // all of it, twice per decision.
            signedInIdentity: {
                await Task.detached(priority: .utility) {
                    Self.readConfigIdentity(configURL)
                }.value
            },
            readLive: readLive,
            oracle: oracle,
            now: now
        )
    }

    static func readConfigIdentity(_ configURL: URL) -> AccountIdentity? {
        // no-log: `ClaudeConfigEditor` logs its own read and parse failures, and a config
        // that names nobody is an ordinary signed-out state.
        guard let oauth = try? ClaudeConfigEditor(configURL: configURL).readOAuthAccount()
        else { return nil }
        return AccountIdentity.parse(oauthAccount: oauth)
    }

    // MARK: D1 — adopt the rotated live credential into the slot the config names

    /// The slot to save when resolution returns `.slotNeedsAdoption`, or why nothing may be
    /// saved. Re-reads the config and the credential itself so the pair it judges is the one
    /// it proved, not one the caller sampled at some earlier moment.
    public func adoptActive(slots: [AccountSlot]) async -> AdoptionDecision {
        let sandwich: (identity: AccountIdentity?, live: Data?)
        do { sandwich = try await consistentLiveState() }
        catch let refusal as AdoptionRefusal {
            log.notice("adoption refused: \(refusal.logLabel)")
            return .refuse(refusal)
        }
        catch {
            log.error("adoption refused: reading the live state failed unexpectedly: \(error: error)")
            return .refuse(.noLiveCredential)
        }

        guard let liveJSON = sandwich.live else {
            log.notice("adoption refused: \(AdoptionRefusal.noLiveCredential.logLabel)")
            return .refuse(.noLiveCredential)
        }
        let configUuid = sandwich.identity?.accountUuid

        if let clash = ActiveAccountResolver.contradiction(
            liveCredentialJSON: liveJSON, slots: slots, configAccountUuid: configUuid
        ) {
            log.notice("adoption refused: \(AdoptionRefusal.contradiction(clash).logLabel)")
            return .refuse(.contradiction(clash))
        }

        let active = ActiveAccountResolver.resolve(
            liveCredentialJSON: liveJSON, slots: slots, configAccountUuid: configUuid
        )
        guard case let .slotNeedsAdoption(uuid) = active,
              let slot = slots.first(where: { $0.identity.accountUuid == uuid })
        else {
            log.info("adoption: nothing pending — the stored accounts are already up to date")
            return .refuse(.nothingToAdopt)
        }

        if let refusal = await proveOwnership(of: liveJSON, isAccount: slot.identity.accountUuid) {
            log.notice("adoption refused: \(refusal.logLabel) \(account: slot.identity.accountUuid)")
            return .refuse(refusal)
        }

        guard let adopted = AdoptionPlan.adoptedActiveSlot(
            active: active, slots: slots, liveCredentialJSON: liveJSON, now: now()
        ) else {
            log.info("adoption: nothing pending — the stored accounts are already up to date")
            return .refuse(.nothingToAdopt)
        }
        log.info("adopting the rotated live credential into its account \(account: adopted.identity.accountUuid)")
        return .adopt(adopted)
    }

    // MARK: "Add current account" — capture whatever Claude Code is signed into

    /// The slot to save for the account Claude Code is signed into right now.
    ///
    /// When that account is already stored the credential is merged into the existing slot
    /// via `replacingCredential`, which keeps its alias and — the part that matters — its
    /// recovery cushion. Building a fresh slot instead would drop the one prior generation
    /// standing between a failed refresh and a forced `/login`.
    public func captureCurrent(slots: [AccountSlot]) async throws -> AccountSlot {
        let sandwich = try await consistentLiveState()
        guard let identity = sandwich.identity else {
            log.notice("capture refused: \(AdoptionRefusal.notSignedIn.logLabel)")
            throw AdoptionRefusal.notSignedIn
        }
        guard let liveJSON = sandwich.live else {
            log.notice("capture refused: \(AdoptionRefusal.noLiveCredential.logLabel)")
            throw AdoptionRefusal.noLiveCredential
        }
        guard let lineage = Lineage.fingerprint(credentialJSON: liveJSON) else {
            log.notice("capture refused: the live credential carries no token pair")
            throw AdoptionRefusal.noLiveCredential
        }

        if let clash = ActiveAccountResolver.contradiction(
            liveCredentialJSON: liveJSON, slots: slots, configAccountUuid: identity.accountUuid
        ) {
            log.notice("capture refused: \(AdoptionRefusal.contradiction(clash).logLabel) \(account: identity.accountUuid)")
            throw AdoptionRefusal.contradiction(clash)
        }
        // The bytes belonging to a stored slot other than the one being captured is the same
        // defect the contradiction veto covers, minus the requirement that the config name a
        // stored account — the case where the user is capturing an account for the first time.
        if case let .slot(owner) = ActiveAccountResolver.resolve(
            liveCredentialJSON: liveJSON, slots: slots
        ), owner != identity.accountUuid {
            log.notice("""
                capture refused: the live credential belongs to another stored account \
                config=\(account: identity.accountUuid) owner=\(account: owner)
                """)
            throw AdoptionRefusal.foreignCredential(slot: identity.accountUuid, owner: owner)
        }

        if let refusal = await proveOwnership(of: liveJSON, isAccount: identity.accountUuid) {
            log.notice("capture refused: \(refusal.logLabel) \(account: identity.accountUuid)")
            throw refusal
        }

        if let existing = slots.first(where: { $0.identity.accountUuid == identity.accountUuid }) {
            log.info("capturing the signed-in account into the slot it already has \(account: identity.accountUuid)")
            var merged = existing.replacingCredential(liveJSON, now: now())
            merged.identity = identity
            return merged
        }
        log.info("capturing the signed-in account as a new slot \(account: identity.accountUuid)")
        return AccountSlot(
            identity: identity, alias: nil, credentialJSON: liveJSON,
            previousCredentialJSON: nil, lineage: lineage, addedAt: now(),
            lastActiveAt: now(), lastRefreshAt: nil, health: .ok
        )
    }

    // MARK: Proofs

    /// config → credential → config, requiring the two config reads to name the same
    /// account. Anything else means an account change landed between them and the pair
    /// cannot be trusted to describe one account.
    private func consistentLiveState() async throws -> (identity: AccountIdentity?, live: Data?) {
        let before = await signedInIdentity()
        let live = await readLive()
        let after = await signedInIdentity()
        guard before?.accountUuid == after?.accountUuid else {
            throw AdoptionRefusal.configUnstable(
                before: before?.accountUuid, after: after?.accountUuid
            )
        }
        return (before, live)
    }

    /// `nil` when the profile endpoint confirms the live token belongs to `accountUuid`.
    private func proveOwnership(
        of liveJSON: Data, isAccount accountUuid: String
    ) async -> AdoptionRefusal? {
        guard let token = Self.accessToken(of: liveJSON) else { return .ownerUnconfirmed }
        let owner: AccountIdentity
        do {
            owner = try await oracle.owner(ofToken: token)
        } catch {
            log.notice("ownership could not be proven, so nothing will be written: \(error: error)")
            return .ownerUnconfirmed
        }
        guard owner.accountUuid == accountUuid else {
            return .foreignCredential(slot: accountUuid, owner: owner.accountUuid)
        }
        return nil
    }

    static func accessToken(of json: Data) -> String? {
        guard
            // no-log: decoding the live credential bytes; the caller acts on "no access
            // token", and the bytes may never reach a log line.
            let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
            let oauth = root["claudeAiOauth"] as? [String: Any],
            let token = oauth["accessToken"] as? String, !token.isEmpty
        else { return nil }
        return token
    }
}
