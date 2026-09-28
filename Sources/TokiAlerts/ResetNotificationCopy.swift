import Foundation
import TokiModels

/// Notification sentences are always English; expiry instants use the user's current zone.
public enum ResetNotificationCopy {
    public static func bankedTitle(isInitial: Bool) -> String {
        isInitial ? "Codex reset available" : "You've received a Codex reset"
    }

    public static func bankedBody(
        count: Int, expiresAt: Date?, detailsComplete: Bool,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> String {
        var body = count == 1 ? "1 reset available." : "\(count) resets available."
        if let expiresAt {
            let date = ResetDateFormat.string(date: expiresAt, locale: Locale(identifier: "en_US"), timeZone: timeZone)
            body += count == 1 && detailsComplete ? " Use by \(date)." : " Next known expiry: \(date)."
        }
        return body
    }

    public static func announcementTitle(provider: UsageProvider) -> String {
        provider == .codex ? "OpenAI announced a Codex reset" : "Anthropic announced a Claude reset"
    }

    public static func announcementBody(scope: String?) -> String {
        if let scope, !scope.isEmpty {
            return "Announced scope: \(scope). Open the official post for eligibility and timing."
        }
        return "A regular usage-limit reset was announced. Open the official post for eligibility and timing."
    }
}
