import Foundation
import Testing
@testable import TokiAlerts
import TokiModels

@Suite("Reset announcement parser")
struct ResetAnnouncementParserTests {
    @Test("Codex parsing accepts only regular events with safe post links")
    func parsesCodexFeedShape() throws {
        let data = Data(#"""
        {
          "events": [
            {"tweet_id":"101","tweet_url":"https://x.com/thsottiaux/status/101","announced_at":"2026-09-07T10:00:00.000Z","reset_type":"regular","source":"webhook","extra":true},
            {"tweet_id":"102","tweet_url":"https://x.com/thsottiaux/status/102","announced_at":"2026-09-07T09:00:00.000Z","reset_type":"banked","source":"webhook"},
            {"tweet_id":"103","tweet_url":"https://chatgpt.com/codex/settings/usage","announced_at":"2026-09-07T08:00:00.000Z","reset_type":"regular","source":"backfill"},
            {"tweet_id":"104","tweet_url":"https://example.com/status/104","announced_at":"2026-09-07T07:00:00.000Z","reset_type":"regular","source":"observed"},
            {"tweet_id":"105","tweet_url":"https://x.com/thsottiaux/status/105","announced_at":"2026-09-07T06:00:00.000Z","reset_type":"regular"},
            {"tweet_id":12,"tweet_url":"https://x.com/thsottiaux/status/105","announced_at":"bad","reset_type":"regular","source":"webhook"}
          ],
          "stats": {"total": 5}
        }
        """#.utf8)

        let events = try ResetAnnouncementParser.parse(data, provider: .codex)

        #expect(events == [ResetAnnouncement(
            id: "101",
            provider: .codex,
            announcedAt: Date(timeIntervalSince1970: 1_788_775_200),
            scope: nil,
            sourceURL: URL(string: "https://x.com/thsottiaux/status/101")!
        )])
    }

    @Test("Claude parsing accepts only curated reset events and preserves scope")
    func parsesClaudeFeedShape() throws {
        let data = Data(#"""
        {
          "providers": {
            "claude": {
              "events": [
                {"id":"201","date":"2026-09-07T11:00:00Z","kind":"reset","scope":"Pro + Max","url":"https://twitter.com/ClaudeDevs/status/201","verification":"curated","note":"extra"},
                {"id":"202","date":"2026-09-07T10:00:00Z","kind":"policy","scope":"all","url":"https://x.com/ClaudeDevs/status/202","verification":"curated"},
                {"id":"203","date":"2026-09-07T09:00:00Z","kind":"reset","scope":"all","url":"https://x.com/ClaudeDevs/status/203","verification":"provisional"},
                {"id":"204","date":"2026-09-07T08:00:00Z","kind":"reset","scope":"all","url":"https://x.com/ClaudeDevs/status/not-a-number","verification":"curated"},
                {"kind":"reset","verification":"curated"}
              ]
            },
            "codex": {"events": []}
          },
          "meta": {"asOf":"2026-09-07T12:00:00Z"}
        }
        """#.utf8)

        let events = try ResetAnnouncementParser.parse(data, provider: .claudeCode)

        #expect(events == [ResetAnnouncement(
            id: "201",
            provider: .claudeCode,
            announcedAt: Date(timeIntervalSince1970: 1_788_778_800),
            scope: "Pro + Max",
            sourceURL: URL(string: "https://twitter.com/ClaudeDevs/status/201")!
        )])
    }

    @Test("unknown or oversized Claude scope falls back to generic copy")
    func filtersClaudeScope() throws {
        let longScope = String(repeating: "a", count: 161)
        let data = Data("""
        {"providers":{"claude":{"events":[{
          "id":"205",
          "date":"2026-09-07T11:00:00Z",
          "kind":"reset",
          "scope":"\(longScope)",
          "url":"https://x.com/ClaudeDevs/status/205",
          "verification":"curated"
        }]}}}
        """.utf8)

        let event = try #require(
            ResetAnnouncementParser.parse(data, provider: .claudeCode).first
        )
        #expect(event.scope == nil)
    }

    @Test("missing root collections and malformed JSON fail instead of becoming empty feeds", arguments: [
        Data(#"{}"#.utf8),
        Data(#"{"events":"not-an-array"}"#.utf8),
        Data("not json".utf8),
    ])
    func rejectsMalformedCodexRoots(data: Data) {
        #expect(throws: (any Error).self) {
            try ResetAnnouncementParser.parse(data, provider: .codex)
        }
    }

    @Test("missing Claude provider collection fails instead of becoming an empty feed")
    func rejectsMissingClaudeRoot() {
        #expect(throws: (any Error).self) {
            try ResetAnnouncementParser.parse(
                Data(#"{"providers":{"codex":{"events":[]}}}"#.utf8),
                provider: .claudeCode
            )
        }
    }

    @Test("an entirely malformed Codex collection throws and recovery establishes the baseline")
    func malformedCodexFeedDoesNotEstablishPolicyHistory() throws {
        let malformed = Data(#"{"events":[null,{"reset_type":"regular","announced_at":"broken"}]}"#.utf8)
        let recovered = Data(#"{"events":[{"tweet_id":"206","tweet_url":"https://x.com/thsottiaux/status/206","announced_at":"2027-01-15T06:00:00Z","reset_type":"regular","source":"webhook"}]}"#.utf8)
        var policy = ResetAnnouncementPolicy()

        #expect(throws: ResetAnnouncementError.invalidFeed) {
            try ResetAnnouncementParser.parse(malformed, provider: .codex)
        }
        let events = try ResetAnnouncementParser.parse(recovered, provider: .codex)
        #expect(policy.observe(
            events,
            provider: .codex,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        ).isEmpty)
    }

    @Test("an entirely malformed Claude collection throws and recovery establishes the baseline")
    func malformedClaudeFeedDoesNotEstablishPolicyHistory() throws {
        let malformed = Data(#"{"providers":{"claude":{"events":[null,{"kind":"reset","date":"broken"}]}}}"#.utf8)
        let recovered = Data(#"{"providers":{"claude":{"events":[{"id":"207","date":"2027-01-15T06:00:00Z","kind":"reset","scope":"all","url":"https://x.com/ClaudeDevs/status/207","verification":"curated"}]}}}"#.utf8)
        var policy = ResetAnnouncementPolicy()

        #expect(throws: ResetAnnouncementError.invalidFeed) {
            try ResetAnnouncementParser.parse(malformed, provider: .claudeCode)
        }
        let events = try ResetAnnouncementParser.parse(recovered, provider: .claudeCode)
        #expect(policy.observe(
            events,
            provider: .claudeCode,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        ).isEmpty)
    }

    @Test("empty and intentionally filtered collections remain valid", arguments: [
        (UsageProvider.codex, Data(#"{"events":[]}"#.utf8)),
        (UsageProvider.codex, Data(#"{"events":[{"tweet_id":"208","tweet_url":"https://x.com/thsottiaux/status/208","announced_at":"2027-01-15T06:00:00Z","reset_type":"banked","source":"webhook"}]}"#.utf8)),
        (UsageProvider.claudeCode, Data(#"{"providers":{"claude":{"events":[]}}}"#.utf8)),
        (UsageProvider.claudeCode, Data(#"{"providers":{"claude":{"events":[{"id":"209","date":"2027-01-15T06:00:00Z","kind":"reset","scope":"all","url":"https://x.com/ClaudeDevs/status/209","verification":"provisional"}]}}}"#.utf8)),
    ])
    func acceptsValidEmptyResult(provider: UsageProvider, data: Data) throws {
        #expect(try ResetAnnouncementParser.parse(data, provider: provider).isEmpty)
    }
}

@Suite("ResetAnnouncementPolicy")
struct ResetAnnouncementPolicyTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func event(
        _ id: String,
        provider: UsageProvider = .codex,
        announcedAt: Date? = nil
    ) -> ResetAnnouncement {
        ResetAnnouncement(
            id: id,
            provider: provider,
            announcedAt: announcedAt ?? now,
            scope: provider == .claudeCode ? "all" : nil,
            sourceURL: URL(string: "https://x.com/account/status/\(id.filter(\.isNumber))")!
        )
    }

    @Test("first observation establishes history without replay")
    func baselineDoesNotReplay() {
        var policy = ResetAnnouncementPolicy()
        #expect(policy.observe([event("100")], provider: .codex, now: now).isEmpty)
        #expect(policy.observe([event("100")], provider: .codex, now: now).isEmpty)
    }

    @Test("a new recent event is returned once")
    func reportsRecentEventOnce() {
        var policy = ResetAnnouncementPolicy()
        _ = policy.observe([], provider: .codex, now: now)
        let recent = event("101", announcedAt: now.addingTimeInterval(-60))

        #expect(policy.observe([recent], provider: .codex, now: now) == [recent])
        #expect(policy.observe([recent], provider: .codex, now: now) == [])
    }

    @Test("an event older than 24 hours is tracked without delivery")
    func ignoresOldBackfill() {
        var policy = ResetAnnouncementPolicy()
        _ = policy.observe([], provider: .codex, now: now)
        let old = event("102", announcedAt: now.addingTimeInterval(-86_401))

        #expect(policy.observe([old], provider: .codex, now: now).isEmpty)
        #expect(policy.observe([old], provider: .codex, now: now).isEmpty)
    }

    @Test("a future row is not marked seen and is delivered after its timestamp")
    func delaysFutureEvent() {
        var policy = ResetAnnouncementPolicy()
        _ = policy.observe([], provider: .codex, now: now)
        let future = event("103", announcedAt: now.addingTimeInterval(240))

        #expect(policy.observe([future], provider: .codex, now: now).isEmpty)
        #expect(policy.observe(
            [future],
            provider: .codex,
            now: now.addingTimeInterval(240)
        ) == [future])
    }

    @Test("a provisional Claude row can notify once it becomes curated")
    func provisionalThenCurated() throws {
        let provisional = Data(#"{"providers":{"claude":{"events":[{"id":"104","date":"2027-01-15T08:00:00Z","kind":"reset","scope":"all","url":"https://x.com/ClaudeDevs/status/104","verification":"provisional"}]}}}"#.utf8)
        let curated = Data(#"{"providers":{"claude":{"events":[{"id":"104","date":"2027-01-15T08:00:00Z","kind":"reset","scope":"all","url":"https://x.com/ClaudeDevs/status/104","verification":"curated"}]}}}"#.utf8)
        var policy = ResetAnnouncementPolicy()

        let initial = try ResetAnnouncementParser.parse(provisional, provider: .claudeCode)
        #expect(policy.observe(initial, provider: .claudeCode, now: now).isEmpty)
        let confirmed = try ResetAnnouncementParser.parse(curated, provider: .claudeCode)
        #expect(policy.observe(confirmed, provider: .claudeCode, now: now).map(\.id) == ["104"])
    }

    @Test("the same stable ID is independent per provider")
    func providerHistoriesAreIndependent() {
        var policy = ResetAnnouncementPolicy()
        _ = policy.observe([], provider: .codex, now: now)
        _ = policy.observe([], provider: .claudeCode, now: now)

        #expect(policy.observe([event("105")], provider: .codex, now: now).map(\.id) == ["105"])
        #expect(policy.observe(
            [event("105", provider: .claudeCode)],
            provider: .claudeCode,
            now: now
        ).map(\.id) == ["105"])
    }

    @Test("Codable restoration preserves every provider history")
    func restoresCodableState() throws {
        var policy = ResetAnnouncementPolicy()
        _ = policy.observe([], provider: .codex, now: now)
        _ = policy.observe([], provider: .claudeCode, now: now)
        let codex = event("106")
        let claude = event("107", provider: .claudeCode)
        _ = policy.observe([codex], provider: .codex, now: now)
        _ = policy.observe([claude], provider: .claudeCode, now: now)

        let data = try JSONEncoder().encode(policy)
        var restored = try JSONDecoder().decode(ResetAnnouncementPolicy.self, from: data)

        #expect(restored.observe([codex], provider: .codex, now: now).isEmpty)
        #expect(restored.observe([claude], provider: .claudeCode, now: now).isEmpty)
    }

    @Test("simultaneous announcements are all returned in feed order")
    func returnsSimultaneousAnnouncements() {
        var policy = ResetAnnouncementPolicy()
        _ = policy.observe([], provider: .codex, now: now)
        let first = event("108")
        let second = event("109")

        #expect(policy.observe([first, second], provider: .codex, now: now) == [first, second])
    }

    @Test("a muted caller can discard output while policy still tracks the event")
    func tracksWhenCallerIsMuted() {
        var policy = ResetAnnouncementPolicy()
        _ = policy.observe([], provider: .codex, now: now)
        let notice = event("110")

        _ = policy.observe([notice], provider: .codex, now: now)
        #expect(policy.observe([notice], provider: .codex, now: now).isEmpty)
    }

    @Test("events from another provider cannot contaminate the requested history")
    func rejectsMismatchedProvider() {
        var policy = ResetAnnouncementPolicy()
        _ = policy.observe([], provider: .codex, now: now)

        #expect(policy.observe(
            [event("111", provider: .claudeCode)],
            provider: .codex,
            now: now
        ).isEmpty)
    }

    @Test("pruned IDs do not replay after the local clock moves backward")
    func pruningRetainsNotificationFloor() {
        var policy = ResetAnnouncementPolicy()
        _ = policy.observe([], provider: .codex, now: now)
        let prior = event("112", announcedAt: now.addingTimeInterval(-23 * 60 * 60))
        #expect(policy.observe([prior], provider: .codex, now: now) == [prior])

        _ = policy.observe([], provider: .codex, now: now.addingTimeInterval(2 * 60 * 60))

        #expect(policy.observe([prior], provider: .codex, now: now).isEmpty)
    }
}
