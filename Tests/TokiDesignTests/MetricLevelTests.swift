import Testing
@testable import TokiDesign

/// `Tokens.level(for:)` is the gauge-colour rule, pulled out so it can be exercised without
/// going through `App/Sources` (not a SwiftPM target, so `swift test` can't reach it).
@Suite("Gauge colour level")
struct MetricLevelTests {
    @Test("just below the warn threshold is still nominal")
    func justBelowWarnIsNominal() {
        #expect(Tokens.level(for: 0.599) == .nominal)
    }

    @Test("exactly at the warn threshold escalates to warning")
    func atWarnIsWarning() {
        #expect(Tokens.level(for: Tokens.warnThreshold) == .warning)
    }

    @Test("just below the critical threshold is still warning")
    func justBelowCriticalIsWarning() {
        #expect(Tokens.level(for: 0.849) == .warning)
    }

    @Test("exactly at the critical threshold escalates to critical")
    func atCriticalIsCritical() {
        #expect(Tokens.level(for: Tokens.criticalThreshold) == .critical)
    }

    @Test("0.0 is nominal")
    func zeroIsNominal() {
        #expect(Tokens.level(for: 0.0) == .nominal)
    }

    @Test("1.0 is critical")
    func oneIsCritical() {
        #expect(Tokens.level(for: 1.0) == .critical)
    }

    @Test("a fraction above 1.0 (usage past its cap) is still critical, not a trap")
    func aboveOneIsCritical() {
        #expect(Tokens.level(for: 1.5) == .critical)
    }

    @Test("a negative fraction resolves to nominal rather than trapping")
    func negativeIsNominal() {
        #expect(Tokens.level(for: -0.5) == .nominal)
    }

    @Test("nominal covers strictly more of 0...1 than warning and critical combined")
    func nominalIsTheDefaultNotTheException() {
        let nominalWidth = Tokens.warnThreshold
        let coloredWidth = 1.0 - Tokens.warnThreshold
        #expect(nominalWidth > coloredWidth)
    }
}
