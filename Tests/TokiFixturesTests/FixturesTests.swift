import Foundation
import Testing
import TokiStatus
@testable import TokiFixtures

@Suite("Fixtures")
struct FixturesTests {

    private static let fixedNow = Date(timeIntervalSince1970: 1_754_000_000)   // 2025-08-01T00:53:20Z

    // MARK: - Every scenario is trap-free

    @Test("every scenario produces a bundle without trapping", arguments: Scenario.allCases)
    func everyScenarioBuilds(_ scenario: Scenario) {
        let bundle = Fixtures.bundle(for: scenario, now: Self.fixedNow)
        // No assertion beyond "didn't trap" — reaching this line is the test.
        _ = bundle
    }

    // MARK: - Determinism

    @Test("same `now` twice produces byte-identical numeric output", arguments: Scenario.allCases)
    func deterministic(_ scenario: Scenario) {
        let a = Fixtures.bundle(for: scenario, now: Self.fixedNow)
        let b = Fixtures.bundle(for: scenario, now: Self.fixedNow)

        // Equatable containers compare directly.
        #expect(a.stats == b.stats)
        #expect(a.accounts == b.accounts)
        #expect(a.instances == b.instances)
        #expect(a.environment == b.environment)
        #expect(a.identity == b.identity)
        #expect(a.limitsState == b.limitsState)

        // UsageLimits/UsageSummary aren't Equatable — compare the numeric fields that matter.
        #expect(a.limits?.windows.map(\.utilization) == b.limits?.windows.map(\.utilization))
        #expect(a.limits?.windows.map(\.resetsAt) == b.limits?.windows.map(\.resetsAt))
        #expect(a.limits?.extra?.utilization == b.limits?.extra?.utilization)
        #expect(a.limits?.extra?.usedCredits == b.limits?.extra?.usedCredits)

        #expect(a.summary?.buckets.count == b.summary?.buckets.count)
        #expect(a.summary?.byModel.count == b.summary?.byModel.count)
        #expect(a.summary?.byProject.count == b.summary?.byProject.count)
        #expect(a.summary?.total.input == b.summary?.total.input)
        #expect(a.summary?.total.output == b.summary?.total.output)
        #expect(a.summary?.cost?.total == b.summary?.cost?.total)
        #expect(a.summary?.buckets.map(\.callCount) == b.summary?.buckets.map(\.callCount))
    }

    // MARK: - Scenario semantics

    @Test("public README fixture shows Fable with demonstration account data")
    func publicReadmeShowsFable() throws {
        let scenario = try #require(Scenario(rawValue: "public-readme"))
        let bundle = Fixtures.bundle(for: scenario, now: Self.fixedNow)
        let windows = try #require(bundle.limits?.windows)
        #expect(windows.map(\.title) == ["5-hour", "7-day", "7-day Fable"])
        #expect(bundle.limits?.claudeResets?.totalResets == 3)
        #expect(bundle.identity?.email == "ada@example.com")
        #expect(bundle.summary != nil)
    }

    @Test("nearLimit really is near the limit on every window")
    func nearLimitIsNearLimit() {
        let bundle = Fixtures.bundle(for: .nearLimit, now: Self.fixedNow)
        let windows = bundle.limits?.windows ?? []
        #expect(!windows.isEmpty)
        for window in windows {
            #expect(window.utilization > 0.9)
        }
    }

    @Test("extraExhausted has spendLimitReached and full utilization")
    func extraExhaustedIsExhausted() {
        let bundle = Fixtures.bundle(for: .extraExhausted, now: Self.fixedNow)
        #expect(bundle.limits?.extra?.spendLimitReached == true)
        #expect(bundle.limits?.extra?.utilization == 1.0)
        let windows = bundle.limits?.windows ?? []
        #expect(!windows.isEmpty)
        for window in windows {
            #expect(window.utilization == 1.0)
        }
    }

    /// `quietEdges` exists ONLY to make two popover branches renderable: an unavailable
    /// window, and extra usage on with nothing spent. If a later edit makes every window
    /// available or flips the extra usage off, the scenario still builds and every other
    /// test still passes — while the two branches it was created for go dark again. These
    /// assertions are what stop that from happening silently.
    @Test("quietEdges keeps exactly the two states no other scenario produces")
    func quietEdgesCoversTheQuietBranches() {
        let bundle = Fixtures.bundle(for: .quietEdges, now: Self.fixedNow)
        let windows = bundle.limits?.windows ?? []

        #expect(windows.contains { !$0.isAvailable }, "needs an unavailable window")
        #expect(windows.contains { $0.isAvailable }, "an unavailable window only reads as one beside available ones")

        let extra = bundle.limits?.extra
        #expect(extra?.isEnabled == true)
        #expect(extra?.spendLimitReached == false)
        #expect(extra?.usedCredits == 0, "enabled with nothing spent is the whole point")
        #expect(extra?.monthlyLimit != nil, "the collapsed row must still have a cap to report")
    }

