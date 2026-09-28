import Foundation
import Testing
import TokiModels
@testable import TokiMenuBar

/// Test-only builders for the live-data shapes `MenuBarLayout.resolve` reads, kept
/// minimal (no reset times, no extras) since resolution only reads utilization/id/
/// availability.
private func window(id: String, utilization: Double, isAvailable: Bool = true) -> RateLimitWindow {
    RateLimitWindow(id: id, title: id, utilization: utilization, resetsAt: nil, isAvailable: isAvailable)
}

private func limits(_ windows: [RateLimitWindow], extra: ExtraUsage? = nil) -> UsageLimits {
    UsageLimits(windows: windows, extra: extra, fetchedAt: Date())
}

@Suite("MenuBarLayout.resolve")
struct MenuBarLayoutTests {
    @Test("provider-aware resolution never crosses Claude and Codex windows")
    func providerAwareResolution() {
        let configuration = MenuBarConfiguration(indicators: [
            MenuBarIndicator(provider: .claudeCode, window: .fiveHour, rendering: .number),
            MenuBarIndicator(provider: .codex, window: .fiveHour, rendering: .number),
        ])
        let resolved = MenuBarLayout.resolve(
            configuration,
            claudeLimits: limits([window(id: "session", utilization: 0.2)]),
            codexLimits: limits([window(id: "session", utilization: 0.8)])
        )
        #expect(resolved.map(\.fraction) == [0.2, 0.8])
        #expect(resolved.map(\.title) == ["5h", "C·5h"])
    }

    @Test("nil limits resolve one unavailable indicator per configured entry, never zero")
    func nilLimitsYieldsSameCountUnavailable() {
        let configuration = MenuBarConfiguration.standard
        let resolved = MenuBarLayout.resolve(configuration, against: nil)
        #expect(resolved.count == configuration.indicators.count)
        #expect(resolved.allSatisfy { $0.isUnavailable && $0.fraction == nil })
    }

    @Test("highestScopedModel picks the higher of two scoped windows, then follows the leader when it swaps")
    func highestScopedModelFollowsTheLeader() {
        let configuration = MenuBarConfiguration(indicators: [
            MenuBarIndicator(window: .highestScopedModel, rendering: .bar),
        ])

        let opusLeads = limits([
            window(id: "weekly_scoped:Opus", utilization: 0.9),
            window(id: "weekly_scoped:Sonnet", utilization: 0.2),
        ])
        let first = MenuBarLayout.resolve(configuration, against: opusLeads)
        #expect(first.count == 1)
        #expect(first[0].title == "Opus")
        #expect(first[0].fraction == 0.9)

        let sonnetLeads = limits([
            window(id: "weekly_scoped:Opus", utilization: 0.1),
            window(id: "weekly_scoped:Sonnet", utilization: 0.7),
        ])
        let second = MenuBarLayout.resolve(configuration, against: sonnetLeads)
        #expect(second[0].title == "Sonnet")
        #expect(second[0].fraction == 0.7)
    }

    @Test("highestScopedModel with no scoped windows at all resolves unavailable, not removed")
    func highestScopedModelWithNoScopedWindows() {
        let configuration = MenuBarConfiguration(indicators: [
            MenuBarIndicator(window: .fiveHour, rendering: .bar),
            MenuBarIndicator(window: .highestScopedModel, rendering: .bar),
        ])
        let onlyFiveHour = limits([window(id: "session", utilization: 0.3)])
        let resolved = MenuBarLayout.resolve(configuration, against: onlyFiveHour)
        #expect(resolved.count == 2)
        #expect(resolved[1].isUnavailable)
        #expect(resolved[1].fraction == nil)
    }

