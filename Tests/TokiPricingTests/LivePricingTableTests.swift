import Testing
import Foundation
import TokiModels
@testable import TokiPricing

@Suite("LivePricingTable")
struct LivePricingTableTests {

    // MARK: - Temp file helper

    /// Returns a unique temp file URL under the system temp directory — NEVER the real
    /// `~/Library/Application Support/Toki` path — and removes any leftover file there.
    private func makeTempFileURL() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("toki-live-pricing-test-\(UUID().uuidString)")
            .appendingPathComponent("pricing-history.json")
        try? FileManager.default.removeItem(at: url)
        return url
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    // MARK: - Date helper

    /// Builds a UTC date at midnight for the given calendar components.
    private func utcDate(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(
            from: DateComponents(year: year, month: month, day: day, hour: 0, minute: 0, second: 0)
        )!
    }

    // MARK: - Crafted seed

    /// The 2026-09-01 transition between Sonnet 5's intro and standard windows.
    private var sonnetFiveTransition: Date { utcDate(2026, 9, 1) }

    /// Crafted rate periods: Sonnet 5 intro/standard, an open-ended Opus 4.8 period, plus a
    /// broad "claude-sonnet-4" and a specific "claude-sonnet-4-6" for longest-prefix tests,
    /// and deliberately off-list Opus 5 / Opus 5.5 / Fable 5.1 rates so an alias test can prove WHICH
    /// id the alias expanded to rather than merely that some rate came back.
    private func craftedSeed() -> [RatePeriod] {
        [
            // Sonnet 5 — introductory $2 / $10 through 2026-09-01 (exclusive).
            RatePeriod(
                modelPrefix: "claude-sonnet-5",
                inputPerMTok: 2, outputPerMTok: 10,
                cacheWrite5mPerMTok: 2.50, cacheWrite1hPerMTok: 4,
                cacheReadPerMTok: 0.20,
                effectiveFrom: nil, effectiveUntil: sonnetFiveTransition
            ),
            // Sonnet 5 — standard $3 / $15 from 2026-09-01.
            RatePeriod(
                modelPrefix: "claude-sonnet-5",
                inputPerMTok: 3, outputPerMTok: 15,
                cacheWrite5mPerMTok: 3.75, cacheWrite1hPerMTok: 6,
                cacheReadPerMTok: 0.30,
                effectiveFrom: sonnetFiveTransition, effectiveUntil: nil
            ),
            // Opus 4.8 — open-ended $5 / $25.
            RatePeriod(
                modelPrefix: "claude-opus-4-8",
                inputPerMTok: 5, outputPerMTok: 25,
                cacheWrite5mPerMTok: 6.25, cacheWrite1hPerMTok: 10,
                cacheReadPerMTok: 0.50,
                effectiveFrom: nil, effectiveUntil: nil
            ),
            // Opus 5 — deliberately NOT the real $5 / $25, so the `opus` alias test can
            // tell "resolved to claude-opus-5" apart from "resolved to claude-opus-4-8".
            RatePeriod(
                modelPrefix: "claude-opus-5",
                inputPerMTok: 9, outputPerMTok: 45,
                cacheWrite5mPerMTok: 11.25, cacheWrite1hPerMTok: 18,
                cacheReadPerMTok: 0.90,
                effectiveFrom: nil, effectiveUntil: nil
            ),
            // Opus 5.5 — actual published rates, distinct from the crafted Opus 5 rate so
            // the moving `opus` alias must select this prefix.
            RatePeriod(
                modelPrefix: "claude-opus-5-5",
                inputPerMTok: 4, outputPerMTok: 20,
                cacheWrite5mPerMTok: 5, cacheWrite1hPerMTok: 8,
                cacheReadPerMTok: 0.20,
                effectiveFrom: nil, effectiveUntil: nil
            ),
            // Fable 5.1 — likewise off-list, for the `fable` alias.
            RatePeriod(
                modelPrefix: "claude-fable-5-1",
                inputPerMTok: 11, outputPerMTok: 55,
                cacheWrite5mPerMTok: 13.75, cacheWrite1hPerMTok: 22,
                cacheReadPerMTok: 0.27,
                effectiveFrom: nil, effectiveUntil: nil
            ),
            // Broad Sonnet 4 — $3 / $15.
            RatePeriod(
                modelPrefix: "claude-sonnet-4",
                inputPerMTok: 3, outputPerMTok: 15,
                cacheWrite5mPerMTok: 3.75, cacheWrite1hPerMTok: 6,
                cacheReadPerMTok: 0.30,
                effectiveFrom: nil, effectiveUntil: nil
            ),
            // Specific Sonnet 4.6 — distinct rates so longest-prefix wins are visible.
            RatePeriod(
                modelPrefix: "claude-sonnet-4-6",
                inputPerMTok: 7, outputPerMTok: 35,
                cacheWrite5mPerMTok: 8.75, cacheWrite1hPerMTok: 14,
                cacheReadPerMTok: 0.70,
                effectiveFrom: nil, effectiveUntil: nil
            ),
        ]
    }

