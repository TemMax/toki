/// Keeps sleeping accounts' tokens alive without ever touching the live one.
import Foundation
import TokiAccounts
import TokiLogging
import TokiModels

private let log = TokiLog.logger("swap")

public enum TokenEndpointError: Error, Equatable {
    /// The lineage is dead — only a fresh `/login` can revive the account.
    case permanent(String)
}

public protocol TokenEndpoint: Sendable {
    /// Exchanges a refresh token for a new credential payload.
    func refresh(refreshToken: String) async throws -> Data
}

public enum RefreshOutcome: Equatable, Sendable {
    case skipped
    case refreshed(AccountSlot)
    case deadLineage(AccountSlot)
    case transientFailure
    /// The endpoint granted a successor generation but it could not be persisted. The
    /// grant is already spent, so the slot carries the new credential in memory only —
    /// flagged so the caller can surface that this account needs attention.
    case persistenceFailed(AccountSlot)
}

/// Claude Code's own OAuth client, verified present in the shipped 2.1.223 binary.
public struct AnthropicTokenEndpoint: TokenEndpoint {
    private static let url = URL(string: "https://platform.claude.com/v1/oauth/token")!
    private static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func refresh(refreshToken: String) async throws -> Data {
        var request = URLRequest(url: Self.url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": Self.clientID,
        ])

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw TokiError.httpError(-1) }

        if (400..<500).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? ""
            if body.contains("invalid_grant") || body.contains("invalid_client") {
                log.notice("the token endpoint refused the grant permanently http=\(http.statusCode)")
                throw TokenEndpointError.permanent(body.contains("invalid_client")
                    ? "invalid_client" : "invalid_grant")
            }
            log.notice("the token endpoint answered http=\(http.statusCode)")
            throw TokiError.httpError(http.statusCode)
        }
        guard http.statusCode == 200 else {
            log.notice("the token endpoint answered http=\(http.statusCode)")
            throw TokiError.httpError(http.statusCode)
        }

        // no-log: the value being decoded is the token-endpoint body, which IS the new
        // token pair; the refusal below carries everything that is safe to say about it.
        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            log.notice("the token endpoint answered with a body this build cannot read")
            throw TokiError.decoding("token endpoint: unreadable body")
        }
        // The endpoint returns the token pair flat; store it in Claude Code's own shape.
        var oauth: [String: Any] = [:]
        oauth["accessToken"] = payload["access_token"] ?? payload["accessToken"]
        oauth["refreshToken"] = payload["refresh_token"] ?? payload["refreshToken"]
        if let expiresIn = payload["expires_in"] as? Double {
            oauth["expiresAt"] = Date().addingTimeInterval(expiresIn).timeIntervalSince1970 * 1000
        }
        if let scopes = payload["scope"] as? String {
            oauth["scopes"] = scopes.split(separator: " ").map(String.init)
        }
        guard oauth["accessToken"] != nil, oauth["refreshToken"] != nil else {
            log.notice("the token endpoint answered 200 with no token pair in it")
            throw TokiError.decoding("token endpoint: no token pair in body")
        }
        return try JSONSerialization.data(withJSONObject: ["claudeAiOauth": oauth])
    }
}

