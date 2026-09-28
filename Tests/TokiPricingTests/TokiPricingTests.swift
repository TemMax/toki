import Testing
import TokiModels
@testable import TokiPricing

@Suite("TokiPricing")
struct TokiPricingTests {

    let table = PricingTable()

    // MARK: - Exact pricing for specific models

    @Test("Current Codex models use their published OpenAI API rates")
    func currentCodexPricing() {
        let sol = table.pricing(for: "gpt-5.6-sol")
        #expect(sol?.inputPerMTok == 4)
        #expect(sol?.cacheReadPerMTok == 0.40)
        #expect(sol?.cacheWrite5mPerMTok == 5)
        #expect(sol?.outputPerMTok == 20)
        #expect(sol?.longContextThresholdTokens == 272_000)

        let terra = table.pricing(for: "gpt-5.6-terra")
        #expect(terra?.inputPerMTok == 2)
        #expect(terra?.cacheReadPerMTok == 0.20)
        #expect(terra?.outputPerMTok == 12)

        let luna = table.pricing(for: "gpt-5.6-luna")
        #expect(luna?.inputPerMTok == 0.20)
        #expect(luna?.cacheReadPerMTok == 0.02)
        #expect(luna?.outputPerMTok == 1.20)
    }

    @Test("GPT-6 models use their published rates, cache writes at 1.25x input")
    func gptSixPricing() throws {
        let expected: [(String, input: Double, cached: Double, write: Double, output: Double)] = [
            ("gpt-6-astra", 10, 1, 12.50, 50),
            ("gpt-6-sol", 2, 0.20, 2.50, 10),
            ("gpt-6-luna", 0.10, 0.01, 0.125, 0.50),
        ]
        for (model, input, cached, write, output) in expected {
            let rate = try #require(table.pricing(for: model), "\(model) must be priced")
            #expect(rate.inputPerMTok == input, "\(model)")
            #expect(rate.cacheReadPerMTok == cached, "\(model)")
            #expect(rate.cacheWrite5mPerMTok == write, "\(model)")
            #expect(rate.outputPerMTok == output, "\(model)")
            #expect(rate.longContextThresholdTokens == 272_000, "\(model)")
            #expect(rate.longContextInputMultiplier == 2, "\(model)")
            #expect(rate.longContextOutputMultiplier == 1.5, "\(model)")
        }
        #expect(table.pricing(for: "gpt-5.4-nano")?.outputPerMTok == 1.25)
        #expect(table.pricing(for: "gpt-5.5-pro")?.longContextThresholdTokens == 272_000)
    }

    @Test("A GPT-6 prompt over 272K input tokens bills 2x input and cache, 1.5x output")
    func gptSixLongContextCost() throws {
        // Codex splits input_tokens into uncached input + cached; together they are the
        // prompt the threshold is measured on.
        let long = TokenUsage(input: 100_000, output: 10_000, cacheRead: 200_000,
                              ephemeral5m: 0, ephemeral1h: 0, webSearch: 0, webFetch: 0)
        let cost = try #require(table.cost(for: long, model: "gpt-6-sol"))
        #expect(abs(cost.input - 0.1 * 2 * 2) < 1e-12)
        #expect(abs(cost.cacheRead - 0.2 * 0.20 * 2) < 1e-12)
        #expect(abs(cost.output - 0.01 * 10 * 1.5) < 1e-12)

        let short = TokenUsage(input: 100_000, output: 10_000, cacheRead: 100_000,
                               ephemeral5m: 0, ephemeral1h: 0, webSearch: 0, webFetch: 0)
        let shortCost = try #require(table.cost(for: short, model: "gpt-6-sol"))
        #expect(abs(shortCost.input - 0.1 * 2) < 1e-12)
        #expect(abs(shortCost.output - 0.01 * 10) < 1e-12)
    }

