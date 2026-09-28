import Foundation

/// Persists the "already announced this episode" latch across launches.
///
/// Modelled on `ThresholdAlertLatchStore`: injected `UserDefaults` so tests never touch the
/// real domain, and an unreadable value costs the user nothing. The failure budget is
/// deliberately one duplicate notification — an unreadable latch falls back to a fresh
/// policy, which at worst re-announces an incident the user already heard about. It never
/// throws, and it never touches any other key, so a corrupt latch cannot cost a setting.
///
/// Without this, every launch during a multi-hour Anthropic incident would greet the user
/// with "Claude Code: degraded performance" all over again.
public struct StatusAlertLatchStore: @unchecked Sendable {
    private static let key = "toki.statusAlertLatch"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults) { self.defaults = defaults }

    /// The stored latch, or a fresh policy when the key is absent or the bytes do not decode.
    public func load() -> StatusAlertPolicy {
        // no-log: local UserDefaults round-trip of a value this module wrote itself, not a
        // network outcome. An absent or unreadable latch is the documented, routine "no
        // announcement yet / schema moved on" case — the fallback to a fresh policy IS the
        // behaviour (see the type's doc comment), not a fault worth a line in the log the
        // user's "it stopped updating" complaint would ever need.
        guard let data = defaults.data(forKey: Self.key),
              let decoded = try? JSONDecoder().decode(StatusAlertPolicy.self, from: data)
        else { return StatusAlertPolicy() }
        return decoded
    }

    public func save(_ policy: StatusAlertPolicy) {
        // no-log: encoding this module's own `Codable` struct (a `Set<String>` of ids) can
        // only fail from a programmer error (e.g. NaN in a future field), which `swift test`
        // catches — not a runtime condition worth logging.
        guard let data = try? JSONEncoder().encode(policy) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
