/// Deterministic builders for each `Scenario`, ported from `App/Sources/SnapshotRunner.swift`'s
/// mock-data builders so the snapshot harness, a debug control channel, and tests can all draw
/// from ONE source. Every builder takes `now` as a parameter — never reads `Date()` internally —
/// so a fixed `now` yields byte-identical output.
import Foundation
import TokiAccounts
import TokiAnalytics
import TokiModels
import TokiStatus

public enum Fixtures {

    public static func bundle(for scenario: Scenario, now: Date = Date()) -> FixtureBundle {
        switch scenario {
        case .fresh: return freshBundle()
        case .singleAccount: return singleAccountBundle(now: now)
        case .publicReadme: return singleAccountBundle(
            now: now, scopedModel: "Fable", claudeResets: sampleClaudeResets(now: now)
        )
        case .multiAccount: return multiAccountBundle(now: now)
        case .nearLimit: return nearLimitBundle(now: now)
        case .extraExhausted: return extraExhaustedBundle(now: now)
        case .heavy: return heavyBundle(now: now)
        case .error: return errorBundle(now: now)
        case .keychainAccess: return FixtureBundle(limitsState: .needsAccess)
        case .empty: return emptyBundle(now: now)
        case .quietEdges: return quietEdgesBundle(now: now)
        case .statusMinorIncident: return statusMinorIncidentBundle(now: now)
        case .statusCriticalOutage: return statusCriticalOutageBundle(now: now)
        case .claudeResets: return claudeResetsBundle(now: now)
        case .claudeResetsZero: return claudeResetsZeroBundle(now: now)
        case .claudeResetsCooldown: return claudeResetsCooldownBundle(now: now)
        case .claudeResetsIneligible: return claudeResetsIneligibleBundle(now: now)
        }
    }

    // MARK: - Scenario builders

    /// Nothing loaded: the very first launch, before any fetch has completed.
    private static func freshBundle() -> FixtureBundle {
        FixtureBundle(limitsState: .notLoggedIn)
    }

    /// One healthy signed-in account: 5h 34%, 7d 71%, one scoped window 88%, extra usage off.
    private static func singleAccountBundle(
        now: Date, scopedModel: String = "Opus", claudeResets: ClaudeResetStatus? = nil
    ) -> FixtureBundle {
        let identity = makeIdentity(
            uuid: "fixture-single", email: "ada@example.com", displayName: "Ada Lovelace",
            organizationName: "Analytical Engine"
        )
        let limits = makeLimits(
            now: now,
            windows: [
                makeWindow(id: "session", title: "5-hour", utilization: 0.34, resetsIn: 2.5 * 3600, now: now),
                makeWindow(id: "weekly_all", title: "7-day", utilization: 0.71, resetsIn: 3 * 24 * 3600, now: now),
                makeWindow(id: "weekly_scoped:\(scopedModel)", title: "7-day \(scopedModel)", utilization: 0.88, resetsIn: 3 * 24 * 3600, now: now),
            ],
            extra: makeExtra(enabled: false),
            claudeResets: claudeResets
        )
        let account = makeAccount(identity: identity, limits: limits, isActive: true, health: .ok, now: now)
        return FixtureBundle(
            limits: limits,
            limitsState: .ok,
            summary: makeSummary(now: now, seed: 0x51A6_1E00, dailyCount: 10, modelCount: 4, projectCount: 6),
            stats: makeStatsHistory(
                now: now, seed: 0x5EED_1234, totalDays: 140,
                gapStartOffset: 55, gapLength: 16, busiestOffset: 20
            ),
            identity: identity,
            accounts: [account],
            instances: makeInstances(now: now, count: 2),
            environment: makeEnvironment(),
            speed: SpeedFixtures.report(now: now, groups: 6)
        )
    }