    @Test("Every current Claude model is priced at its published rate")
    func claudePricing() throws {
        // platform.claude.com/docs/en/about-claude/pricing, 2026-09-23:
        // input, 5m write, 1h write, cache hit, output.
        let expected: [(String, Double, Double, Double, Double, Double)] = [
            ("claude-fable-5-1", 10, 12.50, 20, 0.25, 50),
            ("claude-fable-5", 10, 12.50, 20, 1, 50),
            ("claude-opus-5-5", 4, 5, 8, 0.20, 20),
            ("claude-opus-5", 5, 6.25, 10, 0.50, 25),
            ("claude-opus-4-8", 5, 6.25, 10, 0.50, 25),
            ("claude-opus-4-7", 5, 6.25, 10, 0.50, 25),
            ("claude-opus-4-1", 15, 18.75, 30, 1.50, 75),
            ("claude-sonnet-5", 2, 2.50, 4, 0.20, 10),
            ("claude-sonnet-4-6", 3, 3.75, 6, 0.30, 15),
            ("claude-haiku-4-5-20251001", 1, 1.25, 2, 0.10, 5),
        ]
        for (model, input, write5m, write1h, hit, output) in expected {
            let rate = try #require(table.pricing(for: model), "\(model)")
            #expect(rate.inputPerMTok == input, "\(model)")
            #expect(rate.cacheWrite5mPerMTok == write5m, "\(model)")
            #expect(rate.cacheWrite1hPerMTok == write1h, "\(model)")
            #expect(rate.cacheReadPerMTok == hit, "\(model)")
            #expect(rate.outputPerMTok == output, "\(model)")
            #expect(rate.longContextThresholdTokens == nil, "\(model): full context at standard rates")
        }
    }

    @Test("Historical Codex models use their published OpenAI API rates")
    func historicalCodexPricing() {
        #expect(table.pricing(for: "gpt-5.3-codex")?.inputPerMTok == 1.75)
        #expect(table.pricing(for: "gpt-5.3-codex")?.outputPerMTok == 14)
        #expect(table.pricing(for: "gpt-5.1-codex-max")?.inputPerMTok == 1.25)
        #expect(table.pricing(for: "gpt-5.1-codex-mini")?.inputPerMTok == 0.25)
        #expect(table.pricing(for: "codex-mini-latest")?.cacheReadPerMTok == 0.375)
    }

    @Test("The moving gpt-5.6 alias resolves to Sol")
    func currentOpenAIAlias() {
        #expect(table.pricing(for: "gpt-5.6")?.inputPerMTok == 4)
        #expect(table.pricing(for: "GPT-5.6")?.outputPerMTok == 20)
    }

    @Test("Codex models without a public API price never inherit a broader rate")
    func explicitlyUnpricedCodexModels() {
        #expect(table.pricing(for: "gpt-5.3-codex-spark") == nil)
        #expect(table.pricing(for: "gpt-5.3-codex-spark-preview") == nil)
        #expect(table.pricing(for: "codex-auto-review") == nil)
    }

    @Test("GPT-5.6 long-context multipliers apply to the whole prompt and output")
    func codexLongContextCost() throws {
        let usage = TokenUsage(
            input: 200_000, output: 20_000, cacheRead: 100_000,
            ephemeral5m: 0, ephemeral1h: 0, webSearch: 0, webFetch: 0
        )
        let cost = try #require(table.cost(for: usage, model: "gpt-5.6-sol"))
        #expect(abs(cost.input - 1.60) < 1e-9)
        #expect(abs(cost.cacheRead - 0.08) < 1e-9)
        #expect(abs(cost.output - 0.60) < 1e-9)
        #expect(abs(cost.total - 2.28) < 1e-9)
    }

    @Test("claude-opus-4-8 has correct pricing")
    func opusFourEightPricing() {
        let p = table.pricing(for: "claude-opus-4-8")
        #expect(p != nil)
        #expect(p?.inputPerMTok == 5)
        #expect(p?.outputPerMTok == 25)
        #expect(p?.cacheWrite5mPerMTok == 6.25)
        #expect(p?.cacheWrite1hPerMTok == 10)
        #expect(p?.cacheReadPerMTok == 0.50)
    }

    @Test("claude-opus-5-5 has all five published standard rates")
    func opusFiveFivePricing() {
        let p = table.pricing(for: "claude-opus-5-5")
        #expect(p?.inputPerMTok == 4)
        #expect(p?.outputPerMTok == 20)
        #expect(p?.cacheWrite5mPerMTok == 5)
        #expect(p?.cacheWrite1hPerMTok == 8)
        #expect(p?.cacheReadPerMTok == 0.20)
    }

