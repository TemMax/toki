/// One stored Claude account.
import Foundation
import TokiLogging

private let log = TokiLog.logger("accounts")

public enum AccountHealth: String, Codable, Sendable {
    case ok
    /// The refresh-token lineage is dead; only a `/login` can revive this account.
    case needsReauth
}

/// A stored account: who it is, its credential, and the lineage that credential
/// belongs to. Persisted in a Toki-owned Keychain item — see `SlotStore`.
public struct AccountSlot: Codable, Equatable, Sendable {
    public var identity: AccountIdentity
    public var alias: String?
    /// Raw `{"claudeAiOauth": {…}}` bytes, exactly as Claude Code stores them.
    public var credentialJSON: Data
    /// One prior generation, kept as the recovery cushion for a failed refresh.
    public var previousCredentialJSON: Data?
    public var lineage: String
    public var addedAt: Date
    public var lastActiveAt: Date?
    public var lastRefreshAt: Date?
    public var health: AccountHealth

    public init(
        identity: AccountIdentity,
        alias: String?,
        credentialJSON: Data,
        previousCredentialJSON: Data?,
        lineage: String,
        addedAt: Date,
        lastActiveAt: Date?,
        lastRefreshAt: Date?,
        health: AccountHealth
    ) {
        self.identity = identity
        self.alias = alias
        self.credentialJSON = credentialJSON
        self.previousCredentialJSON = previousCredentialJSON
        self.lineage = lineage
        self.addedAt = addedAt
        self.lastActiveAt = lastActiveAt
        self.lastRefreshAt = lastRefreshAt
        self.health = health
    }

    /// Swap-time sync-back / re-add: a genuinely different lineage displaces the
    /// current one, which becomes the recovery cushion. Same lineage (Claude Code
    /// rotated only the access token) updates in place and leaves the cushion alone.
    public func replacingCredential(_ json: Data, now: Date) -> AccountSlot {
        // Bytes with no refresh token are Claude Code's emptied-on-invalid_grant state.
        // Storing them would destroy the slot's only refresh token and, worse, report the
        // account healthy; the stored credential is strictly better than nothing.
        guard let newLineage = Lineage.fingerprint(credentialJSON: json) else {
            log.error("replacingCredential: incoming credential for \(account: identity.accountUuid) has no refresh token; refusing to overwrite the stored one")
            return self
        }
        var copy = self
        if newLineage != lineage {
            log.info("replacingCredential: lineage changed for \(account: identity.accountUuid); previous generation kept as the recovery cushion")
            copy.previousCredentialJSON = credentialJSON
        } else {
            log.info("replacingCredential: same lineage for \(account: identity.accountUuid); rotating the access token only")
        }
        copy.credentialJSON = json
        copy.lineage = newLineage
        copy.lastActiveAt = now
        copy.health = .ok
        return copy
    }

    /// Refresh-time update: replaces the credential WITHOUT touching the cushion.
    public func refreshingCredential(_ json: Data, now: Date) -> AccountSlot {
        let newLineage = Lineage.fingerprint(credentialJSON: json)
        if newLineage == nil {
            log.error("refreshingCredential: refreshed credential for \(account: identity.accountUuid) has no refresh token; keeping the prior lineage")
        }
        var copy = self
        copy.credentialJSON = json
        copy.lineage = newLineage ?? lineage
        copy.lastRefreshAt = now
        copy.health = .ok
        return copy
    }

    /// Alias when set, otherwise the identity's own label.
    public var displayLabel: String {
        if let alias, !alias.isEmpty { return alias }
        return identity.label
    }
}
