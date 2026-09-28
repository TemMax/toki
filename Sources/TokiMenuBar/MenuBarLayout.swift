import Foundation
import TokiModels

/// One indicator resolved against live data, ready to draw. `App/Sources` consumes
/// only this type — it never touches `WindowSelector` or `UsageLimits` itself.
public struct ResolvedIndicator: Sendable, Equatable {
    public let title: String // e.g. "5h", "7d", "Opus"
    public let fraction: Double? // nil when the window has no data
    public let rendering: IndicatorRendering
    public let isUnavailable: Bool
    /// Whether the drawing prefixes this indicator with `title`.
    public let showsLabel: Bool

    public init(
        title: String,
        fraction: Double?,
        rendering: IndicatorRendering,
        isUnavailable: Bool,
        showsLabel: Bool = true
    ) {
        self.title = title
        self.fraction = fraction
        self.rendering = rendering
        self.isUnavailable = isUnavailable
        self.showsLabel = showsLabel
    }
}

/// Resolves a `MenuBarConfiguration` against a live (or absent) `UsageLimits`
/// snapshot into the list the status item actually draws.
public enum MenuBarLayout {
    /// Prefix the API uses for per-model weekly windows, e.g. `"weekly_scoped:Opus"`.
    /// Mirrors `AccountPresentation.scopedModelPrefix` (TokiAccounts) — duplicated
    /// rather than imported because this module depends on `TokiModels` only.
    static let scopedModelPrefix = "weekly_scoped:"
    static let sessionScopedModelPrefix = "session_scoped:"

    /// Extracts the model name from a scoped window id, e.g. `"weekly_scoped:Opus"`
    /// → `"Opus"`. The one place that understands the id shape, so both the
    /// highest-scoped-model title and the pinned-model match use the same rule.
    /// Falls back to a generic label when the id has no model part (a malformed or
    /// bare-prefix id), and returns the id unchanged when it isn't scoped at all.
    static func modelName(fromScopedId id: String) -> String {
        let name: String
        if id.hasPrefix(scopedModelPrefix) {
            name = String(id.dropFirst(scopedModelPrefix.count))
        } else if id.hasPrefix(sessionScopedModelPrefix) {
            name = String(id.dropFirst(sessionScopedModelPrefix.count))
        } else {
            return id
        }
        return name.isEmpty ? "Model" : name
    }

    /// Short menu-bar title for a window selector when there is no live window
    /// object to derive one from (limits absent, or a pinned model that vanished).
    private static func fallbackTitle(
        for window: WindowSelector,
        provider: UsageProvider = .claudeCode
    ) -> String {
        switch window {
        case .fiveHour: return provider == .codex ? "C·5h" : "5h"
        case .sevenDay: return provider == .codex ? "C·7d" : "7d"
        case .highestScopedModel: return "Model"
        case .scopedModel(let name): return name
        case .extraUsage: return "Extra"
        }
    }

    /// The model names of every scoped weekly window `limits` currently reports, in API
    /// order. The one place that walks `limits.windows` for this — Settings' `scopedModel`
    /// picker needs it to offer only models the account is actually scoped on right now,
    /// rather than an unbounded free-text field or (worse) a picker with nothing in it.
    public static func scopedModelNames(in limits: UsageLimits?) -> [String] {
        guard let limits else { return [] }
        return limits.windows
            .filter {
                $0.id.hasPrefix(scopedModelPrefix)
                    || $0.id.hasPrefix(sessionScopedModelPrefix)
            }
            .map { modelName(fromScopedId: $0.id) }
    }

