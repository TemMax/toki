import Foundation
import TokiModels

public struct ResetAnnouncement: Codable, Sendable, Equatable {
    public let id: String
    public let provider: UsageProvider
    public let announcedAt: Date
    public let scope: String?
    public let sourceURL: URL

    public init(
        id: String,
        provider: UsageProvider,
        announcedAt: Date,
        scope: String?,
        sourceURL: URL
    ) {
        self.id = id
        self.provider = provider
        self.announcedAt = announcedAt
        self.scope = scope
        self.sourceURL = sourceURL
    }
}

public enum ResetAnnouncementParser {
    public static func parse(_ data: Data, provider: UsageProvider) throws -> [ResetAnnouncement] {
        let rootObject = try JSONSerialization.jsonObject(with: data)
        guard let root = rootObject as? [String: Any] else {
            throw ResetAnnouncementError.invalidFeed
        }

        switch provider {
        case .codex:
            guard let rows = root["events"] as? [Any] else {
                throw ResetAnnouncementError.invalidFeed
            }
            return try announcements(from: rows.map(parseCodexRow))
        case .claudeCode:
            guard let providers = root["providers"] as? [String: Any],
                  let claude = providers["claude"] as? [String: Any],
                  let rows = claude["events"] as? [Any] else {
                throw ResetAnnouncementError.invalidFeed
            }
            return try announcements(from: rows.map(parseClaudeRow))
        }
    }

    private enum ParsedRow {
        case malformed
        case excluded
        case announcement(ResetAnnouncement)
    }

    private static func announcements(from rows: [ParsedRow]) throws -> [ResetAnnouncement] {
        guard rows.isEmpty || rows.contains(where: { row in
            if case .malformed = row { return false }
            return true
        }) else {
            throw ResetAnnouncementError.invalidFeed
        }
        return rows.compactMap { row in
            guard case let .announcement(event) = row else { return nil }
            return event
        }
    }

    private static func parseCodexRow(_ value: Any) -> ParsedRow {
        guard let row = value as? [String: Any],
              let resetType = nonempty(row["reset_type"] as? String),
              nonempty(row["source"] as? String) != nil,
              let id = nonempty(row["tweet_id"] as? String),
              let announcedAt = date(row["announced_at"] as? String),
              let sourceURL = postURL(row["tweet_url"] as? String) else {
            return .malformed
        }
        guard resetType == "regular" else { return .excluded }
        return .announcement(ResetAnnouncement(
            id: id,
            provider: .codex,
            announcedAt: announcedAt,
            scope: nil,
            sourceURL: sourceURL
        ))
    }

    private static func parseClaudeRow(_ value: Any) -> ParsedRow {
        guard let row = value as? [String: Any],
              let kind = nonempty(row["kind"] as? String),
              let verification = nonempty(row["verification"] as? String),
              let id = nonempty(row["id"] as? String),
              let announcedAt = date(row["date"] as? String),
              let sourceURL = postURL(row["url"] as? String) else {
            return .malformed
        }
        guard kind == "reset", verification == "curated" else { return .excluded }
        return .announcement(ResetAnnouncement(
            id: id,
            provider: .claudeCode,
            announcedAt: announcedAt,
            scope: boundedScope(row["scope"] as? String),
            sourceURL: sourceURL
        ))
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func boundedScope(_ value: String?) -> String? {
        guard let value = nonempty(value) else { return nil }
        guard value.count <= 160 else { return nil }
        switch value.lowercased() {
        case "all": return "all"
        case "pro + max": return "Pro + Max"
        case "affected users": return "affected users"
        case "max": return "Max"
        default: return nil
        }
    }

    private static func date(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private static func postURL(_ value: String?) -> URL? {
        guard let value, let url = URL(string: value),
              url != ResetLinks.codexUsage,
              ResetLinks.allowed(url) else {
            return nil
        }
        return url
    }
}

enum ResetAnnouncementError: Error, Equatable {
    case invalidFeed
    case invalidResponse
    case responseTooLarge
    case timedOut
}
