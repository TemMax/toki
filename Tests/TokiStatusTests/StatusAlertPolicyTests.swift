import Foundation
import Testing
@testable import TokiStatus

@Suite("StatusAlertPolicy")
struct StatusAlertPolicyTests {

    private func disrupted(
        _ severity: StatusSeverity = .degraded,
        id: String? = "q7txxvbsftgq",
        title: String = "Degraded performance for multiple models"
    ) -> ServiceStatus {
        ServiceStatus(
            severity: severity,
            incident: id.map {
                StatusIncident(id: $0, title: title, latestUpdate: nil,
                               updatedAt: nil, affectedComponentNames: ["Claude Code"])
            }
        )
    }

    @Test("a new incident fires one begin, carrying its severity and title")
    func firesOnce() {
        var policy = StatusAlertPolicy()

        #expect(policy.event(for: disrupted(.outage)) ==
            .incidentBegan(severity: .outage, title: "Degraded performance for multiple models"))
    }

    /// Polling every 30 s during an incident means the same status arrives dozens of times.
    @Test("re-feeding the same status stays silent")
    func repeatedPollsAreSilent() {
        var policy = StatusAlertPolicy()
        #expect(policy.event(for: disrupted()) != nil)

        #expect(policy.event(for: disrupted()) == nil)
        #expect(policy.event(for: disrupted()) == nil)
    }

    /// The real sequence Anthropic produces: the Claude Code component goes
    /// `degraded_performance` a few minutes before the incident is published, so Toki first
    /// sees a disruption with NO incident id and keys it synthetically. When the incident
    /// finally appears it must join the same episode, not open a second one.
    @Test("a degradation seen before its incident is published notifies exactly once")
    func syntheticKeyThenRealIncident() {
        var policy = StatusAlertPolicy()

        let beforePublication = policy.event(for: disrupted(.degraded, id: nil))
        #expect(beforePublication == .incidentBegan(severity: .degraded, title: nil))

        #expect(policy.event(for: disrupted()) == nil,
                "the published incident id joins the running episode instead of re-announcing it")
        #expect(policy.event(for: disrupted()) == nil)
    }

    /// The banner shows the current severity; a second notification saying "it got worse" is
    /// not something the user asked to be interrupted by.
    @Test("an escalation from degraded to outage does not notify again")
    func escalationIsSilent() {
        var policy = StatusAlertPolicy()
        #expect(policy.event(for: disrupted(.degraded)) != nil)

        #expect(policy.event(for: disrupted(.outage)) == nil)
    }

    @Test("going operational after a disruption fires one resolve, then nothing")
    func resolvesOnce() {
        var policy = StatusAlertPolicy()
        _ = policy.event(for: disrupted())

        #expect(policy.event(for: .operational) == .incidentResolved)
        #expect(policy.event(for: .operational) == nil)
    }

    @Test("a clean start that is already healthy says nothing")
    func healthyFromCleanStart() {
        var policy = StatusAlertPolicy()

        #expect(policy.event(for: .operational) == nil)
    }

    /// A second, unrelated incident later is a new episode and does notify.
    @Test("a new episode after a resolve notifies again")
    func nextEpisodeNotifies() {
        var policy = StatusAlertPolicy()
        _ = policy.event(for: disrupted())
        _ = policy.event(for: .operational)

        #expect(policy.event(for: disrupted(.outage, id: "another", title: "API errors")) ==
            .incidentBegan(severity: .outage, title: "API errors"))
    }
}

@Suite("StatusAlertLatchStore")
struct StatusAlertLatchStoreTests {

    private let live = ServiceStatus(
        severity: .degraded,
        incident: StatusIncident(id: "q7txxvbsftgq", title: "Degraded performance for multiple models",
                                 latestUpdate: nil, updatedAt: nil,
                                 affectedComponentNames: ["Claude Code"])
    )

    private func makeStore(_ name: String) -> (StatusAlertLatchStore, UserDefaults) {
        let defaults = UserDefaults(suiteName: "toki.tests.statuslatch.\(name).\(UUID().uuidString)")!
        return (StatusAlertLatchStore(defaults: defaults), defaults)
    }

    /// Anthropic incidents last hours. Without persistence, every relaunch inside those hours
    /// re-announces an outage the user has been looking at all morning.
    @Test("an announced episode survives a restart and does not announce twice")
    func survivesRestart() {
        let (store, _) = makeStore("restart")

        var beforeQuit = StatusAlertPolicy()
        #expect(beforeQuit.event(for: live) != nil)
        store.save(beforeQuit)

        var afterLaunch = store.load()
        #expect(afterLaunch.event(for: live) == nil,
                "an incident announced before the quit must stay quiet after the relaunch")
    }

    /// And the other half: the latch has to survive well enough to still deliver the resolve.
    @Test("a restored latch still fires the resolve when the incident clears")
    func resolveSurvivesRestart() {
        let (store, _) = makeStore("resolve")
        var beforeQuit = StatusAlertPolicy()
        _ = beforeQuit.event(for: live)
        store.save(beforeQuit)

        var afterLaunch = store.load()
        #expect(afterLaunch.event(for: .operational) == .incidentResolved)
    }

    @Test("a first launch, with nothing stored, announces normally")
    func absentKey() {
        let (store, _) = makeStore("absent")
        var policy = store.load()

        #expect(policy.event(for: live) != nil)
    }

    /// The failure budget is one duplicate notification — never a crash, never a lost alert.
    @Test("corrupt bytes load a working policy instead of throwing")
    func corruptBytes() {
        let (store, defaults) = makeStore("corrupt")
        defaults.set(Data("not json".utf8), forKey: "toki.statusAlertLatch")

        var policy = store.load()
        #expect(policy.event(for: live) != nil)
    }

    @Test("the whole latch round trips through the store")
    func roundTrip() {
        let (store, _) = makeStore("roundtrip")
        var policy = StatusAlertPolicy()
        _ = policy.event(for: live)
        store.save(policy)

        #expect(store.load() == policy)
    }
}