    /// Three accounts in different health/activity states, plus one quarantined credential
    /// (an unattributed keychain item, rendered in its own shelf rather than the account list).
    private static func multiAccountBundle(now: Date) -> FixtureBundle {
        let activeIdentity = makeIdentity(
            uuid: "fixture-multi-active", email: "ada@example.com", displayName: "Ada Lovelace",
            organizationName: "Analytical Engine"
        )
        let activeLimits = makeLimits(
            now: now,
            windows: [
                makeWindow(id: "session", title: "5-hour", utilization: 0.34, resetsIn: 2.5 * 3600, now: now),
                makeWindow(id: "weekly_all", title: "7-day", utilization: 0.71, resetsIn: 3 * 24 * 3600, now: now),
                makeWindow(id: "weekly_scoped:Opus", title: "7-day Opus", utilization: 0.88, resetsIn: 3 * 24 * 3600, now: now),
            ],
            extra: makeExtra(enabled: false)
        )
        let idleIdentity = makeIdentity(
            uuid: "fixture-multi-idle", email: "grace@example.com", displayName: "Grace Hopper",
            organizationName: "Analytical Engine"
        )
        let idleLimits = makeLimits(
            now: now,
            windows: [
                makeWindow(id: "session", title: "5-hour", utilization: 0.12, resetsIn: 4 * 3600, now: now),
                makeWindow(id: "weekly_all", title: "7-day", utilization: 0.40, resetsIn: 5 * 24 * 3600, now: now),
            ],
            extra: makeExtra(enabled: false)
        )
        let reauthIdentity = makeIdentity(
            uuid: "fixture-multi-reauth", email: "alan@example.com", displayName: "Alan Turing",
            organizationName: "Analytical Engine"
        )

        let accounts = [
            makeAccount(identity: activeIdentity, limits: activeLimits, isActive: true, health: .ok, now: now),
            makeAccount(
                identity: idleIdentity, limits: idleLimits, isActive: false, health: .ok,
                now: now.addingTimeInterval(-2 * 24 * 3600)
            ),
            makeAccount(
                identity: reauthIdentity, limits: nil, isActive: false, health: .needsReauth,
                now: now.addingTimeInterval(-10 * 24 * 3600), staleSecondsAgo: 10 * 24 * 3600
            ),
        ]

        let quarantine = [
            QuarantineEntry(
                id: "fixture-quarantine-stray",
                credentialJSON: Data("{}".utf8),
                foundAt: now.addingTimeInterval(-6 * 3600),
                ownerLabel: nil
            ),
        ]

        return FixtureBundle(
            limits: activeLimits,
            limitsState: .ok,
            summary: makeSummary(now: now, seed: 0x51A6_1E00, dailyCount: 10, modelCount: 4, projectCount: 6),
            stats: makeStatsHistory(
                now: now, seed: 0x5EED_1234, totalDays: 140,
                gapStartOffset: 55, gapLength: 16, busiestOffset: 20
            ),
            identity: activeIdentity,
            accounts: accounts,
            quarantine: quarantine,
            instances: makeInstances(now: now, count: 2),
            environment: makeEnvironment(),
            speed: SpeedFixtures.report(now: now, groups: 6)
        )
    }

    /// Every window near its ceiling, all with future reset times — the auto-swap-about-to-fire
    /// state.
    private static func nearLimitBundle(now: Date) -> FixtureBundle {
        let identity = makeIdentity(
            uuid: "fixture-near-limit", email: "ada@example.com", displayName: "Ada Lovelace",
            organizationName: "Analytical Engine"
        )
        let limits = makeLimits(
            now: now,
            windows: [
                makeWindow(id: "session", title: "5-hour", utilization: 0.97, resetsIn: 40 * 60, now: now),
                makeWindow(id: "weekly_all", title: "7-day", utilization: 0.93, resetsIn: 18 * 3600, now: now),
                makeWindow(id: "weekly_scoped:Opus", title: "7-day Opus", utilization: 0.99, resetsIn: 18 * 3600, now: now),
            ],
            extra: makeExtra(enabled: false)
        )
        let account = makeAccount(identity: identity, limits: limits, isActive: true, health: .ok, now: now)
        return FixtureBundle(
            limits: limits,
            limitsState: .ok,
            summary: makeSummary(now: now, seed: 0x51A6_1E00, dailyCount: 10, modelCount: 4, projectCount: 6),
            stats: makeStatsHistory(
                now: now, seed: 0x5EED_1234, totalDays: 140,
                gapStartOffset: 55, gapLength: 16, busiestOffset: 20
            ),
            identity: identity,
            accounts: [account],
            instances: makeInstances(now: now, count: 2),
            environment: makeEnvironment()
        )
    }

    /// Extra (pay-as-you-go) usage exhausted this month; both rate-limit windows also full.
    private static func extraExhaustedBundle(now: Date) -> FixtureBundle {
        let identity = makeIdentity(
            uuid: "fixture-extra-exhausted", email: "ada@example.com", displayName: "Ada Lovelace",
            organizationName: "Analytical Engine"
        )
        let limits = makeLimits(
            now: now,
            windows: [
                makeWindow(id: "session", title: "5-hour", utilization: 1.0, resetsIn: 40 * 60, now: now),
                makeWindow(id: "weekly_all", title: "7-day", utilization: 1.0, resetsIn: 18 * 3600, now: now),
            ],
            extra: makeExtra(
                enabled: true, monthlyLimit: 100, usedCredits: 100, utilization: 1.0,
                spendLimitReached: true
            )
        )
        let account = makeAccount(identity: identity, limits: limits, isActive: true, health: .ok, now: now)
        return FixtureBundle(
            limits: limits,
            limitsState: .ok,
            summary: makeSummary(now: now, seed: 0x51A6_1E00, dailyCount: 10, modelCount: 4, projectCount: 6),
            stats: makeStatsHistory(
                now: now, seed: 0x5EED_1234, totalDays: 140,
                gapStartOffset: 55, gapLength: 16, busiestOffset: 20
            ),
            identity: identity,
            accounts: [account],
            instances: makeInstances(now: now, count: 2),
            environment: makeEnvironment()
        )
    }