    /// A `LivePricingTable` backed by a temp-file store seeded with the crafted periods
    /// and an empty default seed (so only the crafted periods are present).
    private func makeTable(url: URL) -> LivePricingTable {
        let store = RateHistoryStore(fileURL: url, seed: craftedSeed())
        return LivePricingTable(store: store)
    }

    // MARK: - Price schedule

    @Test("A model's schedule agrees with point-in-time lookup on every date, boundaries included")
    func scheduleAgreesWithLookup() throws {
        let url = makeTempFileURL()
        defer { cleanup(url) }
        let table = makeTable(url: url)
        let transition = sonnetFiveTransition
        let dates = [
            Date.distantPast, utcDate(2020, 1, 1), transition.addingTimeInterval(-0.001),
            transition, transition.addingTimeInterval(0.001), utcDate(2027, 1, 1), Date.distantFuture,
        ]
        for model in ["claude-sonnet-5", "claude-sonnet-5-20260901", "claude-sonnet-4-6", "claude-opus-4-8",
                      "opus", "claude-haiku-9", "<synthetic>"] {
            let schedule = try #require(table.schedule(for: model), "\(model)")
            for date in dates {
                let expected = table.pricing(for: model, on: date)
                let actual = schedule.pricing(on: date)
                #expect(actual?.inputPerMTok == expected?.inputPerMTok, "\(model) @ \(date)")
                #expect(actual?.outputPerMTok == expected?.outputPerMTok, "\(model) @ \(date)")
                #expect(actual?.cacheReadPerMTok == expected?.cacheReadPerMTok, "\(model) @ \(date)")
            }
        }
        // The Sonnet 5 schedule really does change at the transition.
        let sonnet = try #require(table.schedule(for: "claude-sonnet-5"))
        #expect(sonnet.pricing(on: transition.addingTimeInterval(-1))?.inputPerMTok == 2)
        #expect(sonnet.pricing(on: transition)?.inputPerMTok == 3)
    }

    // MARK: - Point-in-time Sonnet 5

    @Test("Sonnet 5 in July 2026 uses the introductory $2 input rate")
    func sonnetFiveIntroRate() {
        let url = makeTempFileURL()
        defer { cleanup(url) }
        let table = makeTable(url: url)

        let pricing = table.pricing(for: "claude-sonnet-5", on: utcDate(2026, 7, 15))
        #expect(pricing?.inputPerMTok == 2)
        #expect(pricing?.outputPerMTok == 10)
    }

    @Test("Sonnet 5 in September 2026 uses the standard $3 input rate (point-in-time)")
    func sonnetFiveStandardRate() {
        let url = makeTempFileURL()
        defer { cleanup(url) }
        let table = makeTable(url: url)

        let pricing = table.pricing(for: "claude-sonnet-5", on: utcDate(2026, 9, 15))
        #expect(pricing?.inputPerMTok == 3)
        #expect(pricing?.outputPerMTok == 15)
    }

