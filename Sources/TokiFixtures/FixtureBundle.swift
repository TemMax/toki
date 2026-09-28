/// The neutral, app-agnostic payload a `Scenario` resolves to. See `Fixtures.bundle(for:now:)`.
import Foundation
import TokiAccounts
import TokiAnalytics
import TokiModels
import TokiStatus

/// Neutral representation of the live-limits state. The app's own LiveLimits.State lives in
/// the app target, which this module cannot import, so the app maps this across.
public enum FixtureLimitsState: Sendable, Equatable {
    case loading
    case ok
    case stale(secondsAgo: TimeInterval)
    case notLoggedIn
    case needsAccess
    case error(String)
}

public struct FixtureBundle: Sendable {
    public let limits: UsageLimits?
    public let limitsState: FixtureLimitsState
    public let summary: UsageSummary?
    public let stats: StatsHistory?
    public let identity: AccountIdentity?
    public let accounts: [AccountPresentation]
    public let quarantine: [QuarantineEntry]
    public let instances: ClaudeInstancesSnapshot?
    public let environment: ClaudeEnvironment?
    public let serviceStatus: ServiceStatus

    public init(
        limits: UsageLimits? = nil,
        limitsState: FixtureLimitsState = .ok,
        summary: UsageSummary? = nil,
        stats: StatsHistory? = nil,
        identity: AccountIdentity? = nil,
        accounts: [AccountPresentation] = [],
        quarantine: [QuarantineEntry] = [],
        instances: ClaudeInstancesSnapshot? = nil,
        environment: ClaudeEnvironment? = nil,
        serviceStatus: ServiceStatus = .operational
    ) {
        self.limits = limits
        self.limitsState = limitsState
        self.summary = summary
        self.stats = stats
        self.identity = identity
        self.accounts = accounts
        self.quarantine = quarantine
        self.instances = instances
        self.environment = environment
        self.serviceStatus = serviceStatus
    }
}
