import Foundation
import TokiModels

/// One notification decision produced from an account-bound banked-reset snapshot.
public struct BankedResetNotice: Sendable {
    public let isInitial: Bool
    public let availableCount: Int
    public let expiresAt: Date?
}

/// Pure, persisted decision state for Codex banked-reset notifications.
public struct BankedResetPolicy: Codable, Sendable {
    private struct AccountState: Codable, Sendable {
        var availableCount: Int
        var seenIssuanceIDs: Set<String>
        var lastSuccessfulSnapshot: Date
        var detailsWereComplete: Bool

        init(
            availableCount: Int,
            seenIssuanceIDs: Set<String>,
            lastSuccessfulSnapshot: Date,
            detailsWereComplete: Bool = false
        ) {
            self.availableCount = availableCount
            self.seenIssuanceIDs = seenIssuanceIDs
            self.lastSuccessfulSnapshot = lastSuccessfulSnapshot
            self.detailsWereComplete = detailsWereComplete
        }

        private enum CodingKeys: String, CodingKey {
            case availableCount
            case seenIssuanceIDs
            case lastSuccessfulSnapshot
            case detailsWereComplete
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            availableCount = try container.decode(Int.self, forKey: .availableCount)
            seenIssuanceIDs = try container.decode(Set<String>.self, forKey: .seenIssuanceIDs)
            lastSuccessfulSnapshot = try container.decode(
                Date.self,
                forKey: .lastSuccessfulSnapshot
            )
            detailsWereComplete = try container.decodeIfPresent(
                Bool.self,
                forKey: .detailsWereComplete
            ) ?? false
        }
    }

    /// The usage poll is normally 90 seconds. This margin absorbs a small difference between
    /// the backend grant clock and the local fetch clock without admitting genuinely old rows
    /// that merely appeared after a previously partial detail list.
    private static let grantClockTolerance: TimeInterval = 120

    private var accounts: [String: AccountState] = [:]

    public init() {}

    public mutating func observe(
        _ resets: BankedResets?,
        accountID: String?,
        fetchedAt: Date
    ) -> BankedResetNotice? {
        guard let resets,
              resets.availableCount >= 0,
              let accountID,
              !accountID.isEmpty else {
            return nil
        }

        let allDetails = resets.credits ?? []
        let eligibleDetails = allDetails.filter { credit in
            guard credit.status == "available" else { return false }
            guard let expiresAt = credit.expiresAt else { return true }
            return expiresAt > fetchedAt
        }
        let expiry = eligibleDetails.compactMap(\.expiresAt).min()
        let detailsAreComplete = eligibleDetails.count >= resets.availableCount

        guard var state = accounts[accountID] else {
            accounts[accountID] = AccountState(
                availableCount: resets.availableCount,
                seenIssuanceIDs: Set(allDetails.map(\.id)),
                lastSuccessfulSnapshot: fetchedAt,
                detailsWereComplete: detailsAreComplete
            )
            guard resets.availableCount > 0 else { return nil }
            return BankedResetNotice(
                isInitial: true,
                availableCount: resets.availableCount,
                expiresAt: expiry
            )
        }

        guard fetchedAt >= state.lastSuccessfulSnapshot else { return nil }

        let precedingObservation = state.lastSuccessfulSnapshot
        let countIncreased = resets.availableCount > state.availableCount
        // A backward clock allowance is only safe after a complete detail snapshot. When
        // details were partial, an unseen pre-observation ID may simply be an old row that
        // has finally appeared, so strict chronology avoids announcing it as a new grant.
        let oldestPlausibleGrant = state.detailsWereComplete
            ? precedingObservation.addingTimeInterval(-Self.grantClockTolerance)
            : precedingObservation
        let latestPlausibleGrant = fetchedAt.addingTimeInterval(Self.grantClockTolerance)
        let hasIndependentIssuanceDetail = resets.availableCount > 0 && eligibleDetails.contains { credit in
            !state.seenIssuanceIDs.contains(credit.id)
                && credit.grantedAt > oldestPlausibleGrant
                && credit.grantedAt <= latestPlausibleGrant
        }

        state.availableCount = resets.availableCount
        state.seenIssuanceIDs.formUnion(allDetails.map(\.id))
        state.lastSuccessfulSnapshot = fetchedAt
        state.detailsWereComplete = detailsAreComplete
        accounts[accountID] = state

        guard resets.availableCount > 0,
              countIncreased || hasIndependentIssuanceDetail else {
            return nil
        }
        return BankedResetNotice(
            isInitial: false,
            availableCount: resets.availableCount,
            expiresAt: expiry
        )
    }

    private enum CodingKeys: String, CodingKey {
        case accounts
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accounts = try container.decodeIfPresent(
            [String: AccountState].self,
            forKey: .accounts
        ) ?? [:]
    }
}
