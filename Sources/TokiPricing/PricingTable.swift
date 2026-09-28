/// PricingTable — embedded static pricing table with longest-prefix model matching.
import Foundation
import TokiModels

/// Static pricing table embedded at compile time.  Model lookup uses longest-prefix
/// matching so that new model point-releases are automatically covered by the closest
/// ancestor prefix.  When a model is unrecognised, `pricing(for:)` returns nil and
/// `cost(for:model:)` returns nil — never a silent $0.
///
/// See research doc R6 for the full rate table and decision D6 for the multiplier rules.
///
/// Future refresh: a bundled `pricing.json` resource (or a downloaded update cached in
/// `~/Library/Application Support/Toki/pricing.json`) could override `entries` at
/// init time by decoding the same {prefix, input, output, cacheWrite5m, cacheWrite1h,
/// cacheRead} structure and replacing this static dictionary.  No network call is made
/// today — implement fetching only when pricing volatility warrants it.
public struct PricingTable: PricingProviding {

    // MARK: - Static pricing table (USD per million tokens)

    /// Pricing entries keyed by model-id prefix (lowercase), longest prefix first.
    ///
    /// Derived from `BundledRates.seed` — every seed period is open-ended, so its rate is
    /// the model's rate — rather than kept as a second hand-maintained copy that could
    /// drift (it had: GPT-6 Sol was priced in neither, and a fix to one would have
    /// missed the other).
    private static let entries: [(prefix: String, pricing: ModelPricing)] = BundledRates.seed
        .map { (prefix: $0.modelPrefix, pricing: $0.pricing) }
        .sorted { $0.prefix.count > $1.prefix.count }

    // MARK: - Public API

    public init() {}

    /// Returns the pricing entry for `model` using longest-prefix matching.
    /// The comparison is case-insensitive (model id lowercased before lookup).
    /// `date` is ignored — this bundled table is date-agnostic; point-in-time
    /// pricing is implemented by `LivePricingTable` over the rate history.
    ///
    /// A key matches a model id only when, after the key, the next character is
    /// end-of-string or a "-".  This prevents "claude-opus-4-1" from matching
    /// "claude-opus-4-10" or "claude-opus-4-11" (which would mis-price them as
    /// Opus 4.1 at $15/$75).  Date suffixes ("claude-opus-4-1-20250805") still
    /// match because the separator between the version token and the date is "-".
    public func pricing(for model: String, on date: Date) -> ModelPricing? {
        let lowered = canonicalModelID(model).lowercased()
        guard !isExplicitlyUnpricedModelID(lowered) else { return nil }
        // Linear scan over entries sorted longest-prefix-first; first match wins.
        for entry in Self.entries {
            guard lowered.hasPrefix(entry.prefix) else { continue }
            // Boundary check: the character immediately after the prefix must be
            // absent (exact match or date suffix) or a "-" (version delimiter).
            let afterPrefix = lowered.dropFirst(entry.prefix.count)
            if afterPrefix.isEmpty || afterPrefix.first == "-" {
                return entry.pricing
            }
        }
        return nil
    }

    /// Date-agnostic, so the schedule is a single segment.
    public func schedule(for model: String) -> PriceSchedule? {
        .constant(pricing(for: model, on: Date()))
    }
}