    @Test("a pinned scopedModel whose window vanished resolves unavailable and keeps its slot")
    func pinnedScopedModelVanished() {
        let configuration = MenuBarConfiguration(indicators: [
            MenuBarIndicator(window: .fiveHour, rendering: .bar),
            MenuBarIndicator(window: .scopedModel("Opus"), rendering: .bar),
            MenuBarIndicator(window: .sevenDay, rendering: .bar),
        ])
        let noOpusWindow = limits([
            window(id: "session", utilization: 0.4),
            window(id: "weekly_all", utilization: 0.5),
        ])
        let resolved = MenuBarLayout.resolve(configuration, against: noOpusWindow)
        #expect(resolved.count == 3)
        #expect(resolved[1].title == "Opus")
        #expect(resolved[1].isUnavailable)
        #expect(resolved[1].fraction == nil)
        // The slot (and the neighbours' order) is preserved, not collapsed.
        #expect(resolved.map(\.title) == ["5h", "Opus", "7d"])
    }

    @Test("a window the API reports unavailable resolves isUnavailable true with whatever fraction it has")
    func apiUnavailableWindowKeepsItsFraction() {
        let configuration = MenuBarConfiguration(indicators: [
            MenuBarIndicator(window: .fiveHour, rendering: .bar),
        ])
        let inactiveSession = limits([window(id: "session", utilization: 0.42, isAvailable: false)])
        let resolved = MenuBarLayout.resolve(configuration, against: inactiveSession)
        #expect(resolved[0].isUnavailable)
        #expect(resolved[0].fraction == 0.42)
    }

    @Test("order is preserved even when the last indicator has the highest fraction")
    func orderIsPreserved() {
        let configuration = MenuBarConfiguration(indicators: [
            MenuBarIndicator(window: .fiveHour, rendering: .bar),
            MenuBarIndicator(window: .sevenDay, rendering: .bar),
        ])
        let sevenDayIsWorse = limits([
            window(id: "session", utilization: 0.1),
            window(id: "weekly_all", utilization: 0.95),
        ])
        let resolved = MenuBarLayout.resolve(configuration, against: sevenDayIsWorse)
        #expect(resolved.map(\.title) == ["5h", "7d"])
        #expect(resolved[0].fraction == 0.1)
        #expect(resolved[1].fraction == 0.95)
    }

    @Test("compact mode yields exactly one indicator carrying the maximum, titled for its source window")
    func compactModePicksTheMaximum() {
        let configuration = MenuBarConfiguration(
            indicators: [
                MenuBarIndicator(window: .fiveHour, rendering: .bar),
                MenuBarIndicator(window: .sevenDay, rendering: .number),
                MenuBarIndicator(window: .highestScopedModel, rendering: .bar),
            ],
            compact: .worstOf
        )
        let sevenDayIsWorst = limits([
            window(id: "session", utilization: 0.1),
            window(id: "weekly_all", utilization: 0.88),
            window(id: "weekly_scoped:Opus", utilization: 0.3),
        ])
        let resolved = MenuBarLayout.resolve(configuration, against: sevenDayIsWorst)
        #expect(resolved.count == 1)
        #expect(resolved[0].title == "7d")
        #expect(resolved[0].fraction == 0.88)
        // The rendering comes from the FIRST configured entry, not from the window that
        // won. This assertion previously expected `.number` (the winner's own rendering),
        // which meant the status item changed shape as the leader moved between
        // differently-rendered windows — the one thing a compact, glanceable glyph must not
        // do. See `MenuBarLayout.compact(from:)`.
        #expect(resolved[0].rendering == .bar)
    }

    @Test("compact mode with every window unavailable yields one unavailable indicator")
    func compactModeAllUnavailable() {
        let configuration = MenuBarConfiguration(
            indicators: [
                MenuBarIndicator(window: .fiveHour, rendering: .bar),
                MenuBarIndicator(window: .sevenDay, rendering: .bar),
            ],
            compact: .worstOf
        )
        let resolved = MenuBarLayout.resolve(configuration, against: nil)
        #expect(resolved.count == 1)
        #expect(resolved[0].isUnavailable)
    }

