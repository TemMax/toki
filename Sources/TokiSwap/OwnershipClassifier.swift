/// Decides whether a live credential may be written back into a given slot.
import Foundation
import TokiAccounts
import TokiLogging

private let log = TokiLog.logger("swap")

public enum OwnershipVerdict: Equatable, Sendable {
    /// Same lineage — safe to store.
    case own
    /// A newer or older generation of the same lineage — safe to store.
    case ownRotated
    /// Belongs to a different account — must be quarantined, never stored.
    case foreign
    /// Token fields emptied by Claude Code's `invalid_grant` handling — never stored.
    case wiped
    /// Ownership could not be established — treated exactly like `foreign`.
    case unresolved
}

/// The guard that stops a swap from destroying an account's only refresh token.
///
/// The prior art shipped without it and had a slot's credential overwritten by an
/// unrelated login, which is unrecoverable: a refresh token exists in exactly one place.
public enum OwnershipClassifier {
    public static func classify(
        liveCredentialJSON: Data,
        slot: AccountSlot,
        oracleIdentity: AccountIdentity?
    ) -> OwnershipVerdict {
        guard let live = Lineage.fingerprint(credentialJSON: liveCredentialJSON) else {
            log.notice("""
                the live credential carries no token pair (wiped); it will not be stored \
                \(account: slot.identity.accountUuid)
                """)
            return .wiped
        }
        if live == slot.lineage {
            log.info("the live credential is the one this account already holds \(account: slot.identity.accountUuid)")
            return .own
        }
        if let previous = slot.previousCredentialJSON,
           Lineage.fingerprint(credentialJSON: previous) == live {
            log.info("the live credential is this account's previous generation \(account: slot.identity.accountUuid)")
            return .ownRotated
        }
        guard let oracleIdentity else {
            log.notice("ownership of the live credential is unproven; it will be quarantined \(account: slot.identity.accountUuid)")
            return .unresolved
        }
        if oracleIdentity.accountUuid == slot.identity.accountUuid {
            log.info("the profile endpoint confirms the live credential is a rotation of this account's \(account: slot.identity.accountUuid)")
            return .ownRotated
        }
        log.notice("""
            the live credential belongs to another account and will be quarantined \
            slot=\(account: slot.identity.accountUuid) owner=\(account: oracleIdentity.accountUuid)
            """)
        return .foreign
    }
}
