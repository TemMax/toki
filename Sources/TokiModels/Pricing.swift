/// Pricing types for per-model cost computation.
import Foundation

// MARK: - ModelPricing

/// Per-model pricing in USD per million tokens (MTok).
public struct ModelPricing: Sendable {
    /// Prompt/input tokens — USD per MTok.
    public let inputPerMTok: Double
    /// Output/completion tokens — USD per MTok.
    public let outputPerMTok: Double
    /// 5-minute ephemeral cache-write tokens — USD per MTok.
    public let cacheWrite5mPerMTok: Double
    /// 1-hour ephemeral cache-write tokens — USD per MTok (≈4× the 5m rate).
    public let cacheWrite1hPerMTok: Double
    /// Cache-read tokens — USD per MTok.
    public let cacheReadPerMTok: Double
    /// Prompt-token threshold above which long-context multipliers apply.
    /// nil means the model has no separately published long-context tier.
    public let longContextThresholdTokens: Int?
    /// Multiplier applied to all input/cache rates above the long-context threshold.
    public let longContextInputMultiplier: Double?
    /// Multiplier applied to the output rate above the long-context threshold.
    public let longContextOutputMultiplier: Double?

    public init(
        inputPerMTok: Double,
        outputPerMTok: Double,
        cacheWrite5mPerMTok: Double,
        cacheWrite1hPerMTok: Double,
        cacheReadPerMTok: Double,
        longContextThresholdTokens: Int? = nil,
        longContextInputMultiplier: Double? = nil,
        longContextOutputMultiplier: Double? = nil
    ) {
        self.inputPerMTok = inputPerMTok
        self.outputPerMTok = outputPerMTok
        self.cacheWrite5mPerMTok = cacheWrite5mPerMTok
        self.cacheWrite1hPerMTok = cacheWrite1hPerMTok
        self.cacheReadPerMTok = cacheReadPerMTok
        self.longContextThresholdTokens = longContextThresholdTokens
        self.longContextInputMultiplier = longContextInputMultiplier
        self.longContextOutputMultiplier = longContextOutputMultiplier
    }
}

extension ModelPricing {
    /// Itemised cost of `usage` at these rates, with the long-context tier applied when the
    /// prompt exceeds its threshold.
    public func cost(for usage: TokenUsage) -> CostBreakdown {
        let promptTokens = usage.input + usage.cacheRead + usage.cacheCreationTotal
        let isLongContext = longContextThresholdTokens.map { promptTokens > $0 } ?? false
        let inputMultiplier = isLongContext ? (longContextInputMultiplier ?? 1) : 1
        let outputMultiplier = isLongContext ? (longContextOutputMultiplier ?? 1) : 1
        return CostBreakdown(
            input:      Double(usage.input)      / 1_000_000 * inputPerMTok * inputMultiplier,
            output:     Double(usage.output)     / 1_000_000 * outputPerMTok * outputMultiplier,
            cacheWrite: (Double(usage.ephemeral5m) / 1_000_000 * cacheWrite5mPerMTok
                      + Double(usage.ephemeral1h) / 1_000_000 * cacheWrite1hPerMTok) * inputMultiplier,
            cacheRead:  Double(usage.cacheRead)  / 1_000_000 * cacheReadPerMTok * inputMultiplier,
            webSearch:  Double(usage.webSearch) * Self.webSearchPerRequest
        )
    }

    /// Claude API web search: $10 per 1,000 searches (platform.claude.com pricing,
    /// 2026-09-23). Only Claude transcripts report a search count; Codex rollouts carry none,
    /// so this never touches an OpenAI record.
    public static let webSearchPerRequest = 0.01
}

// MARK: - PriceSchedule

/// One model's pricing over all time, as consecutive segments: segment `i` covers
/// `[start(i), start(i+1))`, and the first starts at `.distantPast`. `nil` pricing means the
/// model is unpriced in that segment.
///
/// Point-in-time pricing is piecewise constant — it can only change where some rate period
/// starts or ends — so a provider can state it once per model and a long range can then be
/// priced record by record without touching the provider (and its locks) again.
public struct PriceSchedule: Sendable {
    private let starts: [Date]
    private let pricings: [ModelPricing?]

