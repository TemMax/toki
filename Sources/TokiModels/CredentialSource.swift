/// Where a resolved credential came from. Error handling is source-aware: a 401
/// on an environment-supplied token must never invalidate the Keychain vault.
import Foundation

public enum CredentialSource: String, Sendable, Equatable, Codable {
    /// `CLAUDE_CODE_OAUTH_TOKEN` environment variable.
    case environment
    /// `~/.claude/.credentials.json`.
    case file
    /// Toki' own Keychain item (a copy of a previously harvested token).
    case vault
    /// Freshly read from Claude Code's `Claude Code-credentials` Keychain item.
    case claudeKeychain

    /// True when the token is (or will be) mirrored in the vault, so a 401 on it
    /// should mark the vault copy dead.
    public var isVaultBacked: Bool {
        switch self {
        case .vault, .claudeKeychain: return true
        case .environment, .file: return false
        }
    }
}