    /// Layout stress: 8 models, 12 projects, 180 days of stats, a scoped window per model, and
    /// long strings everywhere to exercise truncation.
    private static func heavyBundle(now: Date) -> FixtureBundle {
        let modelCount = 8
        let identity = makeIdentity(
            uuid: "fixture-heavy",
            email: "someone.with.a.very.long.email.address.for.truncation@example-organization.com",
            displayName: "A Very Long Display Name That Should Truncate In The Header",
            organizationName: "An Extremely Long Organization Name For Layout Stress Testing LLC"
        )
        var windows = [
            makeWindow(id: "session", title: "5-hour", utilization: 0.62, resetsIn: 2 * 3600, now: now),
            makeWindow(id: "weekly_all", title: "7-day", utilization: 0.58, resetsIn: 4 * 24 * 3600, now: now),
        ]
        for name in modelNames(count: modelCount, longNames: true) {
            windows.append(
                makeWindow(
                    id: "weekly_scoped:\(name)", title: "7-day \(name)",
                    utilization: 0.3 + 0.08 * Double(windows.count), resetsIn: 4 * 24 * 3600, now: now
                )
            )
        }
        let limits = makeLimits(now: now, windows: windows, extra: makeExtra(enabled: false))
        let account = makeAccount(identity: identity, limits: limits, isActive: true, health: .ok, now: now)
        return FixtureBundle(
            limits: limits,
            limitsState: .ok,
            summary: makeSummary(
                now: now, seed: 0x4EA1_0000, dailyCount: 30, modelCount: modelCount, projectCount: 12,
                longNames: true
            ),
            stats: makeStatsHistory(
                now: now, seed: 0x4EA1_5EED, totalDays: 180,
                gapStartOffset: 70, gapLength: 21, busiestOffset: 30
            ),
            identity: identity,
            accounts: [account],
            instances: makeInstances(now: now, count: 3),
            environment: makeEnvironment(),
            speed: SpeedFixtures.report(now: now, groups: 13)
        )
    }

    /// The usage API is unreachable; cached limits are absent from the top-level snapshot but
    /// the summary and stats survive from the last successful fetch.
    private static func errorBundle(now: Date) -> FixtureBundle {
        let identity = makeIdentity(
            uuid: "fixture-error", email: "ada@example.com", displayName: "Ada Lovelace",
            organizationName: "Analytical Engine"
        )
        // A failed refresh preserves the last successful snapshot on every surface.
        let cachedLimits = makeLimits(
            now: now.addingTimeInterval(-30 * 60),
            windows: [
                makeWindow(id: "session", title: "5-hour", utilization: 0.34, resetsIn: 2.5 * 3600, now: now),
                makeWindow(id: "weekly_all", title: "7-day", utilization: 0.71, resetsIn: 3 * 24 * 3600, now: now),
            ],
            extra: makeExtra(enabled: false)
        )
        let account = makeAccount(
            identity: identity, limits: cachedLimits, isActive: true, health: .ok, now: now,
            staleSecondsAgo: 30 * 60
        )
        return FixtureBundle(
            limits: cachedLimits,
            limitsState: .stale(secondsAgo: 30 * 60),
            summary: makeSummary(now: now, seed: 0x51A6_1E00, dailyCount: 10, modelCount: 4, projectCount: 6),
            stats: makeStatsHistory(
                now: now, seed: 0x5EED_1234, totalDays: 140,
                gapStartOffset: 55, gapLength: 16, busiestOffset: 20
            ),
            identity: identity,
            accounts: [account],
            instances: makeInstances(now: now, count: 2),
            environment: makeEnvironment()
        )
    }

    /// Signed in, everything zero — "day one after install". Containers are present but empty,
    /// never nil, so the layout can be told apart from `fresh` (nothing loaded at all).
    private static func emptyBundle(now: Date) -> FixtureBundle {
        let identity = makeIdentity(
            uuid: "fixture-empty", email: "new.user@example.com", displayName: "New User",
            organizationName: nil
        )
        let limits = makeLimits(
            now: now,
            windows: [
                makeWindow(id: "session", title: "5-hour", utilization: 0, resetsIn: nil, now: now, isAvailable: true),
                makeWindow(id: "weekly_all", title: "7-day", utilization: 0, resetsIn: nil, now: now, isAvailable: true),
            ],
            extra: makeExtra(enabled: false)
        )
        let account = makeAccount(identity: identity, limits: limits, isActive: true, health: .ok, now: now)
        return FixtureBundle(
            limits: limits,
            limitsState: .ok,
            summary: makeSummary(now: now, seed: 0x0000_E7E7, dailyCount: 0, modelCount: 0, projectCount: 0),
            stats: makeStatsHistory(now: now, seed: 0x0000_E7E7, totalDays: 0, gapStartOffset: nil, gapLength: 0, busiestOffset: nil),
            identity: identity,
            accounts: [account],
            instances: .empty,
            environment: .empty,
            speed: .empty
        )
    }