    /// - Parameter segments: ascending by `start`; the first should start at `.distantPast`
    ///   (a date before the first segment falls into it anyway).
    public init(segments: [(start: Date, pricing: ModelPricing?)]) {
        precondition(!segments.isEmpty, "a schedule needs at least one segment")
        starts = segments.map(\.start)
        pricings = segments.map(\.pricing)
    }

    /// The same pricing on every date.
    public static func constant(_ pricing: ModelPricing?) -> PriceSchedule {
        PriceSchedule(segments: [(.distantPast, pricing)])
    }

    public func pricing(on date: Date) -> ModelPricing? {
        // Last segment starting at or before `date` (binary search; schedules are tiny, but a
        // long history of rate changes should not turn this into a scan).
        var low = 0
        var high = starts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if starts[mid] <= date { low = mid } else { high = mid - 1 }
        }
        return pricings[low]
    }
}

// MARK: - CostBreakdown

/// Itemised cost in USD for a token-usage snapshot.
public struct CostBreakdown: Sendable {
    /// Input-token cost in USD.
    public let input: Double
    /// Output-token cost in USD.
    public let output: Double
    /// Cache-write cost in USD (5m and 1h tiers combined).
    public let cacheWrite: Double
    /// Cache-read cost in USD.
    public let cacheRead: Double
    /// Server-side web search charges in USD (billed per search, not per token).
    public let webSearch: Double

    /// Total cost — sum of every component.
    public var total: Double { input + output + cacheWrite + cacheRead + webSearch }

    /// All-zero baseline for reductions.
    public static let zero = CostBreakdown(input: 0, output: 0, cacheWrite: 0, cacheRead: 0)

    public init(input: Double, output: Double, cacheWrite: Double, cacheRead: Double, webSearch: Double = 0) {
        self.input = input
        self.output = output
        self.cacheWrite = cacheWrite
        self.cacheRead = cacheRead
        self.webSearch = webSearch
    }

    /// Element-wise sum of two cost breakdowns.
    public static func + (lhs: CostBreakdown, rhs: CostBreakdown) -> CostBreakdown {
        CostBreakdown(
            input: lhs.input + rhs.input,
            output: lhs.output + rhs.output,
            cacheWrite: lhs.cacheWrite + rhs.cacheWrite,
            cacheRead: lhs.cacheRead + rhs.cacheRead,
            webSearch: lhs.webSearch + rhs.webSearch
        )
    }

    /// This cost as billed under `modifiers`: every token category scaled, per-search
    /// charges unchanged.
    public func applying(_ modifiers: BillingModifiers) -> CostBreakdown {
        let factor = modifiers.tokenPriceMultiplier
        guard factor != 1 else { return self }
        return CostBreakdown(
            input: input * factor,
            output: output * factor,
            cacheWrite: cacheWrite * factor,
            cacheRead: cacheRead * factor,
            webSearch: webSearch
        )
    }
}

// MARK: - RatePeriod

/// A single entry in the append-only local rate history: the pricing in effect for a
/// model-id prefix over a half-open date interval `[effectiveFrom, effectiveUntil)`.
/// Point-in-time pricing looks up the period whose interval contains the usage record's
/// own date, so historical cost never retroactively jumps when a price changes.
public struct RatePeriod: Sendable, Codable, Equatable {
    /// Lowercase model-id prefix this period applies to, e.g. "claude-sonnet-5".
    public let modelPrefix: String
    /// Prompt/input tokens — USD per MTok.
    public let inputPerMTok: Double
    /// Output/completion tokens — USD per MTok.
    public let outputPerMTok: Double
    /// 5-minute ephemeral cache-write tokens — USD per MTok.
    public let cacheWrite5mPerMTok: Double
    /// 1-hour ephemeral cache-write tokens — USD per MTok.
    public let cacheWrite1hPerMTok: Double
    /// Cache-read tokens — USD per MTok.
    public let cacheReadPerMTok: Double
    /// Prompt-token threshold above which long-context multipliers apply.
    public let longContextThresholdTokens: Int?
    /// Multiplier applied to all input/cache rates above the threshold.
    public let longContextInputMultiplier: Double?
    /// Multiplier applied to the output rate above the threshold.
    public let longContextOutputMultiplier: Double?
    /// Inclusive lower bound of the period; nil means open-ended in the past.
    public let effectiveFrom: Date?
    /// Exclusive upper bound of the period; nil means open-ended (still current).
    public let effectiveUntil: Date?

