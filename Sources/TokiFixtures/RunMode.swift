/// Whether the app is showing the user's real data or a named fixture scenario.
///
/// One owner instead of six independent `demoMode` booleans: callers set this once and
/// every surface follows, so a new view model cannot silently miss the flag the way
/// AccountsViewModel did.
public enum RunMode: Sendable, Equatable {
    case live
    case fixture(Scenario)

    public var isLive: Bool {
        if case .live = self { return true }
        return false
    }

    /// The scenario, when running on fixtures.
    public var scenario: Scenario? {
        if case let .fixture(scenario) = self { return scenario }
        return nil
    }
}