    @Test("claude-sonnet-4-6 has correct pricing")
    func sonnetFourSixPricing() {
        let p = table.pricing(for: "claude-sonnet-4-6")
        #expect(p != nil)
        #expect(p?.inputPerMTok == 3)
        #expect(p?.outputPerMTok == 15)
        #expect(p?.cacheWrite5mPerMTok == 3.75)
        #expect(p?.cacheWrite1hPerMTok == 6)
        #expect(p?.cacheReadPerMTok == 0.30)
    }

    @Test("claude-sonnet-5 has introductory pricing")
    func sonnetFivePricing() {
        let p = table.pricing(for: "claude-sonnet-5")
        #expect(p != nil)
        #expect(p?.inputPerMTok == 2)
        #expect(p?.outputPerMTok == 10)
        #expect(p?.cacheWrite5mPerMTok == 2.50)
        #expect(p?.cacheWrite1hPerMTok == 4)
        #expect(p?.cacheReadPerMTok == 0.20)
    }

    @Test("Date-suffixed sonnet-5 resolves to sonnet-5, not the broad claude-sonnet-4 key")
    func sonnetFiveDateSuffixed() {
        let p = table.pricing(for: "claude-sonnet-5-20260630")
        #expect(p?.inputPerMTok == 2)
        #expect(p?.outputPerMTok == 10)
    }

    @Test("claude-haiku-4-5 has correct pricing")
    func haikuFourFivePricing() {
        let p = table.pricing(for: "claude-haiku-4-5")
        #expect(p != nil)
        #expect(p?.inputPerMTok == 1)
        #expect(p?.outputPerMTok == 5)
        #expect(p?.cacheWrite5mPerMTok == 1.25)
        #expect(p?.cacheWrite1hPerMTok == 2)
        #expect(p?.cacheReadPerMTok == 0.10)
    }

    @Test("claude-opus-4-1 has distinct higher pricing")
    func opusFourOnePricing() {
        let p = table.pricing(for: "claude-opus-4-1")
        #expect(p != nil)
        #expect(p?.inputPerMTok == 15)
        #expect(p?.outputPerMTok == 75)
        #expect(p?.cacheWrite5mPerMTok == 18.75)
        #expect(p?.cacheWrite1hPerMTok == 30)
        #expect(p?.cacheReadPerMTok == 1.50)
    }

    // MARK: - Longest-prefix matching on date-suffixed IDs

    @Test("Date-suffixed opus-4-8 ID resolves via longest-prefix")
    func opusFourEightDateSuffixed() {
        let p = table.pricing(for: "claude-opus-4-8-20260101")
        #expect(p != nil)
        #expect(p?.inputPerMTok == 5)
        #expect(p?.outputPerMTok == 25)
    }

    @Test("Date-suffixed Opus 5.5 resolves through its explicit prefix")
    func opusFiveFiveDateSuffixed() {
        let p = table.pricing(for: "claude-opus-5-5-20260922")
        #expect(p?.inputPerMTok == 4)
        #expect(p?.outputPerMTok == 20)
        #expect(p?.cacheReadPerMTok == 0.20)
    }

    @Test("Date-suffixed sonnet-4-6 ID resolves via longest-prefix")
    func sonnetFourSixDateSuffixed() {
        let p = table.pricing(for: "claude-sonnet-4-6-20260601")
        #expect(p != nil)
        #expect(p?.inputPerMTok == 3)
    }

    // MARK: - Edge cases: IDs that log with different formats

    @Test("claude-sonnet-4-20250514 resolves to sonnet pricing via broad claude-sonnet-4 key")
    func sonnetFourZeroEdgeCase() {
        let p = table.pricing(for: "claude-sonnet-4-20250514")
        #expect(p != nil)
        #expect(p?.inputPerMTok == 3)
        #expect(p?.outputPerMTok == 15)
        #expect(p?.cacheWrite5mPerMTok == 3.75)
        #expect(p?.cacheWrite1hPerMTok == 6)
        #expect(p?.cacheReadPerMTok == 0.30)
    }

    @Test("claude-3-5-haiku-20241022 resolves to haiku-3.5 pricing")
    func haiku35DateSuffixedEdgeCase() {
        let p = table.pricing(for: "claude-3-5-haiku-20241022")
        #expect(p != nil)
        #expect(p?.inputPerMTok == 0.80)
        #expect(p?.outputPerMTok == 4)
        #expect(p?.cacheWrite5mPerMTok == 1.00)
        #expect(p?.cacheWrite1hPerMTok == 1.60)
        #expect(p?.cacheReadPerMTok == 0.08)
    }

