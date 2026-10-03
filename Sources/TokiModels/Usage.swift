/// Token-usage and transcript record types.
import Foundation

// MARK: - TokenUsage

/// Raw token counts for a single API call or an aggregate window.
public struct TokenUsage: Sendable {
    /// Prompt (input) tokens.  Note: ~22% may be placeholder `1` (CC ≤2.1.170 bug).
    public let input: Int
    /// Generated (output/completion) tokens.
    public let output: Int
    /// Cache-read tokens (existing cache hit; cheapest tier).
    public let cacheRead: Int
    /// Cache-write tokens charged at the 5-minute ephemeral rate.
    public let ephemeral5m: Int
    /// Cache-write tokens charged at the 1-hour ephemeral rate (≈4× the 5m rate).
    public let ephemeral1h: Int
    /// Web-search tool invocations.
    public let webSearch: Int
    /// Web-fetch tool invocations.
    public let webFetch: Int

    /// Total cache-creation tokens (5 m + 1 h buckets).
    public var cacheCreationTotal: Int { ephemeral5m + ephemeral1h }

    /// Prompt tokens not served from cache: plain input plus cache writes.
    ///
    /// Providers split these differently. Claude Code writes each turn's new context to the
    /// cache, so it is reported as cache writes and `input` is a handful of tokens; Codex
    /// (OpenAI) caches implicitly and reports the same new context as plain `input`. Only
    /// the sum means the same thing for both.
    public var uncachedInput: Int { input + cacheCreationTotal }

    /// The whole prompt the model was sent: uncached input plus cache reads.
    public var promptTokens: Int { uncachedInput + cacheRead }

    /// Toki's "tokens" figure: everything the model newly read or wrote — uncached input
    /// plus output. Cache reads (re-reading context it already processed, at a tenth of the
    /// price or less) are reported beside it, never inside it, so a long cached session does
    /// not dwarf everything else and Claude and Codex are counted the same way.
    public var processedTokens: Int { uncachedInput + output }

    /// Share of the prompt served from cache, or nil with no prompt at all.
    public var cacheHitRate: Double? {
        let prompt = promptTokens
        return prompt > 0 ? Double(cacheRead) / Double(prompt) : nil
    }

    /// All-zero baseline for reductions.
    public static let zero = TokenUsage(
        input: 0, output: 0, cacheRead: 0,
        ephemeral5m: 0, ephemeral1h: 0,
        webSearch: 0, webFetch: 0
    )

    public init(
        input: Int,
        output: Int,
        cacheRead: Int,
        ephemeral5m: Int,
        ephemeral1h: Int,
        webSearch: Int,
        webFetch: Int
    ) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.ephemeral5m = ephemeral5m
        self.ephemeral1h = ephemeral1h
        self.webSearch = webSearch
        self.webFetch = webFetch
    }

    /// Element-wise sum of two usage snapshots.
    public static func + (lhs: TokenUsage, rhs: TokenUsage) -> TokenUsage {
        TokenUsage(
            input: lhs.input + rhs.input,
            output: lhs.output + rhs.output,
            cacheRead: lhs.cacheRead + rhs.cacheRead,
            ephemeral5m: lhs.ephemeral5m + rhs.ephemeral5m,
            ephemeral1h: lhs.ephemeral1h + rhs.ephemeral1h,
            webSearch: lhs.webSearch + rhs.webSearch,
            webFetch: lhs.webFetch + rhs.webFetch
        )
    }
}

// MARK: - TranscriptRecord

/// A single deduplicated API call parsed from a Claude Code JSONL transcript.
public struct TranscriptRecord: Sendable {
    /// Unique identifier for the API request (dedup key — last-wins per D2).
    public let requestId: String
    /// The Claude Code session this call belongs to.
    public let sessionId: String
    /// Working directory at the time of the call (raw path).
    public let cwd: String
    /// Model identifier, e.g. `claude-opus-4-8`.  `<synthetic>` records are excluded.
    public let model: String
    /// UTC timestamp of the call; bucket to local-TZ day for aggregation.
    public let timestamp: Date
    /// Aggregated token usage for this request.
    public let usage: TokenUsage
    /// True when this record originates from a subagent JSONL file.
    public let isSidechain: Bool
    /// Request options that change its price but not its token counts.
    public let billing: BillingModifiers
    /// End of the request minus its start, in ms — the time the model took to produce
    /// `usage.output` (queueing and time to first token included; see the generation speed
    /// spec). `nil` when the transcript did not show where the request started.
    public let generationMs: Int?
    /// Reasoning effort the request ran at (`low`…`max`), as the transcript spelled it.
    public let effort: String?
    /// Fast mode: Claude `speed: "fast"`, Codex `service_tier: "priority"`. Deliberately not a
    /// `BillingModifiers` flag — Codex priority is not priced.
    public let isFast: Bool

