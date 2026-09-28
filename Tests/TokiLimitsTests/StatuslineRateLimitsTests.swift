import Testing
import Foundation
import TokiModels
@testable import TokiLimits

private let account = UsageAccount(accountUuid: "account-a", organizationUuid: "org-a")
private let weekReset = Date(timeIntervalSince1970: 1_790_000_000)
private let sessionReset = Date(timeIntervalSince1970: 1_789_500_000)
private let polledAt = Date(timeIntervalSince1970: 1_789_490_000)

/// The shape Claude Code pipes to a status line command (trimmed to what matters).
private func payload(five: (Double, Date)? = (40, sessionReset), week: (Double, Date)? = (60, weekReset)) -> Data {
    var limits: [String: Any] = [:]
    if let five { limits["five_hour"] = ["used_percentage": five.0, "resets_at": five.1.timeIntervalSince1970] }
    if let week { limits["seven_day"] = ["used_percentage": week.0, "resets_at": week.1.timeIntervalSince1970] }
    let root: [String: Any] = [
        "session_id": "s", "model": ["display_name": "Opus"], "rate_limits": limits,
    ]
    return try! JSONSerialization.data(withJSONObject: root)
}

private func polled(session: (Double, Date?)? = (0.30, sessionReset), week: Double = 0.55,
                    weekResetsAt: Date? = weekReset) -> UsageLimits {
    var windows: [RateLimitWindow] = []
    if let session {
        windows.append(RateLimitWindow(id: "session", title: "5-hour", utilization: session.0,
                                       resetsAt: session.1, isAvailable: true))
    }
    windows.append(RateLimitWindow(id: "weekly_all", title: "7-day", utilization: week,
                                   resetsAt: weekResetsAt, isAvailable: true))
    windows.append(RateLimitWindow(id: "weekly_scoped:Fable", title: "7-day Fable", utilization: 0.2,
                                   resetsAt: weekReset, isAvailable: true))
    return UsageLimits(
        windows: windows, extra: ExtraUsage(isEnabled: false, monthlyLimit: nil, usedCredits: nil, utilization: nil),
        fetchedAt: polledAt, account: account, bankedResets: nil,
        claudeResets: ClaudeResetStatus(eligible: true, grants: [ClaudeResetGrant(id: "g", resetsLeft: 1)])
    )
}

@Suite("Status line rate limits")
struct StatuslineRateLimitsTests {

    @Test("parses both windows as fractions with their reset dates")
    func parsesWindows() throws {
        let observed = polledAt.addingTimeInterval(30)
        let sample = try #require(StatuslineRateLimits.parse(payload(), observedAt: observed))
        #expect(sample.fiveHour == .init(utilization: 0.40, resetsAt: sessionReset))
        #expect(sample.sevenDay == .init(utilization: 0.60, resetsAt: weekReset))
        #expect(sample.observedAt == observed)
    }

    @Test("a payload before the session's first API response carries no usage",
          arguments: [#"{"session_id":"s"}"#, #"{"rate_limits":{}}"#, "not json", #"[1]"#,
                      #"{"rate_limits":{"five_hour":{"used_percentage":"40","resets_at":1}}}"#])
    func rejectsPayloadsWithoutUsage(body: String) {
        #expect(StatuslineRateLimits.parse(Data(body.utf8), observedAt: polledAt) == nil)
    }

    @Test("newer status line usage replaces the polled 5-hour and 7-day gauges, keeping the rest")
    func mergesIntoSameAccount() throws {
        let observed = polledAt.addingTimeInterval(45)
        let sample = try #require(StatuslineRateLimits.parse(payload(), observedAt: observed))
        let merged = try #require(sample.merged(into: polled()))

        #expect(merged.fiveHour?.utilization == 0.40)
        #expect(merged.sevenDay?.utilization == 0.60)
        #expect(merged.windows.map(\.id) == ["session", "weekly_all", "weekly_scoped:Fable"])
        #expect(merged.windows.last?.utilization == 0.2)
        #expect(merged.fetchedAt == observed)
        #expect(merged.account == account)
        #expect(merged.claudeResets?.totalResets == 1)
        #expect(merged.extra != nil)
    }

    @Test("a sample no newer than the polled snapshot is ignored")
    func olderSampleIgnored() throws {
        let sample = try #require(StatuslineRateLimits.parse(payload(), observedAt: polledAt))
        #expect(sample.merged(into: polled()) == nil)
    }

    // No account id travels in the payload. The weekly reset instant is fixed per account for
    // the week, so it is what ties a sample to the account the gauges are showing.
    @Test("a sample whose weekly reset differs belongs to another account and is ignored")
    func foreignAccountIgnored() throws {
        let other = weekReset.addingTimeInterval(3 * 3600)
        let sample = try #require(StatuslineRateLimits.parse(payload(week: (10, other)),
                                                             observedAt: polledAt.addingTimeInterval(10)))
        #expect(sample.merged(into: polled()) == nil)
    }

    @Test("without a weekly window on either side nothing can be attributed")
    func unboundSampleIgnored() throws {
        let later = polledAt.addingTimeInterval(10)
        let noWeek = try #require(StatuslineRateLimits.parse(payload(week: nil), observedAt: later))
        #expect(noWeek.merged(into: polled()) == nil)
        let sample = try #require(StatuslineRateLimits.parse(payload(), observedAt: later))
        #expect(sample.merged(into: polled(weekResetsAt: nil)) == nil)
    }

    @Test("usage within one window never goes backwards — an idle session redrawing is not news")
    func sameWindowKeepsHigherUsage() throws {
        let sample = try #require(StatuslineRateLimits.parse(payload(five: (10, sessionReset), week: (50, weekReset)),
                                                             observedAt: polledAt.addingTimeInterval(20)))
        let merged = try #require(sample.merged(into: polled(session: (0.30, sessionReset), week: 0.55)))
        #expect(merged.fiveHour?.utilization == 0.30)
        #expect(merged.sevenDay?.utilization == 0.55)
    }

    @Test("a later 5-hour window replaces an earlier or inactive one; an earlier one is ignored")
    func sessionWindowOrdering() throws {
        let later = polledAt.addingTimeInterval(20)
        let next = sessionReset.addingTimeInterval(5 * 3600)
        let newer = try #require(StatuslineRateLimits.parse(payload(five: (3, next)), observedAt: later))
        let replaced = try #require(newer.merged(into: polled())?.fiveHour)
        #expect(replaced.id == "session" && replaced.title == "5-hour" && replaced.isAvailable)
        #expect(replaced.utilization == 0.03 && replaced.resetsAt == next)
        #expect(newer.merged(into: polled(session: (0, nil)))?.fiveHour?.utilization == 0.03)
        #expect(newer.merged(into: polled(session: nil))?.windows.first?.id == "session")

        let stale = try #require(StatuslineRateLimits.parse(payload(five: (90, sessionReset)), observedAt: later))
        #expect(stale.merged(into: polled(session: (0.05, next)))?.fiveHour?.utilization == 0.05)
    }
}
