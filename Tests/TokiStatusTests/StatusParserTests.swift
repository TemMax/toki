import Foundation
import Testing
@testable import TokiStatus

@Suite("StatusParser")
struct StatusParserTests {

    private func parse(_ json: String) throws -> ServiceStatus {
        try StatusParser.serviceStatus(fromSummary: StatusFixtures.data(json))
    }

    @Test("OpenAI summary may omit incidents and still reports the worst Codex component")
    func openAICodexSummaryWithoutIncidents() throws {
        let json = #"""
        {"components":[
          {"id":"login","name":"Login","status":"operational"},
          {"id":"codex-api","name":"Codex API","status":"partial_outage"},
          {"id":"images","name":"Images","status":"major_outage"}
        ]}
        """#
        let status = try StatusParser.serviceStatus(
            fromSummary: Data(json.utf8),
            componentNames: StatusParser.openAICodexComponentNames
        )
        #expect(status.severity == .outage)
        #expect(status.incident == nil)
    }

    /// The edge the feature exists for: components are green again but the incident is still
    /// open. Reporting "operational" here would tell the user everything is fine while
    /// Anthropic is still watching a fix land.
    @Test("an incident in monitoring with every component back to operational still reads degraded")
    func monitoringIncidentIsStillDegraded() throws {
        let status = try parse(StatusFixtures.summaryMonitoring)

        #expect(status.severity == .degraded)
        #expect(status.isDisrupted)
        #expect(status.incident?.id == "q7txxvbsftgq")
        #expect(status.incident?.title == "Degraded performance for multiple models")
        #expect(status.incident?.latestUpdate == "A fix has been implemented and we are monitoring the results.")
        #expect(status.incident?.affectedComponentNames.contains("Claude Code") == true)
    }

    /// The newest update is the head of `incident_updates`, and the names are the union across
    /// all of them, deduplicated in first-seen order — four components, each listed four times.
    @Test("affected component names are the deduplicated union across every update")
    func affectedNamesAreDeduplicated() throws {
        let status = try parse(StatusFixtures.summaryMonitoring)

        #expect(status.incident?.affectedComponentNames == [
            "claude.ai",
            "Claude API (api.anthropic.com)",
            "Claude Code",
            "Claude Cowork",
        ])
    }

    @Test("a live degradation reads degraded")
    func liveDegradation() throws {
        let status = try parse(StatusFixtures.summaryDegraded)

        #expect(status.severity == .degraded)
        #expect(status.incident?.id == "q7txxvbsftgq")
        #expect(status.incident?.latestUpdate?.hasPrefix("We are investigating elevated errors") == true)
    }

    @Test("no incidents and every component green reads operational, with no incident attached")
    func allClear() throws {
        let status = try parse(StatusFixtures.summaryOperational)

        #expect(status.severity == .operational)
        #expect(status.isDisrupted == false)
        #expect(status.incident == nil)
        #expect(status == .operational)
    }

    @Test("a major outage on the component with a critical incident reads outage")
    func outage() throws {
        let status = try parse(StatusFixtures.summaryOutage)

        #expect(status.severity == .outage)
        #expect(status.incident?.id == "q7txxvbsftgq")
    }

    /// The whole point of matching on the component: claude.ai can be on fire while the thing
    /// the user is running in their terminal is completely fine. Showing them a banner for it
    /// would train them to ignore the banner.
    @Test("an incident that never touches Claude Code is invisible")
    func irrelevantIncident() throws {
        let status = try parse(StatusFixtures.summaryIrrelevantIncident)

        #expect(status.severity == .operational)
        #expect(status.incident == nil)
    }

    /// Fractional seconds, which `JSONDecoder`'s stock `.iso8601` strategy handles
    /// inconsistently across Foundation versions — hence the explicit
    /// `.withFractionalSeconds` formatter. `display_at` of the newest update is
    /// 2026-08-18T18:26:31.164Z, and the milliseconds have to survive.
    @Test("fractional-second timestamps parse to the exact instant, milliseconds included")
    func fractionalSecondDates() throws {
        let status = try parse(StatusFixtures.summaryMonitoring)

        let expected = Date(timeIntervalSince1970: 1_787_077_591.164)
        let actual = try #require(status.incident?.updatedAt)
        #expect(abs(actual.timeIntervalSince(expected)) < 0.001)
    }

    /// Dates are decoded as strings and converted nil-tolerantly precisely so this cannot
    /// happen: one unparseable timestamp must cost a missing "updated at", not the incident.
    @Test("a malformed timestamp loses only that date, not the whole status")
    func malformedDateDoesNotLoseTheStatus() throws {
        let json = #"""
        {"components":[{"id":"yyzkbfz2thpt","name":"Claude Code","status":"degraded_performance"}],
         "incidents":[{"id":"abc","name":"Elevated errors","impact":"minor","started_at":"yesterday-ish",
          "incident_updates":[{"body":"Looking into it.","display_at":"not a date",
           "affected_components":[{"code":"yyzkbfz2thpt","name":"Claude Code"}]}]}]}
        """#

        let status = try StatusParser.serviceStatus(fromSummary: StatusFixtures.data(json))

        #expect(status.severity == .degraded)
        #expect(status.incident?.id == "abc")
        #expect(status.incident?.latestUpdate == "Looking into it.")
        #expect(status.incident?.updatedAt == nil)
    }

    @Test("garbage bytes throw instead of trapping")
    func garbageBytes() {
        #expect(throws: StatusParser.ParseError.malformed) {
            try StatusParser.serviceStatus(fromSummary: Data([0x00, 0x01, 0xFF, 0xFE, 0x7F]))
        }
        #expect(throws: StatusParser.ParseError.malformed) {
            try StatusParser.serviceStatus(fromSummary: StatusFixtures.data("not json at all"))
        }
    }

    /// `{}` decodes cleanly into "no components, no incidents" if the fields are optional —
    /// which would report a confident "all systems operational" built out of nothing. It has
    /// to be an error instead.
    @Test("an empty json object is rejected rather than read as all-clear")
    func emptyObject() {
        #expect(throws: StatusParser.ParseError.malformed) {
            try StatusParser.serviceStatus(fromSummary: StatusFixtures.data("{}"))
        }
        #expect(throws: StatusParser.ParseError.malformed) {
            try StatusParser.serviceStatus(fromSummary: Data())
        }
    }

    @Test("the tiny status payload yields its page-wide indicator")
    func statusIndicator() throws {
        #expect(try StatusParser.indicator(fromStatus: StatusFixtures.data(StatusFixtures.statusNone)) == "none")
        #expect(try StatusParser.indicator(fromStatus: StatusFixtures.data(StatusFixtures.statusMinor)) == "minor")
        #expect(throws: StatusParser.ParseError.malformed) {
            try StatusParser.indicator(fromStatus: StatusFixtures.data("{}"))
        }
    }
}
