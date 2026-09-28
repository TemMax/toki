import Foundation

/// Decides when a status change is worth a notification, and remembers what it already said.
///
/// The unit is an *episode*, not a poll and not an incident id: one disruption produces
/// exactly one "began" and exactly one "resolved", however many ways the status page
/// re-describes it in between. Three things make that non-trivial, and each is handled by
/// the same latched set:
///
/// - Anthropic degrades a component minutes before publishing the incident. Toki sees the
///   degradation first and keys it synthetically (`component:degraded`); when the real
///   incident id shows up it JOINS the same episode instead of starting a second one.
/// - An incident escalates (minor → critical). The banner carries the new severity; a second
///   notification saying the same outage is now worse is not new information the user asked
///   for.
/// - The app relaunches mid-incident. The latch is `Codable` and persisted precisely so a
///   restart does not re-announce an outage the user has been staring at for an hour; see
///   `StatusAlertLatchStore`.
///
/// Mirrors `ThresholdAlertPolicy`: pure, `mutating`, and told about every observation rather
/// than left to poll anything itself.
public struct StatusAlertPolicy: Equatable, Sendable, Codable {

    /// At most one of these per observation. Deliberately NOT `Codable` — only the latched
    /// keys outlive the process; a pending event is meaningless after a relaunch.
    public enum Event: Equatable, Sendable {
        case incidentBegan(severity: StatusSeverity, title: String?)
        case incidentResolved
    }

    /// The key used while Claude Code is degraded but no incident has been published yet.
    /// Namespaced so it can never collide with a Statuspage incident id.
    static let syntheticKey = "component:degraded"

    /// Every identity the current episode has been seen under. Empty means "all quiet".
    private var activeKeys: Set<String> = []

    public init() {}

    /// Feed every observed status; returns at most one event to notify about.
    public mutating func event(for status: ServiceStatus) -> Event? {
        guard status.isDisrupted else {
            guard !activeKeys.isEmpty else { return nil }
            activeKeys.removeAll()
            return .incidentResolved
        }

        let key = status.incident?.id ?? Self.syntheticKey
        let wasQuiet = activeKeys.isEmpty
        activeKeys.insert(key)
        guard wasQuiet else { return nil }
        return .incidentBegan(severity: status.severity, title: status.incident?.title)
    }
}
