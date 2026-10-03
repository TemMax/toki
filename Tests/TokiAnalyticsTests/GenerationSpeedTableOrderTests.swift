import Foundation
import Testing
import TokiModels
@testable import TokiAnalytics

private let utc: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }()
private let day0: Int64 = 1_790_899_200_000 // 2026-10-02T00:00:00Z

/// One group's spec: `responses` samples (at least 20, or the report hides the group).
private typealias Spec = (model: String, effort: String?, fast: Bool, responses: Int)

/// A real report built from `specs`, the way the app builds it.
private func report(_ specs: [Spec]) -> GenerationSpeedReport {
    var s = SpeedSamples.empty
    for (index, spec) in specs.enumerated() {
        s.groups.append(SpeedSampleGroup(model: spec.model, effort: spec.effort, isFast: spec.fast))
        for i in 0..<spec.responses {
            s.group.append(UInt16(index))
            s.timestampMs.append(day0 + Int64(i) * 1_000)
            s.outputTokens.append(Int32((i % 50 + 1) * 10))
            s.generationMs.append(10_000)
        }
    }
    return GenerationSpeedReport(samples: s, calendar: utc)
}

/// `model|effort|mode` per row, blocks flattened top to bottom.
private func rows(_ blocks: [GenerationSpeedTableOrder.ModelBlock]) -> [String] {
    blocks.flatMap(\.groups).map { "\($0.model)|\($0.effort ?? "-")|\($0.isFast ? "fast" : "standard")" }
}

@Suite("GenerationSpeedTableOrder")
struct GenerationSpeedTableOrderTests {
    @Test("Unversioned models are ordered by their summed responses, not by their largest row")
    func modelsBySum() {
        // "wide" has the biggest single row overall (100), but "many" has 60 + 50 + 40 = 150.
        let r = report([
            ("wide", "high", false, 100),
            ("many", "low", false, 60), ("many", "medium", false, 50), ("many", "high", false, 40),
        ])
        #expect(r.groups.first?.model == "wide")   // the report's own order is untouched
        let blocks = GenerationSpeedTableOrder.blocks(r.groups)
        #expect(blocks.map(\.id) == ["many", "wide"])
        #expect(blocks[0].groups.map(\.count) == [60, 50, 40])
    }

    @Test("Inside a model: low < medium < high < xhigh < max < other < nil")
    func effortOrder() {
        let r = report([
            ("m", nil, false, 20), ("m", "ultra", false, 21), ("m", "max", false, 22),
            ("m", "xhigh", false, 23), ("m", "high", false, 24), ("m", "medium", false, 25),
            ("m", "low", false, 26), ("m", "minimal", false, 27),
        ])
        let order = GenerationSpeedTableOrder.blocks(r.groups).flatMap(\.groups).map(\.effort)
        #expect(order == ["minimal", "low", "medium", "high", "xhigh", "max", "ultra", nil])
    }

    @Test("Unknown efforts sort after the known ones, alphabetically among themselves")
    func unknownEffortsAlphabetical() {
        let r = report([
            ("m", "zeta", false, 20), ("m", "alpha", false, 21), ("m", "max", false, 22), ("m", nil, false, 23),
        ])
        let order = GenerationSpeedTableOrder.blocks(r.groups).flatMap(\.groups).map(\.effort)
        #expect(order == ["max", "alpha", "zeta", nil])
    }

    @Test("effortRank ranks the known efforts, then others, then nil")
    func effortRankValues() {
        let ranked = ["minimal", "low", "medium", "high", "xhigh", "max"].map { GenerationSpeedTableOrder.effortRank($0).0 }
        #expect(ranked == [0, 1, 2, 3, 4, 5])
        #expect(GenerationSpeedTableOrder.effortRank("ultra").0 > 5)
        #expect(GenerationSpeedTableOrder.effortRank("ultra") < GenerationSpeedTableOrder.effortRank(nil))
        #expect(GenerationSpeedTableOrder.effortRank("a") < GenerationSpeedTableOrder.effortRank("b"))
    }