    @Test("title derivation: scoped id yields the model name, including a malformed id with no model part")
    func titleDerivation() {
        #expect(MenuBarLayout.modelName(fromScopedId: "weekly_scoped:Opus") == "Opus")
        #expect(MenuBarLayout.modelName(fromScopedId: "weekly_scoped:Fable") == "Fable")
        // No model part after the prefix.
        #expect(MenuBarLayout.modelName(fromScopedId: "weekly_scoped:") == "Model")
        // Not a scoped id at all: returned unchanged, not mangled.
        #expect(MenuBarLayout.modelName(fromScopedId: "session") == "session")
        #expect(MenuBarLayout.modelName(fromScopedId: "weekly_all") == "weekly_all")
    }

    @Test("customLabel overrides the derived title but leaves fraction/availability alone")
    func customLabelOverridesTitle() {
        let configuration = MenuBarConfiguration(indicators: [
            MenuBarIndicator(window: .fiveHour, rendering: .number, customLabel: "Session"),
            MenuBarIndicator(window: .highestScopedModel, rendering: .number, customLabel: "Weekly"),
        ])
        let withData = limits([
            window(id: "session", utilization: 0.4),
        ])
        let resolved = MenuBarLayout.resolve(configuration, against: withData)
        #expect(resolved[0].title == "Session")
        #expect(resolved[0].fraction == 0.4)
        // No scoped windows at all: still unavailable, but the override still wins over the
        // fallback "Model" title.
        #expect(resolved[1].title == "Weekly")
        #expect(resolved[1].isUnavailable)
    }

    @Test("no customLabel leaves the derived title exactly as before")
    func noCustomLabelUsesDerivedTitle() {
        let configuration = MenuBarConfiguration(indicators: [
            MenuBarIndicator(window: .fiveHour, rendering: .number),
        ])
        let resolved = MenuBarLayout.resolve(configuration, against: nil)
        #expect(resolved[0].title == "5h")
    }

    @Test("extra usage resolves fraction and availability from ExtraUsage, disabled resolves unavailable")
    func extraUsageResolution() {
        let configuration = MenuBarConfiguration(indicators: [
            MenuBarIndicator(window: .extraUsage, rendering: .number),
        ])

        let enabled = limits([], extra: ExtraUsage(isEnabled: true, monthlyLimit: 20, usedCredits: 5, utilization: 0.25))
        let resolvedEnabled = MenuBarLayout.resolve(configuration, against: enabled)
        #expect(resolvedEnabled[0].title == "Extra")
        #expect(resolvedEnabled[0].fraction == 0.25)
        #expect(resolvedEnabled[0].isUnavailable == false)

        let disabled = limits([], extra: ExtraUsage(isEnabled: false, monthlyLimit: nil, usedCredits: nil, utilization: nil))
        let resolvedDisabled = MenuBarLayout.resolve(configuration, against: disabled)
        #expect(resolvedDisabled[0].isUnavailable)

        let missing = limits([], extra: nil)
        let resolvedMissing = MenuBarLayout.resolve(configuration, against: missing)
        #expect(resolvedMissing[0].isUnavailable)
        #expect(resolvedMissing[0].fraction == nil)
    }
}

@Suite("MenuBarLayout.accessibilityDescription")
struct MenuBarLayoutAccessibilityDescriptionTests {
    @Test("empty input yields a non-empty, informative string rather than an empty one")
    func emptyInputIsNonEmpty() {
        let description = MenuBarLayout.accessibilityDescription(for: [])
        #expect(!description.isEmpty)
    }

    @Test("the two abbreviated window titles are spoken as their full window name")
    func expandsAbbreviatedWindowNames() {
        let configuration = MenuBarConfiguration(indicators: [
            MenuBarIndicator(window: .fiveHour, rendering: .number),
            MenuBarIndicator(window: .sevenDay, rendering: .bar),
        ])
        let resolved = MenuBarLayout.resolve(configuration, against: limits([
            window(id: "session", utilization: 0.42),
            window(id: "weekly_all", utilization: 0.71),
        ]))
        let description = MenuBarLayout.accessibilityDescription(for: resolved)
        #expect(description == "5 hours: 42 percent, 7 days: 71 percent")
    }