    // MARK: - Longest-prefix wins over shorter match

    @Test("claude-sonnet-4-5 prefers specific key over broad claude-sonnet-4")
    func sonnetFourFivePrefersSpecificKey() {
        let p45 = table.pricing(for: "claude-sonnet-4-5")
        let pBroad = table.pricing(for: "claude-sonnet-4")
        #expect(p45 != nil)
        #expect(pBroad != nil)
        #expect(p45?.inputPerMTok == 3)
    }

    @Test("claude-opus-4-1 is not mis-priced by a non-existent broad opus-4 key")
    func opusFourOneNotMispriced() {
        // There is no "claude-opus-4" broad key; opus-4-1 must match "claude-opus-4-1" exactly.
        let p = table.pricing(for: "claude-opus-4-1")
        #expect(p?.inputPerMTok == 15)  // not 5 (which would be the opus 4.5-4.8 rate)
    }

    // MARK: - Unknown model

    @Test("Unknown model returns nil from pricing(for:)")
    func unknownModelPricingNil() {
        #expect(table.pricing(for: "unknown-model-xyz") == nil)
    }

    @Test("Unknown model returns nil from cost(for:model:)")
    func unknownModelCostNil() {
        let usage = TokenUsage(
            input: 100_000, output: 10_000,
            cacheRead: 5_000, ephemeral5m: 2_000, ephemeral1h: 1_000,
            webSearch: 0, webFetch: 0
        )
        #expect(table.cost(for: usage, model: "gpt-99-turbo") == nil)
    }

    @Test("PricingTable stub returns nil for unknown model (original stub test preserved)")
    func unknownModelReturnsNil() {
        #expect(table.pricing(for: "unknown-model-xyz") == nil)
        #expect(table.cost(for: .zero, model: "unknown-model-xyz") == nil)
    }

    // MARK: - Hand-computed cost verification

    @Test("Cost for opus-4-8 sample usage matches hand computation")
    func opusFourEightCostHandComputed() throws {
        // Sample usage:
        //   input:       1_000_000 tokens  -> 1 MTok x $5.00      = $5.000000
        //   output:        500_000 tokens  -> 0.5 MTok x $25.00   = $12.500000
        //   ephemeral5m:   200_000 tokens  -> 0.2 MTok x $6.25    = $1.250000
        //   ephemeral1h:   100_000 tokens  -> 0.1 MTok x $10.00   = $1.000000
        //   cacheRead:     400_000 tokens  -> 0.4 MTok x $0.50    = $0.200000
        //   cacheWrite (combined)                                   = $2.250000
        //   total                                                   = $19.950000
        let usage = TokenUsage(
            input: 1_000_000,
            output: 500_000,
            cacheRead: 400_000,
            ephemeral5m: 200_000,
            ephemeral1h: 100_000,
            webSearch: 0,
            webFetch: 0
        )
        let cost = try #require(table.cost(for: usage, model: "claude-opus-4-8"))

        let tolerance = 1e-9
        #expect(abs(cost.input - 5.0) < tolerance)
        #expect(abs(cost.output - 12.5) < tolerance)
        #expect(abs(cost.cacheWrite - 2.25) < tolerance)
        #expect(abs(cost.cacheRead - 0.2) < tolerance)
        #expect(abs(cost.total - 19.95) < tolerance)
    }

    @Test("Cost for haiku-3-5 date-suffixed ID matches hand computation")
    func haiku35CostHandComputed() throws {
        // Sample: 500_000 input, 100_000 output, 50_000 cache read, no cache write
        //   input:     0.5 MTok x $0.80  = $0.40
        //   output:    0.1 MTok x $4.00  = $0.40
        //   cacheRead: 0.05 MTok x $0.08 = $0.004
        //   cacheWrite: 0
        //   total = $0.804
        let usage = TokenUsage(
            input: 500_000,
            output: 100_000,
            cacheRead: 50_000,
            ephemeral5m: 0,
            ephemeral1h: 0,
            webSearch: 0,
            webFetch: 0
        )
        let cost = try #require(table.cost(for: usage, model: "claude-3-5-haiku-20241022"))

        let tolerance = 1e-9
        #expect(abs(cost.input - 0.40) < tolerance)
        #expect(abs(cost.output - 0.40) < tolerance)
        #expect(abs(cost.cacheWrite - 0.0) < tolerance)
        #expect(abs(cost.cacheRead - 0.004) < tolerance)
        #expect(abs(cost.total - 0.804) < tolerance)
    }

