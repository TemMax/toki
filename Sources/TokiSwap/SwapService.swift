/// The account-swap transaction.
import Foundation
import TokiAccounts
import TokiKeychain
import TokiLogging

private let log = TokiLog.logger("swap")

public protocol LiveCredentialAccess: Sendable {
    /// The credential Claude Code is currently using, plus the item it lives in.
    func readLive() async -> (json: Data, ref: KeychainItemRef)?
}

public struct SwapOutcome: Equatable, Sendable {
    public let from: String?
    public let to: String
    /// True when the outgoing credential could not be attributed and was preserved
    /// instead of being written into a slot.
    public let quarantined: Bool
    /// The target was already the account Claude Code is signed into, so nothing was
    /// touched.
    public let alreadyActive: Bool

    public init(from: String?, to: String, quarantined: Bool, alreadyActive: Bool = false) {
        self.from = from
        self.to = to
        self.quarantined = quarantined
        self.alreadyActive = alreadyActive
    }
}

public enum SwapError: Error, Equatable {
    case unknownAccount
    case alreadySwapping
    case claudeBusy
    case writeFailed
    case configFailed
    /// The outgoing account's credential could not be stored or quarantined. Preserving it
    /// is a precondition of overwriting the live one (D2): writing anyway would destroy
    /// the only surviving copy of that account's refresh token.
    case preservationFailed
    /// The target's refresh token is dead (or its successor could not be recorded), so it
    /// was never activated. Writing it would hand Claude Code a credential it cannot use —
    /// "OAuth session expired and could not be refreshed" — with no way back.
    case targetNeedsReauth
    /// The target's token needed freshening and the attempt failed for a transient reason
    /// (network). Nothing was written; the caller retries.
    case freshenFailed
    /// A credential write/verification or config update failed, and restoring the
    /// outgoing credential failed too. Claude Code may now hold the target's
    /// credential while the config still names the outgoing account.
    case rollbackFailed
    /// Claude Code's credential item is neither readable nor locatable, so there is no
    /// item to write the target credential into.
    case noCredentialItem
}

extension SwapError: LocalizedError {
    // One plain sentence per case: the UI shows `errorDescription` directly, so without this
    // the user sees "The operation couldn't be completed. (TokiSwap.SwapError error N.)".
    public var errorDescription: String? {
        switch self {
        case .unknownAccount:
            return "That account is no longer stored in Toki."
        case .alreadySwapping:
            return "Another account switch is already running."
        case .claudeBusy:
            return "Claude is busy right now — try again in a moment."
        case .writeFailed:
            return "Couldn't write the account's credential to the Keychain."
        case .configFailed:
            return "Couldn't point Claude's configuration at the new account."
        case .targetNeedsReauth:
            return "That account needs signing in again — its session could not be renewed, so Toki left you on the current one."
        case .freshenFailed:
            return "Couldn't renew that account's session just now — check your connection and try again."
        case .preservationFailed:
            return "The switch was cancelled to avoid losing the current account's sign-in, "
                + "which couldn't be saved first."
        case .rollbackFailed:
            return "The switch failed and the previous account couldn't be restored — open "
                + "the Claude CLI and run /login."
        case .noCredentialItem:
            return "Couldn't find a Claude sign-in to switch — sign in to the Claude CLI once, then try again."
        }
    }
}

public struct SwapDependencies: Sendable {
    public let store: any SlotStoring
    public let live: any LiveCredentialAccess
    public let writer: CredentialWriter
    public let config: ClaudeConfigEditor
    public let oracle: any ProfileLookup
    public let locks: LockBroker
    public let configDir: URL
    public let fallbackFileURL: URL
    /// Locates Claude Code's credential item when nothing live can be read. After a
    /// `/logout` there is no credential to read back, which is precisely when restoring a
    /// stored account matters most; `add-generic-password -U` recreates the item.
    public let credentialItemRef: @Sendable () -> KeychainItemRef?
    public let now: @Sendable () -> Date
    /// Called after a successful swap so Toki' own credential cache drops the token
    /// that now belongs to the previous account.
    public let onVaultInvalidated: @Sendable () async -> Void
    /// Brings the target's stored token up to date immediately before it is activated,
    /// given the lineage that is currently live (so the live one is never refreshed).
    /// Defaults to doing nothing, which is what a caller with no token endpoint wants.
    public let freshen: @Sendable (AccountSlot, String?) async -> RefreshOutcome