    /// The other seven scenarios are the reason `quietEdges` had to exist. Pinning that here
    /// means "just add an unavailable window to `singleAccount`" fails loudly rather than
    /// quietly changing a snapshot everyone reviews by eye.
    @Test("no other scenario produces an unavailable window", arguments: Scenario.allCases.filter { $0 != .quietEdges })
    func onlyQuietEdgesHasUnavailableWindows(_ scenario: Scenario) {
        let windows = Fixtures.bundle(for: scenario, now: Self.fixedNow).limits?.windows ?? []
        let hasUnavailable = windows.contains { !$0.isAvailable }
        #expect(hasUnavailable == false, "\(scenario.rawValue) now has an unavailable window")
    }

    @Test("empty has zero totals but non-nil containers")
    func emptyIsZeroButPresent() {
        let bundle = Fixtures.bundle(for: .empty, now: Self.fixedNow)

        // Non-nil: this is the "signed in, day one" layout, not "nothing loaded".
        #expect(bundle.summary != nil)
        #expect(bundle.stats != nil)
        #expect(bundle.identity != nil)

        // Zero: no activity has happened yet.
        #expect(bundle.summary?.buckets.isEmpty == true)
        #expect(bundle.summary?.byModel.isEmpty == true)
        #expect(bundle.summary?.byProject.isEmpty == true)
        #expect(bundle.summary?.total.input == 0)
        #expect(bundle.summary?.total.output == 0)
        #expect(bundle.stats?.allTimeTokens == 0)
        #expect(bundle.stats?.allTimeRequests == 0)
        #expect(bundle.stats?.activeDayCount == 0)
    }

    @Test("only multiAccount carries quarantine entries")
    func quarantineOnlyInMultiAccount() {
        for scenario in Scenario.allCases {
            let bundle = Fixtures.bundle(for: scenario, now: Self.fixedNow)
            if scenario == .multiAccount {
                #expect(bundle.accounts.count == 3)
                #expect(bundle.quarantine.count == 1)
            } else {
                #expect(bundle.quarantine.isEmpty, "\(scenario) should have no quarantine entries")
            }
        }
    }

    /// The status scenarios exist only so the incident banner has something to render. If a
    /// later edit drops their incident, or lets an unrelated scenario go disrupted, the banner
    /// either goes untested or starts appearing in every other snapshot — both silent.
    @Test("only the status scenarios carry a disrupted service status")
    func serviceStatusOnlyInStatusScenarios() {
        let statusScenarios: Set<Scenario> = [.statusMinorIncident, .statusCriticalOutage]
        for scenario in Scenario.allCases {
            let status = Fixtures.bundle(for: scenario, now: Self.fixedNow).serviceStatus
            if statusScenarios.contains(scenario) {
                #expect(status.isDisrupted, "\(scenario.rawValue) must be disrupted")
                #expect(status.incident != nil, "\(scenario.rawValue) needs an incident to render")
                #expect(status.incident?.title.isEmpty == false)
                #expect(status.incident?.affectedComponentNames.isEmpty == false)
            } else {
                #expect(status == .operational, "\(scenario.rawValue) should stay operational")
            }
        }
    }

    @Test("the two status scenarios differ in severity")
    func statusScenariosBracketTheSeverityScale() {
        let minor = Fixtures.bundle(for: .statusMinorIncident, now: Self.fixedNow).serviceStatus
        let outage = Fixtures.bundle(for: .statusCriticalOutage, now: Self.fixedNow).serviceStatus
        #expect(minor.severity == .degraded)
        #expect(outage.severity == .outage)
        #expect(minor.severity < outage.severity)
    }

    @Test("heavy has at least 8 models and 12 projects")
    func heavyIsHeavy() {
        let bundle = Fixtures.bundle(for: .heavy, now: Self.fixedNow)
        #expect((bundle.summary?.byModel.count ?? 0) >= 8)
        #expect((bundle.summary?.byProject.count ?? 0) >= 12)
    }

