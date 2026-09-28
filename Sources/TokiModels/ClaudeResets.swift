import Foundation

/// A saved Claude rate-limit reset grant returned by Claude Code's usage response.
public struct ClaudeResetGrant: Sendable, Codable, Equatable {
    public let id: String
    public let label: String
    public let resetsTotal: Int
    public let resetsLeft: Int
    public let startsAt: Date?
    public let endsAt: Date?
    public let clears: [String]
    public let paused: Bool
    public let usableNow: Bool
    public let useRequiresLimit: Bool
    public let blocking: [String]

    public init(
        id: String,
        label: String = "",
        resetsTotal: Int = 0,
        resetsLeft: Int,
        startsAt: Date? = nil,
        endsAt: Date? = nil,
        clears: [String] = [],
        paused: Bool = false,
        usableNow: Bool = false,
        useRequiresLimit: Bool = true,
        blocking: [String] = []
    ) {
        self.id = id
        self.label = label
        self.resetsTotal = resetsTotal
        self.resetsLeft = resetsLeft
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.clears = clears
        self.paused = paused
        self.usableNow = usableNow
        self.useRequiresLimit = useRequiresLimit
        self.blocking = blocking
    }
}

/// Claude's account-level saved reset state. A nil grant list means the balance is unknown;
/// an empty list is a known zero balance.
public struct ClaudeResetStatus: Sendable, Codable, Equatable {
    public enum DisplayState: Equatable, Sendable {
        case hidden
        case updating
        case balance(Int)
    }

    public let eligible: Bool
    public let ineligibleReason: String?
    public let atLimit: Bool?
    public let exhausted: [String]
    public let grants: [ClaudeResetGrant]?
    public let nextGrantID: String?
    public let weeklyResetsAt: Date?
    public let cooldownUntil: Date?

    public init(
        eligible: Bool,
        ineligibleReason: String? = nil,
        atLimit: Bool? = nil,
        exhausted: [String] = [],
        grants: [ClaudeResetGrant]? = nil,
        nextGrantID: String? = nil,
        weeklyResetsAt: Date? = nil,
        cooldownUntil: Date? = nil
    ) {
        self.eligible = eligible
        self.ineligibleReason = ineligibleReason
        self.atLimit = atLimit
        self.exhausted = exhausted
        self.grants = grants
        self.nextGrantID = nextGrantID
        self.weeklyResetsAt = weeklyResetsAt
        self.cooldownUntil = cooldownUntil
    }

    /// The authoritative sum of all remaining resets, or nil when the server did not provide
    /// a complete grant list or the list contains invalid counts.
    public var totalResets: Int? {
        guard let grants else { return nil }

        var total = 0
        for grant in grants {
            guard grant.resetsTotal >= 0, grant.resetsLeft >= 0 else { return nil }
            let result = total.addingReportingOverflow(grant.resetsLeft)
            guard !result.overflow else { return nil }
            total = result.partialValue
        }
        return total
    }

    /// The badge state for a cached usage snapshot.
    public func displayState(
        fetchedAt: Date,
        now: Date,
        allowsStale: Bool = false
    ) -> DisplayState {
        guard eligible,
              let total = totalResets,
              fetchedAt.timeIntervalSince(now) <= 300
        else {
            return .hidden
        }
        guard allowsStale || now.timeIntervalSince(fetchedAt) <= 210 else { return .hidden }

        if grants?.contains(where: { $0.resetsLeft > 0 && ($0.endsAt ?? .distantFuture) <= now }) == true {
            return .updating
        }

        return .balance(total)
    }

    /// Whether the server says a specific saved reset can be used immediately.
    public func canUse(_ grant: ClaudeResetGrant, at now: Date) -> Bool {
        guard let nextGrantID, nextGrantID == grant.id else { return false }
        if let endsAt = grant.endsAt, endsAt <= now { return false }
        if let cooldownUntil, cooldownUntil > now { return false }
        return eligible && grant.resetsLeft > 0 && grant.usableNow && !grant.paused
    }
}
