import Testing
import Foundation
@testable import TokiAutoSwap

@Suite("AutoSwapSettings.isSilentlyDisarmed")
struct AutoSwapSettingsDisarmedTests {

    private func settings(
        enabled: Bool, watchFiveHour: Bool, watchWeekly: Bool
    ) -> AutoSwapSettings {
        AutoSwapSettings(
            enabled: enabled, watchFiveHour: watchFiveHour, fiveHourThreshold: 0.9,
            watchWeekly: watchWeekly, weeklyThreshold: 0.9, cooldown: 600
        )
    }

    @Test("on with neither window watched is disarmed")
    func neitherWindowWatched() {
        #expect(settings(enabled: true, watchFiveHour: false, watchWeekly: false)
            .isSilentlyDisarmed)
    }

    @Test("one watched window is enough to arm it")
    func oneWindowIsEnough() {
        #expect(!settings(enabled: true, watchFiveHour: true, watchWeekly: false)
            .isSilentlyDisarmed)
        #expect(!settings(enabled: true, watchFiveHour: false, watchWeekly: true)
            .isSilentlyDisarmed)
    }

    @Test("switched off is not a warning — the user asked for nothing to happen")
    func disabledIsNotAWarning() {
        #expect(!settings(enabled: false, watchFiveHour: false, watchWeekly: false)
            .isSilentlyDisarmed)
    }

    @Test("the shipped default is armed")
    func defaultsAreArmed() {
        var enabled = AutoSwapSettings.default
        enabled.enabled = true
        #expect(!enabled.isSilentlyDisarmed)
    }

    @Test("the policy really does nothing in the disarmed configuration")
    func disarmedSettingsNeverSwap() {
        let disarmed = settings(enabled: true, watchFiveHour: false, watchWeekly: false)
        let accounts = [
            AccountSnapshot(
                accountUuid: "a", label: "a", fiveHour: 0.99, weekly: 0.99,
                isActive: true, isHealthy: true, gaugesAreStale: false
            ),
            AccountSnapshot(
                accountUuid: "b", label: "b", fiveHour: 0.01, weekly: 0.01,
                isActive: false, isHealthy: true, gaugesAreStale: false
            )
        ]
        let decision = AutoSwapPolicy.decide(
            accounts: accounts, settings: disarmed, now: Date(), lastSwapAt: nil
        )
        #expect(decision == .doNothing)
        #expect(disarmed.isSilentlyDisarmed)
    }
}
