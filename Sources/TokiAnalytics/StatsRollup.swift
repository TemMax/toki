/// Persisted, pre-aggregated usage data for the Statistics feature: one `RollupDay` per
/// local calendar day, keyed by the same day string it stores. This is the durable
/// on-disk shape `StatsRollupStore` reads/writes; `StatsHistory` derives all display data
/// (heatmap, punchcard, streaks) from it at query time. Cost is never stored here (D3) —
/// only raw token/request counts, which is all the frozen semantics need.
import Foundation

// MARK: - RollupDay

/// One local calendar day's rolled-up usage: 24 hourly token buckets plus a request count.
public struct RollupDay: Sendable, Codable, Equatable {
    /// "yyyy-MM-dd" local-calendar day key (see `StatsRollupStore`'s day formatter).
    public let day: String
    /// Exactly 24 entries: processed tokens per local hour (index 0 = hour 0) — see
    /// `StatsRollup.currentSchemaVersion`.
    public var tokensByHour: [Int]
    public var requests: Int

    /// Computed, not stored — decoded JSON never carries a redundant total to drift out of sync.
    public var totalTokens: Int { tokensByHour.reduce(0, +) }

    /// Normalizes any `tokensByHour` length (e.g. a caller-supplied array, or hand-edited/
    /// foreign JSON) to exactly 24 entries so every hour-indexed read elsewhere — decoded or
    /// constructed directly — can never desync/trap. Shared by this memberwise init and
    /// `init(from:)` below, which is the only reason this initializer isn't the trivial
    /// compiler-synthesized one.
    public init(day: String, tokensByHour: [Int], requests: Int) {
        self.day = day
        self.tokensByHour = Self.normalized(tokensByHour)
        self.requests = requests
    }

    private static func normalized(_ hours: [Int]) -> [Int] {
        if hours.count > 24 {
            return Array(hours.prefix(24))
        } else if hours.count < 24 {
            return hours + repeatElement(0, count: 24 - hours.count)
        }
        return hours
    }

    private enum CodingKeys: String, CodingKey {
        case day, tokensByHour, requests
    }

    /// Custom decode so a corrupt/foreign `tokensByHour` length (e.g. hand-edited JSON, or a
    /// future schema with a different bucket count) can never desync hour-indexed reads
    /// elsewhere — it is always normalized to exactly 24 entries here, once, at the boundary.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        day = try container.decode(String.self, forKey: .day)
        requests = try container.decode(Int.self, forKey: .requests)
        tokensByHour = Self.normalized(try container.decode([Int].self, forKey: .tokensByHour))
    }
}

// MARK: - StatsRollup

/// The full persisted rollup: every known day, keyed by its own `day` string.
public struct StatsRollup: Sendable, Codable, Equatable {
    public var schemaVersion: Int
    /// Invariant: `days[key]!.day == key` for every entry — maintained by `StatsRollupStore`.
    public var days: [String: RollupDay]

    public init(schemaVersion: Int, days: [String: RollupDay]) {
        self.schemaVersion = schemaVersion
        self.days = days
    }

    /// 2: `tokensByHour` counts `TokenUsage.processedTokens` (uncached input + cache writes +
    /// output). 1 counted input + output only, which left out Claude's new context (reported
    /// as cache writes) while counting Codex's (reported as input) — so days did not compare.
    public static let currentSchemaVersion = 2

    public static let empty = StatsRollup(schemaVersion: currentSchemaVersion, days: [:])

    /// Written under an older token definition: the next merge must recompute every day it
    /// can from the full record history instead of topping up the recent window.
    public var needsFullRecompute: Bool { schemaVersion < Self.currentSchemaVersion }
}
