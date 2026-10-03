import Foundation
import Testing
import TokiModels
@testable import TokiAnalytics

private let utc: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }()
private let day0: Int64 = 1_790_899_200_000 // 2026-10-02T00:00:00Z

/// `n` samples for one group on one day, rates 1…n tok/s (tokens = rate × 10, 10 s each).
private func samples(_ groups: [(SpeedSampleGroup, [(dayOffset: Int, rates: [Int])])]) -> SpeedSamples {
    var s = SpeedSamples.empty
    for (index, (group, days)) in groups.enumerated() {
        s.groups.append(group)
        for (offset, rates) in days {
            for (i, rate) in rates.enumerated() {
                s.group.append(UInt16(index))
                s.timestampMs.append(day0 + Int64(offset) * 86_400_000 + Int64(i) * 1_000)
                s.outputTokens.append(Int32(rate * 10))
                s.generationMs.append(10_000)
            }
        }
    }
    return s
}
private let opus = SpeedSampleGroup(model: "claude-opus-5-5", effort: "high", isFast: false)
private let gpt = SpeedSampleGroup(model: "gpt-6-sol", effort: "low", isFast: true)

@Suite("GenerationSpeedReport")
struct GenerationSpeedReportTests {
    @Test("Nearest-rank percentiles and the weighted average")
    func percentiles() {
        let report = GenerationSpeedReport(samples: samples([(opus, [(0, Array(1...100))])]), calendar: utc)
        let g = try! #require(report.groups.first)
        #expect(g.count == 100)
        #expect(g.p10 == 10)
        #expect(g.median == 50)
        #expect(g.p90 == 90)
        #expect(abs(g.weightedAverage - 50.5) < 1e-9)   // Σ(10r) / Σ10 s
        #expect(g.provider == .claudeCode)
    }

    @Test("Weighted average weights by tokens and time, not by request")
    func weighting() {
        var s = samples([(opus, [(0, Array(repeating: 50, count: 20))])])
        s.outputTokens[0] = 10_000; s.generationMs[0] = 100_000   // one long, slower response
        let g = try! #require(GenerationSpeedReport(samples: s, calendar: utc).groups.first)
        // (19 × 500 + 10 000) tokens / (19 × 10 + 100) s
        #expect(abs(g.weightedAverage - 19_500.0 / 290.0) < 1e-9)
    }

    @Test("Groups and days below 20 samples are left out")
    func thresholds() {
        let report = GenerationSpeedReport(samples: samples([
            (opus, [(0, Array(1...25)), (1, Array(1...19)), (3, Array(1...20))]),
            (gpt, [(0, Array(1...19))]),
        ]), calendar: utc)
        #expect(report.groups.map(\.model) == ["claude-opus-5-5"])
        #expect(report.hiddenGroupCount == 1)
        let daily = report.groups[0].daily
        #expect(daily.map(\.count) == [25, 20])   // day 1 (19) omitted → a gap in the line
        #expect(daily.map { utc.dateComponents([.day], from: $0.day).day } == [2, 5])
        #expect(report.groups[0].count == 64)
    }

    @Test("Codex models are attributed to Codex; order is by request count")
    func providerAndOrder() {
        let report = GenerationSpeedReport(samples: samples([
            (opus, [(0, Array(1...20))]),
            (gpt, [(0, Array(1...40))]),
        ]), calendar: utc)
        #expect(report.groups.map(\.provider) == [.codex, .claudeCode])
        #expect(report.groups[0].isFast)
    }

