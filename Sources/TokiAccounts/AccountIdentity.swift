/// The user-facing identity of a stored Claude account.
import Foundation

/// Parsed from the `oauthAccount` block of `~/.claude.json`. Only the fields Toki
/// displays or keys on are kept — never tokens, billing or trial data.
public struct AccountIdentity: Codable, Equatable, Sendable {
    /// Stable across logins; the slot key. Email can change, so it is display-only.
    public let accountUuid: String
    public let email: String?
    public let displayName: String?
    public let organizationName: String?
    public let organizationUuid: String?

    public init(
        accountUuid: String,
        email: String?,
        displayName: String?,
        organizationName: String?,
        organizationUuid: String?
    ) {
        self.accountUuid = accountUuid
        self.email = email
        self.displayName = displayName
        self.organizationName = organizationName
        self.organizationUuid = organizationUuid
    }

    public static func parse(oauthAccount: [String: Any]) -> AccountIdentity? {
        func string(_ key: String) -> String? {
            guard let value = oauthAccount[key] as? String else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        guard let uuid = string("accountUuid") else { return nil }
        return AccountIdentity(
            accountUuid: uuid,
            email: string("emailAddress"),
            displayName: string("displayName"),
            organizationName: string("organizationName"),
            organizationUuid: string("organizationUuid")
        )
    }

    /// Most specific human label available.
    public var label: String {
        email ?? displayName ?? organizationName ?? accountUuid
    }
}