    public init(
        store: any SlotStoring,
        live: any LiveCredentialAccess,
        writer: CredentialWriter,
        config: ClaudeConfigEditor,
        oracle: any ProfileLookup,
        locks: LockBroker,
        configDir: URL,
        fallbackFileURL: URL,
        credentialItemRef: @escaping @Sendable () -> KeychainItemRef? = {
            KeychainItemRef.selectClaudeItem()
        },
        now: @escaping @Sendable () -> Date = { Date() },
        onVaultInvalidated: @escaping @Sendable () async -> Void,
        freshen: @escaping @Sendable (AccountSlot, String?) async -> RefreshOutcome = { _, _ in .skipped }
    ) {
        self.store = store
        self.live = live
        self.writer = writer
        self.config = config
        self.oracle = oracle
        self.locks = locks
        self.configDir = configDir
        self.fallbackFileURL = fallbackFileURL
        self.credentialItemRef = credentialItemRef
        self.now = now
        self.onVaultInvalidated = onVaultInvalidated
        self.freshen = freshen
    }
}

/// Serialises every swap — manual and automatic — through one actor, and through a
/// cross-process lock so a Debug build and the installed Release cannot interleave.
public actor SwapService {
    private let deps: SwapDependencies
    private var inFlight = false

    public init(dependencies: SwapDependencies) {
        self.deps = dependencies
    }

    public func swap(to accountUuid: String) async throws -> SwapOutcome {
        // A queued swap would act on stale gauge data, so a concurrent request is
        // rejected rather than deferred.
        guard !inFlight else {
            log.notice("swap refused: another swap is already running \(account: accountUuid)")
            throw SwapError.alreadySwapping
        }
        inFlight = true
        defer { inFlight = false }

        log.info("swap starting \(account: accountUuid)")
        let slots: [AccountSlot]
        do {
            slots = try deps.store.loadAll()
        } catch {
            log.error("stored accounts could not be loaded: \(error: error)")
            slots = []
        }
        guard var target = slots.first(where: { $0.identity.accountUuid == accountUuid }) else {
            log.error("swap aborted: that account is not stored \(account: accountUuid)")
            throw SwapError.unknownAccount
        }

        // Everything that needs the network happens BEFORE any lock is taken.
        let liveState = await deps.live.readLive()
        // no-log: `ClaudeConfigEditor` logs its own read failure, and a config that names
        // no account is an ordinary state the resolver is built to handle.
        let configAccountUuid = (try? deps.config.readOAuthAccount())?["accountUuid"] as? String
        let outgoing = ActiveAccountResolver.resolve(
            liveCredentialJSON: liveState?.json, slots: slots, configAccountUuid: configAccountUuid
        )

        // Swapping to the account already signed in would write the slot's older copy over
        // a credential Claude Code has since rotated — a refresh token it has already
        // spent — and quarantine the working one. There is nothing to do.
        if Self.resolvedSlotUuid(outgoing) == accountUuid {
            log.info("swap finished: that account is already the live one \(account: accountUuid)")
            return SwapOutcome(
                from: accountUuid, to: accountUuid, quarantined: false, alreadyActive: true
            )
        }

        // Freshen the target before activating it — unconditionally, not just inside
        // Claude Code's refresh buffer. What lands in the Keychain is what Claude Code
        // runs the whole session on, and a token handed over half-spent forces Claude
        // Code's own refresh into the middle of that session: the moment its concurrent
        // processes race over a single-use grant and the loser empties the credential
        // item. Renewing here spends the grant once, from one process, at a moment Toki
        // controls. A target whose grant is dead is NOT activated — writing it produces
        // exactly "OAuth session expired and could not be refreshed" with the outgoing
        // account already overwritten.
        let activeLineage: String? = liveState.flatMap { Lineage.fingerprint(credentialJSON: $0.json) }
        switch await deps.freshen(target, activeLineage) {
        case .skipped:
            // Nothing was renewed because renewing was not safe or not possible: no live
            // credential could be read (a restore after `/logout`), the target IS the live
            // lineage or its recovery cushion, the slot holds no refresh token, or the
            // slot is already flagged `needsReauth`. Activate the stored bytes.
            //
            // That last reason is the one to watch: it activates a credential Toki has
            // already recorded as dead. It is unreachable today — `AccountSwitcher`
            // disables the row and `AutoSwapPolicy` filters candidates on `isHealthy`, so
            // no caller offers such a target — but a future caller that skips those checks
            // would land here and hand Claude Code a token it cannot use.
            break
        case let .refreshed(updated):
            log.info("the target's token was renewed before activation \(account: accountUuid)")
            target = updated
        case .deadLineage, .persistenceFailed:
            // `.persistenceFailed` counts as dead here on purpose: the grant is spent and
            // its successor exists only in memory, so activating would burn the lineage
            // with nothing recorded to swap back to.
            log.error("swap aborted: the target account needs a new sign-in \(account: accountUuid)")
            throw SwapError.targetNeedsReauth
        case .transientFailure:
            log.notice("swap aborted: the target's token could not be renewed just now \(account: accountUuid)")
            throw SwapError.freshenFailed
        }

        let plan = await planSyncBack(liveState: liveState, outgoing: outgoing, slots: slots)

        let outcome = try await withLocks([
            ClaudeLocks.tokiSwap(configDir: deps.configDir),
            ClaudeLocks.oauthRefresh(configDir: deps.configDir),
            ClaudeLocks.storageWrite(configDir: deps.configDir),
        ]) {
            try await self.apply(plan: plan, target: target, liveState: liveState)
        }
        log.info("""
            swap finished quarantined=\(outcome.quarantined) \(account: outcome.to)
            """)
        return outcome
    }

    /// Steps 1–4, run with every Claude Code lock held.
    private func apply(
        plan: SyncBackPlan,
        target: AccountSlot,
        liveState: (json: Data, ref: KeychainItemRef)?
    ) async throws -> SwapOutcome {
        // 1. Sync back / quarantine the outgoing credential. Per D2 this is a precondition
        //    of step 2, not a side effect: the write about to happen destroys the live
        //    bytes, so failing to preserve them first aborts the whole swap.
        switch plan {
        case let .store(slot):
            do {
                try deps.store.save(slot)
                log.info("the outgoing account's credential was saved back into its slot \(account: slot.identity.accountUuid)")
            } catch {
                log.error("""
                    swap aborted: the outgoing account's credential could not be saved, and \
                    overwriting it would destroy the only copy: \(error: error)
                    """)
                throw SwapError.preservationFailed
            }
        case let .quarantine(entry):
            do {
                try deps.store.saveQuarantine(entry, now: deps.now())
                log.notice("the outgoing credential could not be attributed and was quarantined")
            } catch {
                log.error("""
                    swap aborted: the outgoing credential could not be quarantined, and \
                    overwriting it would destroy the only copy: \(error: error)
                    """)
                throw SwapError.preservationFailed
            }
        case .nothing:
            break
        }

        // 2. Write the target credential, keeping the bytes needed to roll back. A machine
        //    with no readable credential (a `/logout`) has nothing to roll back to, but the
        //    item can still be named and written — that is the case restoring exists for.
        guard let ref = liveState?.ref ?? deps.credentialItemRef() else {
            log.error("swap aborted: Claude Code's credential item is neither readable nor locatable")
            throw SwapError.noCredentialItem
        }
        let rollbackCredential = liveState?.json
        // no-log: `ClaudeConfigEditor` logs its own read failure; a nil here simply means
        // there is no config state to roll back to.
        let rollbackOAuth = try? deps.config.readOAuthAccount()
        do {
            try await deps.writer.write(target.credentialJSON, to: ref)
        } catch CredentialWriteError.invalidCredential {
            log.error("swap aborted: target credential is invalid; nothing was written")
            throw SwapError.writeFailed
        } catch {
            log.error("swap aborted: the target credential could not be written: \(error: error)")
            // A timeout or unavailable/mismatched verification can follow a successful
            // write, so the bytes may well have landed. Leaving them there would hand Claude
            // Code the target's credential under the outgoing account's config.
            var rollbackFailed = false
            if let rollbackCredential {
                do {
                    try await deps.writer.write(rollbackCredential, to: ref)
                    log.notice("the outgoing credential was written back after the failed write")
                } catch {
                    rollbackFailed = true
                    log.error("""
                        the outgoing credential could not be written back after a failed \
                        write; Claude Code may now hold the target's credential: \(error: error)
                        """)
                }
            }
            await deps.onVaultInvalidated()
            throw rollbackFailed ? SwapError.rollbackFailed : SwapError.writeFailed
        }

        // 3. Point the config at the target account.
        let existingConfigUuid = (rollbackOAuth ?? nil)?["accountUuid"] as? String
        do {
            try deps.config.replaceOAuthAccount(
                with: Self.oauthObject(for: target, existingConfigUuid: existingConfigUuid)
            )
        } catch {
            log.error("the config could not be pointed at the target account: \(error: error)")
            var failure = SwapError.configFailed
            if let rollbackCredential {
                // Unlike step 2's best-effort restore, this rollback is the only thing
                // standing between the user and a credential/config mismatch, so its
                // failure has to reach them.
                do {
                    try await deps.writer.write(rollbackCredential, to: ref)
                    log.notice("swap rolled back: the outgoing credential is live again")
                } catch {
                    log.fault("""
                        rollback failed: Claude Code holds the target's credential while the \
                        config still names the outgoing account, and only a new sign-in fixes \
                        it: \(error: error)
                        """)
                    failure = .rollbackFailed
                }
            }
            if let rollbackOAuth {
                do {
                    try deps.config.replaceOAuthAccount(with: rollbackOAuth)
                } catch {
                    log.error("the config could not be restored to the outgoing account: \(error: error)")
                }
            }
            await deps.onVaultInvalidated()
            throw failure
        }

        // 4. Keep Claude Code's own fallback consistent — but never create it. A file we
        //    created would only ever be read if the Keychain failed, and by then it would
        //    be stale; an existing one holding the previous account is a trap.
        if FileManager.default.fileExists(atPath: deps.fallbackFileURL.path) {
            Self.writeFallbackFile(target.credentialJSON, to: deps.fallbackFileURL)
        }

        var activated = target
        activated.lastActiveAt = deps.now()
        do {
            try deps.store.save(activated)
        } catch {
            log.error("""
                the account was activated but its slot could not be updated: \(error: error) \
                \(account: activated.identity.accountUuid)
                """)
        }
        await deps.onVaultInvalidated()

        return SwapOutcome(
            from: plan.storedAccountUuid,
            to: target.identity.accountUuid,
            quarantined: plan.isQuarantine
        )
    }

    /// Writes the credential so it is never world-readable, not even for the instant
    /// between the rename and a chmod.
    ///
    /// Measured: `Data.write(options: .atomic)` publishes a NEW inode that inherits the
    /// **destination's** mode, so a 0644 fallback file would briefly hold the secret at
    /// 0644. Narrowing the destination first makes the replacement 0600 from the moment it
    /// exists; the trailing chmod covers a destination that did not exist at all.
    static func writeFallbackFile(_ credentialJSON: Data, to url: URL) {
        let ownerOnly: [FileAttributeKey: Any] = [.posixPermissions: 0o600]
        // no-log: the destination legitimately may not exist yet — this call is the
        // narrowing that makes the replacement inherit 0600 when it does, and the chmod
        // after the write is the one that must succeed.
        try? FileManager.default.setAttributes(ownerOnly, ofItemAtPath: url.path)
        do {
            try credentialJSON.write(to: url, options: .atomic)
        } catch {
            log.error("""
                Claude Code's fallback credential file could not be updated and now holds \
                another account's sign-in code=\((error as NSError).code) \(path: url)
                """)
        }
        do {
            try FileManager.default.setAttributes(ownerOnly, ofItemAtPath: url.path)
        } catch {
            log.error("""
                the fallback credential file could not be narrowed to owner-only \
                code=\((error as NSError).code) \(path: url)
                """)
        }
    }

    private static func resolvedSlotUuid(_ active: ActiveAccount) -> String? {
        switch active {
        case let .slot(uuid), let .slotNeedsAdoption(uuid): return uuid
        case .unknown, .none: return nil
        }
    }

    // MARK: Sync-back planning (network happens here, before any lock)

    private enum SyncBackPlan {
        case store(AccountSlot)
        case quarantine(QuarantineEntry)
        case nothing

        var storedAccountUuid: String? {
            if case let .store(slot) = self { return slot.identity.accountUuid }
            return nil
        }
        var isQuarantine: Bool {
            if case .quarantine = self { return true }
            return false
        }
    }

    private func planSyncBack(
        liveState: (json: Data, ref: KeychainItemRef)?,
        outgoing: ActiveAccount,
        slots: [AccountSlot]
    ) async -> SyncBackPlan {
        guard let liveState else { return .nothing }

        let candidate: AccountSlot?
        if case let .slot(uuid) = outgoing {
            candidate = slots.first { $0.identity.accountUuid == uuid }
        } else {
            candidate = nil
        }

        guard let slot = candidate else {
            return await quarantinePlan(for: liveState.json)
        }

        let oracleIdentity = await lookupOwner(of: liveState.json)
        switch OwnershipClassifier.classify(
            liveCredentialJSON: liveState.json, slot: slot, oracleIdentity: oracleIdentity
        ) {
        case .own, .ownRotated:
            return .store(slot.replacingCredential(liveState.json, now: deps.now()))
        case .foreign, .unresolved:
            return await quarantinePlan(for: liveState.json)
        case .wiped:
            // Never copy Claude Code's emptied credential over a surviving refresh token.
            return .nothing
        }
    }

    private func quarantinePlan(for json: Data) async -> SyncBackPlan {
        guard let lineage = Lineage.fingerprint(credentialJSON: json) else { return .nothing }
        let owner = await lookupOwner(of: json)
        return .quarantine(QuarantineEntry(
            id: String(lineage.prefix(16)),
            credentialJSON: json,
            foundAt: deps.now(),
            ownerLabel: owner?.label
        ))
    }

    private func lookupOwner(of json: Data) async -> AccountIdentity? {
        guard
            // no-log: decoding the live credential bytes; "no access token" is the answer
            // the caller acts on, and the bytes themselves may never reach a log line.
            let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
            let oauth = root["claudeAiOauth"] as? [String: Any],
            let token = oauth["accessToken"] as? String, !token.isEmpty
        else { return nil }
        do {
            return try await deps.oracle.owner(ofToken: token)
        } catch {
            log.notice("the live credential's owner could not be established: \(error: error)")
            return nil
        }
    }

    /// Acquires `descriptors` in order and releases them in reverse on every exit path —
    /// return, throw, or a failure part-way through acquisition.
    ///
    /// `defer { Task { await release } }` cannot do this: the task is only *scheduled*, so
    /// the lock directories are still on disk when the function returns. Measured: zero of
    /// the three were gone at that point, which makes the next swap — and Claude Code's own
    /// credential write — see a lock nobody holds until it times out as stale.
    private func withLocks<T>(
        _ descriptors: [LockDescriptor], _ body: () async throws -> T
    ) async throws -> T {
        var held: [LockToken] = []
        do {
            for descriptor in descriptors { held.append(try await take(descriptor)) }
            let result = try await body()
            await releaseAll(held)
            return result
        } catch {
            log.notice("releasing \(held.count) Claude Code lock(s) after a failed swap")
            await releaseAll(held)
            throw error
        }
    }

    private func releaseAll(_ tokens: [LockToken]) async {
        for token in tokens.reversed() { await deps.locks.release(token) }
    }

    private func take(_ descriptor: LockDescriptor) async throws -> LockToken {
        do {
            return try await deps.locks.acquire(descriptor, timeout: 3)
        } catch {
            log.notice("swap aborted: Claude Code is holding a lock \(path: descriptor.path)")
            throw SwapError.claudeBusy
        }
    }

    private static func oauthObject(
        for slot: AccountSlot, existingConfigUuid: String?
    ) -> [String: Any] {
        var object: [String: Any] = [:]
        // A slot adopted from quarantine without a confirmed identity carries a provisional
        // `accountUuid` — the credential's lineage-fingerprint prefix, not an id Anthropic
        // issued. Writing that into `~/.claude.json` would plant a fabricated account id in
        // Claude Code's own config. Keep whatever accountUuid Claude Code already had until
        // its first successful refresh writes the real one; a confirmed slot writes its own.
        object["accountUuid"] = AdoptionPlan.isProvisionalIdentity(slot)
            ? existingConfigUuid
            : slot.identity.accountUuid
        object["emailAddress"] = slot.identity.email
        object["displayName"] = slot.identity.displayName
        object["organizationName"] = slot.identity.organizationName
        object["organizationUuid"] = slot.identity.organizationUuid
        return object.compactMapValues { $0 }
    }
}
