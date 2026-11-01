import Foundation
import Testing
@testable import TokiModels

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private let week: TimeInterval = 7 * 86400

@Suite("Usage pace")
struct UsagePaceTests {
    @Test("three days into a week, 60% used is ahead and runs out before the reset")
    func aheadProjectsExhaustion() throws {
        let pace = try #require(UsagePace(utilization: 0.60, resetsAt: now.addingTimeInterval(4 * 86400),
                                          duration: week, now: now))
        #expect(abs(pace.expected - 3.0 / 7.0) < 1e-9)
        #expect(pace.verdict == .ahead)
        // 60% in 3 days is 20% a day, so the remaining 40% lasts 2 more days.
        let exhaustion = try #require(pace.projectedExhaustion)
        #expect(abs(exhaustion.timeIntervalSince(now) - 2 * 86400) < 1)
        #expect(pace.warningText(now: now) == "runs out in ~2d 0h at this pace")
    }

    @Test("verdicts keep a 5-point band around even spending", arguments: [
        (0.43, UsagePace.Verdict.onPace), (0.47, .onPace), (0.49, .ahead), (0.37, .under),
    ])
    func band(used: Double, verdict: UsagePace.Verdict) throws {
        let pace = try #require(UsagePace(utilization: used, resetsAt: now.addingTimeInterval(4 * 86400),
                                          duration: week, now: now))
        #expect(pace.verdict == verdict)
        if verdict != .ahead {
            #expect(pace.projectedExhaustion == nil)
            #expect(pace.warningText(now: now) == nil)
        }
    }

    @Test("no pace without enough to judge it")
    func unjudgeable() {
        let reset = now.addingTimeInterval(4 * 86400)
        #expect(UsagePace(utilization: 0.5, resetsAt: nil, duration: week, now: now) == nil)
        #expect(UsagePace(utilization: 0.5, resetsAt: reset, duration: nil, now: now) == nil)
        #expect(UsagePace(utilization: 0.5, resetsAt: now.addingTimeInterval(-1), duration: week, now: now) == nil)
        // Ten minutes into a five-hour window is too early to extrapolate.
        #expect(UsagePace(utilization: 0.2, resetsAt: now.addingTimeInterval(5 * 3600 - 600),
                          duration: 5 * 3600, now: now) == nil)
    }

    @Test("a window already at its limit is ahead but projects nothing")
    func exhausted() throws {
        let pace = try #require(UsagePace(utilization: 1.0, resetsAt: now.addingTimeInterval(86400),
                                          duration: week, now: now))
        #expect(pace.verdict == .ahead)
        #expect(pace.projectedExhaustion == nil)
        #expect(pace.warningText(now: now) == nil)
    }

    @Test("window length comes from the id")
    func durations() {
        #expect(RateLimitWindow.duration(forId: "session") == TimeInterval(5 * 3600))
        #expect(RateLimitWindow.duration(forId: "session_scoped:Spark") == TimeInterval(5 * 3600))
        #expect(RateLimitWindow.duration(forId: "weekly_all") == week)
        #expect(RateLimitWindow.duration(forId: "weekly_scoped:Fable") == week)
        #expect(RateLimitWindow.duration(forId: "codex:x:primary") == nil)
        let unavailable = RateLimitWindow(id: "weekly_all", title: "7-day", utilization: 0.9,
                                          resetsAt: now.addingTimeInterval(86400), isAvailable: false)
        #expect(unavailable.pace(now: now) == nil)
    }
}