    @Test("Codex window abbreviations name their provider for VoiceOver")
    func expandsCodexWindowNames() {
        let configuration = MenuBarConfiguration(indicators: [
            MenuBarIndicator(provider: .codex, window: .fiveHour, rendering: .number),
        ])
        let resolved = MenuBarLayout.resolve(
            configuration,
            claudeLimits: nil,
            codexLimits: limits([window(id: "session", utilization: 0.4)])
        )
        #expect(MenuBarLayout.accessibilityDescription(for: resolved) == "Codex 5 hours: 40 percent")
    }

    @Test("every rendering (bar, number, barAndNumber) speaks the same way — rendering is a drawing choice, not a wording one")
    func everyRenderingSpeaksIdentically() {
        for rendering: IndicatorRendering in [.bar, .number, .barAndNumber] {
            let configuration = MenuBarConfiguration(indicators: [
                MenuBarIndicator(window: .fiveHour, rendering: rendering),
            ])
            let resolved = MenuBarLayout.resolve(configuration, against: limits([window(id: "session", utilization: 0.5)]))
            #expect(MenuBarLayout.accessibilityDescription(for: resolved) == "5 hours: 50 percent")
        }
    }

    @Test("an unavailable entry speaks \"no data\", even one that still carries a stale fraction")
    func unavailableEntrySpeaksNoData() {
        let configuration = MenuBarConfiguration(indicators: [
            MenuBarIndicator(window: .fiveHour, rendering: .number),
        ])
        // The API reports the window present but not currently in effect: it still carries a
        // stale 0.9, which must NOT be spoken as if it were live.
        let resolved = MenuBarLayout.resolve(configuration, against: limits([
            window(id: "session", utilization: 0.9, isAvailable: false),
        ]))
        #expect(MenuBarLayout.accessibilityDescription(for: resolved) == "5 hours: no data")
    }

    @Test("no data at all (nil limits) speaks \"no data\" for every configured indicator")
    func nilLimitsSpeaksNoDataForEveryEntry() {
        let configuration = MenuBarConfiguration(indicators: [
            MenuBarIndicator(window: .fiveHour, rendering: .number),
            MenuBarIndicator(window: .sevenDay, rendering: .number),
        ])
        let resolved = MenuBarLayout.resolve(configuration, against: nil)
        #expect(MenuBarLayout.accessibilityDescription(for: resolved) == "5 hours: no data, 7 days: no data")
    }

    @Test("a custom label is spoken as the user named it, not expanded or altered")
    func customLabelIsSpokenAsNamed() {
        let configuration = MenuBarConfiguration(indicators: [
            MenuBarIndicator(window: .fiveHour, rendering: .number, customLabel: "Session budget"),
        ])
        let resolved = MenuBarLayout.resolve(configuration, against: limits([window(id: "session", utilization: 0.3)]))
        #expect(MenuBarLayout.accessibilityDescription(for: resolved) == "Session budget: 30 percent")
    }

    @Test("independent of showsLabel: a hidden-label indicator is still spoken in full")
    func speaksEvenWhenShowsLabelIsFalse() {
        let configuration = MenuBarConfiguration(indicators: [
            MenuBarIndicator(window: .fiveHour, rendering: .number, showsLabel: false),
        ])
        let resolved = MenuBarLayout.resolve(configuration, against: limits([window(id: "session", utilization: 0.6)]))
        #expect(resolved[0].showsLabel == false)
        #expect(MenuBarLayout.accessibilityDescription(for: resolved) == "5 hours: 60 percent")
    }

    @Test("compact mode still yields a description for the single collapsed indicator")
    func compactModeDescribesTheCollapsedIndicator() {
        let configuration = MenuBarConfiguration(
            indicators: [
                MenuBarIndicator(window: .fiveHour, rendering: .bar),
                MenuBarIndicator(window: .sevenDay, rendering: .number),
            ],
            compact: .worstOf
        )
        let resolved = MenuBarLayout.resolve(configuration, against: limits([
            window(id: "session", utilization: 0.1),
            window(id: "weekly_all", utilization: 0.88),
        ]))
        #expect(resolved.count == 1)
        #expect(MenuBarLayout.accessibilityDescription(for: resolved) == "7 days: 88 percent")
    }

