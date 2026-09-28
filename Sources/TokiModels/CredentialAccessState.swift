/// The result of a silent, non-interactive probe of credential access.
///
/// Unlike `CredentialProviding.currentCredential()`, computing this state never
/// presents the macOS Keychain authorization dialog. It is used to drive
/// onboarding UI: whether Toki can already read the credential, needs the user
/// to grant access, or has no credential to find at all.
public enum CredentialAccessState: Sendable, Equatable {
    /// A credential is readable with no prompt.
    case available
    /// A Keychain item exists but reading it would trigger the authorization dialog.
    case needsAuthorization
    /// The login Keychain is locked.
    case locked
    /// No credential exists anywhere (env var, file, or Keychain).
    case notFound
    /// A Claude Code Keychain item exists but holds no `claudeAiOauth` block — this
    /// Claude Code version stores its credentials in a layout Toki cannot read.
    case unsupportedLayout
}
