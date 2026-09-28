import Testing
import Foundation
import TokiModels
@testable import TokiAccounts

private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

private func slot(alias: String? = nil, health: AccountHealth = .ok) -> AccountSlot {
    AccountSlot(
        identity: AccountIdentity(
            accountUuid: "uuid-1", email: "me@x.y", displayName: "Me",
            organizationName: nil, organizationUuid: nil
        ),
        alias: alias,
        credentialJSON: Data(#"{"claudeAiOauth":{"refreshToken":"r"}}"#.utf8),
        previousCredentialJSON: nil, lineage: "l",
        addedAt: t0, lastActiveAt: t0, lastRefreshAt: nil, health: health
    )
}

private func limits(session: Double, weekly: Double) -> UsageLimits {
    UsageLimits(
        windows: [
            RateLimitWindow(
                id: "session", title: "5-hour", utilization: session, resetsAt: nil,
                isAvailable: true
            ),
            RateLimitWindow(
                id: "weekly_all", title: "7-day", utilization: weekly, resetsAt: nil,
                isAvailable: true
            ),
        ],
        extra: nil, fetchedAt: t0
    )
}

@Suite("AccountPresentation")
struct AccountPresentationTests {

    @Test("maps the session and weekly windows onto the row")
    func mapsWindows() {
        let row = AccountPresentation.make(
            slot: slot(), active: true, limits: limits(session: 0.42, weekly: 0.19), stale: false
        )
        #expect(row.fiveHour == 0.42)
        #expect(row.weekly == 0.19)
        #expect(row.isActive)
    }

    @Test("prefers the alias for display")
    func prefersAlias() {
        #expect(
            AccountPresentation.make(slot: slot(alias: "work"), active: false, limits: nil, stale: false)
                .label == "work"
        )
        #expect(
            AccountPresentation.make(slot: slot(), active: false, limits: nil, stale: false)
                .label == "me@x.y"
        )
    }

    @Test("missing limits leave the gauges unknown rather than zero")
    func missingLimitsAreUnknown() {
        // Zero would read as "plenty of headroom" and could steer an auto-swap into an
        // account we know nothing about.
        let row = AccountPresentation.make(slot: slot(), active: false, limits: nil, stale: true)
        #expect(row.fiveHour == nil)
        #expect(row.weekly == nil)
        #expect(row.gaugesAreStale)
    }

    @Test("a stale sleeping row never exposes cached percentages")
    func staleSleepingRowHidesCachedLimits() {
        let row = AccountPresentation.make(
            slot: slot(), active: false, limits: limits(session: 0.91, weekly: 0.82), stale: true,
            staleReason: .network
        )

        #expect(row.fiveHour == nil)
        #expect(row.weekly == nil)
        #expect(row.gaugesAreStale)
        #expect(row.staleReason == .network)
    }

    @Test("an unhealthy slot is reported so the UI can ask for a re-login")
    func reportsHealth() {
        #expect(
            AccountPresentation.make(
                slot: slot(health: .needsReauth), active: false, limits: nil, stale: false
            ).health == .needsReauth
        )
    }
}