    @Test("Days are local calendar days, across a DST change")
    func localDays() {
        var berlin = Calendar(identifier: .gregorian); berlin.timeZone = TimeZone(identifier: "Europe/Berlin")!
        // 2026-10-25 is the end of CEST. Two runs of 20 samples: 23:30 UTC on Oct 24 (= Oct 25
        // 00:30 CEST → local Oct 25) and 23:30 UTC on Oct 25 (= Oct 26 00:30 CET → local Oct 26).
        var s = SpeedSamples.empty
        s.groups = [opus]
        let oct24_2330Z: Int64 = 1_792_884_600_000
        for base in [oct24_2330Z, oct24_2330Z + 86_400_000] {
            for i in 0..<20 {
                s.group.append(0); s.timestampMs.append(base + Int64(i) * 1_000)
                s.outputTokens.append(500); s.generationMs.append(10_000)
            }
        }
        let daily = GenerationSpeedReport(samples: s, calendar: berlin).groups[0].daily
        #expect(daily.map { berlin.dateComponents([.month, .day], from: $0.day) }
            == [DateComponents(month: 10, day: 25), DateComponents(month: 10, day: 26)])
    }

    @Test("No samples is an empty report")
    func empty() {
        #expect(GenerationSpeedReport(samples: .empty, calendar: utc) == .empty)
    }

    @Test("Quantile selection equals sorting, on random and duplicate-heavy input")
    func selectionMatchesSort() {
        var rng = SystemRandomNumberGenerator()
        // Seven days per group, some below the day threshold (left unsorted) and some above
        // it (sorted per day), so the group as a whole is never sorted when selection runs.
        for perDay in [3, 19, 20, 57, 600] {
            for duplicates in [false, true] {
                let days = (0..<7).map { offset in
                    (dayOffset: offset, rates: (0..<(perDay + offset)).map { _ in
                        duplicates ? Int.random(in: 1...5, using: &rng) : Int.random(in: 1...400, using: &rng)
                    })
                }
                let all = days.flatMap(\.rates)
                let report = GenerationSpeedReport(samples: samples([(opus, days)]), calendar: utc)
                let sorted = all.map(Float.init).sorted()
                let g = try! #require(report.groups.first)
                #expect(g.count == all.count)
                sorted.withUnsafeBufferPointer { s in
                    #expect(g.p10 == Double(GenerationSpeedReport.nearestRank(s, 0.1)))
                    #expect(g.median == Double(GenerationSpeedReport.nearestRank(s, 0.5)))
                    #expect(g.p90 == Double(GenerationSpeedReport.nearestRank(s, 0.9)))
                }
            }
        }
    }

    @Test("Codex is gpt-, codex and o<digit> ids; every other model id is Claude")
    func providerByModelId() {
        let ids = ["claude-opus-5-5", "gpt-6-sol", "GPT-5.1", "codex-mini-latest", "Codex-2", "o3", "o4-mini",
                   "opus-proxy", "omni-custom", "anthropic/claude-x", "my-proxy-model", "gpt5", "o"]
        let report = GenerationSpeedReport(samples: samples(ids.map {
            (SpeedSampleGroup(model: $0, effort: nil, isFast: false), [(0, Array(1...20))])
        }), calendar: utc)
        let provider = Dictionary(uniqueKeysWithValues: report.groups.map { ($0.model, $0.provider) })
        #expect(provider == [
            "claude-opus-5-5": .claudeCode, "gpt-6-sol": .codex, "GPT-5.1": .codex,
            "codex-mini-latest": .codex, "Codex-2": .codex, "o3": .codex, "o4-mini": .codex,
            "opus-proxy": .claudeCode, "omni-custom": .claudeCode, "anthropic/claude-x": .claudeCode,
            "my-proxy-model": .claudeCode, "gpt5": .claudeCode, "o": .claudeCode,
        ])
    }

    @Test("Each day's percentiles equal those of its sorted rates")
    func dailyPercentilesMatchSort() {
        var rng = SystemRandomNumberGenerator()
        let days = (0..<9).map { offset in
            (dayOffset: offset * 2, rates: (0..<(20 + offset * 37)).map { _ in
                offset.isMultiple(of: 3) ? Int.random(in: 1...4, using: &rng) : Int.random(in: 1...500, using: &rng)
            })
        }
        let g = try! #require(GenerationSpeedReport(samples: samples([(opus, days)]), calendar: utc).groups.first)
        #expect(g.daily.count == days.count)
        for (point, day) in zip(g.daily, days) {
            let sorted = day.rates.map(Float.init).sorted()
            #expect(point.count == day.rates.count)
            #expect(point.day == Date(timeIntervalSince1970: Double(day0 + Int64(day.dayOffset) * 86_400_000) / 1000))
            sorted.withUnsafeBufferPointer { s in
                #expect(point.p10 == Double(GenerationSpeedReport.nearestRank(s, 0.1)))
                #expect(point.median == Double(GenerationSpeedReport.nearestRank(s, 0.5)))
                #expect(point.p90 == Double(GenerationSpeedReport.nearestRank(s, 0.9)))
            }
        }
        #expect(g.firstDay == g.daily.first?.day)
        #expect(g.lastDay == g.daily.last?.day)
    }

    @Test("Bucketed selection equals sorting, on spread, clustered and outlier-heavy rates")
    func bucketedSelectionMatchesSort() {
        var rng = SystemRandomNumberGenerator()
        var scratch = GenerationSpeedReport.BucketScratch()
        let inputs: [[Float]] = [
            (0..<50_000).map { _ in Float.random(in: 1...400, using: &rng) },
            (0..<20_000).map { _ in Float(Int.random(in: 1...3, using: &rng)) },
            (0..<20_000).map { i in i == 7 ? 1e9 : Float.random(in: 40...41, using: &rng) },   // one bucket holds all but one
            [Float](repeating: 12.5, count: 5_000),
            (0..<4_096).map { Float($0) },
            (0..<6_000).map { _ in Float(Int.random(in: 1...1_000, using: &rng)) / 7 },
        ]
        for values in inputs {
            let sorted = values.sorted()
            let (p10, p50, p90) = values.withUnsafeBufferPointer { GenerationSpeedReport.bucketQuantiles($0, &scratch) }
            sorted.withUnsafeBufferPointer { s in
                #expect(p10 == GenerationSpeedReport.nearestRank(s, 0.1))
                #expect(p50 == GenerationSpeedReport.nearestRank(s, 0.5))
                #expect(p90 == GenerationSpeedReport.nearestRank(s, 0.9))
            }
        }
    }
}
