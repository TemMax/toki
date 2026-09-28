import Testing
import Foundation
import TokiModels
@testable import TokiAccounts

private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

@Test("fresh limits from B cannot populate A while the account list is reloading")
func foreignAccountOverlayIsUnavailable() {
    let raw = AccountPresentation.make(slot: slot(), active: true, limits: nil, stale: false)
    let values = limits(session: 0.99, weekly: 0.95)
    let foreign = UsageLimits(
        windows: values.windows, extra: nil, fetchedAt: t0,
        account: UsageAccount(accountUuid: "uuid-2", organizationUuid: nil)
    )
    let row = AccountPresentation.overlayingLiveActiveLimits([raw], live: foreign, liveIsFresh: true)[0]
    #expect(row.fiveHour == nil)
    #expect(row.weekly == nil)
    #expect(row.gaugesAreStale)
}

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

@Suite("AccountPresentation.overlayingLiveActiveLimits")
struct AccountPresentationOverlayTests {

    @Test("active row's gauges come from the live snapshot and are not stale")
    func activeRowTakesLiveGauges() {
        let stale = AccountPresentation.make(
            slot: slot(), active: true, limits: nil, stale: true
        )
        let live = limits(session: 0.71, weekly: 0.33)
        let overlaid = AccountPresentation.overlayingLiveActiveLimits(
            [stale], live: live, liveIsFresh: true
        )
        #expect(overlaid.count == 1)
        #expect(overlaid[0].fiveHour == 0.71)
        #expect(overlaid[0].weekly == 0.33)
        #expect(overlaid[0].gaugesAreStale == false)
    }

    @Test("active row's reset dates and scoped-model fields come from the live snapshot")
    func activeRowTakesResetsAndScopedModel() {
        let resetsSession = Date(timeIntervalSince1970: 1_700_001_000)
        let resetsWeekly = Date(timeIntervalSince1970: 1_700_002_000)
        let resetsScoped = Date(timeIntervalSince1970: 1_700_003_000)
        let live = UsageLimits(
            windows: [
                RateLimitWindow(
                    id: "session", title: "5-hour", utilization: 0.5, resetsAt: resetsSession,
                    isAvailable: true
                ),
                RateLimitWindow(
                    id: "weekly_all", title: "7-day", utilization: 0.6, resetsAt: resetsWeekly,
                    isAvailable: true
                ),
                RateLimitWindow(
                    id: "weekly_scoped:Fable", title: "Fable weekly", utilization: 0.4,
                    resetsAt: resetsScoped, isAvailable: true
                ),
            ],
            extra: nil, fetchedAt: t0
        )
        let row = AccountPresentation.make(slot: slot(), active: true, limits: nil, stale: true)
        let overlaid = AccountPresentation.overlayingLiveActiveLimits(
            [row], live: live, liveIsFresh: true
        )[0]
        #expect(overlaid.fiveHourResetsAt == resetsSession)
        #expect(overlaid.weeklyResetsAt == resetsWeekly)
        #expect(overlaid.scopedModel == 0.4)
        #expect(overlaid.scopedModelResetsAt == resetsScoped)
        #expect(overlaid.scopedModelLabel == "Fable")
    }

    @Test("nil live snapshot leaves the active row's gauges nil and stale")
    func nilLiveIsStale() {
        let row = AccountPresentation.make(
            slot: slot(), active: true, limits: limits(session: 0.9, weekly: 0.9), stale: false
        )
        let overlaid = AccountPresentation.overlayingLiveActiveLimits([row], live: nil)[0]
        #expect(overlaid.fiveHour == nil)
        #expect(overlaid.weekly == nil)
        #expect(overlaid.gaugesAreStale)
    }

    @Test("a sleeping row passes through unchanged")
    func sleepingRowUnchanged() {
        let row = AccountPresentation.make(
            slot: slot(), active: false, limits: limits(session: 0.2, weekly: 0.3), stale: true,
            staleReason: .network
        )
        let overlaid = AccountPresentation.overlayingLiveActiveLimits(
            [row], live: limits(session: 0.9, weekly: 0.9), liveIsFresh: true
        )[0]
        #expect(overlaid == row)
    }

    @Test("the active row's staleReason is cleared after overlay")
    func activeRowStaleReasonCleared() {
        let row = AccountPresentation.make(
            slot: slot(), active: true, limits: nil, stale: true, staleReason: .auth
        )
        let overlaid = AccountPresentation.overlayingLiveActiveLimits(
            [row], live: limits(session: 0.5, weekly: 0.5), liveIsFresh: true
        )[0]
        #expect(overlaid.staleReason == nil)
    }

    @Test("a stale live snapshot hides every usage field and preserves its failure reason")
    func staleLiveSnapshotIsNotDisplayed() {
        let reset = Date(timeIntervalSince1970: 1_700_001_000)
        let live = UsageLimits(
            windows: [
                RateLimitWindow(
                    id: "session", title: "5-hour", utilization: 0.99, resetsAt: reset,
                    isAvailable: true
                ),
                RateLimitWindow(
                    id: "weekly_all", title: "7-day", utilization: 0.88, resetsAt: reset,
                    isAvailable: true
                ),
                RateLimitWindow(
                    id: "weekly_scoped:Fable", title: "Fable weekly", utilization: 0.77,
                    resetsAt: reset, isAvailable: true
                ),
            ],
            extra: nil, fetchedAt: t0
        )
        let row = AccountPresentation.make(slot: slot(), active: true, limits: nil, stale: true)

        let overlaid = AccountPresentation.overlayingLiveActiveLimits(
            [row], live: live, liveIsFresh: false, liveStaleReason: .rateLimited
        )[0]

        #expect(overlaid.fiveHour == nil)
        #expect(overlaid.weekly == nil)
        #expect(overlaid.fiveHourResetsAt == nil)
        #expect(overlaid.weeklyResetsAt == nil)
        #expect(overlaid.scopedModel == nil)
        #expect(overlaid.scopedModelResetsAt == nil)
        #expect(overlaid.scopedModelLabel == nil)
        #expect(overlaid.gaugesAreStale)
        #expect(overlaid.staleReason == .rateLimited)
    }

    @Test("make surfaces the staleReason passed to it")
    func makeSurfacesStaleReason() {
        let row = AccountPresentation.make(
            slot: slot(), active: false, limits: nil, stale: true, staleReason: .rateLimited
        )
        #expect(row.staleReason == .rateLimited)
    }
}
