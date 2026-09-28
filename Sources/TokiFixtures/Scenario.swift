/// Named mock-data scenarios shared by the snapshot harness, a debug control channel, and
/// tests — ONE deterministic source instead of each caller building its own ad-hoc mocks.
import Foundation

public enum Scenario: String, CaseIterable, Sendable {
    /// Nothing loaded yet: the very first launch, before any fetch has completed.
    case fresh
    /// One healthy signed-in account.
    case singleAccount = "single-account"
    /// Public README artwork: a healthy demonstration account with a Fable weekly window.
    case publicReadme = "public-readme"
    /// Several accounts in different health/activity states.
    case multiAccount = "multi-account"
    /// Every window close to its ceiling — the auto-swap-about-to-fire state.
    case nearLimit = "near-limit"
    /// Extra (pay-as-you-go) usage exhausted this month.
    case extraExhausted = "extra-exhausted"
    /// Layout stress: many models/projects/days, long strings.
    case heavy
    /// The usage API is unreachable; cached data is shown alongside the error.
    case error
    /// The Claude session exists, but Toki needs Keychain access restored.
    case keychainAccess = "keychain-access"
    /// Signed in, but zero usage recorded yet — "day one after install".
    case empty
    /// The two states the popover renders differently but no other scenario produces: a
    /// rate-limit window the API reports no data for (`isAvailable == false`), and extra
    /// usage that is switched on with nothing spent against it yet.
    ///
    /// It exists because both were unreachable. The popover redesign collapsed each of them
    /// from a full card to a single row, and neither collapsed form could be rendered — the
    /// other seven scenarios have every window available and every extra usage either off or
    /// exhausted, so the branches type-checked and were never once looked at. A branch no
    /// fixture reaches is a branch nobody reviews.
    case quietEdges = "quiet-edges"
    /// An active minor incident affecting Claude Code — the service-status banner in
    /// its warn form, in the popover and the dashboard.
    case statusMinorIncident = "status-minor"
    /// A major outage taking Claude Code down — the banner in its critical form.
    case statusCriticalOutage = "status-outage"
    /// An eligible account with two saved reset grants, one immediately usable.
    case claudeResets = "claude-resets"
    /// An eligible account whose saved reset balance is known to be zero.
    case claudeResetsZero = "claude-resets-zero"
    /// An eligible account with resets saved, but a future cooldown prevents their use.
    case claudeResetsCooldown = "claude-resets-cooldown"
    /// An account whose reset balance exists but is not eligible for use.
    case claudeResetsIneligible = "claude-resets-ineligible"
}
