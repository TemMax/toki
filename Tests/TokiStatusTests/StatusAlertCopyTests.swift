import Foundation
import Testing
@testable import TokiStatus

@Suite("StatusAlertCopy")
struct StatusAlertCopyTests {

    @Test("a degradation reads as degraded performance, with Anthropic's own title as the body")
    func degraded() {
        let event = StatusAlertPolicy.Event.incidentBegan(
            severity: .degraded, title: "Degraded performance for multiple models")

        #expect(StatusAlertCopy.title(for: event) == "Claude: degraded performance")
        #expect(StatusAlertCopy.body(for: event) == "Degraded performance for multiple models")
    }

    @Test("an outage says outage")
    func outage() {
        let event = StatusAlertPolicy.Event.incidentBegan(severity: .outage, title: "Elevated errors")

        #expect(StatusAlertCopy.title(for: event) == "Claude: service outage")
        #expect(StatusAlertCopy.body(for: event) == "Elevated errors")
    }

    /// The pre-publication case: the component is degraded but there is no incident yet, so
    /// there is no title to quote. The body still has to say something useful.
    @Test("a disruption with no published incident falls back to a written body")
    func noTitle() {
        let event = StatusAlertPolicy.Event.incidentBegan(severity: .degraded, title: nil)

        #expect(StatusAlertCopy.title(for: event) == "Claude: degraded performance")
        #expect(StatusAlertCopy.body(for: event) == "Anthropic reports a problem affecting Claude.")
    }

    @Test("the all-clear says it plainly")
    func resolved() {
        let event = StatusAlertPolicy.Event.incidentResolved

        #expect(StatusAlertCopy.title(for: event) == "Claude is back to normal")
        #expect(StatusAlertCopy.body(for: event) == "The incident affecting Claude is resolved.")
    }
}
