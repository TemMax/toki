import Foundation
import TokiLogging

/// Reduces public Statuspage-compatible payloads to the health of the configured
/// provider components (Claude Code by default).
///
/// Everything here is pure — bytes in, `ServiceStatus` out — so every judgement call below
/// (which component counts, which incident counts, how the two combine) is assertable
/// against real captured payloads in `swift test` rather than only observable during a
/// live outage.
public enum StatusParser {
    private static let log = TokiLog.logger("status")

    /// The Claude Code component's Statuspage id. Stable in practice, but a component that
    /// is deleted and recreated gets a new one — hence the name fallback below.
    public static let claudeCodeComponentID = "yyzkbfz2thpt"
    /// The Claude Code component's display name. Renameable, hence the id above. Either
    /// match counts: both can change, but not usually on the same day.
    public static let claudeCodeComponentName = "Claude Code"
    /// Components used by the Codex CLI/desktop integrations on OpenAI's public page.
    /// Login is included because a login outage makes subscription-backed Codex unusable.
    public static let openAICodexComponentNames: Set<String> = [
        "Codex Web", "Codex in ChatGPT Desktop", "Codex API", "VS Code extension", "Login",
    ]

    public enum ParseError: Error, Equatable {
        /// The bytes are not a Statuspage payload of the expected shape.
        case malformed
    }

    // MARK: - Public entry points

    /// Parses `/api/v2/summary.json` into the Claude Code verdict.
    ///
    /// Throws on bytes that are not a summary payload; never traps, and never lets a single
    /// unparseable date field lose the whole status.
    public static func serviceStatus(
        fromSummary data: Data,
        componentNames: Set<String> = [claudeCodeComponentName],
        incidentTitleKeywords: Set<String> = []
    ) throws -> ServiceStatus {
        let payload: SummaryPayload
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            payload = try decoder.decode(SummaryPayload.self, from: data)
        } catch {
            log.error("summary.json decode failed \(decodingDiagnostic(error), privacy: .public)")
            throw ParseError.malformed
        }

        let componentSeverity = payload.components
            .filter { componentNames.contains($0.name ?? "") }
            .map { severity(forComponentStatus: $0.status) }
            .max() ?? .operational

        guard let live = newestRelevantIncident(in: payload.incidents, componentNames: componentNames, incidentTitleKeywords: incidentTitleKeywords) else {
            return ServiceStatus(severity: componentSeverity, incident: nil)
        }

        let incidentSeverity = severity(forIncidentImpact: live.impact)
        let newest = live.incidentUpdates?.first

        let incident = StatusIncident(
            id: live.id ?? "",
            title: live.name ?? "",
            latestUpdate: newest?.body,
            updatedAt: date(from: newest?.displayAt),
            affectedComponentNames: affectedComponentNames(of: live)
        )