    /// An unavailable window beside available ones, and extra usage on with nothing spent.
    ///
    /// The 7-day Fable window is the realistic carrier for `isAvailable == false`: a
    /// per-model window the account has no allocation for is exactly what the API reports no
    /// data for, and it is the window that sat in the popover as an empty track under an
    /// "unavailable" pill until the redesign collapsed it to one line.
    ///
    /// Extra usage is enabled with `usedCredits` at 0 against a $50 cap — the standing state
    /// of anyone who switched pay-as-you-go on and never exceeded the included limits. The
    /// popover must show that as a single row carrying "$0.00 of $50.00", not as a gauge
    /// pinned at zero under its own section header.
    private static func quietEdgesBundle(now: Date) -> FixtureBundle {
        let identity = makeIdentity(
            uuid: "fixture-quiet-edges", email: "edith@example.com", displayName: "Edith Clarke",
            organizationName: "Analytical Engine"
        )
        let limits = makeLimits(
            now: now,
            windows: [
                makeWindow(id: "session", title: "5-hour", utilization: 0.22, resetsIn: 3.5 * 3600, now: now),
                // 4d 17h out, so the day-rollover branch of `ResetCountdown` renders here too
                // — the reason the weekly gauge used to read "resets in ~113h 22m".
                makeWindow(id: "weekly_all", title: "7-day", utilization: 0.44, resetsIn: 113 * 3600 + 22 * 60, now: now),
                makeWindow(id: "weekly_scoped:Fable", title: "7-day Fable", utilization: 0, resetsIn: nil, now: now, isAvailable: false),
            ],
            extra: makeExtra(enabled: true, monthlyLimit: 50, usedCredits: 0, utilization: 0)
        )
        let account = makeAccount(identity: identity, limits: limits, isActive: true, health: .ok, now: now)
        return FixtureBundle(
            limits: limits,
            limitsState: .ok,
            summary: makeSummary(now: now, seed: 0x9C1E_7ED9, dailyCount: 8, modelCount: 3, projectCount: 4),
            stats: makeStatsHistory(
                now: now, seed: 0x9C1E_7ED9, totalDays: 60,
                gapStartOffset: nil, gapLength: 0, busiestOffset: 12
            ),
            identity: identity,
            accounts: [account],
            instances: makeInstances(now: now, count: 1),
            environment: makeEnvironment()
        )
    }

    /// A healthy account under an active minor incident — the service-status banner in its
    /// warn form. Everything else is an ordinary working account on purpose: the banner is
    /// the only thing that differs, so a snapshot shows exactly what it costs the layout.
    private static func statusMinorIncidentBundle(now: Date) -> FixtureBundle {
        let identity = makeIdentity(
            uuid: "fixture-status-minor", email: "ada@example.com", displayName: "Ada Lovelace",
            organizationName: "Analytical Engine"
        )
        let limits = makeLimits(
            now: now,
            windows: [
                makeWindow(id: "session", title: "5-hour", utilization: 0.41, resetsIn: 2 * 3600, now: now),
                makeWindow(id: "weekly_all", title: "7-day", utilization: 0.63, resetsIn: 4 * 24 * 3600, now: now),
                makeWindow(id: "weekly_scoped:Opus", title: "7-day Opus", utilization: 0.55, resetsIn: 4 * 24 * 3600, now: now),
            ],
            extra: makeExtra(enabled: false)
        )
        let account = makeAccount(identity: identity, limits: limits, isActive: true, health: .ok, now: now)
        return FixtureBundle(
            limits: limits,
            limitsState: .ok,
            summary: makeSummary(now: now, seed: 0x57A7_0001, dailyCount: 12, modelCount: 4, projectCount: 5),
            stats: makeStatsHistory(
                now: now, seed: 0x57A7_5EE1, totalDays: 120,
                gapStartOffset: 40, gapLength: 9, busiestOffset: 15
            ),
            identity: identity,
            accounts: [account],
            instances: makeInstances(now: now, count: 2),
            environment: makeEnvironment(),
            serviceStatus: ServiceStatus(
                severity: .degraded,
                incident: StatusIncident(
                    id: "fixture-status-minor",
                    title: "Elevated errors on Claude API requests",
                    latestUpdate: "We are investigating elevated error rates affecting Claude Code.",
                    updatedAt: now.addingTimeInterval(-12 * 60),
                    affectedComponentNames: ["claude.ai", "Claude API (api.anthropic.com)", "Claude Code"]
                )
            )
        )
    }