    @Test("Standard comes before Fast at equal effort, whatever the response counts")
    func standardBeforeFast() {
        let r = report([
            ("m", "high", true, 90), ("m", "high", false, 30), ("m", "low", true, 20),
        ])
        #expect(rows(GenerationSpeedTableOrder.blocks(r.groups)) == [
            "m|low|fast", "m|high|standard", "m|high|fast",
        ])
    }

    @Test("Models with equal version and total responses are ordered by id")
    func modelTiesById() {
        let r = report([("claude-b-5", "high", false, 30), ("claude-a-5", "high", false, 30), ("claude-c-5", "high", false, 30)])
        #expect(GenerationSpeedTableOrder.blocks(r.groups).map(\.id) == ["claude-a-5", "claude-b-5", "claude-c-5"])
    }

    @Test("Model version is parsed from the id", arguments: [
        ("claude-opus-5-5", [5, 5]), ("claude-fable-5-1", [5, 1]), ("claude-opus-5", [5]),
        ("claude-opus-4-8", [4, 8]), ("claude-haiku-4-5-20251001", [4, 5]),
        ("claude-sonnet-4-5-20250929", [4, 5]), ("claude-opus-5-5[1m]", [5, 5]),
        ("gpt-6.1-sol", [6, 1]), ("gpt-6-astra", [6]), ("gpt-5.6-terra", [5, 6]),
        ("gpt-5.3-codex", [5, 3]), ("codex-auto-review", []), ("codex", []),
    ] as [(String, [Int])])
    func versionParsing(id: String, version: [Int]) {
        #expect(GenerationSpeedTableOrder.modelVersion(id) == version)
    }

    @Test("Claude models come out newest version first, then by responses")
    func claudeVersionOrder() {
        let r = report([
            ("claude-opus-5-5", "high", false, 100), ("claude-sonnet-5-5", "high", false, 300),
            ("claude-fable-5-1", "high", false, 50), ("claude-sonnet-5", "high", false, 900),
            ("claude-opus-5", "high", false, 400), ("claude-fable-5", "high", false, 20),
            ("claude-opus-4-8", "high", false, 70), ("claude-haiku-4-5-20251001", "high", false, 500),
        ])
        #expect(GenerationSpeedTableOrder.blocks(r.groups).map(\.id) == [
            "claude-sonnet-5-5", "claude-opus-5-5", "claude-fable-5-1", "claude-sonnet-5",
            "claude-opus-5", "claude-fable-5", "claude-opus-4-8", "claude-haiku-4-5-20251001",
        ])
    }

    @Test("Codex models come out newest version first, unversioned last")
    func codexVersionOrder() {
        let r = report([
            ("gpt-6-astra", "high", false, 800), ("gpt-6.1-sol", "high", false, 20),
            ("gpt-5.6-sol", "high", false, 500), ("gpt-6-sol", "high", false, 900),
            ("codex-auto-review", "high", false, 999),
        ])
        #expect(GenerationSpeedTableOrder.blocks(r.groups).map(\.id) == [
            "gpt-6.1-sol", "gpt-6-sol", "gpt-6-astra", "gpt-5.6-sol", "codex-auto-review",
        ])
    }

    @Test("A mixed report is blocked by model and ordered by effort inside each block")
    func mixed() {
        let r = report([
            ("opus", "high", false, 80), ("sonnet", "medium", false, 70),
            ("opus", "medium", false, 40), ("sonnet", "low", true, 25), ("opus", "high", true, 21),
        ])
        #expect(rows(GenerationSpeedTableOrder.blocks(r.groups)) == [
            "opus|medium|standard", "opus|high|standard", "opus|high|fast",
            "sonnet|low|fast", "sonnet|medium|standard",
        ])
    }

    @Test("Every group appears exactly once")
    func partition() {
        let r = report([
            ("a", "low", false, 20), ("b", "high", true, 30), ("a", nil, false, 25), ("c", "max", false, 22),
        ])
        let flat = GenerationSpeedTableOrder.blocks(r.groups).flatMap(\.groups)
        #expect(flat.count == r.groups.count)
        #expect(Set(flat.map(\.id)) == Set(r.groups.map(\.id)))
    }

    @Test("No groups, no blocks")
    func empty() {
        #expect(GenerationSpeedTableOrder.blocks([]).isEmpty)
        #expect(GenerationSpeedTableOrder.blocks(GenerationSpeedReport.empty.groups).isEmpty)
    }
}