        return ServiceStatus(
            severity: max(componentSeverity, incidentSeverity),
            incident: incident
        )
    }

    /// Parses the tiny `/api/v2/status.json` into its page-wide indicator string
    /// (`none`/`minor`/`major`/`critical`).
    ///
    /// Used ONLY as a cheap change signal by `ServiceStatusClient` — it is a whole-page
    /// roll-up and says nothing about Claude Code specifically, so it must never become the
    /// verdict the user sees.
    public static func indicator(fromStatus data: Data) throws -> String {
        do {
            return try JSONDecoder().decode(StatusPayload.self, from: data).status.indicator
        } catch {
            log.error("status.json decode failed \(decodingDiagnostic(error), privacy: .public)")
            throw ParseError.malformed
        }
    }

    // MARK: - Rules

    private static func isRelevant(
        _ affected: SummaryPayload.AffectedComponent,
        componentNames: Set<String>
    ) -> Bool {
        affected.code == claudeCodeComponentID && componentNames.contains(claudeCodeComponentName)
            || componentNames.contains(affected.name ?? "")
    }

    private static func severity(forComponentStatus status: String?) -> StatusSeverity {
        switch status {
        case "degraded_performance": return .degraded
        case "partial_outage", "major_outage": return .outage
        // `under_maintenance` is planned work, not a fault; anything unknown is treated as
        // healthy rather than alarming the user over a status string we have never seen.
        default: return .operational
        }
    }

    private static func severity(forIncidentImpact impact: String?) -> StatusSeverity {
        switch impact {
        case "major", "critical": return .outage
        // `none` and `minor` — and any unrecognised impact on a live incident — still mean
        // something is wrong, because the incident exists at all.
        default: return .degraded
        }
    }

    /// An incident counts iff Claude Code appears in the affected components of ANY of its
    /// updates, not just the newest one.
    ///
    /// The newest update can drop a component mid-incident: fixture A's "monitoring" update
    /// still lists Claude Code, but Anthropic routinely narrows the blast radius as they
    /// learn more. Reading only the head would make a live incident silently stop being ours.
    private static func isRelevant(
        _ incident: SummaryPayload.Incident,
        componentNames: Set<String>,
        incidentTitleKeywords: Set<String>
    ) -> Bool {
        guard incident.status != "resolved", incident.status != "postmortem" else { return false }
        // OpenAI's compatibility API omits affected_components. Only explicit product
        // names in the title are a fallback, and only when the caller opts in.
        let titleWords = Set((incident.name ?? "").lowercased().split {
            !$0.isLetter && !$0.isNumber
        }.map(String.init))
        if incidentTitleKeywords.contains(where: { titleWords.contains($0.lowercased()) }) {
            return true
        }
        return (incident.incidentUpdates ?? []).contains { update in
            (update.affectedComponents ?? []).contains {
                isRelevant($0, componentNames: componentNames)
            }
        }
    }

    /// The newest relevant incident by `started_at`, or OpenAI's `created_at`.
    ///
    /// `summary.json` lists only UNRESOLVED incidents, so "newest" is simply the one the user
    /// most wants to read. An incident whose `started_at` will not parse still counts — it is
    /// only ordered last, never dropped.
    private static func newestRelevantIncident(
        in incidents: [SummaryPayload.Incident],
        componentNames: Set<String>,
        incidentTitleKeywords: Set<String>
    ) -> SummaryPayload.Incident? {
        let relevant = incidents.filter { isRelevant($0, componentNames: componentNames, incidentTitleKeywords: incidentTitleKeywords) }
        guard !relevant.isEmpty else { return nil }
        return relevant.enumerated().max { lhs, rhs in
            let l = date(from: lhs.element.startedAt) ?? date(from: lhs.element.createdAt)
            let r = date(from: rhs.element.startedAt) ?? date(from: rhs.element.createdAt)
            switch (l, r) {
            case let (l?, r?): return l == r ? lhs.offset > rhs.offset : l < r
            case (nil, _?): return true
            case (_?, nil): return false
            // Both undated: the payload's own order is newest-first, so keep the earlier one.
            case (nil, nil): return lhs.offset > rhs.offset
            }
        }?.element
    }

    /// Every component name the incident has touched, deduplicated, in first-seen order.
    private static func affectedComponentNames(of incident: SummaryPayload.Incident) -> [String] {
        var seen: Set<String> = []
        var names: [String] = []
        for update in incident.incidentUpdates ?? [] {
            for affected in update.affectedComponents ?? [] {
                guard let name = affected.name, seen.insert(name).inserted else { continue }
                names.append(name)
            }
        }
        return names
    }

    // MARK: - Dates

    /// Statuspage sends fractional seconds (`2026-08-18T16:20:22.240Z`), which
    /// `JSONDecoder.dateDecodingStrategy = .iso8601` handles inconsistently across Foundation
    /// versions — so the format is pinned here with `.withFractionalSeconds` instead of
    /// trusted to the decoder. Dates are decoded as `String?` and converted nil-tolerantly:
    /// one odd timestamp must cost at most a missing "updated at", never the whole status.
    private static func date(from string: String?) -> Date? {
        guard let string else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }

    // MARK: - Wire shapes

    /// Only the fields Toki reads. `components` and `incidents` are deliberately NOT optional:
    /// a payload lacking them is not a summary, and decoding `{}` into a cheerful
    /// "all operational" would be a lie told with confidence.
    private struct SummaryPayload: Decodable {
        struct Component: Decodable {
            let id: String?
            let name: String?
            let status: String?
        }

        struct AffectedComponent: Decodable {
            let code: String?
            let name: String?
        }

        struct Update: Decodable {
            let body: String?
            let displayAt: String?
            let affectedComponents: [AffectedComponent]?
        }

        struct Incident: Decodable {
            let id: String?
            let name: String?
            let impact: String?
            let startedAt: String?
            let createdAt: String?
            let status: String?
            let incidentUpdates: [Update]?
        }

        let components: [Component]
        let incidents: [Incident]

        enum CodingKeys: String, CodingKey { case components, incidents }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            // `components` stays required so `{}` can never become a false all-clear.
            components = try container.decode([Component].self, forKey: .components)
            // OpenAI's current Statuspage-compatible summary legitimately omits this key
            // when there are no unresolved incidents; Anthropic returns an empty array.
            incidents = try container.decodeIfPresent([Incident].self, forKey: .incidents) ?? []
        }
    }

    private struct StatusPayload: Decodable {
        struct Indicator: Decodable { let indicator: String }
        let status: Indicator
    }
}