    /// Human-readable project name derived from the last path component of `cwd`.
    public var projectName: String {
        URL(fileURLWithPath: cwd).lastPathComponent
    }

    public init(
        requestId: String,
        sessionId: String,
        cwd: String,
        model: String,
        timestamp: Date,
        usage: TokenUsage,
        isSidechain: Bool,
        billing: BillingModifiers = [],
        generationMs: Int? = nil,
        effort: String? = nil,
        isFast: Bool = false
    ) {
        self.requestId = requestId
        self.sessionId = sessionId
        self.cwd = cwd
        self.model = model
        self.timestamp = timestamp
        self.usage = usage
        self.isSidechain = isSidechain
        self.billing = billing
        self.generationMs = generationMs
        self.effort = effort
        self.isFast = isFast
    }

    /// This record with `generationMs` replaced — the scan learns the duration after parsing.
    public func withGenerationMs(_ ms: Int?) -> TranscriptRecord {
        TranscriptRecord(
            requestId: requestId, sessionId: sessionId, cwd: cwd, model: model,
            timestamp: timestamp, usage: usage, isSidechain: isSidechain, billing: billing,
            generationMs: ms, effort: effort, isFast: isFast
        )
    }
}

// MARK: - BillingModifiers

/// Request-level options that scale a request's token prices. Recorded from the transcript
/// (Claude Code logs `speed` and `inference_geo` on every usage block), so cost reflects
/// what the request was actually billed at rather than the model's standard rate.
public struct BillingModifiers: OptionSet, Sendable, Hashable {
    public let rawValue: Int

    public init(rawValue: Int) { self.rawValue = rawValue }

    /// Fast mode (`speed: "fast"`): every token rate doubles — the published fast prices
    /// are exactly 2x standard, and prompt-caching multipliers apply on top of them.
    public static let fastMode = BillingModifiers(rawValue: 1 << 0)
    /// US-only inference (`inference_geo: "us"`): 1.1x on every token category.
    public static let usOnlyInference = BillingModifiers(rawValue: 1 << 1)

    /// The factor every token rate is multiplied by.
    public var tokenPriceMultiplier: Double {
        (contains(.fastMode) ? 2 : 1) * (contains(.usOnlyInference) ? 1.1 : 1)
    }
}

// MARK: - Aggregate views

/// How wide one bucket of a `UsageSummary`'s trend series is.
///
/// The bucket width is a property of the RANGE, and deciding it here rather than in the
/// chart is the whole point: a one-day range bucketed by day is a single point, which the
/// sparkline can only draw as a flat line with `min` equal to `max`. That is exactly what
/// the Usage tab showed on "Today" — a card that looked broken while being perfectly
/// faithful to a series with one element in it.
public enum BucketSize: Sendable, Equatable {
    /// One bucket per clock hour (local TZ). Used when the range covers a single day.
    case hour
    /// One bucket per calendar day (local TZ).
    case day

    /// The `Calendar.Component` this maps to, for boundary arithmetic.
    public var component: Calendar.Component {
        switch self {
        case .hour: return .hour
        case .day:  return .day
        }
    }
}

/// Token usage and cost for one bucket of the trend series — an hour or a day in local
/// time, per the summary's `bucketSize`.
public struct UsageBucket: Sendable {
    /// Start of the bucket being aggregated (local midnight, or the top of the hour).
    public let date: Date
    /// Sum of all token usage in the bucket.
    public let usage: TokenUsage
    /// Known-price cost subtotal, or nil when none of the records can be priced.
    public let cost: CostBreakdown?
    /// True when at least one record in this aggregate has no published price.
    /// `cost` may still contain the subtotal for records whose pricing is known.
    public let hasUnpricedUsage: Bool
    /// Number of API calls included in this bucket.
    public let callCount: Int