    /// A spoken description of the strip for assistive technology.
    ///
    /// `App/Sources/MenuBarLabel.swift` draws the rasterized strip as an `Image`, which
    /// VoiceOver has nothing to read from on its own — before Phase 2 the label was
    /// `Image(systemName:) + Text("percent%")`, and `Text` spoke for itself; the rasterized
    /// image has no equivalent unless something builds one. This is that something. Not wired
    /// into the view by this change (a sibling task owns that); this is the string alone.
    ///
    /// Independent of `showsLabel`: hiding a title visually is a space decision for a strip
    /// that fits ~120 characters at five indicators (see `MenuBarIndicator.showsLabel`'s doc
    /// comment) — it is not a decision to withhold which window a figure belongs to from
    /// someone who cannot see the strip's shape at all to infer it.
    ///
    /// `ResolvedIndicator.title` only ever carries the SHORT form the visual strip draws
    /// (`"5h"`, `"7d"`, a model name, `"Extra"`) — it does not carry which `WindowSelector`
    /// produced it, so this reads only `title`. The two abbreviations that read badly aloud,
    /// `"5h"` and `"7d"`, are expanded to their full window names ("5 hours", "7 days"); every
    /// other title — a model name, `"Extra"`, the `"Model"` unavailable placeholder, or a
    /// user's own `customLabel` (already substituted into `title` upstream by
    /// `applyCustomLabel`) — already reads fine as a word and is spoken unchanged. This does
    /// mean a `customLabel` whose text happens to literally be `"5h"` or `"7d"` also gets
    /// expanded; there is no signal in `ResolvedIndicator` to tell "derived 5h" apart from "a
    /// user typed the string 5h", and expanding the two known abbreviations correctly is worth
    /// that one unlikely edge case reading slightly differently than the user typed it.
    public static func accessibilityDescription(for indicators: [ResolvedIndicator]) -> String {
        guard !indicators.isEmpty else {
            // Non-empty even for nothing configured: an empty string reads as "the strip has
            // no accessible description" (a bug) rather than "the strip has nothing on it"
            // (the actual, if unreachable through `MenuBarConfiguration`'s own floor, state).
            return "No usage indicators."
        }
        return indicators.map(spokenEntry).joined(separator: ", ")
    }

    /// Expands the two abbreviated window titles to how they should be spoken; every other
    /// title already reads fine aloud. See `accessibilityDescription`'s doc comment for why
    /// this reads only `title` and what that costs.
    private static func spokenWindowName(_ title: String) -> String {
        switch title {
        case "5h": return "5 hours"
        case "7d": return "7 days"
        case "C·5h": return "Codex 5 hours"
        case "C·7d": return "Codex 7 days"
        default: return title
        }
    }

    /// One indicator's spoken form: its window name, then its value — a percentage, or "no
    /// data" when unavailable. `isUnavailable` is checked ahead of `fraction`: a window the
    /// API reports present but not currently in effect can still carry a stale fraction (see
    /// `fromWindow`), and speaking that stale number as if it were live would mislead exactly
    /// the listener who cannot see the strip's own unavailable styling to catch the discrepancy.
    private static func spokenEntry(_ indicator: ResolvedIndicator) -> String {
        let name = spokenWindowName(indicator.title)
        guard !indicator.isUnavailable, let fraction = indicator.fraction else {
            return "\(name): no data"
        }
        let percent = Int((fraction * 100).rounded())
        return "\(name): \(percent) percent"
    }

    public static func resolve(
        _ configuration: MenuBarConfiguration,
        against limits: UsageLimits?
    ) -> [ResolvedIndicator] {
        resolve(configuration, limitsForProvider: { _ in limits })
    }

    /// Provider-aware resolution used by the app. Keeping the legacy one-snapshot overload
    /// above preserves source compatibility for callers and stored-config tests while this
    /// entry point prevents a Codex row from ever reading Claude's similarly named window.
    public static func resolve(
        _ configuration: MenuBarConfiguration,
        claudeLimits: UsageLimits?,
        codexLimits: UsageLimits?
    ) -> [ResolvedIndicator] {
        resolve(configuration) { provider in
            switch provider {
            case .claudeCode: claudeLimits
            case .codex: codexLimits
            }
        }
    }

    private static func resolve(
        _ configuration: MenuBarConfiguration,
        limitsForProvider: (UsageProvider) -> UsageLimits?
    ) -> [ResolvedIndicator] {
        let resolved = configuration.indicators.map {
            applyCustomLabel(
                resolveOne($0, against: limitsForProvider($0.provider)),
                indicator: $0
            )
        }
        guard let selection = configuration.compact else { return resolved }
        switch selection {
        case .worstOf:
            return [compact(from: resolved)]
        case .pinned(let window):
            let provider = configuration.indicators.first(where: { $0.window == window })?.provider
                ?? configuration.indicators.first?.provider
                ?? .claudeCode
            return [pinned(
                window,
                provider: provider,
                configuration: configuration,
                resolved: resolved,
                against: limitsForProvider(provider)
            )]
        case .pinnedIndicator(let id):
            return [pinnedIndicator(id, configuration: configuration, resolved: resolved)]
        }
    }