    @Test("order matches the visual (resolved) order deterministically")
    func orderMatchesVisualOrder() {
        let configuration = MenuBarConfiguration(indicators: [
            MenuBarIndicator(window: .sevenDay, rendering: .number),
            MenuBarIndicator(window: .fiveHour, rendering: .number),
        ])
        let resolved = MenuBarLayout.resolve(configuration, against: limits([
            window(id: "session", utilization: 0.2),
            window(id: "weekly_all", utilization: 0.4),
        ]))
        #expect(MenuBarLayout.accessibilityDescription(for: resolved) == "7 days: 40 percent, 5 hours: 20 percent")
    }
}

@Suite("Leader selection and compact stability")
struct LeaderAndCompactTests {
    private func scoped(_ name: String, _ utilization: Double, available: Bool) -> RateLimitWindow {
        RateLimitWindow(
            id: "weekly_scoped:\(name)", title: "7-day \(name)",
            utilization: utilization, resetsAt: nil, isAvailable: available
        )
    }

    @Test("an available scoped window beats an unavailable one carrying a higher stale figure")
    func availabilityBeatsStaleMaximum() {
        let limits = UsageLimits(
            windows: [scoped("Opus", 0.9, available: false), scoped("Sonnet", 0.5, available: true)],
            extra: nil,
            fetchedAt: Date()
        )
        let config = MenuBarConfiguration(
            indicators: [MenuBarIndicator(window: .highestScopedModel, rendering: .bar)]
        )
        let resolved = MenuBarLayout.resolve(config, against: limits)
        #expect(resolved.first?.title == "Sonnet")
        #expect(resolved.first?.isUnavailable == false)
    }

    @Test("compact keeps the first entry's rendering even when another window wins")
    func compactRenderingIsStable() {
        let limits = UsageLimits(
            windows: [
                RateLimitWindow(id: "session", title: "5-hour", utilization: 0.1, resetsAt: nil, isAvailable: true),
                RateLimitWindow(id: "weekly_all", title: "7-day", utilization: 0.9, resetsAt: nil, isAvailable: true),
            ],
            extra: nil,
            fetchedAt: Date()
        )
        let config = MenuBarConfiguration(
            indicators: [
                MenuBarIndicator(window: .fiveHour, rendering: .bar),
                MenuBarIndicator(window: .sevenDay, rendering: .number),
            ],
            compact: .worstOf
        )
        let resolved = MenuBarLayout.resolve(config, against: limits)
        #expect(resolved.count == 1)
        // The 7-day window wins on value...
        #expect(resolved.first?.title == "7d")
        // ...but the glyph keeps the shape the first entry asked for, so the status item
        // does not reshape itself when the leader moves.
        #expect(resolved.first?.rendering == .bar)
    }
}

/// `.pinned` is the alternative to `.worstOf`: the strip collapses to one window chosen by
/// the user, not whichever currently ranks worst — so it must resolve even when that window
/// is nowhere in `indicators`, and must never let a higher-ranked configured window steal
/// the slot.
@Suite("CompactSelection.pinned resolution")
struct PinnedCompactTests {
    @Test("an exact pin distinguishes the same window across providers")
    func exactPinKeepsProviderIdentity() {
        let claude = MenuBarIndicator(
            provider: .claudeCode, window: .fiveHour, rendering: .bar
        )
        let codex = MenuBarIndicator(
            provider: .codex, window: .fiveHour, rendering: .number
        )
        let config = MenuBarConfiguration(
            indicators: [claude, codex],
            compact: .pinnedIndicator(codex.id)
        )
        let claudeLimits = UsageLimits(
            windows: [
                RateLimitWindow(
                    id: "session", title: "5-hour", utilization: 0.15,
                    resetsAt: nil, isAvailable: true
                ),
            ],
            extra: nil,
            fetchedAt: Date()
        )
        let codexLimits = UsageLimits(
            windows: [
                RateLimitWindow(
                    id: "session", title: "5-hour", utilization: 0.75,
                    resetsAt: nil, isAvailable: true
                ),
            ],
            extra: nil,
            fetchedAt: Date()
        )

        let resolved = MenuBarLayout.resolve(
            config,
            claudeLimits: claudeLimits,
            codexLimits: codexLimits
        )

        #expect(resolved.first?.title == "C·5h")
        #expect(resolved.first?.fraction == 0.75)
        #expect(resolved.first?.rendering == .bar)
    }

