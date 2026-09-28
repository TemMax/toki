import Foundation
import Testing
@testable import TokiStatus

@Suite("StatusPollPlanner")
struct StatusPollPlannerTests {

    @Test("a healthy status polls once a minute")
    func healthy() {
        #expect(StatusPollPlanner.interval(after: .operational) == 60)
    }

    /// While the banner is up the user is watching it, so halve the wait — both to pick up
    /// each new update from Anthropic and to clear the banner promptly when it is over.
    @Test("a live incident polls twice as often, at both severities")
    func disrupted() {
        let degraded = ServiceStatus(severity: .degraded, incident: nil)
        let outage = ServiceStatus(
            severity: .outage,
            incident: StatusIncident(id: "x", title: "t", latestUpdate: nil,
                                     updatedAt: nil, affectedComponentNames: [])
        )

        #expect(StatusPollPlanner.interval(after: degraded) == 30)
        #expect(StatusPollPlanner.interval(after: outage) == 30)
    }
}