    /// Claude Code is down — the banner in its critical form, over an account whose own data
    /// is fine. The distinction matters: an outage is not a rate limit, and the surfaces must
    /// keep showing real usage while shouting about the service.
    private static func statusCriticalOutageBundle(now: Date) -> FixtureBundle {
        let identity = makeIdentity(
            uuid: "fixture-status-outage", email: "ada@example.com", displayName: "Ada Lovelace",
            organizationName: "Analytical Engine"
        )
        let limits = makeLimits(
            now: now,
            windows: [
                makeWindow(id: "session", title: "5-hour", utilization: 0.18, resetsIn: 4.5 * 3600, now: now),
                makeWindow(id: "weekly_all", title: "7-day", utilization: 0.49, resetsIn: 2 * 24 * 3600, now: now),
                makeWindow(id: "weekly_scoped:Opus", title: "7-day Opus", utilization: 0.37, resetsIn: 2 * 24 * 3600, now: now),
            ],
            extra: makeExtra(enabled: false)
        )
        let account = makeAccount(identity: identity, limits: limits, isActive: true, health: .ok, now: now)
        return FixtureBundle(
            limits: limits,
            limitsState: .ok,
            summary: makeSummary(now: now, seed: 0x0F7A_0E02, dailyCount: 14, modelCount: 5, projectCount: 7),
            stats: makeStatsHistory(
                now: now, seed: 0x0F7A_5EE2, totalDays: 100,
                gapStartOffset: 30, gapLength: 7, busiestOffset: 9
            ),
            identity: identity,
            accounts: [account],
            instances: makeInstances(now: now, count: 1),
            environment: makeEnvironment(),
            serviceStatus: ServiceStatus(
                severity: .outage,
                incident: StatusIncident(
                    id: "fixture-status-outage",
                    title: "Claude Code is unavailable",
                    latestUpdate: "Claude Code requests are failing. Engineers are rolling back a deploy.",
                    updatedAt: now.addingTimeInterval(-3 * 60),
                    affectedComponentNames: ["Claude Code", "Claude API (api.anthropic.com)"]
                )
            )
        )
    }

    /// An eligible account with a selected, immediately usable reset grant plus a saved grant
    /// that remains unavailable until the account reaches its limit.
    private static func claudeResetsBundle(now: Date) -> FixtureBundle {
        resetBundle(
            now: now,
            identity: makeIdentity(
                uuid: "fixture-claude-resets", email: "margaret@example.com", displayName: "Margaret Hamilton",
                organizationName: "Apollo Guidance"
            ),
            resets: sampleClaudeResets(now: now)
        )
    }

    private static func sampleClaudeResets(now: Date) -> ClaudeResetStatus {
        ClaudeResetStatus(
            eligible: true,
            atLimit: false,
            grants: [
                ClaudeResetGrant(
                    id: "fixture-reset-ready", label: "Weekly reset", resetsTotal: 3, resetsLeft: 2,
                    startsAt: now.addingTimeInterval(-24 * 3600), endsAt: now.addingTimeInterval(3 * 24 * 3600),
                    clears: ["weekly"], usableNow: true, useRequiresLimit: false
                ),
                ClaudeResetGrant(
                    id: "fixture-reset-saved", label: "Monthly reserve", resetsTotal: 1, resetsLeft: 1,
                    startsAt: now.addingTimeInterval(-24 * 3600), endsAt: now.addingTimeInterval(30 * 24 * 3600),
                    clears: ["weekly"], usableNow: false, useRequiresLimit: true, blocking: ["limit"]
                ),
            ],
            nextGrantID: "fixture-reset-ready"
        )
    }

    /// A complete, eligible response whose empty grant list deliberately differs from an
    /// unknown (`nil`) balance.
    private static func claudeResetsZeroBundle(now: Date) -> FixtureBundle {
        resetBundle(
            now: now,
            identity: makeIdentity(
                uuid: "fixture-claude-resets-zero", email: "katherine@example.com", displayName: "Katherine Johnson",
                organizationName: "Langley Research"
            ),
            resets: ClaudeResetStatus(eligible: true, atLimit: false, grants: [])
        )
    }

    /// The balance is positive and its selected grant is otherwise usable, but the future
    /// cooldown makes no reset usable yet.
    private static func claudeResetsCooldownBundle(now: Date) -> FixtureBundle {
        resetBundle(
            now: now,
            identity: makeIdentity(
                uuid: "fixture-claude-resets-cooldown", email: "dorothy@example.com", displayName: "Dorothy Vaughan",
                organizationName: "West Area Computing"
            ),
            resets: ClaudeResetStatus(
                eligible: true,
                atLimit: true,
                grants: [
                    ClaudeResetGrant(
                        id: "fixture-reset-cooldown", label: "Weekly reset", resetsTotal: 2, resetsLeft: 2,
                        startsAt: now.addingTimeInterval(-24 * 3600), endsAt: now.addingTimeInterval(7 * 24 * 3600),
                        clears: ["weekly"], usableNow: true
                    ),
                ],
                nextGrantID: "fixture-reset-cooldown",
                cooldownUntil: now.addingTimeInterval(6 * 3600)
            )
        )
    }

    /// A positive saved balance is retained for display diagnostics, while eligibility prevents
    /// every grant from being used.
    private static func claudeResetsIneligibleBundle(now: Date) -> FixtureBundle {
        resetBundle(
            now: now,
            identity: makeIdentity(
                uuid: "fixture-claude-resets-ineligible", email: "annie@example.com", displayName: "Annie Easley",
                organizationName: "Lewis Research"
            ),
            resets: ClaudeResetStatus(
                eligible: false,
                ineligibleReason: "plan",
                grants: [
                    ClaudeResetGrant(
                        id: "fixture-reset-ineligible", label: "Weekly reset", resetsTotal: 1, resetsLeft: 1,
                        startsAt: now.addingTimeInterval(-24 * 3600), endsAt: now.addingTimeInterval(14 * 24 * 3600),
                        clears: ["weekly"], usableNow: true
                    ),
                ],
                nextGrantID: "fixture-reset-ineligible"
            )
        )
    }