    @Test("pinned resolves that window even when it is not configured, and even when another window is higher")
    func pinnedIgnoresUnconfiguredAndHigherWindows() {
        let config = MenuBarConfiguration(
            indicators: [
                MenuBarIndicator(window: .fiveHour, rendering: .bar),
                MenuBarIndicator(window: .sevenDay, rendering: .number),
            ],
            compact: .pinned(.highestScopedModel)
        )
        let limits = UsageLimits(
            windows: [
                RateLimitWindow(id: "session", title: "5-hour", utilization: 0.1, resetsAt: nil, isAvailable: true),
                RateLimitWindow(id: "weekly_all", title: "7-day", utilization: 0.9, resetsAt: nil, isAvailable: true),
                RateLimitWindow(id: "weekly_scoped:Opus", title: "7-day Opus", utilization: 0.3, resetsAt: nil, isAvailable: true),
            ],
            extra: nil,
            fetchedAt: Date()
        )
        let resolved = MenuBarLayout.resolve(config, against: limits)
        #expect(resolved.count == 1)
        // Neither the 5h nor the 7d window (the higher of the two configured entries) wins;
        // the pinned window resolves on its own regardless of ranking.
        #expect(resolved.first?.title == "Opus")
        #expect(resolved.first?.fraction == 0.3)
    }

    @Test("pinned to a window with no data still resolves unavailable, not removed")
    func pinnedWithNoDataResolvesUnavailable() {
        let config = MenuBarConfiguration(
            indicators: [MenuBarIndicator(window: .fiveHour, rendering: .bar)],
            compact: .pinned(.scopedModel("Opus"))
        )
        let resolved = MenuBarLayout.resolve(config, against: nil)
        #expect(resolved.count == 1)
        #expect(resolved.first?.title == "Opus")
        #expect(resolved.first?.isUnavailable == true)
        #expect(resolved.first?.fraction == nil)
    }

    @Test("pinned keeps the first entry's rendering and label choice, even pinned to a later, differently-drawn entry")
    func pinnedKeepsFirstEntryRenderingAndLabel() {
        let config = MenuBarConfiguration(
            indicators: [
                MenuBarIndicator(window: .fiveHour, rendering: .bar, showsLabel: false),
                MenuBarIndicator(window: .sevenDay, rendering: .number, showsLabel: true),
            ],
            compact: .pinned(.sevenDay)
        )
        let limits = UsageLimits(
            windows: [
                RateLimitWindow(id: "session", title: "5-hour", utilization: 0.2, resetsAt: nil, isAvailable: true),
                RateLimitWindow(id: "weekly_all", title: "7-day", utilization: 0.6, resetsAt: nil, isAvailable: true),
            ],
            extra: nil,
            fetchedAt: Date()
        )
        let resolved = MenuBarLayout.resolve(config, against: limits)
        #expect(resolved.count == 1)
        #expect(resolved.first?.title == "7d")
        #expect(resolved.first?.fraction == 0.6)
        // The pinned window's OWN configured rendering/label (`.number`, labelled) lose to
        // the first entry's (`.bar`, unlabelled) — same stability rule as `.worstOf`.
        #expect(resolved.first?.rendering == .bar)
        #expect(resolved.first?.showsLabel == false)
    }
}
