import Testing
import Foundation
import TokiModels
@testable import TokiAccounts

/// A percentage without a reset time is not actionable — 92% that clears in twenty minutes
/// and 92% that clears in four days call for opposite decisions. These cover the reset
/// dates reaching the account cards at all.
@Suite("AccountPresentation reset dates")
struct AccountPresentationResetTests {

    private let fiveHourReset = Date(timeIntervalSince1970: 1_700_010_000)
    private let weeklyReset = Date(timeIntervalSince1970: 1_700_600_000)

    private func limits() -> UsageLimits {
        UsageLimits(
            windows: [
                RateLimitWindow(
                    id: "session", title: "5-hour", utilization: 0.42,
                    resetsAt: fiveHourReset, isAvailable: true
                ),
                RateLimitWindow(
                    id: "weekly_all", title: "7-day", utilization: 0.71,
                    resetsAt: weeklyReset, isAvailable: true
                ),
            ],
            extra: nil,
            fetchedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func slot() -> AccountSlot {
        AccountSlot(
            identity: AccountIdentity(
                accountUuid: "acct", email: "a@example.com", displayName: nil,
                organizationName: nil, organizationUuid: nil
            ),
            alias: nil,
            credentialJSON: Data("{}".utf8),
            previousCredentialJSON: nil,
            lineage: "lin",
            addedAt: Date(timeIntervalSince1970: 1_699_000_000),
            lastActiveAt: nil,
            lastRefreshAt: nil,
            health: .ok
        )
    }

    @Test("a stored account carries both windows' reset dates")
    func storedAccountCarriesResetDates() {
        let row = AccountPresentation.make(
            slot: slot(), active: false, limits: limits(), stale: false
        )

        #expect(row.fiveHourResetsAt == fiveHourReset)
        #expect(row.weeklyResetsAt == weeklyReset)
    }

    @Test("no limits snapshot means no reset dates — unknown, not zero")
    func missingLimitsYieldNoDates() {
        let row = AccountPresentation.make(
            slot: slot(), active: false, limits: nil, stale: true
        )

        #expect(row.fiveHourResetsAt == nil)
        #expect(row.weeklyResetsAt == nil)
    }

    @Test("the signed-in-but-unsaved account carries them too")
    func liveUnstoredCarriesResetDates() {
        let row = AccountPresentation.makeLiveUnstored(
            identity: AccountIdentity(
                accountUuid: "live", email: "b@example.com", displayName: nil,
                organizationName: nil, organizationUuid: nil
            ),
            limits: limits(),
            stale: false
        )

        #expect(row.fiveHourResetsAt == fiveHourReset)
        #expect(row.weeklyResetsAt == weeklyReset)
    }

    @Test("the shared extractors read the same window ids as the utilization ones")
    func extractorsMatchWindowIds() {
        #expect(AccountPresentation.fiveHourResetsAt(from: limits()) == fiveHourReset)
        #expect(AccountPresentation.weeklyResetsAt(from: limits()) == weeklyReset)
        #expect(AccountPresentation.fiveHourResetsAt(from: nil) == nil)
        #expect(AccountPresentation.weeklyResetsAt(from: nil) == nil)
    }
}
