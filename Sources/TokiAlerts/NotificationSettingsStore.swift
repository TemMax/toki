import Foundation
import TokiLogging

private let log = TokiLog.logger("alerts")

/// Mirrors `MenuBarConfigurationStore`: injected `UserDefaults` so tests never touch the real
/// domain, and an unreadable preference costs the user nothing.
public struct NotificationSettingsStore: @unchecked Sendable {
    private static let key = "toki.notificationSettings"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults) { self.defaults = defaults }

    public func load() -> NotificationSettings {
        guard let data = defaults.data(forKey: Self.key) else { return .standard }
        do {
            return try JSONDecoder().decode(NotificationSettings.self, from: data)
        } catch {
            log.error("notification settings decode failed, reverting to standard \(error: error)")
            return .standard
        }
    }

    public func save(_ settings: NotificationSettings) {
        let data: Data
        do {
            data = try JSONEncoder().encode(settings)
        } catch {
            log.error("notification settings encode failed \(error: error)")
            return
        }
        defaults.set(data, forKey: Self.key)
    }
}