    private static func resetBundle(now: Date, identity: AccountIdentity, resets: ClaudeResetStatus) -> FixtureBundle {
        let limits = makeLimits(
            now: now,
            windows: [
                makeWindow(id: "session", title: "5-hour", utilization: 0.46, resetsIn: 2 * 3600, now: now),
                makeWindow(id: "weekly_all", title: "7-day", utilization: 0.68, resetsIn: 3 * 24 * 3600, now: now),
                makeWindow(id: "weekly_scoped:Opus", title: "7-day Opus", utilization: 0.52, resetsIn: 3 * 24 * 3600, now: now),
            ],
            extra: makeExtra(enabled: false),
            claudeResets: resets
        )
        let account = makeAccount(identity: identity, limits: limits, isActive: true, health: .ok, now: now)
        return FixtureBundle(
            limits: limits,
            limitsState: .ok,
            summary: makeSummary(
                now: now, seed: 0xC1A0_DE55, dailyCount: 10, modelCount: 4, projectCount: 6,
                modelIDs: ["claude-opus-5-5", "claude-sonnet-5", "claude-haiku-4-5", "claude-instant-legacy"]
            ),
            stats: makeStatsHistory(
                now: now, seed: 0xC1A0_5EED, totalDays: 90,
                gapStartOffset: 35, gapLength: 8, busiestOffset: 16
            ),
            identity: identity,
            accounts: [account],
            instances: makeInstances(now: now, count: 2),
            environment: makeEnvironment()
        )
    }

    // MARK: - Shared value builders

    private static func makeIdentity(
        uuid: String, email: String?, displayName: String?, organizationName: String?,
        organizationUuid: String? = nil
    ) -> AccountIdentity {
        AccountIdentity(
            accountUuid: uuid, email: email, displayName: displayName,
            organizationName: organizationName, organizationUuid: organizationUuid
        )
    }

    private static func makeWindow(
        id: String, title: String, utilization: Double, resetsIn interval: TimeInterval?, now: Date,
        isAvailable: Bool = true
    ) -> RateLimitWindow {
        RateLimitWindow(
            id: id, title: title, utilization: utilization,
            resetsAt: interval.map { now.addingTimeInterval($0) },
            isAvailable: isAvailable
        )
    }

    private static func makeExtra(
        enabled: Bool,
        monthlyLimit: Double? = nil,
        usedCredits: Double? = nil,
        utilization: Double? = nil,
        spendLimitReached: Bool = false
    ) -> ExtraUsage {
        ExtraUsage(
            isEnabled: enabled,
            monthlyLimit: monthlyLimit,
            usedCredits: usedCredits,
            utilization: utilization,
            currency: "USD",
            decimalPlaces: 2,
            spendLimitReached: spendLimitReached
        )
    }

    private static func makeLimits(
        now: Date, windows: [RateLimitWindow], extra: ExtraUsage?, claudeResets: ClaudeResetStatus? = nil
    ) -> UsageLimits {
        UsageLimits(
            windows: windows, extra: extra, fetchedAt: now,
            bankedResets: nil, claudeResets: claudeResets
        )
    }

    /// Builds one account row from a hypothetical per-account limits snapshot — mirrors
    /// `AccountPresentation.make`, but fixtures have no `AccountSlot` to derive from.
    private static func makeAccount(
        identity: AccountIdentity, limits: UsageLimits?, isActive: Bool, health: AccountHealth, now: Date,
        staleSecondsAgo: TimeInterval? = nil, isStored: Bool = true
    ) -> AccountPresentation {
        AccountPresentation(
            accountUuid: identity.accountUuid,
            label: identity.label,
            isActive: isActive,
            health: health,
            fiveHour: AccountPresentation.fiveHour(from: limits),
            weekly: AccountPresentation.weekly(from: limits),
            gaugesAreStale: staleSecondsAgo != nil,
            lastActiveAt: now,
            isStored: isStored,
            fiveHourResetsAt: AccountPresentation.fiveHourResetsAt(from: limits),
            weeklyResetsAt: AccountPresentation.weeklyResetsAt(from: limits),
            scopedModel: AccountPresentation.scopedModelWindow(from: limits)?.utilization,
            scopedModelResetsAt: AccountPresentation.scopedModelWindow(from: limits)?.resetsAt,
            scopedModelLabel: AccountPresentation.scopedModelLabel(from: limits)
        )
    }