    public init(
        date: Date,
        usage: TokenUsage,
        cost: CostBreakdown?,
        callCount: Int,
        hasUnpricedUsage: Bool = false
    ) {
        self.date = date
        self.usage = usage
        self.cost = cost
        self.callCount = callCount
        self.hasUnpricedUsage = hasUnpricedUsage
    }
}

/// Token usage and cost for a single project (identified by its working-directory path).
public struct ProjectUsage: Sendable {
    /// Human-readable project name (basename of `path`).
    public let project: String
    /// Absolute working-directory path this project aggregates (the raw `cwd`).
    /// Empty only for synthetic/fixture data that has no real location.
    public let path: String
    /// Sum of all token usage for this project.
    public let usage: TokenUsage
    /// Known-price cost subtotal, or nil when none of the records can be priced.
    public let cost: CostBreakdown?
    /// True when at least one record in this aggregate has no published price.
    public let hasUnpricedUsage: Bool
    /// Number of API calls attributed to this project.
    public let callCount: Int

    public init(
        project: String,
        path: String,
        usage: TokenUsage,
        cost: CostBreakdown?,
        callCount: Int,
        hasUnpricedUsage: Bool = false
    ) {
        self.project = project
        self.path = path
        self.usage = usage
        self.cost = cost
        self.callCount = callCount
        self.hasUnpricedUsage = hasUnpricedUsage
    }
}

/// Token usage and cost broken down by model identifier.
public struct ModelUsage: Sendable {
    /// Model identifier, e.g. `claude-opus-4-8`.
    public let model: String
    /// Sum of all token usage for this model.
    public let usage: TokenUsage
    /// Known-price cost subtotal, or nil when none of the records can be priced.
    public let cost: CostBreakdown?
    /// True when at least one record in this aggregate has no published price.
    public let hasUnpricedUsage: Bool
    /// Number of API calls that used this model.
    public let callCount: Int

    public init(
        model: String,
        usage: TokenUsage,
        cost: CostBreakdown?,
        callCount: Int,
        hasUnpricedUsage: Bool = false
    ) {
        self.model = model
        self.usage = usage
        self.cost = cost
        self.callCount = callCount
        self.hasUnpricedUsage = hasUnpricedUsage
    }
}

/// Full analytics summary for a date range.
public struct UsageSummary: Sendable {
    /// Aggregated token totals across the entire range.
    public let total: TokenUsage
    /// Known-price cost subtotal across the range, or nil when no record can be priced.
    public let cost: CostBreakdown?
    /// True when `cost` excludes one or more records whose model has no published price.
    public let hasUnpricedUsage: Bool
    /// Trend series, sorted ascending by date, one element per `bucketSize`.
    ///
    /// CONTIGUOUS: buckets with no activity are present with zero usage rather than
    /// omitted. A series that skips idle buckets plots an even spacing over uneven time,
    /// so five busy days scattered through a month drew the same shape as five
    /// consecutive ones.
    public let buckets: [UsageBucket]
    /// Width of one `buckets` element — see `BucketSize`.
    public let bucketSize: BucketSize
    /// Per-project breakdown (sorted descending by call count).
    public let byProject: [ProjectUsage]
    /// Per-model breakdown (sorted descending by call count).
    public let byModel: [ModelUsage]
    /// Inclusive start of the reporting range.
    public let rangeStart: Date
    /// Inclusive end of the reporting range.
    public let rangeEnd: Date

    public init(
        total: TokenUsage,
        cost: CostBreakdown?,
        buckets: [UsageBucket],
        bucketSize: BucketSize,
        byProject: [ProjectUsage],
        byModel: [ModelUsage],
        rangeStart: Date,
        rangeEnd: Date,
        hasUnpricedUsage: Bool = false
    ) {
        self.total = total
        self.cost = cost
        self.buckets = buckets
        self.bucketSize = bucketSize
        self.byProject = byProject
        self.byModel = byModel
        self.rangeStart = rangeStart
        self.rangeEnd = rangeEnd
        self.hasUnpricedUsage = hasUnpricedUsage
    }
}
