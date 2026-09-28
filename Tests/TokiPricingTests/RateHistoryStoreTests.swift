import Testing
import Foundation
import TokiModels
@testable import TokiPricing

@Suite("RateHistoryStore")
struct RateHistoryStoreTests {

    // MARK: - Temp file helper

    /// Returns a unique temp file URL under the system temp directory — NEVER the
    /// real `~/Library/Application Support/Toki` path — and removes any leftover
    /// file at that path before handing it back.
    private func makeTempFileURL() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("toki-pricing-test-\(UUID().uuidString)")
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

    // MARK: - Fresh store returns the seed

    @Test("A fresh store with no existing file returns the seed")
    func freshStoreReturnsSeed() {
        let url = makeTempFileURL()
        defer { cleanup(url) }

        let store = RateHistoryStore(fileURL: url)
        let all = store.all()

        #expect(all.count == BundledRates.seed.count)
        for seeded in BundledRates.seed {
            #expect(all.contains(seeded))
        }
    }

    @Test("A fresh store persists the seed to disk")
    func freshStorePersistsSeedToDisk() {
        let url = makeTempFileURL()
        defer { cleanup(url) }

        _ = RateHistoryStore(fileURL: url)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - Merge adds genuinely new periods

    @Test("Merge adds a genuinely new (prefix, from) period")
    func mergeAddsNewPeriod() {
        let url = makeTempFileURL()
        defer { cleanup(url) }

        let store = RateHistoryStore(fileURL: url)
        let baselineCount = store.all().count

        let newPeriod = RatePeriod(
            modelPrefix: "claude-haiku-9-0",
            inputPerMTok: 0.5, outputPerMTok: 2.5,
            cacheWrite5mPerMTok: 0.625, cacheWrite1hPerMTok: 1.0,
            cacheReadPerMTok: 0.05,
            effectiveFrom: nil, effectiveUntil: nil
        )

        let result = store.merge([newPeriod])

        #expect(result.count == baselineCount + 1)
        #expect(result.contains(newPeriod))
    }

    // MARK: - Merge of a changed rate freezes the past and opens a new period

    @Test("Merge of a changed current rate closes the old period and appends a new open one")
    func mergeChangedRateFreezesPastAndOpensNew() {
        let url = makeTempFileURL()
        defer { cleanup(url) }

        let store = RateHistoryStore(fileURL: url)
        let baselineCount = store.all().count
        let now = utcDate(2026, 6, 30)

        // The bundled open-ended Opus 4.8 period is $5; the page now shows $5.5.
        let changed = RatePeriod(
            modelPrefix: "claude-opus-4-8",
            inputPerMTok: 5.5, outputPerMTok: 27.5,
            cacheWrite5mPerMTok: 6.875, cacheWrite1hPerMTok: 11,
            cacheReadPerMTok: 0.55,
            effectiveFrom: nil, effectiveUntil: nil
        )

        let result = store.merge([changed], asOf: now)

        #expect(result.count == baselineCount + 1, "A changed rate must close-old + append-new (count grows by 1)")

        let opus = result.filter { $0.modelPrefix == "claude-opus-4-8" }
        #expect(opus.count == 2)

        // The old $5 period is retained but now closed at `now`.
        let old = opus.first { $0.inputPerMTok == 5 }
        #expect(old != nil)
        #expect(old?.effectiveUntil == now)

        // The new $5.5 period is open and starts at `now`.
        let new = opus.first { $0.inputPerMTok == 5.5 }
        #expect(new?.effectiveFrom == now)
        #expect(new?.effectiveUntil == nil)

        // Point-in-time: before `now` prices at the old $5 rate, on/after at $5.5.
        let before = RatePeriod.representative(in: opus, on: now.addingTimeInterval(-1))
        #expect(before?.inputPerMTok == 5)
        let after = RatePeriod.representative(in: opus, on: now)
        #expect(after?.inputPerMTok == 5.5)
    }

    // MARK: - Idempotency

    @Test("Merging the same current rate twice (same now) adds nothing")
    func mergeSameRateTwiceIsIdempotent() {
        let url = makeTempFileURL()
        defer { cleanup(url) }

        let store = RateHistoryStore(fileURL: url)
        let now = utcDate(2026, 6, 30)

        // An incoming that exactly matches the seeded open-ended Opus 4.8 rate.
        let same = RatePeriod(
            modelPrefix: "claude-opus-4-8",
            inputPerMTok: 5, outputPerMTok: 25,
            cacheWrite5mPerMTok: 6.25, cacheWrite1hPerMTok: 10,
            cacheReadPerMTok: 0.50,
            effectiveFrom: nil, effectiveUntil: nil
        )

        let first = store.merge([same], asOf: now)
        let firstCount = first.count
        let second = store.merge([same], asOf: now)

        #expect(second.count == firstCount, "Re-merging an unchanged rate must not add periods")
        let opus = second.filter { $0.modelPrefix == "claude-opus-4-8" }
        #expect(opus.count == 1, "No duplicate Opus 4.8 period should be created")
    }

    // MARK: - Merge never removes a pre-existing period

    @Test("Merge never removes a pre-existing period")
    func mergeNeverRemovesExistingPeriod() {
        let url = makeTempFileURL()
        defer { cleanup(url) }

        let store = RateHistoryStore(fileURL: url)
        let before = store.all()

        // Merge something entirely unrelated.
        let unrelated = RatePeriod(
            modelPrefix: "claude-haiku-9-9",
            inputPerMTok: 0.1, outputPerMTok: 0.5,
            cacheWrite5mPerMTok: 0.125, cacheWrite1hPerMTok: 0.2,
            cacheReadPerMTok: 0.01,
            effectiveFrom: nil, effectiveUntil: nil
        )
        let after = store.merge([unrelated])

        for period in before {
            #expect(after.contains(period), "Pre-existing period \(period) must survive the merge")
        }
    }

    // MARK: - Persistence round-trips

    @Test("Persistence round-trips: a second store on the same fileURL sees merged data")
    func persistenceRoundTrips() {
        let url = makeTempFileURL()
        defer { cleanup(url) }

        let firstStore = RateHistoryStore(fileURL: url)
        let newPeriod = RatePeriod(
            modelPrefix: "claude-haiku-9-1",
            inputPerMTok: 0.6, outputPerMTok: 3.0,
            cacheWrite5mPerMTok: 0.75, cacheWrite1hPerMTok: 1.2,
            cacheReadPerMTok: 0.06,
            effectiveFrom: nil, effectiveUntil: nil
        )
        firstStore.merge([newPeriod])

        // A fresh store instance reading the same file should see the merged period
        // without needing a fresh merge call.
        let secondStore = RateHistoryStore(fileURL: url)
        let all = secondStore.all()

        #expect(all.contains(newPeriod))
    }

    @Test("Persistence round-trips a frozen rate change across store instances")
    func persistenceRoundTripsRateChange() {
        let url = makeTempFileURL()
        defer { cleanup(url) }
        let now = utcDate(2026, 6, 30)

        let firstStore = RateHistoryStore(fileURL: url)
        // Seeded Haiku 4.5 is $1; the page now shows $1.1.
        let changed = RatePeriod(
            modelPrefix: "claude-haiku-4-5",
            inputPerMTok: 1.1, outputPerMTok: 5.5,
            cacheWrite5mPerMTok: 1.375, cacheWrite1hPerMTok: 2.2,
            cacheReadPerMTok: 0.11,
            effectiveFrom: nil, effectiveUntil: nil
        )
        firstStore.merge([changed], asOf: now)

        let secondStore = RateHistoryStore(fileURL: url)
        let haiku = secondStore.all().filter { $0.modelPrefix == "claude-haiku-4-5" }

        // Both the closed old period and the new open period survive the round-trip.
        #expect(haiku.count == 2)
        let old = haiku.first { $0.inputPerMTok == 1 }
        #expect(old?.effectiveUntil == now)
        let new = haiku.first { $0.inputPerMTok == 1.1 }
        #expect(new?.effectiveFrom == now)
        #expect(new?.effectiveUntil == nil)
    }

    @Test("Persisted historical seeds acquire the bundled Opus 5.5 prefix")
    func persistedHistoricalSeedAcquiresOpusFiveFive() {
        let url = makeTempFileURL()
        defer { cleanup(url) }

        let historicalSeed = [
            RatePeriod(
                modelPrefix: "claude-opus-5",
                inputPerMTok: 5, outputPerMTok: 25,
                cacheWrite5mPerMTok: 6.25, cacheWrite1hPerMTok: 10,
                cacheReadPerMTok: 0.50,
                effectiveFrom: nil, effectiveUntil: nil
            )
        ]
        _ = RateHistoryStore(fileURL: url, seed: historicalSeed)

        let updatedStore = RateHistoryStore(fileURL: url)
        let periods = updatedStore.all()
        #expect(periods.first { $0.modelPrefix == "claude-opus-5" }?.inputPerMTok == 5)
        let opusFiveFive = periods.first { $0.modelPrefix == "claude-opus-5-5" }
        #expect(opusFiveFive?.inputPerMTok == 4)
        #expect(opusFiveFive?.outputPerMTok == 20)
        #expect(opusFiveFive?.cacheWrite5mPerMTok == 5)
        #expect(opusFiveFive?.cacheWrite1hPerMTok == 8)
        #expect(opusFiveFive?.cacheReadPerMTok == 0.20)
    }

    @Test("A corrected bundled OpenAI rate replaces what an older build persisted")
    func bundledOnlyPrefixesFollowTheSeed() throws {
        let url = makeTempFileURL()
        defer { cleanup(url) }

        // What an older build wrote: GPT-6 Astra with the old cache-write rate and no
        // long-context tier, no GPT-6 Sol at all — and a Claude rate learnt from the
        // pricing page that differs from the bundled one.
        let staleAstra = RatePeriod(
            modelPrefix: "gpt-6-astra", inputPerMTok: 10, outputPerMTok: 50,
            cacheWrite5mPerMTok: 10, cacheWrite1hPerMTok: 10, cacheReadPerMTok: 1,
            effectiveFrom: nil, effectiveUntil: nil
        )
        let parsedOpus = RatePeriod(
            modelPrefix: "claude-opus-5", inputPerMTok: 6, outputPerMTok: 30,
            cacheWrite5mPerMTok: 7.5, cacheWrite1hPerMTok: 12, cacheReadPerMTok: 0.60,
            effectiveFrom: nil, effectiveUntil: nil
        )
        _ = RateHistoryStore(fileURL: url, seed: [staleAstra, parsedOpus], seedOwnedPrefixes: [])

        let store = RateHistoryStore(fileURL: url)
        let astra = store.all().filter { $0.modelPrefix == "gpt-6-astra" }
        #expect(astra.count == 1)
        #expect(astra.first?.cacheWrite5mPerMTok == 12.50)
        #expect(astra.first?.longContextThresholdTokens == 272_000)
        #expect(store.all().contains { $0.modelPrefix == "gpt-6-sol" })
        // A live-refreshed (Anthropic) prefix keeps what the page taught it.
        #expect(store.all().filter { $0.modelPrefix == "claude-opus-5" }.map(\.inputPerMTok) == [6])

        // And the correction is written back, so it is on disk for the next launch too.
        let reread = RateHistoryStore(fileURL: url, seed: [], seedOwnedPrefixes: [])
        #expect(reread.all().first { $0.modelPrefix == "gpt-6-astra" }?.cacheWrite5mPerMTok == 12.50)
    }

    @Test("Only OpenAI prefixes are seed-owned; Anthropic ones stay page-refreshed")
    func seedOwnedPrefixesAreOpenAIOnly() {
        #expect(!BundledRates.bundledOnlyPrefixes.isEmpty)
        #expect(BundledRates.bundledOnlyPrefixes.allSatisfy { !$0.hasPrefix("claude-") })
        #expect(BundledRates.bundledOnlyPrefixes.contains("gpt-6-sol"))
    }

    // MARK: - Crafted dated fixture

    /// A two-window model whose introductory rate ends at 2026-09-01 and is replaced by a
    /// standard one. The bundled seed no longer carries a pair like this (see
    /// `seedCarriesNoFutureDatedPeriods`), but `PricingPageParser` still emits one whenever
    /// the page announces a dated price step, so the merge paths that handle it are
    /// exercised against this fixture instead.
    private func datedPairSeed() -> [RatePeriod] {
        let transition = utcDate(2026, 9, 1)
        return [
            RatePeriod(
                modelPrefix: "claude-test-5",
                inputPerMTok: 2, outputPerMTok: 10,
                cacheWrite5mPerMTok: 2.50, cacheWrite1hPerMTok: 4,
                cacheReadPerMTok: 0.20,
                effectiveFrom: nil, effectiveUntil: transition
            ),
            RatePeriod(
                modelPrefix: "claude-test-5",
                inputPerMTok: 3, outputPerMTok: 15,
                cacheWrite5mPerMTok: 3.75, cacheWrite1hPerMTok: 6,
                cacheReadPerMTok: 0.30,
                effectiveFrom: transition, effectiveUntil: nil
            ),
        ]
    }

    // MARK: - Bundled seed shape

    /// The seed once carried a SECOND, future-dated Sonnet 5 period at $3/$15 opening on
    /// 2026-09-01 — the announced end of the introductory rate. That step never landed;
    /// the pricing page dropped the date window and kept $2/$10. A pre-dated period like
    /// that silently starts over-charging on its own the day it opens, with nothing to
    /// correct it offline, so the seed now only records rates that are already in effect
    /// and leaves announced changes to `PricingPageParser`.
    @Test("Every bundled seed period is open-ended — no pre-dated future rate steps")
    func seedCarriesNoFutureDatedPeriods() {
        for period in BundledRates.seed {
            #expect(
                period.effectiveFrom == nil && period.effectiveUntil == nil,
                "\(period.modelPrefix) seeds a dated window; see this test's comment"
            )
        }
    }

