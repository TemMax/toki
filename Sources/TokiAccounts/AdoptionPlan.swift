/// What to store when a credential has to be adopted into a slot.
import Foundation
import TokiLogging

private let log = TokiLog.logger("accounts")

/// The two adoption decisions, kept out of the view layer so they can be exercised
/// without a Keychain, a config file or the profile endpoint.
public enum AdoptionPlan {
    /// The uuid to present (and to hand the auto-swap policy) as the active account.
    ///
    /// `.slotNeedsAdoption` is just as active as `.slot`: the config names that account and
    /// Claude Code is signed into it. Treating it as "no active account" would show every
    /// row as sleeping and let the policy swap away from an account it cannot see.
    public static func activeSlotUuid(_ active: ActiveAccount) -> String? {
        switch active {
        case let .slot(uuid), let .slotNeedsAdoption(uuid): return uuid
        case .unknown, .none: return nil
        }
    }

    /// The slot to save when resolution returns `.slotNeedsAdoption` (D1): `~/.claude.json`
    /// names this account, but Claude Code has refreshed the live credential past every
    /// generation the slot knows. Storing the live bytes moves the slot's lineage forward,
    /// so the next resolution matches on bytes again and the refresher keeps recognising
    /// this slot as the live one it must never touch.
    ///
    /// `nil` when there is nothing to adopt: another resolution, no live bytes, a slot that
    /// is no longer stored, or a credential `replacingCredential` refuses (no refresh
    /// token) — writing that would be a pointless Keychain round trip.
    ///
    /// Also `nil` — the local half of the veto — when the live bytes already fingerprint to
    /// a *different* stored slot (`ActiveAccountResolver.contradiction`). `active` is an
    /// input the caller resolved earlier, possibly against a config read that has since
    /// been contradicted; re-deriving from the bytes here costs one hash and stops a
    /// credential from being written into an account it demonstrably does not belong to.
    /// It is only the local half: when the bytes match *no* slot (the rotation case this
    /// path exists for) nothing local can attest ownership, which is why the guarded
    /// caller (`TokiSwap.CredentialAdoption`) also demands a profile-oracle proof.
    public static func adoptedActiveSlot(
        active: ActiveAccount, slots: [AccountSlot], liveCredentialJSON: Data?, now: Date
    ) -> AccountSlot? {
        guard case let .slotNeedsAdoption(uuid) = active else { return nil }
        guard
            let liveCredentialJSON,
            let slot = slots.first(where: { $0.identity.accountUuid == uuid })
        else {
            log.info("adoptedActiveSlot: \(account: uuid) needs adoption but there is no live credential or matching stored slot; nothing to adopt")
            return nil
        }
        guard ActiveAccountResolver.contradiction(
            liveCredentialJSON: liveCredentialJSON, slots: slots, configAccountUuid: uuid
        ) == nil else {
            log.error("adoptedActiveSlot: refusing to adopt into \(account: uuid); the live bytes are contradicted by another stored slot")
            return nil
        }
        let adopted = slot.replacingCredential(liveCredentialJSON, now: now)
        guard adopted != slot else {
            log.info("adoptedActiveSlot: \(account: uuid) is already up to date; nothing to adopt")
            return nil
        }
        log.info("adoptedActiveSlot: adopting the live credential into \(account: uuid)")
        return adopted
    }

    /// True when a slot's `accountUuid` is the provisional key `adoptedQuarantineSlot` mints
    /// when the profile oracle can't confirm identity: the credential's lineage-fingerprint
    /// prefix (`QuarantineEntry.id`), not an id Anthropic ever issued. Detected by that exact
    /// relationship — the prefix equals `String(lineage.prefix(16))` — since a real
    /// `accountUuid` is a 36-char UUID and can never coincide with a 16-char lineage prefix.
    ///
    /// Callers that write into Claude Code's own config (`~/.claude.json`'s
    /// `oauthAccount.accountUuid`) must not persist a provisional key there — it would be a
    /// fabricated account id in Claude Code's config. The key is retired the moment the first
    /// successful refresh replaces the identity with a confirmed one.
    public static func isProvisionalIdentity(_ slot: AccountSlot) -> Bool {
        slot.identity.accountUuid == String(slot.lineage.prefix(16))
    }

    /// The identity of the account Claude Code is signed into but Toki has not stored, or
    /// nil when there is nothing extra to show.
    ///
    /// Returns `configIdentity` only when its account is not already among the stored slots:
    /// a stored account is rendered from its slot (with its saved alias and health), so
    /// showing the live one again would double it. This is what stops the Accounts tab
    /// looking empty while the user is plainly signed in — the row it produces is marked
    /// unstored so the UI offers to save it rather than switch to it.
    public static func liveUnstoredIdentity(
        configIdentity: AccountIdentity?, slots: [AccountSlot]
    ) -> AccountIdentity? {
        guard let configIdentity else { return nil }
        let stored = slots.contains { $0.identity.accountUuid == configIdentity.accountUuid }
        return stored ? nil : configIdentity
    }

    /// The slot to store when the user adopts a quarantined credential.
    ///
    /// `confirmed` is the profile endpoint's answer when it could be reached. It usually
    /// cannot: a quarantined credential's ACCESS token has almost always expired by the
    /// time the user sees the entry, so requiring it closed the only recovery path this
    /// credential has. Without it the entry's own record stands in — `ownerLabel` for the
    /// human label, `foundAt` for last-seen — keyed on the entry id, which is the
    /// credential's lineage fingerprint and therefore stable and unique per credential.
    ///
    /// That key is provisional, not Anthropic's account uuid, which is why a confirmed
    /// identity always wins when one is available.
    ///
    /// `nil` when the credential carries no refresh token: there is no lineage to key on
    /// and nothing worth restoring.
    public static func adoptedQuarantineSlot(
        entry: QuarantineEntry, confirmed: AccountIdentity?, now: Date
    ) -> AccountSlot? {
        guard let lineage = Lineage.fingerprint(credentialJSON: entry.credentialJSON) else {
            log.error("adoptedQuarantineSlot: quarantined credential has no refresh token; nothing to restore")
            return nil
        }
        let identity = confirmed ?? AccountIdentity(
            accountUuid: entry.id, email: entry.ownerLabel, displayName: nil,
            organizationName: nil, organizationUuid: nil
        )
        log.info("adoptedQuarantineSlot: restoring the quarantined credential into \(account: identity.accountUuid) (\(confirmed != nil ? "confirmed by profile oracle" : "unconfirmed, keyed on lineage", privacy: .public))")
        return AccountSlot(
            identity: identity, alias: nil, credentialJSON: entry.credentialJSON,
            previousCredentialJSON: nil, lineage: lineage, addedAt: now,
            lastActiveAt: entry.foundAt, lastRefreshAt: nil, health: .ok
        )
    }
}
