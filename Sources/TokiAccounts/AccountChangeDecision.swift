/// What to do when `~/.claude.json`'s signed-in account may have changed.
import Foundation
import TokiLogging
import TokiModels

private let log = TokiLog.logger("accounts")

public enum AccountChange: Equatable, Sendable {
    /// Same account as last seen (or unreadable) — deduplicated, nothing to do. Claude Code
    /// rewrites the config constantly for unrelated reasons, so most events land here.
    case ignore
    /// The account changed to one already stored: refresh the gauges/stats so they track the
    /// switch instantly, but don't offer to save what is already saved.
    case reloadOnly
    /// The account changed to one Toki doesn't store: refresh, and offer to save it.
    case offerSave(String)
}

public enum AccountChangeDecision {
    /// Used after a successful config read. A nil identity means an actual logout;
    /// unreadable files are filtered by the watcher before calling this overload.
    public static func decide(
        newIdentity: UsageAccount?, lastSeenIdentity: UsageAccount?, storedUuids: Set<String>
    ) -> AccountChange {
        guard newIdentity != lastSeenIdentity else { return .ignore }
        guard let newIdentity else { return .reloadOnly }
        if newIdentity.accountUuid == lastSeenIdentity?.accountUuid { return .reloadOnly }
        return decide(
            newUuid: newIdentity.accountUuid,
            lastSeenUuid: lastSeenIdentity?.accountUuid,
            storedUuids: storedUuids
        )
    }

    /// Keyed on `accountUuid`, never the token: Claude Code rotates the token of the *same*
    /// account routinely, and that must not read as a new account. Only a different account
    /// uuid is a change worth acting on.
    public static func decide(
        newUuid: String?, lastSeenUuid: String?, storedUuids: Set<String>
    ) -> AccountChange {
        guard let newUuid, newUuid != lastSeenUuid else {
            log.info("decide: no account change detected (same as last seen, or unreadable); ignoring")
            return .ignore
        }
        if storedUuids.contains(newUuid) {
            log.info("decide: config now names \(account: newUuid), already stored; reloading only")
            return .reloadOnly
        }
        log.info("decide: config now names \(account: newUuid), not yet stored; offering to save")
        return .offerSave(newUuid)
    }
}
