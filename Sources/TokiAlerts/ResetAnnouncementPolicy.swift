import Foundation
import TokiModels

public struct ResetAnnouncementPolicy: Codable, Sendable {
    private struct ProviderHistory: Codable, Sendable {
        var seenAtByID: [String: Date]
        var notificationFloor: Date?

        init(seenAtByID: [String: Date], notificationFloor: Date? = nil) {
            self.seenAtByID = seenAtByID
            self.notificationFloor = notificationFloor
        }
    }

    private static let recentWindow: TimeInterval = 24 * 60 * 60
    private static let futureClockTolerance: TimeInterval = 5 * 60
    private static let maximumSeenIDsPerProvider = 8_192

    private var histories: [String: ProviderHistory] = [:]

    public init() {}

    public mutating func observe(
        _ events: [ResetAnnouncement],
        provider: UsageProvider,
        now: Date
    ) -> [ResetAnnouncement] {
        let providerEvents = events.filter { $0.provider == provider }
        let key = provider.rawValue

        guard var history = histories[key] else {
            let baseline = providerEvents.filter { $0.announcedAt <= now }
            histories[key] = boundedHistory(
                ProviderHistory(seenAtByID: Dictionary(
                    baseline.map { ($0.id, $0.announcedAt) },
                    uniquingKeysWith: max
                )),
                now: now
            )
            return []
        }

        let oldestRecentDate = now.addingTimeInterval(-Self.recentWindow)
        let latestPlausibleDate = now.addingTimeInterval(Self.futureClockTolerance)
        var notices: [ResetAnnouncement] = []

        for event in providerEvents where history.seenAtByID[event.id] == nil {
            if let floor = history.notificationFloor, event.announcedAt <= floor {
                continue
            }
            guard event.announcedAt <= latestPlausibleDate else { continue }
            // A slightly fast feed clock is plausible, but a notification must not precede
            // the feed's own announcement time. Leaving it unseen lets a later poll deliver it.
            guard event.announcedAt <= now else { continue }

            history.seenAtByID[event.id] = event.announcedAt
            if event.announcedAt >= oldestRecentDate {
                notices.append(event)
            }
        }

        histories[key] = boundedHistory(history, now: now)
        return notices
    }

    private func boundedHistory(_ history: ProviderHistory, now: Date) -> ProviderHistory {
        let retentionFloor = now.addingTimeInterval(-Self.recentWindow)
        var notificationFloor = history.notificationFloor
        let expired = history.seenAtByID.filter { $0.value < retentionFloor }
        if let newestExpired = expired.values.max() {
            notificationFloor = Swift.max(notificationFloor ?? .distantPast, newestExpired)
        }
        var retained = history.seenAtByID.filter { $0.value >= retentionFloor }
        if retained.count > Self.maximumSeenIDsPerProvider {
            let sorted = retained.sorted { lhs, rhs in
                if lhs.value == rhs.value { return lhs.key < rhs.key }
                return lhs.value < rhs.value
            }
            let removalCount = sorted.count - Self.maximumSeenIDsPerProvider
            if let newestRemoved = sorted.prefix(removalCount).map(\.value).max() {
                notificationFloor = Swift.max(notificationFloor ?? .distantPast, newestRemoved)
            }
            retained = Dictionary(sorted.suffix(Self.maximumSeenIDsPerProvider), uniquingKeysWith: max)
        }
        return ProviderHistory(seenAtByID: retained, notificationFloor: notificationFloor)
    }

    private enum CodingKeys: String, CodingKey {
        case histories
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        histories = try container.decodeIfPresent(
            [String: ProviderHistory].self,
            forKey: .histories
        ) ?? [:]
    }
}
