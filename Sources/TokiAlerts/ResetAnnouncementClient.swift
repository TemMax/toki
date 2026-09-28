import Foundation
import TokiModels

public actor ResetAnnouncementClient {
    private static let maximumResponseBytes = 1_048_576
    private let session: URLSession
    private let timeoutInterval: TimeInterval

    public init(session: URLSession = .shared) {
        self.session = session
        timeoutInterval = 15
    }

    init(session: URLSession, timeoutInterval: TimeInterval) {
        self.session = session
        self.timeoutInterval = timeoutInterval
    }

    public func fetch(provider: UsageProvider) async throws -> [ResetAnnouncement] {
        let session = session
        let timeoutInterval = timeoutInterval
        return try await withThrowingTaskGroup(of: [ResetAnnouncement].self) { group in
            group.addTask {
                try await Self.fetch(
                    provider: provider,
                    session: session,
                    timeoutInterval: timeoutInterval
                )
            }
            group.addTask {
                try await Task.sleep(
                    nanoseconds: UInt64(Swift.max(0, timeoutInterval) * 1_000_000_000)
                )
                throw ResetAnnouncementError.timedOut
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw ResetAnnouncementError.invalidResponse
            }
            return result
        }
    }

    private static func fetch(
        provider: UsageProvider,
        session: URLSession,
        timeoutInterval: TimeInterval
    ) async throws -> [ResetAnnouncement] {
        var request = URLRequest(url: Self.feedURL(for: provider))
        request.timeoutInterval = timeoutInterval
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw ResetAnnouncementError.invalidResponse
        }

        var data = Data()
        data.reserveCapacity(min(http.expectedContentLength.clampedToInt, Self.maximumResponseBytes))
        for try await byte in bytes {
            guard data.count < Self.maximumResponseBytes else {
                throw ResetAnnouncementError.responseTooLarge
            }
            data.append(byte)
        }
        return try ResetAnnouncementParser.parse(data, provider: provider)
    }

    private static func feedURL(for provider: UsageProvider) -> URL {
        switch provider {
        case .codex:
            URL(string: "https://codex-resets.com/api/resets")!
        case .claudeCode:
            URL(string: "https://claude-resets.com/api/resets")!
        }
    }
}

private extension Int64 {
    var clampedToInt: Int {
        guard self > 0 else { return 0 }
        return Int(Swift.min(self, Int64(Int.max)))
    }
}
