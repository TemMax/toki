import Foundation
import Testing
@testable import TokiStatus

@Suite("OpenAI incident compatibility")
struct OpenAIStatusTests {
    // Shape captured from status.openai.com/api/v2/incidents.json on 2026-09-07:
    // OpenAI omits affected_components and started_at. Status is replayed as monitoring
    // to verify a live incident with already-operational component gauges.
    private func summary(title: String = "Elevated Codex API authentication errors", status: String = "monitoring") -> Data {
        Data("""
        {"components":[{"id":"codex-api","name":"Codex API","status":"operational"}],
         "incidents":[{"id":"codex-auth","name":"\(title)","status":"\(status)",
         "created_at":"2026-09-04T07:00:26Z","impact":"minor",
         "incident_updates":[{"body":"We are monitoring recovery.","display_at":"2026-09-04T09:47:58Z","status":"monitoring"}]}]}
        """.utf8)
    }

    @Test("explicit Codex incident remains visible without affected component metadata")
    func incidentWithoutComponents() throws {
        let status = try StatusParser.serviceStatus(
            fromSummary: summary(), componentNames: StatusParser.openAICodexComponentNames,
            incidentTitleKeywords: ["Codex"]
        )
        #expect(status.severity == .degraded)
        #expect(status.incident?.id == "codex-auth")
        #expect(status.incident?.latestUpdate == "We are monitoring recovery.")
    }

    @Test("OpenAI incidents are ordered by created_at when started_at is absent")
    func ordersByCreationDate() throws {
        var payload = try #require(JSONSerialization.jsonObject(with: summary()) as? [String: Any])
        let original = try #require((payload["incidents"] as? [[String: Any]])?.first)
        var older = original
        older["id"] = "older"
        older["created_at"] = "2026-09-01T07:00:26Z"
        payload["incidents"] = [older, original]
        let status = try StatusParser.serviceStatus(
            fromSummary: JSONSerialization.data(withJSONObject: payload),
            componentNames: StatusParser.openAICodexComponentNames,
            incidentTitleKeywords: ["Codex"]
        )
        #expect(status.incident?.id == "codex-auth")
    }

    @Test("title fallback excludes unrelated products, resolved incidents and other providers")
    func limitsFallbackScope() throws {
        for data in [summary(title: "Elevated image errors"), summary(status: "resolved"), summary(title: "Codexyz errors")] {
            let status = try StatusParser.serviceStatus(
                fromSummary: data, componentNames: StatusParser.openAICodexComponentNames,
                incidentTitleKeywords: ["Codex"]
            )
            #expect(status == .operational)
        }
        #expect(try StatusParser.serviceStatus(fromSummary: summary()) == .operational)
    }
}
