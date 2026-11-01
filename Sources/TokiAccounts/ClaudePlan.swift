/// The Claude subscription plan name shown next to an account.
import Foundation

public enum ClaudePlan {
    /// The user-facing plan name ("Pro", "Max", "Ultra", "Team", …), or nil when nothing
    /// names one.
    ///
    /// The sources, most specific first:
    /// - `planDisplayName`: Claude Code writes Anthropic's own name for the plan into
    ///   `~/.claude.json` (`oauthAccount.planDisplayName`, e.g. "Ultra"). Used as is.
    /// - `rateLimitTier`: `oauthAccount.organizationRateLimitTier` or the credential's
    ///   `rateLimitTier`, e.g. `default_claude_max_20x`. On 2026-10-30 Anthropic renamed
    ///   Max 20x to Ultra and Max 5x to Max; the tier ids kept their old names.
    /// - `organizationType` / `subscriptionType`: `claude_max`, `max`, `pro`, … These
    ///   cannot tell Max from Ultra, so they only count when no tier is known.
    public static func displayName(
        planDisplayName: String? = nil,
        rateLimitTier: String? = nil,
        organizationType: String? = nil,
        subscriptionType: String? = nil
    ) -> String? {
        if let name = clean(planDisplayName) { return name }
        if let tier = clean(rateLimitTier)?.lowercased() {
            if tier.contains("max_20x") || tier.contains("ultra") { return "Ultra" }
            if tier.contains("max_5x") || tier.contains("max") { return "Max" }
            if tier.contains("pro") { return "Pro" }
        }
        for raw in [organizationType, subscriptionType] {
            guard var kind = clean(raw)?.lowercased() else { continue }
            if kind.hasPrefix("claude_") { kind.removeFirst("claude_".count) }
            switch kind {
            case "max_20x", "ultra": return "Ultra"
            case "max", "max_5x": return "Max"
            case "pro": return "Pro"
            case "team": return "Team"
            case "enterprise": return "Enterprise"
            case "free": return "Free"
            default:
                return kind.split(separator: "_").map { $0.capitalized }.joined(separator: " ")
            }
        }
        return nil
    }

    /// The plan named by a stored credential, `{"claudeAiOauth": {"subscriptionType": …,
    /// "rateLimitTier": …}}`. Reads only those two fields, never the tokens.
    public static func displayName(credentialJSON: Data) -> String? {
        // no-log: a credential without plan fields just shows no plan.
        guard let root = try? JSONSerialization.jsonObject(with: credentialJSON) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any] else { return nil }
        return displayName(
            rateLimitTier: oauth["rateLimitTier"] as? String,
            subscriptionType: oauth["subscriptionType"] as? String
        )
    }

    private static func clean(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