    @Test("Bundled seed prices Sonnet 5 at $2/$10 on both sides of the abandoned transition")
    func seededSonnetFiveIsFlatAcrossTheAbandonedTransition() throws {
        let url = makeTempFileURL()
        defer { cleanup(url) }

        let store = RateHistoryStore(fileURL: url)
        let sonnetFive = store.all().filter { $0.modelPrefix == "claude-sonnet-5" }
        #expect(sonnetFive.count == 1)

        let august = try #require(RatePeriod.representative(in: sonnetFive, on: utcDate(2026, 8, 15)))
        let september = try #require(RatePeriod.representative(in: sonnetFive, on: utcDate(2026, 9, 15)))
        #expect(august.inputPerMTok == 2)
        #expect(august.outputPerMTok == 10)
        #expect(september.inputPerMTok == 2)
        #expect(september.outputPerMTok == 10)
    }

    @Test("Bundled seed prices Fable 5.1 apart from Fable 5 (cache reads differ 4x)")
    func seededFableGenerationsArePricedApart() throws {
        let url = makeTempFileURL()
        defer { cleanup(url) }

        let store = RateHistoryStore(fileURL: url)
        let all = store.all()

        let fiveOne = try #require(
            RatePeriod.representative(
                in: all.filter { $0.modelPrefix == "claude-fable-5-1" }, on: utcDate(2026, 9, 15)
            )
        )
        let five = try #require(
            RatePeriod.representative(
                in: all.filter { $0.modelPrefix == "claude-fable-5" }, on: utcDate(2026, 9, 15)
            )
        )
        #expect(fiveOne.inputPerMTok == 10)
        #expect(fiveOne.outputPerMTok == 50)
        #expect(fiveOne.cacheReadPerMTok == 0.25)
        #expect(five.cacheReadPerMTok == 1.00)
    }

    // MARK: - Adjacent dated windows

    /// Dated windows no longer come from the bundled seed, but `PricingPageParser` still
    /// produces them whenever the page announces a "through <date>" / "starting <date>"
    /// pair, so the adjacency arithmetic stays under test on a crafted fixture.
    @Test("Adjacent dated windows have no overlap or gap at their shared boundary")
    func adjacentDatedWindowsHaveNoOverlapOrGap() throws {
        let transition = utcDate(2026, 9, 1)
        let seed = datedPairSeed()
        let intro = try #require(seed.first { $0.effectiveFrom == nil })
        let standard = try #require(seed.first { $0.effectiveFrom != nil })

        // The intro window closes exactly where the standard one opens.
        #expect(intro.effectiveUntil == standard.effectiveFrom)

        // No overlap: a moment just before the transition is active in intro only;
        // the transition moment itself (and after) is active in standard only.
        let justBefore = transition.addingTimeInterval(-1)
        #expect(intro.isActive(on: justBefore))
        #expect(!standard.isActive(on: justBefore))

        #expect(!intro.isActive(on: transition))
        #expect(standard.isActive(on: transition))

        let url = makeTempFileURL()
        defer { cleanup(url) }
        let store = RateHistoryStore(fileURL: url, seed: seed)
        let stored = store.all().filter { $0.modelPrefix == "claude-test-5" }
        #expect(RatePeriod.representative(in: stored, on: justBefore)?.inputPerMTok == 2)
        #expect(RatePeriod.representative(in: stored, on: transition)?.inputPerMTok == 3)
    }

    // MARK: - Frozen change: representative before/after the transition

    @Test("A changed undated rate freezes the past: before is $5, on/after is $6, count grows by 1")
    func frozenChangeKeepsPastFrozen() throws {
        let url = makeTempFileURL()
        defer { cleanup(url) }
        let now = utcDate(2026, 6, 30)

        // Seed a single open-ended opus-4-8 at $5.
        let seed = [
            RatePeriod(
                modelPrefix: "claude-opus-4-8",
                inputPerMTok: 5, outputPerMTok: 25,
                cacheWrite5mPerMTok: 6.25, cacheWrite1hPerMTok: 10,
                cacheReadPerMTok: 0.50,
                effectiveFrom: nil, effectiveUntil: nil
            )
        ]
        let store = RateHistoryStore(fileURL: url, seed: seed)
        let baselineCount = store.all().count

        // Page now shows $6 (undated).
        let incoming = RatePeriod(
            modelPrefix: "claude-opus-4-8",
            inputPerMTok: 6, outputPerMTok: 30,
            cacheWrite5mPerMTok: 7.5, cacheWrite1hPerMTok: 12,
            cacheReadPerMTok: 0.60,
            effectiveFrom: nil, effectiveUntil: nil
        )

        let result = store.merge([incoming], asOf: now)
        let opus = result.filter { $0.modelPrefix == "claude-opus-4-8" }

        #expect(result.count == baselineCount + 1, "Count must grow by exactly 1")

        // Before `now` → $5; on/after `now` → $6.
        let before = try #require(RatePeriod.representative(in: opus, on: now.addingTimeInterval(-1)))
        #expect(before.inputPerMTok == 5)
        let onNow = try #require(RatePeriod.representative(in: opus, on: now))
        #expect(onNow.inputPerMTok == 6)
        let after = try #require(RatePeriod.representative(in: opus, on: now.addingTimeInterval(86_400)))
        #expect(after.inputPerMTok == 6)

        // The old $5 period now has effectiveUntil == now; nothing was deleted.
        let old = try #require(opus.first { $0.inputPerMTok == 5 })
        #expect(old.effectiveUntil == now)
        #expect(opus.contains { $0.inputPerMTok == 6 && $0.effectiveFrom == now && $0.effectiveUntil == nil })
    }

    // MARK: - Unchanged dated windows are a no-op

    @Test("Re-merging an unchanged dated pair is a no-op and prices stay correct")
    func unchangedDatedWindowsAreNoOp() {
        let url = makeTempFileURL()
        defer { cleanup(url) }
        let julyNow = utcDate(2026, 7, 15)

        let store = RateHistoryStore(fileURL: url, seed: datedPairSeed())
        let before = store.all().filter { $0.modelPrefix == "claude-test-5" }
        #expect(before.count == 2)

        // Merge exactly the two seeded windows again.
        let result = store.merge(before, asOf: julyNow)
        let after = result.filter { $0.modelPrefix == "claude-test-5" }

        #expect(after.count == before.count, "Re-merging the same windows must be a no-op")
        for period in before {
            #expect(after.contains(period))
        }

        // Point-in-time still correct: July → $2 (intro), Sept → $3 (standard).
        let july = RatePeriod.representative(in: after, on: utcDate(2026, 7, 15))
        #expect(july?.inputPerMTok == 2)
        let sept = RatePeriod.representative(in: after, on: utcDate(2026, 9, 15))
        #expect(sept?.inputPerMTok == 3)
    }

    // MARK: - Collapse robustness

    @Test("An incoming undated rate at the standard price does not clobber the intro window")
    func collapseToUndatedDoesNotClobberIntroWindow() {
        let url = makeTempFileURL()
        defer { cleanup(url) }
        let septNow = utcDate(2026, 9, 15)

        let store = RateHistoryStore(fileURL: url, seed: datedPairSeed())

        // Page collapsed the model to a single undated $3 row.
        let collapsed = RatePeriod(
            modelPrefix: "claude-test-5",
            inputPerMTok: 3, outputPerMTok: 15,
            cacheWrite5mPerMTok: 3.75, cacheWrite1hPerMTok: 6,
            cacheReadPerMTok: 0.30,
            effectiveFrom: nil, effectiveUntil: nil
        )

        let result = store.merge([collapsed], asOf: septNow)
        let sonnet = result.filter { $0.modelPrefix == "claude-test-5" }

        // The intro $2 window must remain: a July date still prices at $2.
        let july = RatePeriod.representative(in: sonnet, on: utcDate(2026, 7, 15))
        #expect(july?.inputPerMTok == 2, "The intro $2 window must NOT be clobbered by the undated $3")

        // September still prices at the standard $3.
        let sept = RatePeriod.representative(in: sonnet, on: septNow)
        #expect(sept?.inputPerMTok == 3)
    }

    // MARK: - New model is added

    @Test("Merging a brand-new prefix adds its periods")
    func mergeNewModelAddsPeriods() {
        let url = makeTempFileURL()
        defer { cleanup(url) }
        let now = utcDate(2026, 6, 30)

        let store = RateHistoryStore(fileURL: url)
        let baselineCount = store.all().count

        let newModel = RatePeriod(
            modelPrefix: "claude-opus-9",
            inputPerMTok: 7, outputPerMTok: 35,
            cacheWrite5mPerMTok: 8.75, cacheWrite1hPerMTok: 14,
            cacheReadPerMTok: 0.70,
            effectiveFrom: nil, effectiveUntil: nil
        )

        let result = store.merge([newModel], asOf: now)

        #expect(result.count == baselineCount + 1)
        #expect(result.contains(newModel))
    }

    // MARK: - Never deletes

    @Test("Across changed, no-op, collapse, and new-model merges the count never decreases")
    func mergeNeverDecreasesCount() {
        let url = makeTempFileURL()
        defer { cleanup(url) }
        let now = utcDate(2026, 6, 30)

        let store = RateHistoryStore(fileURL: url)
        var count = store.all().count

        // 1. Changed rate.
        let changed = store.merge([
            RatePeriod(
                modelPrefix: "claude-opus-4-8",
                inputPerMTok: 6, outputPerMTok: 30,
                cacheWrite5mPerMTok: 7.5, cacheWrite1hPerMTok: 12,
                cacheReadPerMTok: 0.60,
                effectiveFrom: nil, effectiveUntil: nil
            )
        ], asOf: now)
        #expect(changed.count >= count)
        count = changed.count

        // 2. No-op re-merge of the seeded Sonnet 5 windows.
        let sonnetSeed = store.all().filter { $0.modelPrefix == "claude-sonnet-5" }
        let noop = store.merge(sonnetSeed, asOf: now)
        #expect(noop.count >= count)
        count = noop.count

        // 3. Collapse: undated Sonnet 5 standard rate.
        let collapse = store.merge([
            RatePeriod(
                modelPrefix: "claude-sonnet-5",
                inputPerMTok: 3, outputPerMTok: 15,
                cacheWrite5mPerMTok: 3.75, cacheWrite1hPerMTok: 6,
                cacheReadPerMTok: 0.30,
                effectiveFrom: nil, effectiveUntil: nil
            )
        ], asOf: utcDate(2026, 9, 15))
        #expect(collapse.count >= count)
        count = collapse.count

        // 4. Brand-new model.
        let newModel = store.merge([
            RatePeriod(
                modelPrefix: "claude-opus-9",
                inputPerMTok: 7, outputPerMTok: 35,
                cacheWrite5mPerMTok: 8.75, cacheWrite1hPerMTok: 14,
                cacheReadPerMTok: 0.70,
                effectiveFrom: nil, effectiveUntil: nil
            )
        ], asOf: now)
        #expect(newModel.count >= count)
    }
}