    @Test("fresh has nil limits and notLoggedIn state")
    func freshIsFresh() {
        let bundle = Fixtures.bundle(for: .fresh, now: Self.fixedNow)
        #expect(bundle.limits == nil)
        #expect(bundle.limitsState == .notLoggedIn)
        #expect(bundle.summary == nil)
        #expect(bundle.stats == nil)
        #expect(bundle.identity == nil)
        #expect(bundle.accounts.isEmpty)
    }

    @Test("failed refresh keeps cached usage with an explicit stale state")
    func errorKeepsCachedData() {
        let bundle = Fixtures.bundle(for: .error, now: Self.fixedNow)
        #expect(bundle.limits?.fiveHour?.utilization == 0.34)
        #expect(bundle.limits?.fetchedAt == Self.fixedNow.addingTimeInterval(-1800))
        #expect(bundle.limitsState == .stale(secondsAgo: 1800))
        #expect(bundle.summary != nil)
    }

    @Test("claudeResets carries two deterministic grants with one selected usable grant")
    func claudeResetsHasUsableAndSavedGrants() throws {
        let bundle = Fixtures.bundle(for: .claudeResets, now: Self.fixedNow)
        let resets = try #require(bundle.limits?.claudeResets)
        let grants = try #require(resets.grants)

        #expect(bundle.accounts.count == 1)
        #expect(resets.eligible)
        #expect(resets.totalResets == 3)
        #expect(grants.count == 2)
        #expect(grants[0].resetsLeft == 2)
        #expect(grants[0].endsAt == Self.fixedNow.addingTimeInterval(3 * 24 * 3600))
        #expect(resets.canUse(grants[0], at: Self.fixedNow))
        #expect(grants[1].resetsLeft == 1)
        #expect(grants[1].endsAt == Self.fixedNow.addingTimeInterval(30 * 24 * 3600))
        #expect(grants[1].useRequiresLimit)
        #expect(!resets.canUse(grants[1], at: Self.fixedNow))
        #expect(bundle.summary?.byModel.contains { $0.model == "claude-opus-5-5" } == true)
    }

    @Test("claude reset scenarios pin zero, cooldown, and ineligible states")
    func claudeResetEdgeStates() throws {
        let zero = try #require(Fixtures.bundle(for: .claudeResetsZero, now: Self.fixedNow).limits?.claudeResets)
        #expect(zero.eligible)
        #expect(zero.grants?.isEmpty == true)
        #expect(zero.totalResets == 0)

        let cooldown = try #require(Fixtures.bundle(for: .claudeResetsCooldown, now: Self.fixedNow).limits?.claudeResets)
        let cooldownGrant = try #require(cooldown.grants?.first)
        #expect(cooldown.eligible)
        #expect(cooldown.totalResets == 2)
        #expect(cooldown.cooldownUntil == Self.fixedNow.addingTimeInterval(6 * 3600))
        #expect(!cooldown.canUse(cooldownGrant, at: Self.fixedNow))

        let ineligible = try #require(Fixtures.bundle(for: .claudeResetsIneligible, now: Self.fixedNow).limits?.claudeResets)
        let ineligibleGrant = try #require(ineligible.grants?.first)
        #expect(!ineligible.eligible)
        #expect(ineligible.totalResets == 1)
        #expect(!ineligible.canUse(ineligibleGrant, at: Self.fixedNow))
    }

    @Test("normal scenarios retain no Claude reset fixture data")
    func normalScenariosRemainUnchanged() {
        let resetScenarios: Set<Scenario> = [.publicReadme, .claudeResets, .claudeResetsZero, .claudeResetsCooldown, .claudeResetsIneligible]
        for scenario in Scenario.allCases where !resetScenarios.contains(scenario) {
            #expect(Fixtures.bundle(for: scenario, now: Self.fixedNow).limits?.claudeResets == nil)
        }
    }

    @Test("Speed fixtures: populated scenarios have a 30-day series, empty has none")
    func speedFixtures() throws {
        let now = Date(timeIntervalSince1970: 1_790_935_200)
        let single = try #require(Fixtures.bundle(for: .singleAccount, now: now).speed)
        #expect(single.groups.count >= 4)
        #expect(single.groups.contains { $0.provider == .codex })
        #expect(single.groups.contains { $0.isFast })
        #expect(single.groups[0].daily.count >= 25)            // a few gap days, by design
        #expect(single.hiddenGroupCount == 1)
        #expect((Fixtures.bundle(for: .heavy, now: now).speed?.groups.count ?? 0) >= 12)
        #expect(Fixtures.bundle(for: .empty, now: now).speed == .empty)
        #expect(Fixtures.bundle(for: .fresh, now: now).speed == nil)
    }
}
