import Foundation
import Testing
@testable import TokiModels

@Suite("WindowSelector.resolve")
struct WindowSelectorResolveTests {
    private let now = Date(timeIntervalSince1970: 1_770_000_000)

    private func limits() -> UsageLimits {
        UsageLimits(
            windows: [
                RateLimitWindow(id: "session", title: "5-hour", utilization: 0.20,
                                resetsAt: now.addingTimeInterval(3600), isAvailable: true),
                RateLimitWindow(id: "weekly_all", title: "7-day", utilization: 0.55,
                                resetsAt: now.addingTimeInterval(86400), isAvailable: true),
                RateLimitWindow(id: "weekly_scoped:Fable", title: "7-day Fable", utilization: 0.91,
                                resetsAt: now.addingTimeInterval(86400), isAvailable: true),
            ],
            extra: nil,
            fetchedAt: now
        )
    }

    @Test("five-hour resolves to the session window")
    func fiveHour() {
        let selected = WindowSelector.fiveHour.resolve(against: limits())
        #expect(selected?.utilization == 0.20)
        #expect(selected?.title == "5-hour")
    }

    @Test("highest scoped model follows the leader rather than a pinned name")
    func highestScoped() {
        let selected = WindowSelector.highestScopedModel.resolve(against: limits())
        #expect(selected?.utilization == 0.91)
        #expect(selected?.title == "Fable")
    }

    @Test("no limits resolves to nil rather than to zero")
    func noLimits() {
        #expect(WindowSelector.fiveHour.resolve(against: nil) == nil)
    }

    @Test("a pinned model that the account is not scoped on resolves to nil")
    func missingPinnedModel() {
        #expect(WindowSelector.scopedModel("Opus").resolve(against: limits()) == nil)
    }
}