    @Test("Cost for sonnet-4-6 with 1h cache write prices both tiers correctly")
    func sonnetFourSixCostWithBothCacheTiers() throws {
        // 1_000_000 ephemeral5m x $3.75/MTok = $3.75
        // 1_000_000 ephemeral1h x $6.00/MTok = $6.00
        // combined cacheWrite = $9.75
        let usage = TokenUsage(
            input: 0,
            output: 0,
            cacheRead: 0,
            ephemeral5m: 1_000_000,
            ephemeral1h: 1_000_000,
            webSearch: 0,
            webFetch: 0
        )
        let cost = try #require(table.cost(for: usage, model: "claude-sonnet-4-6"))
        #expect(abs(cost.cacheWrite - 9.75) < 1e-9)
    }

    // MARK: - Boundary-aware prefix matching (regression for FIX-MED)

    @Test("claude-opus-4-10 must NOT match claude-opus-4-1 key (boundary check)")
    func opusFourTenDoesNotMatchOpusFourOne() {
        let p = table.pricing(for: "claude-opus-4-10")
        #expect(p == nil, "claude-opus-4-10 must return nil, not Opus 4.1 pricing")
    }

    @Test("claude-opus-4-11-20270101 must NOT match claude-opus-4-1 key (boundary check)")
    func opusFourElevenDateSuffixedDoesNotMatchOpusFourOne() {
        let p = table.pricing(for: "claude-opus-4-11-20270101")
        #expect(p == nil, "claude-opus-4-11-20270101 must return nil, not Opus 4.1 pricing")
    }

    @Test("claude-opus-4-1 still resolves to Opus 4.1 pricing after boundary fix")
    func opusFourOneExactStillResolves() {
        let p = table.pricing(for: "claude-opus-4-1")
        #expect(p?.inputPerMTok == 15)
        #expect(p?.outputPerMTok == 75)
    }

    @Test("claude-opus-4-1-20250805 still resolves to Opus 4.1 pricing after boundary fix")
    func opusFourOneDateSuffixedStillResolves() {
        let p = table.pricing(for: "claude-opus-4-1-20250805")
        #expect(p?.inputPerMTok == 15)
        #expect(p?.outputPerMTok == 75)
    }

    // MARK: - Case insensitivity

    @Test("Model lookup is case-insensitive")
    func caseInsensitiveLookup() {
        let lower = table.pricing(for: "claude-opus-4-8")
        let upper = table.pricing(for: "Claude-Opus-4-8")
        let mixed = table.pricing(for: "CLAUDE-OPUS-4-8")
        #expect(lower != nil)
        #expect(upper?.inputPerMTok == lower?.inputPerMTok)
        #expect(mixed?.inputPerMTok == lower?.inputPerMTok)
    }

    @Test("Opus 5.5 model lookup is case-insensitive")
    func opusFiveFiveCaseInsensitiveLookup() {
        #expect(table.pricing(for: "CLAUDE-OPUS-5-5")?.inputPerMTok == 4)
    }

    // MARK: - Zero usage produces zero cost (not nil) for known model

    @Test("Zero usage for known model returns zero cost (not nil)")
    func zeroUsageKnownModel() throws {
        let cost = try #require(table.cost(for: .zero, model: "claude-opus-4-8"))
        #expect(cost.total == 0)
        #expect(cost.input == 0)
        #expect(cost.output == 0)
        #expect(cost.cacheWrite == 0)
        #expect(cost.cacheRead == 0)
    }

    // MARK: - Variant tags and short aliases (context-window tag + bare family aliases)

    @Test("claude-opus-4-8[1m] prices identically to claude-opus-4-8")
    func opusOneMillionContextVariant() {
        let base = table.pricing(for: "claude-opus-4-8")
        let variant = table.pricing(for: "claude-opus-4-8[1m]")
        #expect(variant != nil)
        #expect(variant?.inputPerMTok == base?.inputPerMTok)
        #expect(variant?.outputPerMTok == base?.outputPerMTok)
        #expect(variant?.inputPerMTok == 5)
        #expect(variant?.outputPerMTok == 25)
    }

