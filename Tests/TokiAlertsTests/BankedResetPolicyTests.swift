import Foundation
import Testing
@testable import TokiAlerts
import TokiModels

@Suite("BankedResetPolicy")
struct BankedResetPolicyTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func credit(
        _ id: String,
        grantedAt: Date,
        expiresAt: Date? = nil,
        status: String = "available"
    ) -> BankedResetCredit {
        BankedResetCredit(
            id: id,
            grantedAt: grantedAt,
            expiresAt: expiresAt,
            status: status,
            resetType: "codexRateLimits"
        )
    }

    private func resets(
        _ availableCount: Int,
        _ credits: [BankedResetCredit]? = nil
    ) -> BankedResets {
        BankedResets(availableCount: availableCount, credits: credits)
    }

    @Test("first positive observation reports existing availability once")
    func reportsInitialAvailabilityOnce() throws {
        var policy = BankedResetPolicy()
        let expiry = start.addingTimeInterval(3_600)
        let snapshot = resets(1, [credit("one", grantedAt: start, expiresAt: expiry)])

        let observed = policy.observe(snapshot, accountID: "a", fetchedAt: start)
        let notice = try #require(observed)
        #expect(notice.isInitial)
        #expect(notice.availableCount == 1)
        #expect(notice.expiresAt == expiry)
        #expect(policy.observe(
            snapshot,
            accountID: "a",
            fetchedAt: start.addingTimeInterval(90)
        ) == nil)
    }

    @Test("a first zero observation establishes a baseline without notifying")
    func zeroEstablishesBaseline() throws {
        var policy = BankedResetPolicy()

        #expect(policy.observe(resets(0), accountID: "a", fetchedAt: start) == nil)
        let observed = policy.observe(
            resets(1),
            accountID: "a",
            fetchedAt: start.addingTimeInterval(90)
        )
        let notice = try #require(observed)

        #expect(!notice.isInitial)
        #expect(notice.availableCount == 1)
    }

    @Test("each authoritative count increase supplies new issuance evidence")
    func reportsSuccessiveCountIncreases() throws {
        var policy = BankedResetPolicy()
        #expect(policy.observe(resets(0), accountID: "a", fetchedAt: start) == nil)

        let firstObserved = policy.observe(
            resets(1),
            accountID: "a",
            fetchedAt: start.addingTimeInterval(90)
        )
        let first = try #require(firstObserved)
        let secondObserved = policy.observe(
            resets(2),
            accountID: "a",
            fetchedAt: start.addingTimeInterval(180)
        )
        let second = try #require(secondObserved)

        #expect(!first.isInitial)
        #expect(first.availableCount == 1)
        #expect(!second.isInitial)
        #expect(second.availableCount == 2)
    }

    @Test("a newly granted available detail can notify while the count is unchanged")
    func reportsNewDetailAtSameCount() throws {
        var policy = BankedResetPolicy()
        let old = credit("old", grantedAt: start.addingTimeInterval(-3_600))
        _ = policy.observe(resets(1, [old]), accountID: "a", fetchedAt: start)

        let replacement = credit(
            "replacement",
            grantedAt: start.addingTimeInterval(60),
            expiresAt: start.addingTimeInterval(7_200)
        )
        let observed = policy.observe(
            resets(1, [replacement]),
            accountID: "a",
            fetchedAt: start.addingTimeInterval(90)
        )
        let notice = try #require(observed)

        #expect(!notice.isInitial)
        #expect(notice.availableCount == 1)
        #expect(notice.expiresAt == start.addingTimeInterval(7_200))
    }

    @Test("small server clock skew does not hide a newly revealed grant")
    func toleratesSmallGrantClockSkew() {
        var policy = BankedResetPolicy()
        _ = policy.observe(
            resets(1, [credit("old", grantedAt: start.addingTimeInterval(-3_600))]),
            accountID: "a",
            fetchedAt: start
        )

        let notice = policy.observe(
            resets(1, [credit("new", grantedAt: start.addingTimeInterval(-30))]),
            accountID: "a",
            fetchedAt: start.addingTimeInterval(90)
        )

        #expect(notice != nil)
        #expect(notice?.isInitial == false)
    }

    @Test("an old detail arriving late is remembered without being announced")
    func ignoresDelayedOldDetail() {
        var policy = BankedResetPolicy()
        _ = policy.observe(resets(1), accountID: "a", fetchedAt: start)

        let delayed = credit("delayed", grantedAt: start.addingTimeInterval(-3_600))
        #expect(policy.observe(
            resets(1, [delayed]),
            accountID: "a",
            fetchedAt: start.addingTimeInterval(90)
        ) == nil)
        #expect(policy.observe(
            resets(1, [delayed]),
            accountID: "a",
            fetchedAt: start.addingTimeInterval(180)
        ) == nil)
    }

    @Test("partial details do not replace the authoritative count")
    func usesCountWhenDetailsArePartial() throws {
        var policy = BankedResetPolicy()
        _ = policy.observe(resets(0), accountID: "a", fetchedAt: start)
        let expiry = start.addingTimeInterval(3_600)

        let observed = policy.observe(
            resets(2, [credit("known", grantedAt: start, expiresAt: expiry)]),
            accountID: "a",
            fetchedAt: start.addingTimeInterval(90)
        )
        let notice = try #require(observed)

        #expect(notice.availableCount == 2)
        #expect(notice.expiresAt == expiry)
    }

    @Test("details arriving after a count-only increase do not announce the same grant twice")
    func deduplicatesDelayedDetailsAfterCountEvidence() throws {
        var policy = BankedResetPolicy()
        _ = policy.observe(resets(0), accountID: "a", fetchedAt: start)
        let increaseAt = start.addingTimeInterval(90)

        let countNotice = policy.observe(
            resets(1),
            accountID: "a",
            fetchedAt: increaseAt
        )
        #expect(countNotice != nil)

        let revealed = credit(
            "revealed-later",
            grantedAt: increaseAt.addingTimeInterval(-30)
        )
        #expect(policy.observe(
            resets(1, [revealed]),
            accountID: "a",
            fetchedAt: increaseAt.addingTimeInterval(90)
        ) == nil)
    }

    @Test("an implausibly future grant timestamp does not announce a new issuance")
    func ignoresFutureGrantTimestamp() {
        var policy = BankedResetPolicy()
        _ = policy.observe(
            resets(1, [credit("old", grantedAt: start.addingTimeInterval(-3_600))]),
            accountID: "a",
            fetchedAt: start
        )
        let observedAt = start.addingTimeInterval(90)

        #expect(policy.observe(
            resets(1, [credit("future", grantedAt: observedAt.addingTimeInterval(3_600))]),
            accountID: "a",
            fetchedAt: observedAt
        ) == nil)
    }

    @Test("a known redemption does not discard deduplication for a surviving partial detail")
    func redemptionDoesNotTurnDelayedPartialDetailIntoIssuance() {
        var policy = BankedResetPolicy()
        let known = credit("known-a", grantedAt: start.addingTimeInterval(-3_600))
        #expect(policy.observe(
            resets(2, [known]),
            accountID: "a",
            fetchedAt: start
        )?.isInitial == true)

        let redeemed = credit(
            "known-a",
            grantedAt: start.addingTimeInterval(-3_600),
            status: "redeemed"
        )
        let surviving = credit("existing-b", grantedAt: start.addingTimeInterval(-30))

        #expect(policy.observe(
            resets(1, [redeemed, surviving]),
            accountID: "a",
            fetchedAt: start.addingTimeInterval(90)
        ) == nil)
    }

    @Test("a post-observation grant is new even after initial count-only availability")
    func postObservationReplacementAfterPartialSnapshotNotifies() {
        var policy = BankedResetPolicy()
        #expect(policy.observe(
            resets(1),
            accountID: "a",
            fetchedAt: start
        )?.isInitial == true)

        let replacement = credit("new-b", grantedAt: start.addingTimeInterval(60))
        let notice = policy.observe(
            resets(1, [replacement]),
            accountID: "a",
            fetchedAt: start.addingTimeInterval(90)
        )

        #expect(notice?.isInitial == false)
        #expect(notice?.availableCount == 1)
    }

    @Test("a nil observation does not advance the account baseline")
    func preservesBaselineAcrossUnknownGap() {
        var policy = BankedResetPolicy()
        _ = policy.observe(resets(1), accountID: "a", fetchedAt: start)
        #expect(policy.observe(
            nil,
            accountID: "a",
            fetchedAt: start.addingTimeInterval(600)
        ) == nil)

        let grantedDuringGap = credit("new", grantedAt: start.addingTimeInterval(300))
        let notice = policy.observe(
            resets(1, [grantedDuringGap]),
            accountID: "a",
            fetchedAt: start.addingTimeInterval(1_200)
        )

        #expect(notice?.isInitial == false)
    }

    @Test("account state is independent and survives Codable restoration")
    func separatesAccountsAndRestoresState() throws {
        var policy = BankedResetPolicy()
        #expect(policy.observe(resets(1), accountID: "a", fetchedAt: start)?.isInitial == true)
        #expect(policy.observe(resets(1), accountID: "b", fetchedAt: start)?.isInitial == true)

        let data = try JSONEncoder().encode(policy)
        var restored = try JSONDecoder().decode(BankedResetPolicy.self, from: data)

        #expect(restored.observe(
            resets(1),
            accountID: "a",
            fetchedAt: start.addingTimeInterval(90)
        ) == nil)
        #expect(restored.observe(
            resets(2),
            accountID: "a",
            fetchedAt: start.addingTimeInterval(180)
        )?.isInitial == false)
    }

    @Test("redeemed and expired detail rows neither trigger nor supply an expiry")
    func ignoresUnavailableDetails() throws {
        var policy = BankedResetPolicy()
        _ = policy.observe(resets(1), accountID: "a", fetchedAt: start)
        let observedAt = start.addingTimeInterval(90)

        #expect(policy.observe(
            resets(1, [
                credit("redeemed", grantedAt: start.addingTimeInterval(30), status: "redeemed"),
                credit(
                    "expired",
                    grantedAt: start.addingTimeInterval(30),
                    expiresAt: observedAt.addingTimeInterval(-1)
                ),
            ]),
            accountID: "a",
            fetchedAt: observedAt
        ) == nil)

        let later = observedAt.addingTimeInterval(90)
        let earliest = later.addingTimeInterval(600)
        let observed = policy.observe(
            resets(2, [
                credit("redeemed", grantedAt: start.addingTimeInterval(30), status: "redeemed"),
                credit("no-expiry", grantedAt: later, expiresAt: nil),
                credit("later", grantedAt: later, expiresAt: later.addingTimeInterval(1_200)),
                credit("earlier", grantedAt: later, expiresAt: earliest),
            ]),
            accountID: "a",
            fetchedAt: later
        )
        let notice = try #require(observed)

        #expect(notice.expiresAt == earliest)
    }

    @Test("an out-of-order snapshot is ignored without changing state")
    func ignoresOutOfOrderSnapshot() throws {
        var policy = BankedResetPolicy()
        _ = policy.observe(resets(0), accountID: "a", fetchedAt: start)

        #expect(policy.observe(
            resets(1),
            accountID: "a",
            fetchedAt: start.addingTimeInterval(-90)
        ) == nil)
        let observed = policy.observe(
            resets(1),
            accountID: "a",
            fetchedAt: start.addingTimeInterval(90)
        )
        let notice = try #require(observed)

        #expect(!notice.isInitial)
        #expect(notice.availableCount == 1)
    }

    @Test("missing account identity cannot establish notification state")
    func requiresAccountIdentity() {
        var policy = BankedResetPolicy()
        #expect(policy.observe(resets(1), accountID: nil, fetchedAt: start) == nil)
        #expect(policy.observe(resets(1), accountID: "", fetchedAt: start) == nil)
        #expect(policy.observe(resets(1), accountID: "a", fetchedAt: start)?.isInitial == true)
    }
}
