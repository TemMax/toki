import Testing
import Foundation
@testable import TokiAutoSwap

private let trigger = SwapTrigger(window: .fiveHour, utilization: 0.95)

private func snapshot(
    _ uuid: String, isActive: Bool = false, isHealthy: Bool = true
) -> AccountSnapshot {
    AccountSnapshot(
        accountUuid: uuid, label: "\(uuid)@example.com", fiveHour: 0.1, weekly: 0.1,
        isActive: isActive, isHealthy: isHealthy, gaugesAreStale: false
    )
}

private let roster = [snapshot("a", isActive: true), snapshot("b", isHealthy: false)]

@Suite("AutoSwapNotificationPolicy")
struct AutoSwapNotificationPolicyTests {

    @Test("swap notifications turned off silences the all-exhausted alert too")
    func exhaustionRespectsTheSetting() {
        var policy = AutoSwapNotificationPolicy()
        let result = policy.notification(
            for: .allExhausted(trigger), accounts: roster, notificationsEnabled: false
        )
        #expect(result == nil)
    }

    @Test("all-exhausted fires once per episode when notifications are on")
    func exhaustionFiresOncePerEpisode() {
        var policy = AutoSwapNotificationPolicy()
        let first = policy.notification(
            for: .allExhausted(trigger), accounts: roster, notificationsEnabled: true
        )
        let second = policy.notification(
            for: .allExhausted(trigger), accounts: roster, notificationsEnabled: true
        )
        #expect(first == .allExhausted)
        #expect(second == nil)
    }

    @Test("a re-login blocker is reported as such, naming the account")
    func reauthIsRoutedToItsOwnNotification() {
        var policy = AutoSwapNotificationPolicy()
        let result = policy.notification(
            for: .needsReauth(trigger), accounts: roster, notificationsEnabled: true
        )
        #expect(result == .needsReauth(label: "b@example.com"))
    }

    @Test("the re-login notification does not repeat every poll")
    func reauthFiresOncePerEpisode() {
        var policy = AutoSwapNotificationPolicy()
        let first = policy.notification(
            for: .needsReauth(trigger), accounts: roster, notificationsEnabled: true
        )
        let second = policy.notification(
            for: .needsReauth(trigger), accounts: roster, notificationsEnabled: true
        )
        #expect(first == .needsReauth(label: "b@example.com"))
        #expect(second == nil)
    }

    @Test("it re-arms once a swap or a quiet poll clears the episode")
    func recoveryReArmsBothNotifications() {
        var policy = AutoSwapNotificationPolicy()
        _ = policy.notification(for: .needsReauth(trigger), accounts: roster, notificationsEnabled: true)
        _ = policy.notification(
            for: .swap(to: "b", trigger: trigger), accounts: roster, notificationsEnabled: true
        )
        let again = policy.notification(
            for: .needsReauth(trigger), accounts: roster, notificationsEnabled: true
        )
        #expect(again == .needsReauth(label: "b@example.com"))
    }

    @Test("turning notifications back on mid-episode still tells the user")
    func optingBackInIsNotSwallowedByTheLatch() {
        var policy = AutoSwapNotificationPolicy()
        _ = policy.notification(
            for: .allExhausted(trigger), accounts: roster, notificationsEnabled: false
        )
        let afterOptIn = policy.notification(
            for: .allExhausted(trigger), accounts: roster, notificationsEnabled: true
        )
        #expect(afterOptIn == .allExhausted)
    }

    @Test("a quiet poll notifies nothing")
    func quietPollIsSilent() {
        var policy = AutoSwapNotificationPolicy()
        let result = policy.notification(
            for: .doNothing, accounts: roster, notificationsEnabled: true
        )
        #expect(result == nil)
    }
}
