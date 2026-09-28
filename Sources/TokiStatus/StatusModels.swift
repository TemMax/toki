import Foundation

/// How bad things are for Claude Code, as one ordered scale.
///
/// Statuspage exposes two independent vocabularies — a per-component status and a
/// per-incident impact — and neither alone answers "should the user see a banner".
/// Collapsing both onto one comparable scale is what lets the app take the worse of the
/// two without every surface re-learning Statuspage's terminology.
public enum StatusSeverity: Int, Sendable, Equatable, Comparable, Codable {
    case operational = 0
    /// Component `degraded_performance`, or an incident of impact `none`/`minor`.
    case degraded = 1
    /// Component `partial_outage`/`major_outage`, or an incident of impact `major`/`critical`.
    case outage = 2

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// The newest unresolved status-page incident that affects Claude Code.
public struct StatusIncident: Sendable, Equatable {
    public let id: String
    public let title: String
    /// Body of the newest `incident_update` — the sentence Anthropic last published.
    public let latestUpdate: String?
    /// `display_at` of that newest update, or nil when the page sent a date we cannot parse.
    public let updatedAt: Date?
    /// Every component named across the incident's updates, e.g. `["claude.ai", "Claude Code"]`.
    public let affectedComponentNames: [String]

    public init(
        id: String,
        title: String,
        latestUpdate: String?,
        updatedAt: Date?,
        affectedComponentNames: [String]
    ) {
        self.id = id
        self.title = title
        self.latestUpdate = latestUpdate
        self.updatedAt = updatedAt
        self.affectedComponentNames = affectedComponentNames
    }
}

/// The one datum every surface observes: is Claude Code okay, and if not, why.
public struct ServiceStatus: Sendable, Equatable {
    public let severity: StatusSeverity
    public let incident: StatusIncident?

    /// The healthy value — also what the app shows before its first successful poll.
    public static let operational = ServiceStatus(severity: .operational, incident: nil)

    public var isDisrupted: Bool { severity != .operational }

    public init(severity: StatusSeverity, incident: StatusIncident?) {
        self.severity = severity
        self.incident = incident
    }
}