    @Test("A bracketed variant tag does not break the boundary check (claude-opus-4-1[1m] -> Opus 4.1)")
    func opusFourOneOneMillionVariant() {
        let p = table.pricing(for: "claude-opus-4-1[1m]")
        #expect(p?.inputPerMTok == 15)
        #expect(p?.outputPerMTok == 75)
    }

    @Test("Bare alias 'opus' resolves to claude-opus-5-5 pricing")
    func bareOpusAlias() {
        let p = table.pricing(for: "opus")
        #expect(p?.inputPerMTok == 4)
        #expect(p?.outputPerMTok == 20)
        #expect(p?.cacheReadPerMTok == 0.20)
    }

    @Test("Bare alias 'sonnet' resolves to claude-sonnet-5 pricing")
    func bareSonnetAlias() {
        let p = table.pricing(for: "sonnet")
        #expect(p?.inputPerMTok == 2)
        #expect(p?.outputPerMTok == 10)
    }

    @Test("Bare alias 'fable' resolves to claude-fable-5-1 pricing")
    func bareFableAlias() {
        let p = table.pricing(for: "fable")
        #expect(p?.inputPerMTok == 10)
        #expect(p?.outputPerMTok == 50)
        // 5.1's cache-read rate, not Fable 5's $1.00.
        #expect(p?.cacheReadPerMTok == 0.25)
    }

    @Test("Bare alias 'haiku' resolves to claude-haiku-4-5 pricing")
    func bareHaikuAlias() {
        let p = table.pricing(for: "haiku")
        #expect(p?.inputPerMTok == 1)
        #expect(p?.outputPerMTok == 5)
    }

    @Test("Alias matching is case-insensitive")
    func aliasCaseInsensitive() {
        #expect(table.pricing(for: "OPUS")?.inputPerMTok == 4)
    }

    // MARK: - Fable / Mythos / Opus 5

    @Test("claude-fable-5-1 has correct pricing")
    func fableFiveOnePricing() {
        let p = table.pricing(for: "claude-fable-5-1")
        #expect(p != nil)
        #expect(p?.inputPerMTok == 10)
        #expect(p?.outputPerMTok == 50)
        #expect(p?.cacheWrite5mPerMTok == 12.50)
        #expect(p?.cacheWrite1hPerMTok == 20)
        #expect(p?.cacheReadPerMTok == 0.25)
    }

    @Test("claude-fable-5 has correct pricing")
    func fableFivePricing() {
        let p = table.pricing(for: "claude-fable-5")
        #expect(p != nil)
        #expect(p?.inputPerMTok == 10)
        #expect(p?.outputPerMTok == 50)
        #expect(p?.cacheReadPerMTok == 1.00)
    }

    /// The two Fable generations differ ONLY in cache reads ($0.25 vs $1.00), and
    /// "claude-fable-5" is a legal prefix of "claude-fable-5-1" under the boundary rule.
    /// Longest-prefix ordering is the only thing keeping 5.1 off the 5 entry, and a
    /// cache-heavy session priced at the wrong one is off by 4x on that line.
    @Test("claude-fable-5-1 does not fall through to the shorter claude-fable-5 key")
    func fableFiveOnePrefersSpecificKey() {
        #expect(table.pricing(for: "claude-fable-5-1")?.cacheReadPerMTok == 0.25)
        #expect(table.pricing(for: "claude-fable-5")?.cacheReadPerMTok == 1.00)
        #expect(table.pricing(for: "claude-fable-5-1-20260901")?.cacheReadPerMTok == 0.25)
    }

    @Test("claude-mythos-5-1 prices identically to claude-fable-5-1")
    func mythosFiveOnePricing() {
        let mythos = table.pricing(for: "claude-mythos-5-1")
        let fable = table.pricing(for: "claude-fable-5-1")
        #expect(mythos != nil)
        #expect(mythos?.inputPerMTok == fable?.inputPerMTok)
        #expect(mythos?.outputPerMTok == fable?.outputPerMTok)
        #expect(mythos?.cacheReadPerMTok == fable?.cacheReadPerMTok)
    }

