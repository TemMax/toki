import Foundation
import TokiLogging

private let log = TokiLog.logger("account")

/// Reads the active Claude account's identity — display name, email, organization —
/// from the `oauthAccount` block of `~/.claude.json`, so the app can show *which*
/// account Claude Code is currently signed into.
///
/// SECURITY: `~/.claude.json` is a large, mixed-sensitivity document (its
/// `oauthAccount` block sits alongside OAuth tokens elsewhere in the file, API-key
/// responses, and raw MCP server configs). This reader is the single, deliberate,
/// narrowly-scoped exception to the app-wide rule that `oauthAccount` is off-limits:
/// it extracts ONLY three non-sensitive, user-facing identity strings —
/// `displayName`, `emailAddress`, `organizationName` — and never returns tokens,
/// UUIDs, billing data, or any other field. The rest of the environment pipeline
/// (`EnvironmentService`) still never touches `oauthAccount`.
public struct AccountService: Sendable {
    /// Path to the top-level `~/.claude.json` config file. Injectable so the read
    /// can be unit-tested against a fixture file instead of the real user home.
    public let claudeJSON: URL

    public init(
        claudeJSON: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude.json")
    ) {
        self.claudeJSON = claudeJSON
    }

    /// Returns the active account's identity, or `nil` when the file is missing,
    /// unreadable, has no `oauthAccount`, or carries no usable identity string.
    ///
    /// Runs the parse off the main actor: `~/.claude.json` can be large (it also
    /// stores project/session history), so it is never read on the UI thread.
    public func loadActiveAccount() async -> ActiveAccount? {
        let url = claudeJSON
        return await Task.detached(priority: .utility) {
            Self.read(claudeJSON: url)
        }.value
    }

    /// Pure, synchronous read — extracted so it can be unit-tested against a fixture
    /// file. Tolerant of every failure mode (missing file, malformed JSON, absent or
    /// wrong-typed keys): any of them yields `nil` rather than throwing.
    static func read(claudeJSON url: URL) -> ActiveAccount? {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            // Routine: `~/.claude.json` absent or momentarily unreadable (not created yet,
            // or a race with a concurrent write) — not a failure worth surfacing.
            log.debug("account config read miss \(error: error)")
            return nil
        }
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: data)
        } catch {
            log.error("account config decode failed \(error: error)")
            return nil
        }
        guard
            let root = parsed as? [String: Any],
            let oauth = root["oauthAccount"] as? [String: Any]
        else { return nil }

        func string(_ key: String) -> String? {
            guard let value = oauth[key] as? String else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        let account = ActiveAccount(
            displayName: string("displayName"),
            email: string("emailAddress"),
            organizationName: string("organizationName")
        )
        // No usable identity string → report as absent so callers hide the label.
        return account.label == nil ? nil : account
    }
}
