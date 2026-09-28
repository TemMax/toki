/// Identity of a credential *lineage*, used to tell "the same account, rotated"
/// from "a different account entirely".
import Foundation
import CryptoKit
import TokiLogging

private let log = TokiLog.logger("accounts")

/// Fingerprints the refresh token rather than the access token: Claude Code rotates
/// access tokens constantly, but a refresh-token change means a new generation of the
/// same lineage, and a completely different value means a different account.
///
/// The returned digest is a bare, unsalted `SHA256(refreshToken)` — deliberately NOT
/// something this module ever logs verbatim. It is a stable, cross-install-comparable
/// identifier for one specific refresh token (that IS its purpose: two reads of the
/// same lineage must produce the same value everywhere). Printing it as-is anywhere
/// this codebase logs would be functionally the same mistake `HashSalt`'s own doc
/// comment warns against for an unsalted `SHA256(email)` — high entropy makes it
/// infeasible to invert back to the token, but it would still be a stable handle that
/// lets two log lines (or two different logs, on two different installs, if ever
/// compared) be joined on "the same account" without needing the plaintext. Any call
/// site that wants to mention a lineage value in a log line must route it through
/// `\(account:)` (or `privacy: .hashed`) so it is re-hashed behind the per-install
/// salt first, exactly like an email or display name would be.
public enum Lineage {
    public static func fingerprint(refreshToken: String) -> String {
        SHA256.hash(data: Data(refreshToken.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Returns nil when the payload carries no `claudeAiOauth.refreshToken` — e.g. an
    /// environment-token credential, or Claude Code's emptied-on-`invalid_grant` state.
    public static func fingerprint(credentialJSON: Data) -> String? {
        let parsed: [String: Any]?
        do {
            parsed = try JSONSerialization.jsonObject(with: credentialJSON) as? [String: Any]
        } catch {
            log.error("fingerprint: credentialJSON is not valid JSON, no lineage can be derived: \(error: error)")
            return nil
        }
        guard
            let root = parsed,
            let oauth = root["claudeAiOauth"] as? [String: Any],
            let refresh = oauth["refreshToken"] as? String,
            !refresh.isEmpty
        else {
            log.info("fingerprint: credentialJSON has no claudeAiOauth.refreshToken (environment-token credential, or Claude Code's emptied-on-invalid_grant state); no lineage to derive")
            return nil
        }
        return fingerprint(refreshToken: refresh)
    }
}
