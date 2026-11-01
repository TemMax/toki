/// The user-facing identity of a stored Claude account.
import Foundation

/// Parsed from the `oauthAccount` block of `~/.claude.json`. Only the fields Toki
/// displays or keys on are kept — never tokens, billing or trial data. The plan name is
/// kept as a display string only ("Ultra"), not the billing details behind it.
public struct AccountIdentity: Codable, Equatable, Sendable {
    /// Stable across logins; the slot key. Email can change, so it is display-only.
    public let accountUuid: String
    public let email: String?
    public let displayName: String?
    public let organizationName: String?
    public let organizationUuid: String?
    /// The subscription plan's display name when the source named one ("Pro", "Max",
    /// "Ultra"). Optional in storage, so slots saved before it existed still decode.
    public let plan: String?

    public init(
        accountUuid: String,
        email: String?,
        displayName: String?,
        organizationName: String?,
        organizationUuid: String?,
        plan: String? = nil
    ) {
        self.accountUuid = accountUuid
        self.email = email
        self.displayName = displayName
        self.organizationName = organizationName
        self.organizationUuid = organizationUuid
        self.plan = plan
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
            organizationUuid: string("organizationUuid"),
            plan: ClaudePlan.displayName(
                planDisplayName: string("planDisplayName"),
                rateLimitTier: string("organizationRateLimitTier") ?? string("userRateLimitTier"),
                organizationType: string("organizationType")
            )
        )
    }

    /// Most specific human label available.
    public var label: String {
        email ?? displayName ?? organizationName ?? accountUuid
    }
}