    /// Applied uniformly at the one call site above rather than inside every branch of
    /// `resolveOne` — `customLabel` overrides the title regardless of which window produced
    /// it (a live window, a fallback-unavailable title, a vanished pinned model, …), so one
    /// override after the fact is the whole rule; scattering it into each branch would risk a
    /// future branch forgetting it.
    private static func applyCustomLabel(_ resolved: ResolvedIndicator, indicator: MenuBarIndicator) -> ResolvedIndicator {
        guard let customLabel = indicator.customLabel else { return resolved }
        return ResolvedIndicator(
            title: customLabel,
            fraction: resolved.fraction,
            rendering: resolved.rendering,
            isUnavailable: resolved.isUnavailable,
            showsLabel: resolved.showsLabel
        )
    }

    private static func resolveOne(_ indicator: MenuBarIndicator, against limits: UsageLimits?) -> ResolvedIndicator {
        guard let limits else {
            // No data at all: every indicator still draws, unavailable rather than
            // absent — a blank status item looks like a crash, and a vanished
            // indicator shifts everything beside it.
            return ResolvedIndicator(
                title: fallbackTitle(for: indicator.window, provider: indicator.provider),
                fraction: nil,
                rendering: indicator.rendering,
                isUnavailable: true,
                showsLabel: indicator.showsLabel
            )
        }

        let selected = indicator.window.resolve(against: limits)

        // The short menu-bar title, per case — NOT `SelectedWindow.title`, which is the long
        // form (`"5-hour"`, `"7-day"`) a notification has room for. `.highestScopedModel` and
        // `.scopedModel` are the two cases whose short title already IS the model name, so
        // those read it off the resolved window / the case itself rather than a fixed string.
        let title: String
        switch indicator.window {
        case .fiveHour: title = indicator.provider == .codex ? "C·5h" : "5h"
        case .sevenDay: title = indicator.provider == .codex ? "C·7d" : "7d"
        case .highestScopedModel: title = selected?.title ?? "Model"
        case .scopedModel(let name): title = name
        case .extraUsage: title = "Extra"
        }

        guard let selected else {
            return ResolvedIndicator(title: title, fraction: nil, rendering: indicator.rendering, isUnavailable: true, showsLabel: indicator.showsLabel)
        }
        return ResolvedIndicator(
            title: title,
            fraction: selected.utilization,
            rendering: indicator.rendering,
            isUnavailable: !selected.isAvailable,
            showsLabel: indicator.showsLabel
        )
    }

    /// The scoped window with the greatest utilisation, or nil when the account has
    /// none right now (its scope set is entirely data-driven by the API).
    ///
    /// Available windows beat unavailable ones regardless of utilisation. An unavailable
    /// window can still carry a stale figure, and picking it because that stale 0.9 tops a
    /// live 0.5 would show an indicator marked unavailable while real data sat one slot
    /// away — the opposite of "the scoped window that matters most right now".
    private static func leaderScopedWindow(in limits: UsageLimits) -> RateLimitWindow? {
        var leader: RateLimitWindow?
        for window in limits.windows where window.id.hasPrefix(scopedModelPrefix)
            || window.id.hasPrefix(sessionScopedModelPrefix) {
            guard let current = leader else {
                leader = window
                continue
            }
            if window.isAvailable != current.isAvailable {
                if window.isAvailable { leader = window }
            } else if window.utilization > current.utilization {
                leader = window
            }
        }
        return leader
    }

    private static func fromWindow(_ window: RateLimitWindow?, title: String, indicator: MenuBarIndicator) -> ResolvedIndicator {
        let rendering = indicator.rendering
        guard let window else {
            return ResolvedIndicator(title: title, fraction: nil, rendering: rendering, isUnavailable: true, showsLabel: indicator.showsLabel)
        }
        // The API can report a window as present but not currently in effect
        // (`isAvailable == false`); it still carries whatever fraction it has, it
        // is just drawn as unavailable rather than a live gauge.
        return ResolvedIndicator(title: title, fraction: window.utilization, rendering: rendering, isUnavailable: !window.isAvailable, showsLabel: indicator.showsLabel)
    }

    private static func fromExtraUsage(_ extra: ExtraUsage?, indicator: MenuBarIndicator) -> ResolvedIndicator {
        let rendering = indicator.rendering
        guard let extra, extra.isEnabled, let fraction = extra.utilization else {
            return ResolvedIndicator(title: "Extra", fraction: extra?.utilization, rendering: rendering, isUnavailable: true, showsLabel: indicator.showsLabel)
        }
        return ResolvedIndicator(title: "Extra", fraction: fraction, rendering: rendering, isUnavailable: false, showsLabel: indicator.showsLabel)
    }

