/// Which system notification an auto-swap evaluation warrants — the driver's notification
/// rules as a pure value so they are testable without UserNotifications or a Keychain.
import Foundation

public enum AutoSwapNotification: Equatable, Sendable {
    case allExhausted
    /// The only thing between the user and a working account is a re-login, so say that
    /// instead of claiming every account is at its limit — waiting would not fix this one.
    case needsReauth(label: String)
}

public struct AutoSwapNotificationPolicy: Equatable, Sendable {
    private var exhaustion = ExhaustionLatch()
    private var reauthNotified = false

    public init() {}

    /// - Parameter notificationsEnabled: whether the user wants to hear about EITHER kind this
    ///   policy can return. The caller knows which kind it received and gates the actual post on
    ///   the matching per-notification flag; this parameter only decides whether the latches run
    ///   at all, so passing "either kind is wanted" keeps the policy armed for both.
    public mutating func notification(
        for decision: SwapDecision,
        accounts: [AccountSnapshot],
        notificationsEnabled: Bool
    ) -> AutoSwapNotification? {
        // Reset rather than latch while opted out: a user who turns notifications back on
        // during an episode is told what is happening now, not after the next recovery.
        guard notificationsEnabled else {
            self = AutoSwapNotificationPolicy()
            return nil
        }

        // The latch is fed every decision, not just the ones it answers for — that is what
        // re-arms it when the situation changes.
        let exhausted = exhaustion.shouldNotify(decision: decision)

        switch decision {
        case .allExhausted:
            return exhausted ? .allExhausted : nil
        case .needsReauth:
            guard let label = accounts.first(where: { !$0.isActive && !$0.isHealthy })?.label
            else { return nil }
            guard !reauthNotified else { return nil }
            reauthNotified = true
            return .needsReauth(label: label)
        case .doNothing, .swap:
            reauthNotified = false
            return nil
        }
    }
}
