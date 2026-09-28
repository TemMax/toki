/// Which stored account is the one Claude Code is currently signed into.
import Foundation
import TokiLogging

private let log = TokiLog.logger("accounts")

public enum ActiveAccount: Equatable, Sendable {
    /// The live credential's lineage belongs to this stored slot.
    case slot(String)
    /// No lineage matched, but `~/.claude.json` names this stored account as the one
    /// signed in — Claude Code has rotated past every generation the slot knows. The
    /// caller must adopt the live credential into the slot (`replacingCredential`) so
    /// the lineage tracks forward and the next resolution matches on bytes again.
    case slotNeedsAdoption(String)
    /// A credential is present but belongs to no stored slot — the user signed in
    /// outside Toki. A first-class state, not an error.
    case unknown
    /// No usable credential at all.
    case none
}

/// Two stored slots claim to be the signed-in one at the same time: the live bytes
/// fingerprint to `byteMatchedUuid`, while `~/.claude.json` names `configNamedUuid`.
public struct ActiveAccountContradiction: Equatable, Sendable {
    /// The slot whose lineage (or recovery cushion) the live refresh token hashes to.
    public let byteMatchedUuid: String
    /// The stored slot `~/.claude.json`'s `oauthAccount.accountUuid` names.
    public let configNamedUuid: String

    public init(byteMatchedUuid: String, configNamedUuid: String) {
        self.byteMatchedUuid = byteMatchedUuid
        self.configNamedUuid = configNamedUuid
    }
}

/// Derives the active account from LIVE bytes only.
///
/// Toki must never trust a stored "active account" marker: if the user runs `/login`
/// behind its back, a stale marker would make the refresher treat the genuinely
/// active account as sleeping, refresh it, consume its single-use refresh token and
/// leave Claude Code holding a dead credential — a forced re-login caused by the
/// feature that exists to prevent re-logins.
public enum ActiveAccountResolver {
    /// `configAccountUuid` is `~/.claude.json`'s `oauthAccount.accountUuid`, written by
    /// Claude Code itself: authoritative, local and free. It is the only way to recognise
    /// a live credential Claude Code has refreshed past everything the slots store.
    ///
    /// **Why the bytes win over the config.** The config legitimately lags the credential:
    /// a swap writes the Keychain first and `~/.claude.json` second (a `security`
    /// subprocess plus a verifying read-back apart), and any cached copy of the config
    /// lags further still. During that window the config names the outgoing account while
    /// the bytes are already the incoming one's — and the bytes are what Claude Code will
    /// actually authenticate with, so they decide who is live. That is why the config is
    /// consulted only after the lineage loop finds nothing, and why a mismatch must never
    /// be treated as an error here: it is a normal, transient shape of a swap in progress.
    public static func resolve(
        liveCredentialJSON: Data?,
        slots: [AccountSlot],
        configAccountUuid: String? = nil
    ) -> ActiveAccount {
        guard let liveCredentialJSON else {
            log.info("resolve: no live credential present")
            return .none
        }
        guard let live = Lineage.fingerprint(credentialJSON: liveCredentialJSON) else {
            log.info("resolve: live credential has no derivable lineage; account unknown")
            return .unknown
        }
        for slot in slots {
            if slot.lineage == live {
                log.info("resolve: live credential matched \(account: slot.identity.accountUuid) by its current lineage")
                return .slot(slot.identity.accountUuid)
            }
            if let previous = slot.previousCredentialJSON,
               Lineage.fingerprint(credentialJSON: previous) == live {
                log.info("resolve: live credential matched \(account: slot.identity.accountUuid) by its recovery-cushion lineage")
                return .slot(slot.identity.accountUuid)
            }
        }
        // The bytes win over the config, which can lag a swap — hence only after the loop.
        if let configAccountUuid,
           slots.contains(where: { $0.identity.accountUuid == configAccountUuid }) {
            log.debug("resolve: no lineage matched, but config names stored \(account: configAccountUuid); needs adoption")
            return .slotNeedsAdoption(configAccountUuid)
        }
        log.debug("resolve: no lineage matched and config names no stored slot; account unknown")
        return .unknown
    }

    /// The one config-versus-bytes disagreement that is NOT explainable by lag: the live
    /// credential fingerprints to stored slot A while the config names a *different*
    /// stored slot B.
    ///
    /// What makes this case different from the ordinary lag `resolve` tolerates: lag means
    /// the config still names the account the bytes are moving *away* from, and the moment
    /// the config catches up the two agree again. Here both accounts are stored and Toki
    /// has a fingerprint for each, so "who owns these bytes" is already settled — SHA256 of
    /// a refresh token cannot collide across accounts. Two stored slots claiming the same
    /// live credential therefore means one of them physically holds the other's credential.
    ///
    /// Deliberately NOT part of `resolve`: the display rule stays "bytes win", because a
    /// swap in flight and a stale cached config produce this same shape for a few hundred
    /// milliseconds, and a wrong label for that long beats an error state the user has to
    /// dismiss. This is a detector — a veto on *writes* (nothing may adopt or capture a
    /// credential while it holds) and a signal worth surfacing, not a fourth `ActiveAccount`
    /// case.
    public static func contradiction(
        liveCredentialJSON: Data?,
        slots: [AccountSlot],
        configAccountUuid: String?
    ) -> ActiveAccountContradiction? {
        guard let configAccountUuid,
              slots.contains(where: { $0.identity.accountUuid == configAccountUuid })
        else { return nil }
        guard case let .slot(byteMatched) = resolve(
            liveCredentialJSON: liveCredentialJSON,
            slots: slots,
            configAccountUuid: configAccountUuid
        ) else { return nil }
        guard byteMatched != configAccountUuid else { return nil }
        log.error("contradiction: live credential bytes belong to \(account: byteMatched) while config names \(account: configAccountUuid); refusing to treat these as the same account")
        return ActiveAccountContradiction(
            byteMatchedUuid: byteMatched, configNamedUuid: configAccountUuid
        )
    }
}
