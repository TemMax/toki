import Testing
import Foundation
import TokiModels
@testable import TokiAccounts

/// The usage API reports a per-model weekly window (currently Fable) alongside the session
/// and all-model ones. It is carried by model *name*, not hardcoded: the scoped model has
/// already changed once (Opus, Sonnet) and a hardcoded id would silently empty the gauge
/// the next time it changes.
@Suite("AccountPresentation scoped-model window")
struct AccountPresentationScopedModelTests {

    private let scopedReset = Date(timeIntervalSince1970: 1_700_600_000)

    private func limits(scopedModel: String?) -> UsageLimits {
        var windows = [
            RateLimitWindow(
                id: "session", title: "5-hour", utilization: 0.2,
                resetsAt: Date(timeIntervalSince1970: 1_700_010_000), isAvailable: true
            ),
            RateLimitWindow(
                id: "weekly_all", title: "7-day", utilization: 0.64,
                resetsAt: Date(timeIntervalSince1970: 1_700_500_000), isAvailable: true
            ),
        ]
        if let scopedModel {
            windows.append(
                RateLimitWindow(
                    id: "weekly_scoped:\(scopedModel)", title: "7-day \(scopedModel)",
                    utilization: 1.0, resetsAt: scopedReset, isAvailable: true
                )
            )
        }
        return UsageLimits(
            windows: windows, extra: nil, fetchedAt: Date(timeIntervalSince1970: 1_700_000_000)
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

    @Test("the scoped window is carried with the model's own name, whatever it is")
    func carriesScopedWindowByModelName() {
        let row = AccountPresentation.make(
            slot: slot(), active: false, limits: limits(scopedModel: "Fable"), stale: false
        )

        #expect(row.scopedModelLabel == "Fable")
        #expect(row.scopedModel == 1.0)
        #expect(row.scopedModelResetsAt == scopedReset)
    }

    @Test("a differently named scoped model is carried just as well")
    func worksForAnyModelName() {
        let row = AccountPresentation.make(
            slot: slot(), active: false, limits: limits(scopedModel: "Opus"), stale: false
        )

        #expect(row.scopedModelLabel == "Opus")
        #expect(row.scopedModel == 1.0)
    }

    @Test("no scoped window means no gauge — nothing is invented")
    func absentScopedWindowYieldsNil() {
        let row = AccountPresentation.make(
            slot: slot(), active: false, limits: limits(scopedModel: nil), stale: false
        )

        #expect(row.scopedModelLabel == nil)
        #expect(row.scopedModel == nil)
        #expect(row.scopedModelResetsAt == nil)
    }

    @Test("the signed-in-but-unsaved account carries it too")
    func liveUnstoredCarriesScopedWindow() {
        let row = AccountPresentation.makeLiveUnstored(
            identity: AccountIdentity(
                accountUuid: "live", email: "b@example.com", displayName: nil,
                organizationName: nil, organizationUuid: nil
            ),
            limits: limits(scopedModel: "Fable"),
            stale: false
        )

        #expect(row.scopedModelLabel == "Fable")
        #expect(row.scopedModel == 1.0)
    }

    @Test("the shared extractor finds the window regardless of its position")
    func extractorIsPositionIndependent() {
        let reordered = UsageLimits(
            windows: [
                RateLimitWindow(
                    id: "weekly_scoped:Fable", title: "7-day Fable", utilization: 0.5,
                    resetsAt: scopedReset, isAvailable: true
                ),
                RateLimitWindow(
                    id: "session", title: "5-hour", utilization: 0.2,
                    resetsAt: nil, isAvailable: true
                ),
            ],
            extra: nil, fetchedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        #expect(AccountPresentation.scopedModelWindow(from: reordered)?.utilization == 0.5)
        #expect(AccountPresentation.scopedModelWindow(from: nil) == nil)
    }
}
