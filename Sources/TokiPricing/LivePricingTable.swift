/// LivePricingTable — point-in-time `PricingProviding` backed by the append-only rate
/// history. Prices each lookup by the rate period effective on the requested date, so
/// historical cost never retroactively jumps when a price changes, and can pull fresh
/// rates from the official pricing page on demand.
import Foundation
import TokiModels
import TokiLogging

private let log = TokiLog.logger("pricing")

/// Resolves per-model pricing as of a given date from a `RateHistoryStore`.
///
/// Lookup is point-in-time: for each `modelPrefix` it picks the single representative
/// period active on `date` (falling back sensibly for out-of-window dates), then
/// boundary-matches the longest such prefix against the model id — mirroring
/// `PricingTable`'s matching rules but layered over the date-aware rate history.
///
/// `@unchecked Sendable` because the store it reads is itself `NSLock`-guarded and the
/// `URLSession` is a `Sendable` reference; this type holds no other mutable state.
public final class LivePricingTable: PricingProviding, @unchecked Sendable {

    // MARK: Properties

    private let store: RateHistoryStore
    private let session: URLSession

    private let cacheLock = NSLock()
    private var cachedGroups: [(prefix: String, periods: [RatePeriod])]?
    private var cachedGeneration: UInt64?
    private var canonicalNames: [String: String] = [:]

    // MARK: Init

    public init(store: RateHistoryStore = RateHistoryStore(), session: URLSession = .shared) {
        self.store = store
        self.session = session
    }

    // MARK: PricingProviding

    /// Returns the pricing for `model` effective on `date`, or nil when no known prefix
    /// matches. For each `modelPrefix` the representative period at `date` is chosen, the
    /// resulting `(prefix, ModelPricing)` pairs are sorted longest-prefix-first, and the
    /// first boundary-matching prefix wins (next char after the prefix is end-of-string
    /// or "-").
    public func pricing(for model: String, on date: Date) -> ModelPricing? {
        let groups = prefixGroups()

        // Longest prefix first, and a prefix with no period active on `date` falls through
        // to the next shorter one — the same outcome the previous implementation reached by
        // filtering to representatives and then sorting.
        let lowered = canonicalModel(model)
        guard !isExplicitlyUnpricedModelID(lowered) else { return nil }
        for group in groups {
            guard lowered.hasPrefix(group.prefix) else { continue }
            // Boundary check: the character right after the prefix must be absent
            // (exact match or date suffix) or a "-" (version delimiter).
            let afterPrefix = lowered.dropFirst(group.prefix.count)
            guard afterPrefix.isEmpty || afterPrefix.first == "-" else { continue }
            if let chosen = RatePeriod.representative(in: group.periods, on: date) {
                return chosen.pricing
            }
        }
        return nil
    }

    /// `model`'s pricing over all time. Point-in-time pricing can only change where a rate
    /// period of a matching prefix starts or ends, so it is evaluated once per interval
    /// between those boundaries — by `pricing(for:on:)` itself, which keeps the two exactly
    /// in agreement.
    public func schedule(for model: String) -> PriceSchedule? {
        let lowered = canonicalModel(model)
        guard !isExplicitlyUnpricedModelID(lowered) else { return .constant(nil) }
        var boundaries = Set<Date>()
        for group in prefixGroups() where lowered.hasPrefix(group.prefix) {
            for period in group.periods {
                if let from = period.effectiveFrom { boundaries.insert(from) }
                if let until = period.effectiveUntil { boundaries.insert(until) }
            }
        }
        var segments: [(start: Date, pricing: ModelPricing?)] = [(.distantPast, pricing(for: model, on: .distantPast))]
        for boundary in boundaries.sorted() where boundary > .distantPast {
            segments.append((boundary, pricing(for: model, on: boundary)))
        }
        return PriceSchedule(segments: segments)
    }

    // MARK: Derived-state caches

    /// Rate periods grouped by model prefix, longest prefix first.
    ///
    /// Derived once per rate-history generation rather than per lookup. It used to be
    /// rebuilt — dictionary, candidate array and a sort — on every call, which measured at
    /// 12 µs per record: pricing 36,720 records took 438 ms of a 579 ms analytics pass,
    /// 75% of the total, and that pass ran once a second while transcripts were being
    /// written.
    private func prefixGroups() -> [(prefix: String, periods: [RatePeriod])] {
        let (periods, generation) = store.snapshot()
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cachedGroups, cachedGeneration == generation { return cachedGroups }

        var byPrefix: [String: [RatePeriod]] = [:]
        for period in periods {
            byPrefix[period.modelPrefix, default: []].append(period)
        }
        let groups = byPrefix
            .map { (prefix: $0.key, periods: $0.value) }
            .sorted { $0.prefix.count > $1.prefix.count }

        cachedGroups = groups
        cachedGeneration = generation
        // A new generation invalidates the derived names too: nothing about them depends on
        // the rates, but clearing here keeps the two caches from drifting in lifetime.
        canonicalNames.removeAll(keepingCapacity: true)
        return groups
    }

    /// `canonicalModelID(_:).lowercased()` is pure and called once per record with only a
    /// handful of distinct model ids in play, so it is memoized rather than re-derived.
    private func canonicalModel(_ model: String) -> String {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached = canonicalNames[model] { return cached }
        let derived = canonicalModelID(model).lowercased()
        canonicalNames[model] = derived
        return derived
    }

    // MARK: Refresh

    /// Fetches the official pricing page, parses it into rate periods, and merges them
    /// into the rate history. Swallows every error (network, decode, parse) — on any
    /// failure the existing rates are left untouched, never throwing.
    public func refresh() async {
        let request = URLRequest(url: PricingPageParser.pricingURL)
        let data: Data
        do {
            (data, _) = try await session.data(for: request)
        } catch {
            log.error("pricing page fetch failed \(error: error)")
            return
        }
        guard let html = String(data: data, encoding: .utf8) else {
            return
        }
        let periods = PricingPageParser.parse(html: html)
        guard !periods.isEmpty else { return }
        store.merge(periods, asOf: Date())
    }
}
