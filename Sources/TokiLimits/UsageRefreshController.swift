import Foundation
import TokiLogging
import TokiModels

private let log = TokiLog.logger("limits")

/// A request was intentionally skipped because a shared cadence or backoff is active.
/// Callers keep their previously published snapshot and state.
public struct UsageRefreshDeferred: Error, Sendable {
    public init() {}
}

/// The one request-cadence boundary for provider usage limits. UI events, background
/// polling and saved-account upkeep all reserve a permit here before contacting a provider.
public struct UsageRefreshKey: Hashable, Sendable, Codable {
    public enum Provider: String, Hashable, Sendable, Codable { case claude, codex }

    public let provider: Provider
    public let accountID: String
    public let organizationID: String?

    public init(provider: Provider, accountID: String, organizationID: String? = nil) {
        self.provider = provider
        self.accountID = accountID
        self.organizationID = organizationID
    }
}

public actor UsageRefreshController {
    public static let minimumInterval: TimeInterval = 90

    public struct Permit: Equatable, Sendable {
        fileprivate let key: UsageRefreshKey
        fileprivate let id: UUID
    }

    public enum Outcome: Sendable, Equatable {
        case success
        case failure
        case rateLimited(retryAfter: TimeInterval)

        public static func response(_ limits: UsageLimits) -> Self {
            if let partial = limits.supplementalRateLimit {
                return .rateLimited(retryAfter: partial.retryAfter)
            }
            return .success
        }

        public static func error(_ error: Error) -> Self {
            if case TokiError.rateLimited(let retryAfter) = error {
                return .rateLimited(retryAfter: retryAfter)
            }
            return .failure
        }
    }

    private struct Entry {
        var permitID: UUID?
        var nextAllowedAt: Date = .distantPast
        var consecutiveRateLimits = 0
    }

    /// What survives a relaunch: when each account may next be asked, and its 429 streak.
    private struct PersistedEntry: Codable {
        let key: UsageRefreshKey
        let nextAllowedAt: Date
        let consecutiveRateLimits: Int
    }

    private let now: @Sendable () -> Date
    private let minimumInterval: TimeInterval
    private let firstRateLimitInterval: TimeInterval
    private let repeatedRateLimitInterval: TimeInterval
    private var entries: [UsageRefreshKey: Entry] = [:]
    private let scheduleURL: URL?

    /// Default location of the persisted schedule.
    public static func defaultScheduleURL() -> URL {
        AppSupportDirectory.url.appendingPathComponent("usage-refresh-schedule.json")
    }

    /// Production uses the defaults. Zero intervals are only for isolated wire tests
    /// that need to script several provider responses without waiting on real time.
    ///
    /// - Parameter scheduleURL: where the per-account schedule is kept across launches.
    ///   Without it the cadence resets on every launch, and relaunching the app — a crash,
    ///   an update, a developer rebuilding — asks the provider again at once, straight
    ///   through a 90-second floor or a 429 backoff it had been told to honour.
    public init(
        minimumInterval: TimeInterval = UsageRefreshController.minimumInterval,
        firstRateLimitInterval: TimeInterval = 360,
        repeatedRateLimitInterval: TimeInterval = 720,
        scheduleURL: URL? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        precondition(minimumInterval >= 0 && firstRateLimitInterval >= 0 && repeatedRateLimitInterval >= 0)
        self.minimumInterval = minimumInterval
        self.firstRateLimitInterval = firstRateLimitInterval
        self.repeatedRateLimitInterval = repeatedRateLimitInterval
        self.scheduleURL = scheduleURL
        self.now = now
        self.entries = Self.loadSchedule(
            from: scheduleURL,
            now: now(),
            // A clock that jumped backwards must not lock an account out for longer than the
            // longest wait this controller would ever have set.
            longestWait: max(minimumInterval, repeatedRateLimitInterval)
        )
    }

    private static func loadSchedule(from url: URL?, now: Date, longestWait: TimeInterval) -> [UsageRefreshKey: Entry] {
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let saved: [PersistedEntry]
        do {
            saved = try JSONDecoder().decode([PersistedEntry].self, from: Data(contentsOf: url))
        } catch {
            // Starting without the schedule only costs one early request per account.
            log.error("usage refresh schedule unreadable, starting fresh \(error: error)")
            return [:]
        }
        var entries: [UsageRefreshKey: Entry] = [:]
        for item in saved {
            entries[item.key] = Entry(
                permitID: nil,
                nextAllowedAt: min(item.nextAllowedAt, now.addingTimeInterval(longestWait)),
                consecutiveRateLimits: item.consecutiveRateLimits
            )
        }
        return entries
    }

    private func saveSchedule() {
        guard let scheduleURL else { return }
        let cutoff = now()
        let saved = entries.compactMap { key, entry -> PersistedEntry? in
            // Only waits still pending (or a 429 streak still worth remembering) matter.
            guard entry.nextAllowedAt > cutoff || entry.consecutiveRateLimits > 0 else { return nil }
            return PersistedEntry(key: key, nextAllowedAt: entry.nextAllowedAt,
                                  consecutiveRateLimits: entry.consecutiveRateLimits)
        }
        do {
            try FileManager.default.createDirectory(
                at: scheduleURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try JSONEncoder().encode(saved).write(to: scheduleURL, options: .atomic)
        } catch {
            // Best effort: failing to persist only costs the cross-launch cadence.
            log.error("failed to persist the usage refresh schedule \(error: error)")
        }
    }

    /// Returns nil when another request is in flight or this account is still cooling down.
    /// Every caller must leave its existing snapshot untouched in that case.
    public func begin(_ key: UsageRefreshKey) -> Permit? {
        var entry = entries[key] ?? Entry()
        guard entry.permitID == nil, now() >= entry.nextAllowedAt else { return nil }
        let permit = Permit(key: key, id: UUID())
        entry.permitID = permit.id
        entry.nextAllowedAt = now().addingTimeInterval(minimumInterval)
        entries[key] = entry
        saveSchedule()
        return permit
    }

    /// Closes the in-flight reservation and applies provider backoff after a 429.
    public func finish(_ permit: Permit, outcome: Outcome) {
        guard var entry = entries[permit.key], entry.permitID == permit.id else { return }
        entry.permitID = nil
        switch outcome {
        case .success:
            entry.consecutiveRateLimits = 0
        case .failure:
            break
        case .rateLimited(let retryAfter):
            entry.consecutiveRateLimits += 1
            let backoff = entry.consecutiveRateLimits == 1
                ? firstRateLimitInterval : repeatedRateLimitInterval
            entry.nextAllowedAt = max(
                entry.nextAllowedAt,
                now().addingTimeInterval(backoff == 0 ? 0 : max(backoff, retryAfter))
            )
        }
        entries[permit.key] = entry
        saveSchedule()
    }

}
