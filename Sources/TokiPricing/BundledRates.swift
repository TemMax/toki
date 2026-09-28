/// BundledRates — compile-time seed for the local rate history (point-in-time pricing).
import Foundation
import TokiModels

/// The rate-history seed bundled with the app, and the table `PricingTable` serves. Every
/// model gets a single open-ended period:
/// no model in this table has had a price change within our history.
///
/// Sonnet 5 used to carry two — an "introductory" $2/$10 through 2026-08-31 and a
/// $3/$15 standard rate after it. That transition never happened: the pricing page
/// dropped the date window and kept $2/$10, so the second period would have started
/// over-charging every Sonnet 5 record from 2026-09-01 on. A dated seed period is
/// therefore only worth writing for a price change that has ALREADY taken effect —
/// an announced future one belongs to `PricingPageParser`, which re-reads it every
/// launch and can watch it move.
///
/// `RateHistoryStore` merges this seed under any persisted history so a corrected
/// or freshly parsed rate from `PricingPageParser` always wins, while this seed
/// still fills in any prefix the persisted file hasn't learned about yet — except for
/// `bundledOnlyPrefixes`, which no parser refreshes, so the seed is authoritative there.
public enum BundledRates {

    /// OpenAI's public table has up to four token rates. Cache writes are ordinary input
    /// unless the model publishes a distinct write rate (GPT-6 and GPT-5.6: 1.25x input).
    private static func openAIRate(
        _ prefix: String,
        input: Double,
        cachedInput: Double,
        output: Double,
        cacheWrite: Double? = nil,
        longContext: Bool = false
    ) -> RatePeriod {
        RatePeriod(
            modelPrefix: prefix,
            inputPerMTok: input,
            outputPerMTok: output,
            cacheWrite5mPerMTok: cacheWrite ?? input,
            cacheWrite1hPerMTok: cacheWrite ?? input,
            cacheReadPerMTok: cachedInput,
            longContextThresholdTokens: longContext ? 272_000 : nil,
            longContextInputMultiplier: longContext ? 2 : nil,
            longContextOutputMultiplier: longContext ? 1.5 : nil,
            effectiveFrom: nil,
            effectiveUntil: nil
        )
    }

    /// Compile-time rate-history seed. See `RateHistoryStore` for how this seed
    /// is merged with any persisted, parser-supplied history.
    public static let seed: [RatePeriod] = openAISeed + anthropicSeed

    /// Prefixes whose only source is this seed. Anthropic's rates are refreshed from its
    /// pricing page (`PricingPageParser`), but nothing re-fetches OpenAI's — so for these,
    /// a correction shipped here must replace what an older build persisted, or it never
    /// reaches an existing install (see `RateHistoryStore.init`).
    public static let bundledOnlyPrefixes: Set<String> = Set(openAISeed.map(\.modelPrefix))

    /// Source: developers.openai.com/api/docs/pricing and the per-model pages, 2026-09-23.
    /// Every long-context model bills a prompt over 272K input tokens at 2x input, cache
    /// read and cache write, and 1.5x output, for the whole request.
    private static let openAISeed: [RatePeriod] = [
        openAIRate("gpt-6-astra", input: 10, cachedInput: 1, output: 50, cacheWrite: 12.50, longContext: true),
        openAIRate("gpt-6-sol", input: 2, cachedInput: 0.20, output: 10, cacheWrite: 2.50, longContext: true),
        openAIRate("gpt-6-luna", input: 0.10, cachedInput: 0.01, output: 0.50, cacheWrite: 0.125, longContext: true),
        openAIRate("gpt-5.6-sol", input: 4, cachedInput: 0.40, output: 20, cacheWrite: 5, longContext: true),
        openAIRate("gpt-5.6-terra", input: 2, cachedInput: 0.20, output: 12, cacheWrite: 2.50, longContext: true),
        openAIRate("gpt-5.6-luna", input: 0.20, cachedInput: 0.02, output: 1.20, cacheWrite: 0.25, longContext: true),
        // Pro models publish no cached-input rate: cached tokens bill as ordinary input.
        openAIRate("gpt-5.5-pro", input: 30, cachedInput: 30, output: 180, longContext: true),
        openAIRate("gpt-5.5", input: 5, cachedInput: 0.50, output: 30, longContext: true),
        openAIRate("gpt-5.4-pro", input: 30, cachedInput: 30, output: 180, longContext: true),
        openAIRate("gpt-5.4-mini", input: 0.75, cachedInput: 0.075, output: 4.50),
        openAIRate("gpt-5.4-nano", input: 0.20, cachedInput: 0.02, output: 1.25),
        openAIRate("gpt-5.4", input: 2.50, cachedInput: 0.25, output: 15, longContext: true),
        openAIRate("gpt-5.3-codex", input: 1.75, cachedInput: 0.175, output: 14),
        openAIRate("gpt-5.2-codex", input: 1.75, cachedInput: 0.175, output: 14),
        openAIRate("gpt-5.1-codex-max", input: 1.25, cachedInput: 0.125, output: 10),
        openAIRate("gpt-5.1-codex-mini", input: 0.25, cachedInput: 0.025, output: 2),
        openAIRate("gpt-5.1-codex", input: 1.25, cachedInput: 0.125, output: 10),
        openAIRate("gpt-5-codex", input: 1.25, cachedInput: 0.125, output: 10),
        openAIRate("codex-mini-latest", input: 1.50, cachedInput: 0.375, output: 6),
    ]

