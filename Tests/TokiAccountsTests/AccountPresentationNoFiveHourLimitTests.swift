import Foundation
import Testing
import TokiModels
@testable import TokiAccounts

private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

private func slot() -> AccountSlot {
    AccountSlot(
        identity: AccountIdentity(
            accountUuid: "uuid-1", email: "me@x.y", displayName: "Me",
            organizationName: nil, organizationUuid: nil
        ),
        alias: nil,
        credentialJSON: Data(#"{"claudeAiOauth":{"refreshToken":"r"}}"#.utf8),
        previousCredentialJSON: nil, lineage: "l",
        addedAt: t0, lastActiveAt: t0, lastRefreshAt: nil, health: .ok
    )
}

/// A verified Claude Ultra response: weekly windows, no `session`.
private let ultra = UsageLimits(
    windows: [
        RateLimitWindow(id: "weekly_all", title: "7-day", utilization: 0.16, resetsAt: t0, isAvailable: true),
        RateLimitWindow(id: "weekly_scoped:Fable", title: "7-day Fable", utilization: 0, resetsAt: t0, isAvailable: true),
    ],
    extra: nil, fetchedAt: t0
)

@Suite("Accounts without a 5-hour limit")
struct AccountPresentationNoFiveHourLimitTests {
    @Test("a fresh weekly-only response marks the account as having no 5-hour limit")
    func freshWeeklyOnly() {
        let row = AccountPresentation.make(slot: slot(), active: false, limits: ultra, stale: false)
        #expect(row.hasNoFiveHourLimit)
        #expect(row.fiveHour == nil)
        #expect(row.headlineUtilization == 0.16)
        #expect(row.fiveHourForPolicy == 0)
        #expect(AccountPresentation.fiveHourForPolicy(from: ultra) == 0)
    }

    @Test("stale or missing data stays unknown rather than limit-free")
    func unknownStaysUnknown() {
        let stale = AccountPresentation.make(slot: slot(), active: false, limits: ultra, stale: true)
        #expect(!stale.hasNoFiveHourLimit)
        #expect(stale.fiveHourForPolicy == nil)
        let missing = AccountPresentation.make(slot: slot(), active: false, limits: nil, stale: false)
        #expect(!missing.hasNoFiveHourLimit)
        #expect(missing.fiveHourForPolicy == nil)
        #expect(AccountPresentation.fiveHourForPolicy(from: nil) == nil)
    }

    @Test("the live overlay carries the flag onto the active row")
    func liveOverlay() {
        let raw = AccountPresentation.make(slot: slot(), active: true, limits: nil, stale: false)
        let row = AccountPresentation.overlayingLiveActiveLimits([raw], live: ultra, liveIsFresh: true)[0]
        #expect(!row.gaugesAreStale)
        #expect(row.hasNoFiveHourLimit)
        #expect(row.headlineUtilization == 0.16)
    }
}