    /// Deterministic ~N-day mock `StatsHistory`: weekday-biased activity, an optional silent
    /// gap, and an optional standout day. Ported from `SnapshotRunner.makeMockStatsHistory`,
    /// generalized over day count / gap / seed so every scenario can share one implementation.
    private static func makeStatsHistory(
        now: Date, seed: UInt64, totalDays: Int,
        gapStartOffset: Int?, gapLength: Int, busiestOffset: Int?
    ) -> StatsHistory {
        var rng = SnapshotLCG(seed: seed)
        let calendar = Calendar.current
        let dayFormatter = Self.dayFormatter(calendar: calendar)

        var days: [String: RollupDay] = [:]
        for offset in 0..<totalDays {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: now) else { continue }
            if let gapStartOffset, offset >= gapStartOffset && offset < gapStartOffset + gapLength { continue }

            let weekday = calendar.component(.weekday, from: date)   // 1 = Sunday ... 7 = Saturday
            let isWeekend = weekday == 1 || weekday == 7
            if rng.nextUnit() < (isWeekend ? 0.45 : 0.12) { continue }

            var hours = Array(repeating: 0, count: 24)
            var requests = 0
            let activeHours = isWeekend ? (11..<23) : (9..<20)
            for hour in activeHours {
                guard rng.nextUnit() < 0.6 else { continue }
                let base = isWeekend ? 8_000 : 14_000
                hours[hour] = base + Int(rng.nextUnit() * Double(base))
                requests += 1 + Int(rng.nextUnit() * 4)
            }

            if let busiestOffset, offset == busiestOffset {
                hours[14] += 900_000
                requests += 40
            }

            let key = dayFormatter.string(from: date)
            days[key] = RollupDay(day: key, tokensByHour: hours, requests: requests)
        }