    /// Collapses a resolved list to the single worst-of indicator for compact mode:
    /// whichever configured window carries the greatest fraction, keeping its title,
    /// fraction and availability. Ties (including "everything is nil, nothing has data")
    /// keep the first configured entry, so the result is deterministic and stays anchored
    /// to the configuration's order rather than jumping between equally-ranked windows from
    /// one refresh to the next.
    ///
    /// The RENDERING is the exception: it always comes from the first configured entry, not
    /// from whichever window won. Inheriting the winner's rendering meant the status item
    /// changed *shape* — a bar one minute, a number the next — as the leader moved between
    /// differently-rendered windows. Compact mode exists to be one steady glyph; a glyph
    /// that reshapes itself is the thing it was meant to avoid.
    private static func compact(from resolved: [ResolvedIndicator]) -> ResolvedIndicator {
        guard var best = resolved.first else {
            // `MenuBarConfiguration` clamps an empty list up to the standard set, so this is
            // unreachable through the public API; it stays as a visible placeholder rather
            // than a crash in case a future entry point forgets.
            return ResolvedIndicator(title: "—", fraction: nil, rendering: .bar, isUnavailable: true)
        }
        let rendering = best.rendering
        let showsLabel = best.showsLabel
        for candidate in resolved.dropFirst() where (candidate.fraction ?? -1) > (best.fraction ?? -1) {
            best = candidate
        }
        return ResolvedIndicator(
            title: best.title,
            fraction: best.fraction,
            rendering: rendering,
            isUnavailable: best.isUnavailable,
            showsLabel: showsLabel
        )
    }

    /// Resolves `.pinned(window)`: one glyph, always `window`, regardless of whether it is
    /// among the configured indicators — a user who pinned it did so deliberately, so an
    /// unconfigured window still resolves rather than falling back to something else.
    ///
    /// Rendering and label follow the FIRST configured entry, same rule and same reason as
    /// `compact(from:)`'s doc comment: pinning exists so the glyph never reshapes itself, and
    /// that has to hold even for a window nothing in `indicators` describes.
    private static func pinned(
        _ window: WindowSelector,
        provider: UsageProvider,
        configuration: MenuBarConfiguration,
        resolved: [ResolvedIndicator],
        against limits: UsageLimits?
    ) -> ResolvedIndicator {
        guard let first = resolved.first else {
            // `MenuBarConfiguration` clamps an empty list up to the standard set, so this is
            // unreachable through the public API; stays as a visible placeholder rather than
            // a crash in case a future entry point forgets.
            return ResolvedIndicator(title: "—", fraction: nil, rendering: .bar, isUnavailable: true)
        }
        let matchedIndex = configuration.indicators.firstIndex {
            $0.provider == provider && $0.window == window
        }
        let source: ResolvedIndicator
        if let matchedIndex {
            source = resolved[matchedIndex]
        } else {
            let syntheticIndicator = MenuBarIndicator(
                provider: provider,
                window: window,
                rendering: first.rendering,
                showsLabel: first.showsLabel
            )
            source = applyCustomLabel(resolveOne(syntheticIndicator, against: limits), indicator: syntheticIndicator)
        }
        return ResolvedIndicator(
            title: source.title,
            fraction: source.fraction,
            rendering: first.rendering,
            isUnavailable: source.isUnavailable,
            showsLabel: first.showsLabel
        )
    }

    /// Provider-aware compact pinning. The selected row supplies the data and label while
    /// the first visible row still supplies the stable glyph shape, matching `.worstOf` and
    /// the legacy `.pinned` behavior.
    private static func pinnedIndicator(
        _ id: UUID,
        configuration: MenuBarConfiguration,
        resolved: [ResolvedIndicator]
    ) -> ResolvedIndicator {
        guard let first = resolved.first else {
            return ResolvedIndicator(
                title: "—", fraction: nil, rendering: .bar, isUnavailable: true
            )
        }
        guard let index = configuration.indicators.firstIndex(where: { $0.id == id }),
              resolved.indices.contains(index) else {
            return first
        }
        let source = resolved[index]
        return ResolvedIndicator(
            title: source.title,
            fraction: source.fraction,
            rendering: first.rendering,
            isUnavailable: source.isUnavailable,
            showsLabel: first.showsLabel
        )
    }
}
