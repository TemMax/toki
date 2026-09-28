import Foundation
import Observation
import TokiCore
import TokiFixtures
import TokiMenuBar

// MARK: - MenuBarViewModel

/// Presents the shared `LiveLimits` for the menu-bar label and popover. It owns no fetch
/// cycle of its own — that lives in `LiveLimits`, the single source every surface observes —
/// so the popover, the Usage tab and the Accounts tab never drift apart.
///
/// The menu-bar *configuration* (which indicators, in what order, drawn how) is a second,
/// separate datum with its own single owner, `MenuBarConfigurationState` — this forwards to
/// it via computed `get`/`set` the same way it already forwards `LiveLimits`'s properties,
/// rather than caching its own copy.
@Observable
@MainActor
final class MenuBarViewModel {

    typealias State = LiveLimits.State

    private let live: LiveLimits
    private let configurationState: MenuBarConfigurationState
    private let usageDisplayState: UsageDisplayConfigurationState
    let availableProviders: Set<UsageProvider>

    init(
        live: LiveLimits,
        configurationState: MenuBarConfigurationState,
        usageDisplayState: UsageDisplayConfigurationState,
        availableProviders: Set<UsageProvider> = Set(UsageProvider.allCases)
    ) {
        self.live = live
        self.configurationState = configurationState
        self.usageDisplayState = usageDisplayState
        self.availableProviders = availableProviders
    }

    /// The current menu-bar configuration. A later Settings screen writes here; every
    /// observer (today just the status item's label) updates for free.
    var configuration: MenuBarConfiguration {
        get { configurationState.configuration }
        set { configurationState.configuration = newValue }
    }

    /// Shared visibility configuration for the dashboard Usage tab and the popover.
    var usageDisplayConfiguration: UsageDisplayConfiguration {
        get { usageDisplayState.configuration }
        set { usageDisplayState.configuration = newValue }
    }

    func displayedLimits(for provider: UsageProvider) -> UsageLimits? {
        let source = provider == .claudeCode ? limits : codexLimits
        return usageDisplayConfiguration.displayedLimits(from: source, provider: provider)
    }

    /// Reset availability is shown independently of selected gauge windows, but only
    /// after a successful current-account read. The view handles age/expiry on a timer.
    var currentCodexResetLimits: UsageLimits? {
        let isRestoredStale: Bool
        if case .stale = codexState { isRestoredStale = live.allowsRestoredCodexResets }
        else { isRestoredStale = false }
        let stateAllowsDisplay = codexState == .ok || isRestoredStale
        guard availableProviders.contains(.codex), usageDisplayConfiguration[.codex].isEnabled,
              stateAllowsDisplay, let codexLimits, codexLimits.bankedResets != nil else { return nil }
        return codexLimits
    }

    /// Last-known active-account data remains visible during a provider 429 or a
    /// deferred refresh after returning to that account. The reset model still enforces
    /// its expiry and eligibility rules.
    var allowsStaleClaudeResetDisplay: Bool {
        guard case .stale = state else { return false }
        return live.failure == .rateLimited || live.allowsRestoredClaudeResets
    }

    /// Claude reset availability shares the active-account limits snapshot. Gauge filtering
    /// does not remove it. A rate-limited or restored stale read retains last-known
    /// metadata; other failures keep the existing hidden behavior.
    var currentClaudeResetLimits: UsageLimits? {
        let stateAllowsDisplay = state == .ok || allowsStaleClaudeResetDisplay
        guard availableProviders.contains(.claudeCode),
              usageDisplayConfiguration[.claudeCode].isEnabled,
              stateAllowsDisplay,
              let limits,
              limits.claudeResets != nil
        else { return nil }
        return limits
    }

    // MARK: Forwarded state (single source: `LiveLimits`)

    var limits: UsageLimits? {
        get { live.limits }
        set { live.limits = newValue }
    }

    var state: State {
        get { live.state }
        set { live.state = newValue }
    }

    var claudeNeedsReconnect: Bool { live.failure == .authorization }

    var codexLimits: UsageLimits? {
        get { live.codexLimits }
        set { live.codexLimits = newValue }
    }

    var codexState: State {
        get { live.codexState }
        set { live.codexState = newValue }
    }

    var runMode: RunMode {
        get { live.runMode }
        set { live.runMode = newValue }
    }

    var limitsFetchEnabled: Bool {
        get { live.limitsFetchEnabled }
        set { live.limitsFetchEnabled = newValue }
    }

    // MARK: Derived

    /// True when the account is *currently* on extra usage — extra usage enabled and an
    /// included window (5-hour or 7-day) maxed out, so further usage spills into extra. Keyed
    /// on live limit state, not `extra.utilization` (a monthly counter that would otherwise
    /// leave the indicator stuck after dropping back under the limits).
    var isExtraUsageActive: Bool {
        guard let extra = limits?.extra, extra.isEnabled else { return false }
        let fiveHourMaxed = (limits?.fiveHour?.utilization ?? 0) >= 1.0
        let sevenDayMaxed = (limits?.sevenDay?.utilization ?? 0) >= 1.0
        return fiveHourMaxed || sevenDayMaxed
    }

    /// The configured indicator list, resolved against live data — what the status item draws
    /// in normal mode. `MenuBarLayout` is pure, so this recomputes from the two owning stores
    /// (`configurationState`, `live`) rather than caching a third copy of either.
    var resolvedIndicators: [ResolvedIndicator] {
        let visible = configuration.indicators.filter { availableProviders.contains($0.provider) }
        let effective: MenuBarConfiguration
        if visible.isEmpty, let provider = availableProviders.first {
            effective = MenuBarConfiguration(
                indicators: [
                    MenuBarIndicator(provider: provider, window: .fiveHour, rendering: .number),
                    MenuBarIndicator(provider: provider, window: .sevenDay, rendering: .number),
                ],
                style: configuration.style,
                compact: configuration.compact
            )
        } else {
            effective = MenuBarConfiguration(
                indicators: visible,
                style: configuration.style,
                compact: configuration.compact
            )
        }
        return MenuBarLayout.resolve(
            effective,
            claudeLimits: limits,
            codexLimits: codexLimits
        )
    }

    /// The single extra-usage indicator — what the status item draws instead of
    /// `resolvedIndicators` while `isExtraUsageActive`. Built through the same
    /// `MenuBarLayout.resolve` entry point every other indicator goes through (a throwaway
    /// one-entry configuration; `MenuBarConfiguration` never rejects a non-empty list), so
    /// availability/fraction handling for the extra-usage window has exactly one
    /// implementation, not a second hand-rolled one here.
    var extraUsageIndicator: ResolvedIndicator {
        let single = MenuBarConfiguration(
            indicators: [MenuBarIndicator(window: .extraUsage, rendering: .number)]
        )
        return MenuBarLayout.resolve(single, against: limits).first
            ?? ResolvedIndicator(title: "Extra", fraction: nil, rendering: .number, isUnavailable: true)
    }

    // MARK: Lifecycle (delegated to the shared store)

    func start() { live.start() }
    func startCodex() { live.startCodex() }
    func stop() { live.stop() }
    func primeFromCache(includeClaude: Bool = true, includeCodex: Bool = true) {
        live.primeFromCache(includeClaude: includeClaude, includeCodex: includeCodex)
    }
    func refreshNow() { live.refreshNow() }
    func refreshCodexNow() { live.refreshCodexNow() }
}