    @Test("The 2026-09-01 transition moment is priced at the standard rate (exclusive upper bound)")
    func sonnetFiveTransitionBoundary() {
        let url = makeTempFileURL()
        defer { cleanup(url) }
        let table = makeTable(url: url)

        // The exclusive upper bound of intro == inclusive lower bound of standard.
        let pricing = table.pricing(for: "claude-sonnet-5", on: sonnetFiveTransition)
        #expect(pricing?.inputPerMTok == 3)

        // One second before the transition is still the intro rate.
        let justBefore = sonnetFiveTransition.addingTimeInterval(-1)
        #expect(table.pricing(for: "claude-sonnet-5", on: justBefore)?.inputPerMTok == 2)
    }

    // MARK: - Boundary match on date-suffixed ids

    @Test("A date-suffixed Sonnet 5 id resolves via boundary match")
    func dateSuffixedIdResolves() {
        let url = makeTempFileURL()
        defer { cleanup(url) }
        let table = makeTable(url: url)

        // Within the intro window (the suffix is just an id, not a date filter).
        let pricing = table.pricing(for: "claude-sonnet-5-20260815", on: utcDate(2026, 7, 1))
        #expect(pricing?.inputPerMTok == 2)
    }

    // MARK: - Longest-prefix correctness

    @Test("claude-sonnet-4-6 matches the specific prefix, not the broad claude-sonnet-4")
    func longestPrefixWins() {
        let url = makeTempFileURL()
        defer { cleanup(url) }
        let table = makeTable(url: url)

        let specific = table.pricing(for: "claude-sonnet-4-6", on: utcDate(2026, 7, 1))
        #expect(specific?.inputPerMTok == 7, "Should match claude-sonnet-4-6, not the broad claude-sonnet-4")

        // A dated Sonnet 4.0 id still falls back to the broad prefix.
        let broad = table.pricing(for: "claude-sonnet-4-20250514", on: utcDate(2026, 7, 1))
        #expect(broad?.inputPerMTok == 3, "claude-sonnet-4-* should match the broad claude-sonnet-4 prefix")
    }

    // MARK: - Open-ended Opus

    @Test("Open-ended Opus period resolves on any date")
    func openEndedOpus() {
        let url = makeTempFileURL()
        defer { cleanup(url) }
        let table = makeTable(url: url)

        #expect(table.pricing(for: "claude-opus-4-8", on: utcDate(2020, 1, 1))?.inputPerMTok == 5)
        #expect(table.pricing(for: "claude-opus-4-8-20260301", on: utcDate(2026, 7, 1))?.inputPerMTok == 5)
    }

    // MARK: - Unknown model

    @Test("Default bundled history prices Codex and leaves Spark unpriced")
    func bundledCodexRates() {
        let url = makeTempFileURL()
        defer { cleanup(url) }
        let table = LivePricingTable(store: RateHistoryStore(fileURL: url))

        #expect(table.pricing(for: "gpt-5.6-sol", on: utcDate(2026, 9, 4))?.inputPerMTok == 4)
        #expect(table.pricing(for: "gpt-5.3-codex", on: utcDate(2026, 9, 4))?.outputPerMTok == 14)
        #expect(table.pricing(for: "gpt-5.3-codex-spark", on: utcDate(2026, 9, 4)) == nil)
    }

    @Test("An unknown model returns nil")
    func unknownModelIsNil() {
        let url = makeTempFileURL()
        defer { cleanup(url) }
        let table = makeTable(url: url)

        #expect(table.pricing(for: "gpt-4o", on: utcDate(2026, 7, 1)) == nil)
        #expect(table.pricing(for: "claude-haiku-9-0", on: utcDate(2026, 7, 1)) == nil)
    }

    // MARK: - No boundary false positives

