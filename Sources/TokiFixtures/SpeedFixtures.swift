import Foundation
import TokiAnalytics
import TokiModels

/// Deterministic generation-speed data for the snapshot harness and the debug channel.
public enum SpeedFixtures {
    private static let catalogue: [(SpeedSampleGroup, base: Float)] = [
        (SpeedSampleGroup(model: "claude-opus-5-5", effort: "high", isFast: false), 92),
        (SpeedSampleGroup(model: "claude-sonnet-5-5", effort: "high", isFast: false), 138),
        (SpeedSampleGroup(model: "gpt-6-sol", effort: "high", isFast: false), 40),
        (SpeedSampleGroup(model: "gpt-6.1-sol", effort: "high", isFast: true), 34),
        (SpeedSampleGroup(model: "claude-sonnet-5-5", effort: "medium", isFast: false), 128),
        (SpeedSampleGroup(model: "claude-haiku-4-5-20251001", effort: nil, isFast: false), 84),
        (SpeedSampleGroup(model: "gpt-6-astra", effort: "xhigh", isFast: false), 25),
        (SpeedSampleGroup(model: "claude-opus-5-5", effort: "medium", isFast: false), 101),
        (SpeedSampleGroup(model: "claude-fable-5-1", effort: "low", isFast: false), 77),
        (SpeedSampleGroup(model: "gpt-6-luna", effort: "medium", isFast: false), 44),
        (SpeedSampleGroup(model: "claude-opus-5-5", effort: "xhigh", isFast: true), 171),
        (SpeedSampleGroup(model: "gpt-5.6-terra", effort: "medium", isFast: false), 46),
        (SpeedSampleGroup(model: "claude-opus-4-8", effort: "high", isFast: false), 56),
    ]

    /// `groups` visible groups plus one below the sample threshold. Opus 5.5 high slows by
    /// ~12% over the last week, so the chart has a story to tell; every 9th day is quiet
    /// (fewer than 20 samples) to show the line breaking.
    public static func report(now: Date, groups: Int, calendar: Calendar = .current) -> GenerationSpeedReport {
        var state: UInt32 = 0x9E37_79B9
        func next() -> Float { state = state &* 1_664_525 &+ 1_013_904_223; return Float(state >> 8) / Float(1 << 24) }
        let today = calendar.startOfDay(for: now)
        var s = SpeedSamples.empty
        let chosen = Array(catalogue.prefix(min(groups, catalogue.count))) + [
            (SpeedSampleGroup(model: "claude-opus-5", effort: "low", isFast: false), 66),
        ]
        for (index, (group, base)) in chosen.enumerated() {
            s.groups.append(group)
            let isHidden = index == chosen.count - 1
            for dayOffset in (0..<30).reversed() {
                let day = calendar.date(byAdding: .day, value: -dayOffset, to: today)!
                let perDay = isHidden ? (dayOffset == 0 ? 6 : 0) : (dayOffset % 9 == 4 ? 8 : 30 + (index * 7 + dayOffset) % 25)
                let drift: Float = (index == 0 && dayOffset < 7) ? 0.88 : 1
                for i in 0..<perDay {
                    let rate = base * drift * (0.7 + 0.6 * next())
                    let ms = Int32(4_000 + Int(next() * 20_000))
                    s.group.append(UInt16(index))
                    s.timestampMs.append(Int64(day.timeIntervalSince1970 * 1000) + 3_600_000 * 9 + Int64(i) * 60_000)
                    s.generationMs.append(ms)
                    s.outputTokens.append(Int32(rate * Float(ms) / 1000))
                }
            }
        }
        return GenerationSpeedReport(samples: s, calendar: calendar)
    }
}