    public init(
        modelPrefix: String,
        inputPerMTok: Double,
        outputPerMTok: Double,
        cacheWrite5mPerMTok: Double,
        cacheWrite1hPerMTok: Double,
        cacheReadPerMTok: Double,
        longContextThresholdTokens: Int? = nil,
        longContextInputMultiplier: Double? = nil,
        longContextOutputMultiplier: Double? = nil,
        effectiveFrom: Date?,
        effectiveUntil: Date?
    ) {
        self.modelPrefix = modelPrefix
        self.inputPerMTok = inputPerMTok
        self.outputPerMTok = outputPerMTok
        self.cacheWrite5mPerMTok = cacheWrite5mPerMTok
        self.cacheWrite1hPerMTok = cacheWrite1hPerMTok
        self.cacheReadPerMTok = cacheReadPerMTok
        self.longContextThresholdTokens = longContextThresholdTokens
        self.longContextInputMultiplier = longContextInputMultiplier
        self.longContextOutputMultiplier = longContextOutputMultiplier
        self.effectiveFrom = effectiveFrom
        self.effectiveUntil = effectiveUntil
    }

    /// This period's rates as a `ModelPricing` value.
    public var pricing: ModelPricing {
        ModelPricing(
            inputPerMTok: inputPerMTok,
            outputPerMTok: outputPerMTok,
            cacheWrite5mPerMTok: cacheWrite5mPerMTok,
            cacheWrite1hPerMTok: cacheWrite1hPerMTok,
            cacheReadPerMTok: cacheReadPerMTok,
            longContextThresholdTokens: longContextThresholdTokens,
            longContextInputMultiplier: longContextInputMultiplier,
            longContextOutputMultiplier: longContextOutputMultiplier
        )
    }

    /// True when `date` falls within `[effectiveFrom, effectiveUntil)`.
    public func isActive(on date: Date) -> Bool {
        (effectiveFrom.map { date >= $0 } ?? true) && (effectiveUntil.map { date < $0 } ?? true)
    }

    /// True iff all five rate fields are equal to `other`'s (prefix and dates are ignored).
    public func hasSameRates(as other: RatePeriod) -> Bool {
        inputPerMTok == other.inputPerMTok
            && outputPerMTok == other.outputPerMTok
            && cacheWrite5mPerMTok == other.cacheWrite5mPerMTok
            && cacheWrite1hPerMTok == other.cacheWrite1hPerMTok
            && cacheReadPerMTok == other.cacheReadPerMTok
            && longContextThresholdTokens == other.longContextThresholdTokens
            && longContextInputMultiplier == other.longContextInputMultiplier
            && longContextOutputMultiplier == other.longContextOutputMultiplier
    }

    /// Chooses the single period from `periods` (assumed to share a prefix) to represent
    /// the rate at `date`:
    /// 1. Among periods active on `date`, the one with the greatest `effectiveFrom`
    ///    (a nil `effectiveFrom` sorts as `.distantPast`).
    /// 2. Otherwise, among periods whose `effectiveFrom` is nil or `<= date`, the one with
    ///    the greatest `effectiveFrom` (nil = `.distantPast`).
    /// 3. Otherwise (everything starts in the future), the period with the smallest
    ///    `effectiveFrom` (nil = `.distantPast`).
    /// Returns nil only when `periods` is empty.
    public static func representative(in periods: [RatePeriod], on date: Date) -> RatePeriod? {
        guard !periods.isEmpty else { return nil }

        func startKey(_ period: RatePeriod) -> Date { period.effectiveFrom ?? .distantPast }

        let active = periods.filter { $0.isActive(on: date) }
        if !active.isEmpty {
            return active.max(by: { startKey($0) < startKey($1) })
        }

        let started = periods.filter { period in
            period.effectiveFrom.map { $0 <= date } ?? true
        }
        if !started.isEmpty {
            return started.max(by: { startKey($0) < startKey($1) })
        }

        return periods.min(by: { startKey($0) < startKey($1) })
    }
}