    @Test("claude-mythos-5 does not capture claude-mythos-5-1")
    func mythosFiveOnePrefersSpecificKey() {
        #expect(table.pricing(for: "claude-mythos-5")?.cacheReadPerMTok == 1.00)
        #expect(table.pricing(for: "claude-mythos-5-1")?.cacheReadPerMTok == 0.25)
    }

    @Test("claude-opus-5 has correct pricing and is not confused with the 4.x keys")
    func opusFivePricing() {
        let p = table.pricing(for: "claude-opus-5")
        #expect(p != nil)
        #expect(p?.inputPerMTok == 5)
        #expect(p?.outputPerMTok == 25)
        #expect(p?.cacheWrite5mPerMTok == 6.25)
        #expect(p?.cacheWrite1hPerMTok == 10)
        #expect(p?.cacheReadPerMTok == 0.50)
        // Not the Opus 4.1 rate, which the ambiguity would show up as.
        #expect(p?.inputPerMTok != 15)
    }

    @Test("claude-opus-5[1m] prices identically to claude-opus-5")
    func opusFiveOneMillionContextVariant() {
        let variant = table.pricing(for: "claude-opus-5[1m]")
        #expect(variant?.inputPerMTok == 5)
        #expect(variant?.outputPerMTok == 25)
    }

    @Test("claude-opus-5-5[1m] retains Opus 5.5 standard pricing")
    func opusFiveFiveOneMillionContextVariant() {
        let variant = table.pricing(for: "claude-opus-5-5[1m]")
        #expect(variant?.inputPerMTok == 4)
        #expect(variant?.outputPerMTok == 20)
        #expect(variant?.cacheReadPerMTok == 0.20)
    }

    @Test("Cost for Opus 5.5 mixed usage matches the published rates")
    func opusFiveFiveMixedCost() throws {
        let usage = TokenUsage(
            input: 1_000_000,
            output: 500_000,
            cacheRead: 400_000,
            ephemeral5m: 200_000,
            ephemeral1h: 100_000,
            webSearch: 0,
            webFetch: 0
        )
        let cost = try #require(table.cost(for: usage, model: "claude-opus-5-5"))

        #expect(abs(cost.input - 4) < 1e-9)
        #expect(abs(cost.output - 10) < 1e-9)
        #expect(abs(cost.cacheWrite - 1.8) < 1e-9)
        #expect(abs(cost.cacheRead - 0.08) < 1e-9)
        #expect(abs(cost.total - 15.88) < 1e-9)
    }

    @Test("claude-fable-5-1[1m] prices identically to claude-fable-5-1")
    func fableOneMillionContextVariant() {
        let variant = table.pricing(for: "claude-fable-5-1[1m]")
        #expect(variant?.inputPerMTok == 10)
        #expect(variant?.outputPerMTok == 50)
        #expect(variant?.cacheReadPerMTok == 0.25)
    }

    @Test("Cost for fable-5-1 sample usage matches hand computation")
    func fableFiveOneCostHandComputed() throws {
        // Sample usage:
        //   input:       1_000_000 tokens  -> 1 MTok x $10.00   = $10.00
        //   output:        500_000 tokens  -> 0.5 MTok x $50.00 = $25.00
        //   ephemeral5m:   200_000 tokens  -> 0.2 MTok x $12.50 = $2.50
        //   ephemeral1h:   100_000 tokens  -> 0.1 MTok x $20.00 = $2.00
        //   cacheRead:     400_000 tokens  -> 0.4 MTok x $0.25  = $0.10
        //   total                                                = $39.60
        let usage = TokenUsage(
            input: 1_000_000,
            output: 500_000,
            cacheRead: 400_000,
            ephemeral5m: 200_000,
            ephemeral1h: 100_000,
            webSearch: 0,
            webFetch: 0
        )
        let cost = try #require(table.cost(for: usage, model: "claude-fable-5-1"))

        let tolerance = 1e-9
        #expect(abs(cost.input - 10.0) < tolerance)
        #expect(abs(cost.output - 25.0) < tolerance)
        #expect(abs(cost.cacheWrite - 4.5) < tolerance)
        #expect(abs(cost.cacheRead - 0.1) < tolerance)
        #expect(abs(cost.total - 39.6) < tolerance)
    }
}
