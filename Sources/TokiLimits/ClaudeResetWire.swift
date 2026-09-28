import Foundation
import TokiModels

/// Decodes Claude's optional `cedar_ember` block independently from the ordinary usage
/// payload. Any reset-only schema problem therefore degrades to unknown reset state without
/// discarding rate-limit windows or extra-spend data.
enum ClaudeResetWire {
    static func decode(from data: Data) -> ClaudeResetStatus? {
        // no-log: optional reset-only decoding deliberately degrades schema failures to unknown reset state.
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              let status = envelope.status
        else {
            return nil
        }
        return status.toDomain()
    }
}

private extension ClaudeResetWire {
    struct Envelope: Decodable {
        let status: Status?

        enum CodingKeys: String, CodingKey {
            case status = "cedar_ember"
        }
    }

    struct Status: Decodable {
        let eligible: Bool
        let ineligibleReason: String?
        let atLimit: Bool?
        let exhausted: [String]
        let grants: [Failable<Grant>]?
        let nextGrantID: String?
        let weeklyResetsAt: String?
        let cooldownUntil: String?

        enum CodingKeys: String, CodingKey {
            case eligible
            case ineligibleReason = "ineligible_reason"
            case atLimit = "at_limit"
            case exhausted
            case grants
            case nextGrantID = "next_grant_id"
            case weeklyResetsAt = "weekly_resets_at"
            case cooldownUntil = "cooldown_until"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            eligible = try container.decode(Bool.self, forKey: .eligible)
            ineligibleReason = try container.decodeIfPresent(String.self, forKey: .ineligibleReason)
            atLimit = container.contains(.atLimit)
                ? try container.decode(Bool.self, forKey: .atLimit)
                : nil
            exhausted = container.contains(.exhausted)
                ? try container.decode([String].self, forKey: .exhausted)
                : []
            grants = container.contains(.grants)
                ? try container.decode([Failable<Grant>].self, forKey: .grants)
                : nil
            nextGrantID = try container.decodeIfPresent(String.self, forKey: .nextGrantID)
            weeklyResetsAt = try container.decodeIfPresent(String.self, forKey: .weeklyResetsAt)
            cooldownUntil = try container.decodeIfPresent(String.self, forKey: .cooldownUntil)
        }

        func toDomain() -> ClaudeResetStatus? {
            let weeklyDate: Date?
            if let weeklyResetsAt {
                guard let parsed = parseWireDate(weeklyResetsAt) else { return nil }
                weeklyDate = parsed
            } else {
                weeklyDate = nil
            }

            let cooldownDate: Date?
            if let cooldownUntil {
                guard let parsed = parseWireDate(cooldownUntil) else { return nil }
                cooldownDate = parsed
            } else {
                cooldownDate = nil
            }

            var mappedGrants: [ClaudeResetGrant]?
            if let grants {
                var mapped: [ClaudeResetGrant] = []
                var seenIDs: Set<String> = []
                var total = 0

                for decoded in grants {
                    guard let candidate = decoded.value,
                          candidate.hasValidID,
                          candidate.resetsTotal >= 0,
                          candidate.resetsLeft >= 0
                    else {
                        return nil
                    }

                    let startsAt: Date?
                    if let value = candidate.startsAt {
                        guard let parsed = parseWireDate(value) else { return nil }
                        startsAt = parsed
                    } else {
                        startsAt = nil
                    }

                    let endsAt: Date?
                    if let value = candidate.endsAt {
                        guard let parsed = parseWireDate(value) else { return nil }
                        endsAt = parsed
                    } else {
                        endsAt = nil
                    }

                    guard seenIDs.insert(candidate.id).inserted else { return nil }
                    let sum = total.addingReportingOverflow(candidate.resetsLeft)
                    guard !sum.overflow else { return nil }
                    total = sum.partialValue

                    mapped.append(ClaudeResetGrant(
                        id: candidate.id,
                        label: candidate.label,
                        resetsTotal: candidate.resetsTotal,
                        resetsLeft: candidate.resetsLeft,
                        startsAt: startsAt,
                        endsAt: endsAt,
                        clears: candidate.clears,
                        paused: candidate.paused,
                        usableNow: candidate.usableNow,
                        useRequiresLimit: candidate.useRequiresLimit,
                        blocking: candidate.blocking
                    ))
                }
                mappedGrants = mapped
            } else {
                mappedGrants = nil
            }

            let matchedNextGrantID = nextGrantID.flatMap { candidate in
                mappedGrants?.contains(where: { $0.id == candidate }) == true ? candidate : nil
            }

            return ClaudeResetStatus(
                eligible: eligible,
                ineligibleReason: ineligibleReason,
                atLimit: atLimit,
                exhausted: exhausted,
                grants: mappedGrants,
                nextGrantID: matchedNextGrantID,
                weeklyResetsAt: weeklyDate,
                cooldownUntil: cooldownDate
            )
        }
    }

    struct Grant: Decodable {
        let id: String
        let label: String
        let resetsTotal: Int
        let resetsLeft: Int
        let startsAt: String?
        let endsAt: String?
        let clears: [String]
        let paused: Bool
        let usableNow: Bool
        let useRequiresLimit: Bool
        let blocking: [String]

        enum CodingKeys: String, CodingKey {
            case id
            case label
            case resetsTotal = "resets_total"
            case resetsLeft = "resets_left"
            case startsAt = "starts_at"
            case endsAt = "ends_at"
            case clears
            case paused
            case usableNow = "usable_now"
            case useRequiresLimit = "use_requires_limit"
            case blocking
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            label = container.contains(.label)
                ? try container.decode(String.self, forKey: .label)
                : ""
            resetsTotal = container.contains(.resetsTotal)
                ? try container.decode(Int.self, forKey: .resetsTotal)
                : 0
            resetsLeft = try container.decode(Int.self, forKey: .resetsLeft)
            startsAt = try container.decodeIfPresent(String.self, forKey: .startsAt)
            endsAt = try container.decodeIfPresent(String.self, forKey: .endsAt)
            clears = container.contains(.clears)
                ? try container.decode([String].self, forKey: .clears)
                : []
            paused = container.contains(.paused)
                ? try container.decode(Bool.self, forKey: .paused)
                : false
            usableNow = container.contains(.usableNow)
                ? try container.decode(Bool.self, forKey: .usableNow)
                : false
            useRequiresLimit = container.contains(.useRequiresLimit)
                ? try container.decode(Bool.self, forKey: .useRequiresLimit)
                : true
            blocking = container.contains(.blocking)
                ? try container.decode([String].self, forKey: .blocking)
                : []
        }

        var hasValidID: Bool {
            id.range(of: #"^[a-z0-9_-]{1,40}$"#, options: .regularExpression) != nil
        }
    }

    struct Failable<Value: Decodable>: Decodable {
        let value: Value?

        init(from decoder: Decoder) throws {
            // no-log: malformed optional reset grants deliberately degrade to unknown reset state.
            value = try? Value(from: decoder)
        }
    }

    static func parseWireDate(_ string: String) -> Date? {
        // no-log: alternate date parse attempts are normal; invalid optional reset dates degrade to unknown reset state.
        if let date = try? Date(
            string,
            strategy: .iso8601.year().month().day()
                .time(includingFractionalSeconds: true).timeZone(separator: .colon)
        ) {
            return date
        }
        // no-log: alternate date parse attempts are normal; invalid optional reset dates degrade to unknown reset state.
        return try? Date(
            string,
            strategy: .iso8601.year().month().day()
                .time(includingFractionalSeconds: false).timeZone(separator: .colon)
        )
    }
}
