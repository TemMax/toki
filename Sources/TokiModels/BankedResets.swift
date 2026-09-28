import Foundation

/// One Codex rate-limit reset credit returned by the official App Server response.
public struct BankedResetCredit: Sendable, Codable, Equatable {
    public let id: String
    public let grantedAt: Date
    public let expiresAt: Date?
    public let status: String
    public let resetType: String

    public init(
        id: String,
        grantedAt: Date,
        expiresAt: Date?,
        status: String,
        resetType: String
    ) {
        self.id = id
        self.grantedAt = grantedAt
        self.expiresAt = expiresAt
        self.status = status
        self.resetType = resetType
    }
}

/// Current banked-reset availability. The count is authoritative; detail rows are optional
/// and may describe fewer credits than `availableCount`.
public struct BankedResets: Sendable, Codable, Equatable {
    public let availableCount: Int
    public let credits: [BankedResetCredit]?

    public init(availableCount: Int, credits: [BankedResetCredit]?) {
        self.availableCount = availableCount
        self.credits = credits
    }
}
