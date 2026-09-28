/// RateHistoryStore — append-only local history of pricing rate periods, persisted as JSON.
import Foundation
import TokiModels
import TokiLogging

private let log = TokiLog.logger("pricing")

// MARK: - RateHistoryStore

/// Holds the in-memory and on-disk record of every `RatePeriod` Toki knows about,
/// grouped by `modelPrefix`. Merges are fetch-time-aware: when a model's current rate
/// changes by the merge's `now`, the open historical period is closed at `now` and a
/// new open period is appended — so the past stays frozen and only usage from the
/// change onward re-prices. Periods are never deleted, so historical cost lookups
/// always find the rate that was active on a given date even after later merges.
///
/// `NSLock`-guarded rather than an actor so callers (including `LivePricingTable`,
/// which must answer `pricing(for:on:)` synchronously) can read without `await`.
/// Marked `@unchecked Sendable` because the lock — not the compiler — guarantees
/// exclusive access to the mutable `periods` array.
public final class RateHistoryStore: @unchecked Sendable {

    // MARK: Properties

    private let lock = NSLock()
    private var periods: [RatePeriod]
    /// Bumped on every mutation. Readers that cache anything derived from `periods`
    /// (see `LivePricingTable`) compare this instead of re-deriving per lookup.
    private var generation: UInt64 = 0
    private let fileURL: URL

    /// Default location: `~/Library/Application Support/Toki/pricing-history.json`.
    public static var defaultFileURL: URL {
        AppSupportDirectory.url.appendingPathComponent("pricing-history.json")
    }

    // MARK: Init

    /// Creates a store backed by `fileURL`. If a valid JSON history already exists
    /// at that location, the on-disk periods are taken as authoritative and only
    /// `seed` periods whose `modelPrefix` the disk has never seen are added (a
    /// prefix-level union with disk winning). Otherwise the store starts from `seed`
    /// alone and persists it immediately, so the file always reflects current state.
    ///
    /// The exception is `seedOwnedPrefixes` the seed carries: nothing refreshes those
    /// from a live source, so what is on disk is only an older build's seed — the current
    /// seed replaces it outright. Without this a corrected bundled rate never reached an
    /// install that had already persisted the old one.
    public init(
        fileURL: URL = RateHistoryStore.defaultFileURL,
        seed: [RatePeriod] = BundledRates.seed,
        seedOwnedPrefixes: Set<String> = BundledRates.bundledOnlyPrefixes
    ) {
        self.fileURL = fileURL
        // Best-effort directory creation — load()/persist() handle absence gracefully.
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            log.error("rate history directory creation failed \(error: error)")
        }