    @Test("A prefix does not match when the next character is not a boundary")
    func noBoundaryFalsePositive() {
        let url = makeTempFileURL()
        defer { cleanup(url) }
        let store = RateHistoryStore(
            fileURL: url,
            seed: [
                RatePeriod(
                    modelPrefix: "claude-opus-4-1",
                    inputPerMTok: 15, outputPerMTok: 75,
                    cacheWrite5mPerMTok: 18.75, cacheWrite1hPerMTok: 30,
                    cacheReadPerMTok: 1.50,
                    effectiveFrom: nil, effectiveUntil: nil
                )
            ]
        )
        let table = LivePricingTable(store: store)

        // "claude-opus-4-10" must NOT match "claude-opus-4-1" (next char is "0", not "-").
        #expect(table.pricing(for: "claude-opus-4-10", on: utcDate(2026, 7, 1)) == nil)
        // The exact id and a date-suffixed variant DO match.
        #expect(table.pricing(for: "claude-opus-4-1", on: utcDate(2026, 7, 1))?.inputPerMTok == 15)
        #expect(table.pricing(for: "claude-opus-4-1-20250805", on: utcDate(2026, 7, 1))?.inputPerMTok == 15)
    }

    // MARK: - Variant tags and short aliases

    @Test("claude-opus-4-8[1m] prices identically to claude-opus-4-8 (Live)")
    func oneMillionContextVariantLive() {
        let url = makeTempFileURL()
        defer { cleanup(url) }
        let table = makeTable(url: url)

        #expect(table.pricing(for: "claude-opus-4-8[1m]", on: utcDate(2026, 7, 1))?.inputPerMTok == 5)
    }

    @Test("Opus 5.5 exact, dated, [1m], and case variants resolve in live pricing")
    func opusFiveFiveLiveVariants() {
        let url = makeTempFileURL()
        defer { cleanup(url) }
        let table = makeTable(url: url)
        let date = utcDate(2026, 7, 1)

        for model in ["claude-opus-5-5", "claude-opus-5-5-20260922", "claude-opus-5-5[1m]", "CLAUDE-OPUS-5-5"] {
            let p = table.pricing(for: model, on: date)
            #expect(p?.inputPerMTok == 4)
            #expect(p?.outputPerMTok == 20)
            #expect(p?.cacheWrite5mPerMTok == 5)
            #expect(p?.cacheWrite1hPerMTok == 8)
            #expect(p?.cacheReadPerMTok == 0.20)
        }
    }

    @Test("Bare alias 'opus' resolves to claude-opus-5-5, not historical Opus rates (Live)")
    func bareOpusAliasLive() {
        let url = makeTempFileURL()
        defer { cleanup(url) }
        let table = makeTable(url: url)

        // Crafted seed prices claude-opus-5 at $9 and claude-opus-4-8 at $5, while the
        // current Opus 5.5 prefix is $4. The alias must select the latter.
        #expect(table.pricing(for: "opus", on: utcDate(2026, 7, 1))?.inputPerMTok == 4)
    }

    @Test("Bare alias 'sonnet' resolves to claude-sonnet-5, not the broad claude-sonnet-4 (Live)")
    func bareSonnetAliasLive() {
        let url = makeTempFileURL()
        defer { cleanup(url) }
        let table = makeTable(url: url)

        // Crafted seed prices claude-sonnet-5 at $2 in July, distinct from both the broad
        // claude-sonnet-4 ($3) and the specific claude-sonnet-4-6 ($7).
        #expect(table.pricing(for: "sonnet", on: utcDate(2026, 7, 1))?.inputPerMTok == 2)
    }

    @Test("Bare alias 'fable' resolves to claude-fable-5-1 (Live)")
    func bareFableAliasLive() {
        let url = makeTempFileURL()
        defer { cleanup(url) }
        let table = makeTable(url: url)

        #expect(table.pricing(for: "fable", on: utcDate(2026, 7, 1))?.inputPerMTok == 11)
    }

    /// The alias is expanded BEFORE the rate history is consulted, so a bare family name
    /// only prices when the expanded id has a period — this is the failure mode that
    /// leaves a whole model unpriced, and it is silent (`nil`, not an error).
    @Test("A bare alias whose expansion has no rate period returns nil (Live)")
    func bareAliasWithoutRatePeriodIsNil() {
        let url = makeTempFileURL()
        defer { cleanup(url) }
        let table = makeTable(url: url)

        // The crafted seed carries no claude-haiku-4-5 period.
        #expect(table.pricing(for: "haiku", on: utcDate(2026, 7, 1)) == nil)
    }
}
