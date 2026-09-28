import Foundation
import TokiLogging

private let log = TokiLog.logger("menubar")

/// Loads and saves the menu-bar configuration.
///
/// Takes its `UserDefaults` by injection rather than reaching for `.standard` so tests can
/// hand it an isolated suite instead of touching the developer's real preferences.
///
/// `@unchecked Sendable`: `UserDefaults` is thread-safe (documented by Apple) but this SDK
/// doesn't mark it `Sendable`, the same escape hatch `SubprocessGate` (`TokiKeychain`) takes
/// for the same reason.
public struct MenuBarConfigurationStore: @unchecked Sendable {
    private static let key = "toki.menuBarConfiguration"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// Never throws and never returns an empty list — an unreadable preference must not cost
    /// the user their menu bar. Falls back to `.standard` in three cases: nothing has been
    /// saved yet, the stored bytes aren't valid JSON at all (corrupt), and the bytes ARE valid
    /// JSON but decode to something `MenuBarConfiguration`'s `Decodable` itself rejects (e.g.
    /// an `IndicatorRendering` raw value from a future version this build doesn't know).
    /// `MenuBarConfiguration`'s own decoder already clamps an out-of-range indicator count, so
    /// this layer only has to guard against decode *failing* outright.
    public func load() -> MenuBarConfiguration {
        guard let data = defaults.data(forKey: Self.key) else { return .standard }
        do {
            return try JSONDecoder().decode(MenuBarConfiguration.self, from: data)
        } catch {
            log.error("menu bar configuration decode failed, reverting to standard \(error: error)")
            return .standard
        }
    }

    /// Silently drops the write on encode failure (there is nothing actionable to do — the
    /// value being saved is always a valid, in-memory `MenuBarConfiguration`) rather than
    /// throwing into a caller that has no recovery path either.
    public func save(_ configuration: MenuBarConfiguration) {
        let data: Data
        do {
            data = try JSONEncoder().encode(configuration)
        } catch {
            log.error("menu bar configuration encode failed \(error: error)")
            return
        }
        defaults.set(data, forKey: Self.key)
    }
}