    /// Source: platform.claude.com/docs/en/about-claude/pricing, 2026-09-23. Claude 4.6 and
    /// later bill the full 1M context at standard rates, so no long-context tier here.
    private static let anthropicSeed: [RatePeriod] = [
        RatePeriod(
            modelPrefix: "claude-fable-5-1",
            inputPerMTok: 10, outputPerMTok: 50,
            cacheWrite5mPerMTok: 12.50, cacheWrite1hPerMTok: 20,
            cacheReadPerMTok: 0.25,
            effectiveFrom: nil, effectiveUntil: nil
        ),
        RatePeriod(
            modelPrefix: "claude-mythos-5-1",
            inputPerMTok: 10, outputPerMTok: 50,
            cacheWrite5mPerMTok: 12.50, cacheWrite1hPerMTok: 20,
            cacheReadPerMTok: 0.25,
            effectiveFrom: nil, effectiveUntil: nil
        ),

        // Fable 5 / Mythos 5 — $10 / $50 / $12.50 / $20 / $1.00 (cache reads are 4x
        // the 5.1 rate, so the two generations must not share a prefix).
        RatePeriod(
            modelPrefix: "claude-fable-5",
            inputPerMTok: 10, outputPerMTok: 50,
            cacheWrite5mPerMTok: 12.50, cacheWrite1hPerMTok: 20,
            cacheReadPerMTok: 1.00,
            effectiveFrom: nil, effectiveUntil: nil
        ),
        RatePeriod(
            modelPrefix: "claude-mythos-5",
            inputPerMTok: 10, outputPerMTok: 50,
            cacheWrite5mPerMTok: 12.50, cacheWrite1hPerMTok: 20,
            cacheReadPerMTok: 1.00,
            effectiveFrom: nil, effectiveUntil: nil
        ),

        // Opus 5.5 — $4 / $20 / $5 / $8 / $0.20
        RatePeriod(
            modelPrefix: "claude-opus-5-5",
            inputPerMTok: 4, outputPerMTok: 20,
            cacheWrite5mPerMTok: 5, cacheWrite1hPerMTok: 8,
            cacheReadPerMTok: 0.20,
            effectiveFrom: nil, effectiveUntil: nil
        ),

        // Opus 5 — $5 / $25 / $6.25 / $10 / $0.50
        RatePeriod(
            modelPrefix: "claude-opus-5",
            inputPerMTok: 5, outputPerMTok: 25,
            cacheWrite5mPerMTok: 6.25, cacheWrite1hPerMTok: 10,
            cacheReadPerMTok: 0.50,
            effectiveFrom: nil, effectiveUntil: nil
        ),

        // Opus 4.5 / 4.6 / 4.7 / 4.8 — $5 / $25 / $6.25 / $10 / $0.50
        RatePeriod(
            modelPrefix: "claude-opus-4-5",
            inputPerMTok: 5, outputPerMTok: 25,
            cacheWrite5mPerMTok: 6.25, cacheWrite1hPerMTok: 10,
            cacheReadPerMTok: 0.50,
            effectiveFrom: nil, effectiveUntil: nil
        ),
        RatePeriod(
            modelPrefix: "claude-opus-4-6",
            inputPerMTok: 5, outputPerMTok: 25,
            cacheWrite5mPerMTok: 6.25, cacheWrite1hPerMTok: 10,
            cacheReadPerMTok: 0.50,
            effectiveFrom: nil, effectiveUntil: nil
        ),
        RatePeriod(
            modelPrefix: "claude-opus-4-7",
            inputPerMTok: 5, outputPerMTok: 25,
            cacheWrite5mPerMTok: 6.25, cacheWrite1hPerMTok: 10,
            cacheReadPerMTok: 0.50,
            effectiveFrom: nil, effectiveUntil: nil
        ),
        RatePeriod(
            modelPrefix: "claude-opus-4-8",
            inputPerMTok: 5, outputPerMTok: 25,
            cacheWrite5mPerMTok: 6.25, cacheWrite1hPerMTok: 10,
            cacheReadPerMTok: 0.50,
            effectiveFrom: nil, effectiveUntil: nil
        ),

        // Opus 4.1 — $15 / $75 / $18.75 / $30 / $1.50
        RatePeriod(
            modelPrefix: "claude-opus-4-1",
            inputPerMTok: 15, outputPerMTok: 75,
            cacheWrite5mPerMTok: 18.75, cacheWrite1hPerMTok: 30,
            cacheReadPerMTok: 1.50,
            effectiveFrom: nil, effectiveUntil: nil
        ),

        // Sonnet 5 — $2 / $10 / $2.50 / $4 / $0.20. Open-ended: see this type's doc
        // comment for why the announced 2026-09-01 step to $3 / $15 is not seeded here.
        RatePeriod(
            modelPrefix: "claude-sonnet-5",
            inputPerMTok: 2, outputPerMTok: 10,
            cacheWrite5mPerMTok: 2.50, cacheWrite1hPerMTok: 4,
            cacheReadPerMTok: 0.20,
            effectiveFrom: nil, effectiveUntil: nil
        ),

        // Sonnet 4.5 / 4.6 — $3 / $15 / $3.75 / $6 / $0.30
        RatePeriod(
            modelPrefix: "claude-sonnet-4-5",
            inputPerMTok: 3, outputPerMTok: 15,
            cacheWrite5mPerMTok: 3.75, cacheWrite1hPerMTok: 6,
            cacheReadPerMTok: 0.30,
            effectiveFrom: nil, effectiveUntil: nil
        ),
        RatePeriod(
            modelPrefix: "claude-sonnet-4-6",
            inputPerMTok: 3, outputPerMTok: 15,
            cacheWrite5mPerMTok: 3.75, cacheWrite1hPerMTok: 6,
            cacheReadPerMTok: 0.30,
            effectiveFrom: nil, effectiveUntil: nil
        ),

        // Sonnet 4.0 fallback (broad prefix) — $3 / $15 / $3.75 / $6 / $0.30
        RatePeriod(
            modelPrefix: "claude-sonnet-4",
            inputPerMTok: 3, outputPerMTok: 15,
            cacheWrite5mPerMTok: 3.75, cacheWrite1hPerMTok: 6,
            cacheReadPerMTok: 0.30,
            effectiveFrom: nil, effectiveUntil: nil
        ),

        // Haiku 4.5 — $1 / $5 / $1.25 / $2 / $0.10
        RatePeriod(
            modelPrefix: "claude-haiku-4-5",
            inputPerMTok: 1, outputPerMTok: 5,
            cacheWrite5mPerMTok: 1.25, cacheWrite1hPerMTok: 2,
            cacheReadPerMTok: 0.10,
            effectiveFrom: nil, effectiveUntil: nil
        ),

        // Haiku 3.5 — two prefixes covering both naming conventions.
        RatePeriod(
            modelPrefix: "claude-3-5-haiku",
            inputPerMTok: 0.80, outputPerMTok: 4,
            cacheWrite5mPerMTok: 1.00, cacheWrite1hPerMTok: 1.60,
            cacheReadPerMTok: 0.08,
            effectiveFrom: nil, effectiveUntil: nil
        ),
        RatePeriod(
            modelPrefix: "claude-haiku-3-5",
            inputPerMTok: 0.80, outputPerMTok: 4,
            cacheWrite5mPerMTok: 1.00, cacheWrite1hPerMTok: 1.60,
            cacheReadPerMTok: 0.08,
            effectiveFrom: nil, effectiveUntil: nil
        ),
    ]
}