        let rollup = StatsRollup(schemaVersion: 1, days: days)
        return StatsHistory(rollup: rollup, today: now, calendar: calendar)
    }

    private static func dayFormatter(calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        return formatter
    }

    /// Deterministic mock `UsageSummary`. Ported from `SnapshotRunner.makeMockSummary`,
    /// generalized over the daily/model/project counts so `heavy` (and `empty`) can share it.
    /// The last model is always left unpriced (`cost == nil`), mirroring the original fixture's
    /// "unpriced model" case.
    private static func makeSummary(
        now: Date, seed: UInt64, dailyCount: Int, modelCount: Int, projectCount: Int,
        longNames: Bool = false, modelIDs: [String]? = nil
    ) -> UsageSummary {
        var rng = SnapshotLCG(seed: seed)
        let cal = Calendar.current

        var buckets: [UsageBucket] = []
        for i in 0..<dailyCount {
            let date = cal.startOfDay(
                for: cal.date(byAdding: .day, value: -(dailyCount - 1 - i), to: now) ?? now
            )
            let calls = 100 + Int(rng.nextUnit() * 800)
            let cost = 1.0 + rng.nextUnit() * 9.0
            let tokens = TokenUsage(
                input: calls * 800, output: calls * 200, cacheRead: calls * 300,
                ephemeral5m: calls * 50, ephemeral1h: calls * 10,
                webSearch: calls / 20, webFetch: calls / 40
            )
            let breakdown = CostBreakdown(
                input: cost * 0.40, output: cost * 0.45, cacheWrite: cost * 0.08, cacheRead: cost * 0.07
            )
            buckets.append(UsageBucket(date: date, usage: tokens, cost: breakdown, callCount: calls))
        }

        let models = modelIDs ?? modelNames(count: modelCount, longNames: longNames)
        var byModel: [ModelUsage] = []
        for (idx, name) in models.enumerated() {
            let calls = 200 + Int(rng.nextUnit() * 3000)
            let usage = TokenUsage(
                input: calls * 900, output: calls * 250, cacheRead: calls * 400,
                ephemeral5m: calls * 60, ephemeral1h: calls * 12,
                webSearch: calls / 25, webFetch: calls / 50
            )
            // Last model unpriced -> cost nil, mirroring the original "unpriced model" fixture.
            let cost: CostBreakdown? = idx == models.count - 1
                ? nil
                : CostBreakdown(
                    input: Double(calls) * 0.006, output: Double(calls) * 0.003,
                    cacheWrite: Double(calls) * 0.0006, cacheRead: Double(calls) * 0.0002
                )
            byModel.append(ModelUsage(model: name, usage: usage, cost: cost, callCount: calls))
        }

        let projects = projectNames(count: projectCount, longNames: longNames)
        var byProject: [ProjectUsage] = []
        for name in projects {
            let calls = 100 + Int(rng.nextUnit() * 2500)
            let usage = TokenUsage(
                input: calls * 700, output: calls * 180, cacheRead: calls * 250,
                ephemeral5m: calls * 40, ephemeral1h: calls * 8,
                webSearch: calls / 15, webFetch: calls / 30
            )
            let cost = CostBreakdown(
                input: Double(calls) * 0.005, output: Double(calls) * 0.0022,
                cacheWrite: Double(calls) * 0.0005, cacheRead: Double(calls) * 0.0002
            )
            byProject.append(
                ProjectUsage(project: name, path: "/Users/you/dev/\(name)", usage: usage, cost: cost, callCount: calls)
            )
        }

        let totalTokens = byModel.map(\.usage).reduce(.zero, +)
        let totalCost = byModel.compactMap(\.cost).reduce(.zero, +)
        let rangeStart = buckets.first?.date ?? now
        let rangeEnd = now

        return UsageSummary(
            total: totalTokens, cost: totalCost, buckets: buckets, bucketSize: .day,
            byProject: byProject, byModel: byModel,
            rangeStart: rangeStart, rangeEnd: rangeEnd
        )
    }

    /// Deterministic model-id list. `longNames` appends a long, truncation-exercising suffix.
    private static func modelNames(count: Int, longNames: Bool) -> [String] {
        let base = [
            "claude-opus-4-8", "claude-sonnet-5", "claude-haiku-4-5", "claude-instant-legacy",
            "claude-opus-4-8-thinking", "claude-sonnet-5-preview", "claude-haiku-4-5-mini",
            "claude-experimental-vision-large",
        ]
        let names = (0..<count).map { i -> String in
            let repeatIndex = i / base.count
            let name = base[i % base.count]
            return repeatIndex == 0 ? name : "\(name)-\(repeatIndex)"
        }
        guard longNames else { return names }
        return names.map { "\($0)-extended-context-window-2026-08-01-nightly-build-identifier" }
    }

    /// Deterministic project-name list. `longNames` appends a long, truncation-exercising prefix.
    private static func projectNames(count: Int, longNames: Bool) -> [String] {
        let base = [
            "alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta",
            "iota", "kappa", "lambda", "mu",
        ]
        let names = (0..<count).map { i -> String in
            let repeatIndex = i / base.count
            let name = base[i % base.count]
            return repeatIndex == 0 ? name : "\(name)-\(repeatIndex)"
        }
        guard longNames else { return names }
        return names.map { "very-long-project-name-that-should-truncate-in-the-ui-\($0)-final-subsystem-module" }
    }

    private static func makeInstances(now: Date, count: Int) -> ClaudeInstancesSnapshot {
        let all: [ClaudeInstance] = [
            ClaudeInstance(
                pid: 4821, version: "2.1.197",
                executablePath: "/Users/example/.local/share/claude/versions/2.1.197/claude",
                workingDirectory: "/Users/example/Developer/personal/Toki",
                startedAt: now.addingTimeInterval(-3600 * 3), memoryBytes: 155_189_248,
                source: .native, isOutdated: false
            ),
            ClaudeInstance(
                pid: 5310, version: "2.1.197",
                executablePath: "/Applications/Conductor.app/Contents/Resources/agent-binaries/claude/2.1.197/claude",
                workingDirectory: "/Users/example/Developer/work/api-gateway",
                startedAt: now.addingTimeInterval(-60 * 5), memoryBytes: 1_310_720_000,
                source: .managed, isOutdated: false
            ),
            ClaudeInstance(
                pid: 6120, version: "2.0.88",
                executablePath: "/Users/example/.local/share/claude/versions/2.0.88/claude",
                workingDirectory: "/Users/example/Developer/work/very-long-monorepo-name-that-should-truncate-in-the-instances-list",
                startedAt: now.addingTimeInterval(-3600 * 20), memoryBytes: 210_000_000,
                source: .native, isOutdated: true
            ),
        ]
        return ClaudeInstancesSnapshot(instances: Array(all.prefix(count)), referenceVersion: "2.1.197")
    }

    private static func makeEnvironment() -> ClaudeEnvironment {
        ClaudeEnvironment(
            cli: CLIInfo(
                version: "2.1.197", installMethod: "native", autoUpdates: true,
                lastUpdateFrom: "2.1.190", lastUpdateTo: "2.1.197", lastUpdateAt: nil,
                lastUpdateOutcome: "success"
            ),
            marketplaces: [
                MarketplaceInfo(name: "official", repo: "anthropics/claude-code-marketplace", lastUpdated: nil),
            ],
            plugins: [
                PluginInfo(
                    name: "superpowers", marketplace: "official", version: "1.2.0", latestVersion: "1.2.0",
                    updateAvailable: false, enabled: true, installedAt: nil, lastUpdated: nil,
                    description: "Skill bundle", usageCount: 12, isFavorite: true
                ),
                PluginInfo(
                    name: "figma", marketplace: "official", version: "2.1.0", latestVersion: "2.2.0",
                    updateAvailable: true, enabled: true, installedAt: nil, lastUpdated: nil,
                    description: "Figma integration", usageCount: 7, isFavorite: false
                ),
                PluginInfo(
                    name: "local-workflow", marketplace: "team", version: "build-42", latestVersion: nil,
                    updateAvailable: false, enabled: false, installedAt: nil, lastUpdated: nil,
                    description: "Internal workflow", usageCount: nil, isFavorite: false
                ),
            ],
            skills: [
                SkillInfo(
                    name: "systematic-debugging", plugin: "superpowers", description: "Debug systematically",
                    usageCount: 5, marketplace: "official"
                ),
            ],
            mcpServers: [
                MCPServerInfo(
                    name: "context7", transport: "http", detail: "mcp.context7.com", source: "user",
                    providingPluginVersion: nil, needsAuth: false
                ),
            ]
        )
    }
}