        if let onDisk = Self.load(from: fileURL), !onDisk.isEmpty {
            // Prefix-level union, disk winning: keep every on-disk period, and add
            // only the seed periods for prefixes the disk has never recorded —
            // except seed-owned prefixes, where the seed replaces the disk.
            let owned = seedOwnedPrefixes.intersection(seed.map(\.modelPrefix))
            let kept = onDisk.filter { !owned.contains($0.modelPrefix) }
            let keptPrefixes = Set(kept.map(\.modelPrefix))
            self.periods = kept + seed.filter { !keptPrefixes.contains($0.modelPrefix) }
            if self.periods != onDisk { persist() }
        } else {
            self.periods = seed
            persist()
        }
    }

    // MARK: Public API

    /// Returns a snapshot copy of every rate period currently known.
    public func all() -> [RatePeriod] {
        lock.lock()
        defer { lock.unlock() }
        return periods
    }

    /// The current periods together with the generation they belong to, read under one
    /// lock so a cache can never store rates from one generation under another's number.
    public func snapshot() -> (periods: [RatePeriod], generation: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        return (periods, generation)
    }

    /// Fetch-time-aware merge of `incoming` into the history, as of `now`.
    ///
    /// For each `modelPrefix` present in `incoming`:
    /// - The representative incoming rate at `now` is computed. If a brand-new prefix,
    ///   all its incoming periods are appended verbatim.
    /// - If the stored current rate already equals the incoming current rate, no
    ///   transition is stamped (idempotent).
    /// - Otherwise the past is frozen: the open stored period is closed at `now`
    ///   (replaced by a copy with `effectiveUntil == now`) and a new open period with
    ///   the incoming rate and `effectiveFrom == now` is appended.
    /// - Future-dated incoming periods (`effectiveFrom > now`) are scheduled if an
    ///   identical `(effectiveFrom, effectiveUntil)` window isn't already stored.
    ///
    /// Periods are never deleted; the total count never shrinks. Persists the result
    /// to disk and returns the full, post-merge history. Never throws.
    @discardableResult
    public func merge(_ incoming: [RatePeriod], asOf now: Date = Date()) -> [RatePeriod] {
        lock.lock()
        periods = Self.mergePeriods(incoming, into: periods, asOf: now)
        generation &+= 1
        let snapshot = periods
        lock.unlock()
        persist(snapshot)
        return snapshot
    }

    // MARK: Merge helper

    /// Pure, fetch-time-aware merge. See `merge(_:asOf:)` for the algorithm.
    private static func mergePeriods(
        _ incoming: [RatePeriod],
        into base: [RatePeriod],
        asOf now: Date
    ) -> [RatePeriod] {
        var result = base

        // Distinct incoming prefixes, in first-seen order, to keep output deterministic.
        var incomingPrefixes: [String] = []
        var seenPrefix = Set<String>()
        for period in incoming where seenPrefix.insert(period.modelPrefix).inserted {
            incomingPrefixes.append(period.modelPrefix)
        }

        for prefix in incomingPrefixes {
            let incomingForPrefix = incoming.filter { $0.modelPrefix == prefix }
            guard let incomingActive = RatePeriod.representative(in: incomingForPrefix, on: now) else {
                continue
            }

            let storedForPrefix = result.filter { $0.modelPrefix == prefix }

            // Brand-new model: append every incoming period for this prefix verbatim.
            if storedForPrefix.isEmpty {
                result.append(contentsOf: incomingForPrefix)
                continue
            }

            let storedActive = RatePeriod.representative(in: storedForPrefix, on: now)

            if let storedActive, storedActive.hasSameRates(as: incomingActive) {
                // Current rate unchanged — do not stamp a transition (idempotent).
            } else {
                // Rate changed by `now`: freeze the past and open a new current period.
                if let storedActive,
                   storedActive.effectiveUntil == nil || storedActive.effectiveUntil! > now {
                    // Close the still-open stored period in place at `now`.
                    if let index = result.firstIndex(of: storedActive) {
                        result[index] = Self.closed(storedActive, at: now)
                    }
                }
                result.append(
                    RatePeriod(
                        modelPrefix: prefix,
                        inputPerMTok: incomingActive.inputPerMTok,
                        outputPerMTok: incomingActive.outputPerMTok,
                        cacheWrite5mPerMTok: incomingActive.cacheWrite5mPerMTok,
                        cacheWrite1hPerMTok: incomingActive.cacheWrite1hPerMTok,
                        cacheReadPerMTok: incomingActive.cacheReadPerMTok,
                        longContextThresholdTokens: incomingActive.longContextThresholdTokens,
                        longContextInputMultiplier: incomingActive.longContextInputMultiplier,
                        longContextOutputMultiplier: incomingActive.longContextOutputMultiplier,
                        effectiveFrom: now,
                        effectiveUntil: incomingActive.effectiveUntil
                    )
                )
            }

            // Future-dated step: schedule pre-announced changes, idempotently.
            for period in incomingForPrefix {
                guard let from = period.effectiveFrom, from > now else { continue }
                let alreadyStored = result.contains { stored in
                    stored.modelPrefix == prefix
                        && stored.effectiveFrom == period.effectiveFrom
                        && stored.effectiveUntil == period.effectiveUntil
                }
                if !alreadyStored {
                    result.append(period)
                }
            }
        }

        return result
    }

    /// Returns a copy of `period` closed at `now` — identical except `effectiveUntil`.
    private static func closed(_ period: RatePeriod, at now: Date) -> RatePeriod {
        RatePeriod(
            modelPrefix: period.modelPrefix,
            inputPerMTok: period.inputPerMTok,
            outputPerMTok: period.outputPerMTok,
            cacheWrite5mPerMTok: period.cacheWrite5mPerMTok,
            cacheWrite1hPerMTok: period.cacheWrite1hPerMTok,
            cacheReadPerMTok: period.cacheReadPerMTok,
            longContextThresholdTokens: period.longContextThresholdTokens,
            longContextInputMultiplier: period.longContextInputMultiplier,
            longContextOutputMultiplier: period.longContextOutputMultiplier,
            effectiveFrom: period.effectiveFrom,
            effectiveUntil: now
        )
    }

    // MARK: Persistence

    private static func load(from fileURL: URL) -> [RatePeriod]? {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            // Routine: no history file yet (first launch) reads as a missing-file error
            // every time.
            log.debug("rate history read miss \(error: error)")
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode([RatePeriod].self, from: data)
        } catch {
            log.error("rate history decode failed \(error: error)")
            return nil
        }
    }

    /// Persists the current `periods` snapshot. Call only outside the lock (the
    /// caller must pass an already-captured snapshot, or call the no-arg overload
    /// which takes the lock itself) — file I/O must never happen while holding
    /// `lock`.
    private func persist() {
        lock.lock()
        let snapshot = periods
        lock.unlock()
        persist(snapshot)
    }

    private func persist(_ snapshot: [RatePeriod]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data: Data
        do {
            data = try encoder.encode(snapshot)
        } catch {
            log.error("rate history encode failed \(error: error)")
            return
        }
        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            log.error("rate history write failed \(error: error)")
        }
    }
}
