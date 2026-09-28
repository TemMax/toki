import Foundation

/// Identity of the Claude account Claude Code is currently signed into, as read
/// from the `oauthAccount` block of `~/.claude.json`.
///
/// Purely descriptive fields shown to the user about their *own* account — never
/// tokens, UUIDs, or any other secret. See `AccountService` for the security
/// scoping of the read.
public struct ActiveAccount: Equatable, Sendable {
    /// Human display name (e.g. "Alex"), when present.
    public let displayName: String?
    /// Account email address (e.g. "alex@example.com") — the least-ambiguous identifier.
    public let email: String?
    /// Organization / team name (e.g. "Example Org"), present for team/enterprise plans.
    public let organizationName: String?

    public init(displayName: String?, email: String?, organizationName: String?) {
        self.displayName = displayName
        self.email = email
        self.organizationName = organizationName
    }

    /// The identity parts that are present — display name, email, organization, in
    /// that order — joined with " · " for display, e.g. "Alex · alex@example.com · Example Org".
    /// Missing parts are simply dropped; returns `nil` when no part is available.
    public var label: String? {
        let parts = [displayName, email, organizationName]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
