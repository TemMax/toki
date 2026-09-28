import Testing
@testable import TokiModels

/// `ExtraUsage.prominence` decides whether extra usage gets a gauge card, one quiet line, or
/// nothing. It used to live in the popover view, where `swift test` could not reach it — and
/// it was wrong there: keyed on `usedCredits` alone, a response carrying a `utilization` but
/// no credit amount collapsed to the quiet line, which has no amounts to print and falls back
/// to the word "on". A percentage the API sent was dropped on the floor, and no test could
/// have noticed. These cases exist so that specific mistake fails here instead.
@Suite("ExtraUsage.prominence")
struct ExtraUsageProminenceTests {

    private func extra(
        enabled: Bool = true,
        limit: Double? = 50,
        used: Double? = nil,
        utilization: Double? = nil,
        capReached: Bool = false
    ) -> ExtraUsage {
        ExtraUsage(
            isEnabled: enabled,
            monthlyLimit: limit,
            usedCredits: used,
            utilization: utilization,
            spendLimitReached: capReached
        )
    }

    @Test("off and untouched says nothing at all")
    func offAndUnusedIsHidden() {
        #expect(extra(enabled: false).prominence == .hidden)
        #expect(extra(enabled: false, used: 0, utilization: 0).prominence == .hidden)
    }

    @Test("on with nothing spent collapses to one line")
    func enabledButUnspentIsALine() {
        #expect(extra(used: 0, utilization: 0).prominence == .line)
        #expect(extra().prominence == .line)
    }

    @Test("spent credits earn the full card")
    func spendingEarnsTheCard() {
        #expect(extra(used: 12.5, utilization: 0.25).prominence == .card)
    }

    /// The regression this whole type exists for. `usedCredits` and `utilization` are
    /// independent optionals on the wire; neither can stand in for the other.
    @Test("a utilization with no credit amount still earns the card")
    func utilizationAloneEarnsTheCard() {
        let u = extra(limit: nil, used: nil, utilization: 0.42)
        #expect(u.usedCredits == nil, "precondition: this is the field that used to decide")
        #expect(u.prominence == .card, "a percentage the API sent must not collapse to \"on\"")
    }

    /// The API can flip `is_enabled` off at the exact moment the cap is hit. Hiding the
    /// section there would remove the only explanation for why usage stopped.
    @Test("the cap being reached shows the card even with the switch off")
    func capReachedOverridesDisabled() {
        #expect(extra(enabled: false, used: 50, utilization: 1, capReached: true).prominence == .card)
        #expect(extra(enabled: false, used: nil, utilization: nil, capReached: true).prominence == .card)
    }

    /// Deliberate: money spent this month is worth reporting whatever position the switch is
    /// in now. The behaviour this replaced keyed the whole section on `isEnabled` and hid it.
    @Test("spend recorded while switched off still shows the card")
    func spendSurvivesBeingSwitchedOff() {
        #expect(extra(enabled: false, used: 7.25).prominence == .card)
    }

    /// A gauge pinned at 0% is not information — the line still reports that it is on.
    @Test("exactly zero utilization is not enough for a card")
    func zeroUtilizationStaysALine() {
        #expect(extra(used: 0, utilization: 0).prominence == .line)
    }
}
