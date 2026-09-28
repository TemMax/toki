import Foundation
import UserNotifications
import TokiAlerts
import TokiCore
import TokiAutoSwap

private let log = TokiLog.logger("app")

/// System notifications for account swaps.
struct SwapNotifier: Sendable {
    // UNUserNotificationCenter isn't Sendable in this SDK, but `.current()` is a
    // documented thread-safe singleton — safe to hand across actors unguarded.
    private nonisolated(unsafe) let center = UNUserNotificationCenter.current()

    func requestAuthorization() async -> Bool {
        do {
            return try await center.requestAuthorization(options: [.alert, .sound])
        } catch {
            log.error("requestAuthorization: failed: \(error: error)")
            return false
        }
    }

    func notifySwap(
        from: String?,
        to: String,
        trigger: SwapTrigger?,
        provider: UsageProvider = .claudeCode
    ) {
        let route = from.map { "\($0) → \(to)" } ?? "Now using \(to)"
        var body = route
        if let trigger {
            let window = trigger.window == .fiveHour ? "5-hour" : "weekly"
            body += " · \(window) limit \(Int((trigger.utilization * 100).rounded()))%"
        }
        post(title: "Toki switched \(provider.displayName) accounts", body: body)
    }

    func notifyAllExhausted(provider: UsageProvider = .claudeCode) {
        post(
            title: "All \(provider.displayName) accounts are at their limit",
            body: "No account has enough headroom to switch to right now."
        )
    }

    func notifyNeedsReauth(label: String, provider: UsageProvider = .claudeCode) {
        let instruction = provider == .claudeCode
            ? "Open the Claude CLI and run /login."
            : "Open Codex and sign in again."
        post(title: "\(label) needs you to sign in again", body: instruction)
    }

    /// One or more configured rate-limit thresholds have been reached. The wording is
    /// `ThresholdAlertCopy`'s, not this type's, so it stays testable without UserNotifications.
    func notifyThresholds(_ alert: ThresholdAlert, provider: UsageProvider = .claudeCode) {
        post(
            title: "\(provider.displayName): \(ThresholdAlertCopy.title(for: alert))",
            body: ThresholdAlertCopy.body(for: alert)
        )
    }

    /// Claude Code's own service began — or finished — having a problem. The wording is
    /// `StatusAlertCopy`'s, for the same reason as the thresholds above.
    func notifyServiceStatus(
        _ event: StatusAlertPolicy.Event,
        provider: UsageProvider = .claudeCode
    ) {
        let organization = provider == .claudeCode ? "Anthropic" : "OpenAI"
        post(
            title: StatusAlertCopy.title(for: event, providerName: provider.displayName),
            body: StatusAlertCopy.body(
                for: event,
                providerName: provider.displayName,
                organizationName: organization
            )
        )
    }

    /// A new account was signed into in Claude Code that Toki doesn't store yet. Tapping the
    /// notification opens the dashboard's Accounts tab, where it can be saved (macOS can't put
    /// an action button on a local notification for this, so tap-to-open is the affordance).
    func notifyNewAccount(label: String, provider: UsageProvider = .claudeCode) {
        post(
            title: "New \(provider.displayName) account signed in",
            body: "\(label) — open Toki to save it and switch back later.",
            opensAccounts: true
        )
    }

    func notifyReset(title: String, body: String, destination: URL) {
        guard ResetLinks.allowed(destination) else { return }
        post(title: title, body: body, destination: destination)
    }

    static let resetURLKey = "toki.resetURL"

    private func post(title: String, body: String, opensAccounts: Bool = false, destination: URL? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        // Left at the default interruption level. `.timeSensitive` needs the
        // com.apple.developer.usernotifications.time-sensitive entitlement, which requires a
        // provisioning-profile change — a separate release task, deliberately not done here.
        if opensAccounts {
            // Read by the notification-center delegate (`AppDelegate`) on tap.
            content.userInfo = [Self.openAccountsKey: true]
        }
        if let destination { content.userInfo[Self.resetURLKey] = destination.absoluteString }
        center.add(UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil
        ))
    }

    /// userInfo flag marking a notification whose tap should open the Accounts tab.
    static let openAccountsKey = "toki.openAccounts"
}
