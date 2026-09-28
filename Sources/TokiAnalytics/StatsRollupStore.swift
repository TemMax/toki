/// Persistent, incrementally-updated store for `StatsRollup` — the durable data behind the
/// Statistics feature. Mirrors `Sources/TokiLimits/LimitsCache.swift`'s atomic-file pattern:
/// an actor (not a plain struct, since `merge` does real aggregation work worth isolating)
/// backed by a single JSON file, corrupt/foreign contents degrade to `.empty` rather than
/// throwing, and writes are atomic so a crash mid-write can never leave a torn file.
import Foundation
import TokiModels
import TokiLogging

private let log = TokiLog.logger("analytics")

public actor StatsRollupStore {

    // MARK: Properties

    private let fileURL: URL
    private let calendar: Calendar

    // MARK: Init

    /// Creates a store backed by `fileURL`, or the default location
    /// `~/Library/Application Support/Toki/stats-rollup.json` when nil.
    /// `calendar` decides the local day/hour bucketing for every `merge` call.
    public init(fileURL: URL? = nil, calendar: Calendar = .current) {
        let url = fileURL ?? Self.defaultFileURL()
        self.fileURL = url
        self.calendar = calendar
        // Best-effort directory creation — load()/merge() tolerate its absence.
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            log.error("stats rollup directory creation failed \(error: error)")
        }
    }

    private static func defaultFileURL() -> URL {
        AppSupportDirectory.url.appendingPathComponent("stats-rollup.json")
    }

    // MARK: Public API

    /// Decodes the current rollup, or `.empty` when the file is missing, unreadable, holds
    /// invalid JSON, or has a `schemaVersion` this build does not understand. Never throws.
    ///
    /// When the file exists but fails to decode/has a foreign schema, it is quarantined
    /// (renamed aside to `<name>.corrupt`, best-effort, overwriting any older quarantine)
    /// rather than silently discarded — a single corrupt byte must never destroy the
    /// accumulated history this rollup exists to preserve; `.empty` is only ever the return
    /// value here, never what gets written back over the original bytes.
    public func load() -> StatsRollup {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            // Routine: no rollup file yet (first launch) reads as a missing-file error
            // every time.
            log.debug("stats rollup read miss \(error: error)")
            return .empty
        }
        let decoded: StatsRollup
        do {
            decoded = try JSONDecoder().decode(StatsRollup.self, from: data)
        } catch {
            log.error("stats rollup decode failed, quarantining \(error: error)")
            quarantineCorruptFile()
            return .empty
        }
        guard (1...StatsRollup.currentSchemaVersion).contains(decoded.schemaVersion) else {
            log.notice("stats rollup has an unsupported schema version \(decoded.schemaVersion), quarantining")
            quarantineCorruptFile()
            return .empty
        }
        return decoded
    }

    /// Best-effort: renames the unreadable/foreign-schema file aside so its bytes survive for
    /// inspection instead of being clobbered by the next atomic write. Failures here (e.g. no
    /// write permission) are swallowed — quarantining is a nicety, not a correctness
    /// requirement, and must never make `load()`/`merge()` throw.
    private func quarantineCorruptFile() {
        let corruptURL = URL(fileURLWithPath: fileURL.path + ".corrupt")
        // no-log: removing a stale quarantine file that may not exist yet is expected and
        // not actionable — the move below is what actually matters for preserving the
        // corrupt bytes, and its own failure is logged.
        try? FileManager.default.removeItem(at: corruptURL)
        do {
            try FileManager.default.moveItem(at: fileURL, to: corruptURL)
        } catch {
            log.error("failed to quarantine corrupt stats rollup, corrupt bytes may be lost \(error: error)")
        }
    }

    /// Aggregates `records` into per-local-day/-hour buckets and merges them into the
    /// persisted rollup, then writes the result back atomically and returns it.
    ///
    /// Per-day merge is monotonic and whole-record: a freshly aggregated day only replaces
    /// what's stored when its `totalTokens` is greater-or-equal, and when it does, it
    /// replaces the *entire* stored `RollupDay` (never mixes fields from old and new) — this
    /// is what makes re-merging the same transcript window idempotent, and keeps a stale,
    /// smaller re-scan (e.g. after transcript cleanup) from clobbering a bigger prior result.
    /// Days present in the store but absent from `records` are left untouched; nothing is
    /// ever deleted here.
    ///
    /// A rollup written under an older schema (`needsFullRecompute`) is the exception: its
    /// days hold a different token definition, so a freshly aggregated day replaces the stored
    /// one unconditionally, and the result is stamped with the current version. The caller
    /// passes the full record history for that merge; days it has no records for keep their
    /// old values.
    @discardableResult
    public func merge(records: [TranscriptRecord]) throws -> StatsRollup {
        var rollup = load()
        let recompute = rollup.needsFullRecompute
        let dayFormatter = Self.dayFormatter(calendar: calendar)

        var fresh: [String: RollupDay] = [:]
        // Formatting the day key and extracting the hour both walk the calendar's time-zone
        // rules — ~2 µs a record, most of a 45-day merge. Records arrive ordered by
        // timestamp, so both are recomputed only when a day / hour boundary is crossed; the
        // cached intervals are the calendar's own, so this stays exact across DST changes.
        // Unordered input is still correct, just slower.
        var currentDay: (interval: DateInterval, key: String)?
        var currentHour: (interval: DateInterval, hour: Int)?
        for record in records {
            let timestamp = record.timestamp
            let key: String
            if let day = currentDay, day.interval.containsHalfOpen(timestamp) {
                key = day.key
            } else {
                key = dayFormatter.string(from: timestamp)
                currentDay = calendar.dateInterval(of: .day, for: timestamp).map { ($0, key) }
            }
            let hour: Int
            if let cached = currentHour, cached.interval.containsHalfOpen(timestamp) {
                hour = cached.hour
            } else {
                hour = calendar.component(.hour, from: timestamp)
                currentHour = calendar.dateInterval(of: .hour, for: timestamp).map { ($0, hour) }
            }
            fresh[key, default: RollupDay(day: key, tokensByHour: Array(repeating: 0, count: 24), requests: 0)]
                .add(tokens: record.usage.processedTokens, hour: hour)
        }

        for (key, freshDay) in fresh {
            if !recompute, let existing = rollup.days[key], existing.totalTokens > freshDay.totalTokens {
                continue
            }
            rollup.days[key] = freshDay
        }
        rollup.schemaVersion = StatsRollup.currentSchemaVersion

        let data = try JSONEncoder().encode(rollup)
        try data.write(to: fileURL, options: .atomic)
        return rollup
    }

    // MARK: Private

    /// "yyyy-MM-dd" in `en_US_POSIX`, with `calendar`'s own calendar identifier and time
    /// zone — this is the one true definition of "which local day a timestamp belongs to"
    /// for both writing (here) and reading back (`StatsHistory` parses these same keys).
    private static func dayFormatter(calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        return formatter
    }
}

private extension RollupDay {
    mutating func add(tokens: Int, hour: Int) {
        tokensByHour[hour] += tokens
        requests += 1
    }
}
