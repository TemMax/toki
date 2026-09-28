import Testing
@testable import TokiAlerts

@Suite("ThresholdAlertCopy")
struct ThresholdAlertCopyTests {
    private func alert(_ entries: (String, Double)...) -> ThresholdAlert {
        ThresholdAlert(entries: entries.map {
            ThresholdAlert.Entry(title: $0.0, utilization: $0.1, threshold: 0.9)
        })
    }

    @Test("one window names it in the title")
    func single() {
        #expect(ThresholdAlertCopy.title(for: alert(("5-hour", 0.91))) == "5-hour limit at 91%")
    }

    @Test("several windows are summarised, not repeated")
    func several() {
        let a = alert(("7-day", 0.91), ("Fable", 0.95))
        #expect(ThresholdAlertCopy.title(for: a) == "2 limits are running low")
        #expect(ThresholdAlertCopy.body(for: a) == "7-day 91% · Fable 95%")
    }

    @Test("a full window says it is out, not that it is running low")
    func exhausted() {
        #expect(ThresholdAlertCopy.title(for: alert(("5-hour", 1.0))) == "5-hour limit reached")
    }

    @Test("percentages round rather than truncate")
    func rounding() {
        #expect(ThresholdAlertCopy.title(for: alert(("5-hour", 0.899))) == "5-hour limit at 90%")
    }
}