/// Refreshes sleeping slots only.
public actor TokenRefresher {
    /// Refresh this far ahead of expiry. Twice Claude Code's own 5-minute buffer, so an
    /// account activated moments later is already fresh and the CLI does not immediately
    /// run its own refresh.
    public static let freshenWindow: TimeInterval = 600

    private let endpoint: any TokenEndpoint
    private let store: any SlotStoring
    private let now: @Sendable () -> Date

    public init(
        endpoint: any TokenEndpoint,
        store: any SlotStoring,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.endpoint = endpoint
        self.store = store
        self.now = now
    }

    /// `activeAccountUuid` is the account `~/.claude.json` names, when it is known. It is a
    /// second, independent exclusion: while the live credential has rotated past every
    /// generation the slots hold — or while adoption is being refused because ownership
    /// could not be proven — `activeLineage` matches nothing, and the config is then the
    /// only thing that still identifies the live account. Refreshing that slot would spend
    /// an older generation of the LIVE lineage: either it fails and the account is flagged
    /// dead for no reason, or it succeeds and invalidates the credential Claude Code is
    /// holding, forcing the re-login this whole feature exists to prevent.
    /// `force` skips only the expiry-window check — for a caller whose usage poll
    /// just got a 401, the token is proven dead whatever `expiresAt` claims. It
    /// never bypasses the live-account exclusions above: a 401 on a slot that IS
    /// secretly the live account must still refresh nothing.
    public func refreshIfNeeded(
        slot: AccountSlot,
        activeLineage: String?,
        activeAccountUuid: String? = nil,
        force: Bool = false
    ) async -> RefreshOutcome {
        if let activeAccountUuid, slot.identity.accountUuid == activeAccountUuid {
            return .skipped
        }
        // The single most important rule in the feature: Claude Code owns the live
        // credential, and its refresh tokens are single-use. Not knowing which account is
        // live is therefore a reason to refresh nothing — the alternative is refreshing
        // the live one, and a `nil` here is routine (a silent Keychain read that failed).
        guard let activeLineage else { return .skipped }
        guard slot.lineage != activeLineage else { return .skipped }
        // The resolver reports a slot as active through its recovery cushion too, so the
        // same slot must be off-limits here.
        if let previous = slot.previousCredentialJSON,
           Lineage.fingerprint(credentialJSON: previous) == activeLineage {
            return .skipped
        }
        guard slot.health == .ok else { return .skipped }
        guard let refreshToken = Self.refreshToken(of: slot.credentialJSON) else { return .skipped }
        guard force || Self.expiresSoon(slot.credentialJSON, now: now(), window: Self.freshenWindow) else {
            return .skipped
        }

        log.info("refreshing a sleeping account's token \(account: slot.identity.accountUuid)")
        do {
            let fresh = try await endpoint.refresh(refreshToken: refreshToken)
            let updated = slot.refreshingCredential(fresh, now: now())
            // Persist first, unconditionally: the grant consumed a generation, and a
            // successor that is never stored is a lineage killed by its own renewal. A
            // failed save must not be reported as `.refreshed` — the caller needs to know
            // the only copy of the new token is sitting in memory for one tick. Do not
            // retry the REFRESH here: that would spend another (already-scarce) grant.
            // Retrying the WRITE is a different question, answered in `savingWithOneRetry`.
            do {
                try Self.savingWithOneRetry(updated, to: store)
                log.info("token refreshed and stored \(account: slot.identity.accountUuid)")
                return .refreshed(updated)
            } catch {
                log.error("""
                    the refreshed token could not be stored, so the only copy of it is in \
                    memory: \(error: error) \(account: slot.identity.accountUuid)
                    """)
                var flagged = updated
                flagged.health = .needsReauth
                return .persistenceFailed(flagged)
            }
        } catch is TokenEndpointError {
            log.error("the account's refresh token is dead; only a new sign-in can revive it \(account: slot.identity.accountUuid)")
            var dead = slot
            dead.health = .needsReauth
            do {
                try store.save(dead)
            } catch {
                log.error("""
                    the account could not be flagged as needing a new sign-in: \(error: error) \
                    \(account: slot.identity.accountUuid)
                    """)
            }
            return .deadLineage(dead)
        } catch {
            // "Transient" describes what we can observe, not what necessarily happened.
            // A request that never reached the endpoint is genuinely harmless and the
            // retry costs nothing. But a request that DID reach it and whose response was
            // lost — a timeout, a dropped connection — has already rotated the grant
            // server-side, and nothing in this error distinguishes the two cases. In that
            // shape the stored token is spent, `health` still reads `.ok`, and the next
            // attempt is the one that gets `invalid_grant` and marks the account dead.
            // There is no client-side fix: the token endpoint takes no idempotency key,
            // so a retry cannot be made to re-fetch the successor it already issued.
            // Do not "improve" this into a silent retry loop — each pass is another
            // chance to spend a grant whose answer never comes back.
            log.notice("token refresh failed for now; it will be retried: \(error: error) \(account: slot.identity.accountUuid)")
            return .transientFailure
        }
    }

    /// Swap-in renewal. What matters when a stored credential is about to become the
    /// live one is not "is it close to expiry" but "how much of a token lifetime does
    /// Claude Code get before IT must refresh". A slot freshened hours ago passes the
    /// first test and fails the second: it activates with the tail of a lifetime, and
    /// Claude Code's own refresh then lands in the middle of a working session — which
    /// is where its concurrent processes race each other over a single-use grant, the
    /// losers get `invalid_grant`, and a loser empties the credential item for everyone
    /// (observed 2026-08-26: fifteen sessions, one dead account, no way back but
    /// `/login`). Renewing unconditionally moves that refresh to a moment Toki controls,
    /// with exactly one process holding the successor.
    ///
    /// `force` skips the expiry window and nothing else, so every live-account exclusion
    /// in `refreshIfNeeded` still applies. In particular an unreadable live credential
    /// (`activeLineage == nil`) still renews nothing: restoring a stored account after a
    /// `/logout` has no live lineage to compare against, and refreshing without knowing
    /// which lineage is live is the one move this subsystem must never make. That path
    /// keeps activating the stored bytes, exactly as before.
    public func freshenForActivation(
        slot: AccountSlot,
        activeLineage: String?
    ) async -> RefreshOutcome {
        await refreshIfNeeded(slot: slot, activeLineage: activeLineage, force: true)
    }

    /// Writes a refreshed slot, retrying the write — and only the write — exactly once.
    ///
    /// The no-retry rule on the refresh itself forbids asking the *endpoint* again, because
    /// that spends another already-scarce grant. Asking the *store* again spends nothing:
    /// by the time this runs the grant is gone either way, and the only question left is
    /// whether its successor survives. Losing that race is expensive and silent — the slot
    /// keeps a token the endpoint has just consumed while `health` still reads `.ok`, so
    /// the account presents as fine and is already dead, and only a `/login` brings it
    /// back. A momentarily unavailable Keychain is not worth an account.
    ///
    /// Twice and no further. A store that refuses two writes in a row is broken in a way a
    /// third attempt will not fix, and every caller here needs an answer this tick rather
    /// than a loop.
    static func savingWithOneRetry(_ slot: AccountSlot, to store: any SlotStoring) throws {
        do {
            try store.save(slot)
        } catch {
            log.notice("""
                the refreshed token could not be stored; retrying the write once: \
                \(error: error) \(account: slot.identity.accountUuid)
                """)
            try store.save(slot)
        }
    }

    static func refreshToken(of json: Data) -> String? {
        guard
            // no-log: decoding stored credential bytes; the answer this returns is "there
            // is no usable refresh token", which the caller acts on, and the bytes
            // themselves must never reach a log line.
            let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
            let oauth = root["claudeAiOauth"] as? [String: Any],
            let token = oauth["refreshToken"] as? String, !token.isEmpty
        else { return nil }
        return token
    }

    static func expiresSoon(_ json: Data, now: Date, window: TimeInterval) -> Bool {
        guard
            // no-log: same stored credential bytes; an unreadable expiry is handled by
            // treating the token as due, which is the safe answer, not an error.
            let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
            let oauth = root["claudeAiOauth"] as? [String: Any],
            let ms = oauth["expiresAt"] as? Double
        else { return true }   // unknown expiry → treat as due
        return Date(timeIntervalSince1970: ms / 1000) < now.addingTimeInterval(window)
    }
}
