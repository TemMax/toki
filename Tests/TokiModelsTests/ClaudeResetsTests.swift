import Foundation
import Testing
@testable import TokiModels

@Suite("Claude resets")
struct ClaudeResetsTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func grant(
        id: String = "grant-1",
        left: Int = 1,
        endsAt: Date? = nil,
        paused: Bool = false,
        usableNow: Bool = true
    ) -> ClaudeResetGrant {
        ClaudeResetGrant(
            id: id,
            label: "Weekly reset",
            resetsTotal: 3,
            resetsLeft: left,
            startsAt: now.addingTimeInterval(600),
            endsAt: endsAt,
            clears: ["weekly"],
            paused: paused,
            usableNow: usableNow,
            blocking: ["limit"]
        )
    }

    @Test("reset values round-trip through JSON with CLI defaults")
    func jsonRoundTrip() throws {
        let original = ClaudeResetStatus(
            eligible: true,
            ineligibleReason: "plan",
            atLimit: true,
            exhausted: ["weekly"],
            grants: [grant(endsAt: now.addingTimeInterval(3600))],
            nextGrantID: "grant-1",
            weeklyResetsAt: now.addingTimeInterval(7200),
            cooldownUntil: now.addingTimeInterval(300)
        )
        let decoded = try JSONDecoder().decode(ClaudeResetStatus.self, from: JSONEncoder().encode(original))
        #expect(decoded == original)

        let defaults = ClaudeResetGrant(id: "default", resetsLeft: 0)
        #expect(defaults.label == "")
        #expect(defaults.resetsTotal == 0)
        #expect(defaults.clears.isEmpty)
        #expect(!defaults.paused)
        #expect(!defaults.usableNow)
        #expect(defaults.useRequiresLimit)
        #expect(defaults.blocking.isEmpty)
    }

    @Test("multiple reset counts aggregate, while absent grants remain unknown")
    func totalsDistinguishUnknownFromZero() {
        let multiple = ClaudeResetStatus(eligible: true, grants: [grant(id: "one", left: 2), grant(id: "two", left: 3)])
        #expect(multiple.totalResets == 5)
        #expect(multiple.displayState(fetchedAt: now, now: now) == .balance(5))

        let unknown = ClaudeResetStatus(eligible: true)
        #expect(unknown.totalResets == nil)
        #expect(unknown.displayState(fetchedAt: now, now: now) == .hidden)

        let zero = ClaudeResetStatus(eligible: true, grants: [])
        #expect(zero.totalResets == 0)
        #expect(zero.displayState(fetchedAt: now, now: now) == .balance(0))
    }

    @Test("invalid and overflowing reset counts are unknown")
    func invalidTotalsAreUnknown() {
        let negative = ClaudeResetStatus(eligible: true, grants: [grant(left: -1)])
        #expect(negative.totalResets == nil)
        #expect(negative.displayState(fetchedAt: now, now: now) == .hidden)

        let negativeTotal = ClaudeResetStatus(
            eligible: true,
            grants: [ClaudeResetGrant(id: "invalid-total", resetsTotal: -1, resetsLeft: 1)]
        )
        #expect(negativeTotal.totalResets == nil)

        let overflow = ClaudeResetStatus(eligible: true, grants: [grant(id: "one", left: .max), grant(id: "two", left: 1)])
        #expect(overflow.totalResets == nil)
        #expect(overflow.displayState(fetchedAt: now, now: now) == .hidden)
    }

    @Test("expired positive grants update instead of displaying a stale balance")
    func expiryAndSnapshotFreshness() {
        let expiredGrant = grant(endsAt: now)
        let expired = ClaudeResetStatus(eligible: true, grants: [expiredGrant], nextGrantID: "grant-1")
        #expect(expired.displayState(fetchedAt: now, now: now) == .updating)
        #expect(!expired.canUse(expiredGrant, at: now))

        let fresh = ClaudeResetStatus(eligible: true, grants: [])
        #expect(fresh.displayState(fetchedAt: now.addingTimeInterval(-210), now: now) == .balance(0))
        #expect(fresh.displayState(fetchedAt: now.addingTimeInterval(-210.001), now: now) == .hidden)
        #expect(fresh.displayState(fetchedAt: now.addingTimeInterval(300), now: now) == .balance(0))
        #expect(fresh.displayState(fetchedAt: now.addingTimeInterval(300.001), now: now) == .hidden)
        #expect(ClaudeResetStatus(eligible: false, grants: []).displayState(fetchedAt: now, now: now) == .hidden)
    }

    @Test("rate-limit stale allowance bypasses only snapshot age")
    func rateLimitStaleAllowancePreservesSafetyGuards() {
        let oldFetchedAt = now.addingTimeInterval(-211)
        let active = ClaudeResetStatus(
            eligible: true,
            grants: [grant(left: 2, endsAt: now.addingTimeInterval(600))]
        )
        #expect(active.displayState(fetchedAt: oldFetchedAt, now: now) == .hidden)
        #expect(active.displayState(fetchedAt: oldFetchedAt, now: now, allowsStale: true) == .balance(2))

        let expired = ClaudeResetStatus(
            eligible: true,
            grants: [grant(left: 2, endsAt: now)]
        )
        #expect(expired.displayState(fetchedAt: oldFetchedAt, now: now, allowsStale: true) == .updating)
        #expect(ClaudeResetStatus(eligible: false, grants: [])
            .displayState(fetchedAt: oldFetchedAt, now: now, allowsStale: true) == .hidden)
        #expect(ClaudeResetStatus(eligible: true)
            .displayState(fetchedAt: oldFetchedAt, now: now, allowsStale: true) == .hidden)
        #expect(ClaudeResetStatus(eligible: true, grants: [grant(left: -1)])
            .displayState(fetchedAt: oldFetchedAt, now: now, allowsStale: true) == .hidden)
        #expect(active.displayState(
            fetchedAt: now.addingTimeInterval(300.001),
            now: now,
            allowsStale: true
        ) == .hidden)
    }

    @Test("only the selected, server-usable, unblocked grant can be used")
    func immediateUsability() {
        let selected = grant()
        let status = ClaudeResetStatus(eligible: true, grants: [selected], nextGrantID: selected.id)
        #expect(status.canUse(selected, at: now))
        #expect(!ClaudeResetStatus(eligible: true, grants: [selected], nextGrantID: "other").canUse(selected, at: now))

        let paused = grant(paused: true)
        #expect(!ClaudeResetStatus(eligible: true, grants: [paused], nextGrantID: paused.id).canUse(paused, at: now))
        let unusable = grant(usableNow: false)
        #expect(!ClaudeResetStatus(eligible: true, grants: [unusable], nextGrantID: unusable.id).canUse(unusable, at: now))
        #expect(!ClaudeResetStatus(eligible: true, grants: [selected], nextGrantID: selected.id, cooldownUntil: now.addingTimeInterval(1)).canUse(selected, at: now))

        let futureStarting = grant()
        #expect(ClaudeResetStatus(eligible: true, grants: [futureStarting], nextGrantID: futureStarting.id).canUse(futureStarting, at: now))
    }
}
