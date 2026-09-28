import Foundation
import Testing
@testable import TokiAlerts

@Suite("Reset notification destinations")
struct ResetNotificationCopyTests {
    @Test("English copy distinguishes existing availability and never invents an expiry")
    func copy() throws {
        #expect(ResetNotificationCopy.bankedTitle(isInitial: true) == "Codex reset available")
        #expect(ResetNotificationCopy.bankedTitle(isInitial: false) == "You've received a Codex reset")
        #expect(ResetNotificationCopy.bankedBody(count: 1, expiresAt: nil, detailsComplete: false) == "1 reset available.")
        #expect(ResetNotificationCopy.bankedBody(count: 2, expiresAt: nil, detailsComplete: false) == "2 resets available.")
        let date = try #require(ISO8601DateFormatter().date(from: "2026-09-07T00:30:00Z"))
        let body = ResetNotificationCopy.bankedBody(count: 2, expiresAt: date, detailsComplete: false,
            timeZone: try #require(TimeZone(identifier: "America/Los_Angeles")))
        #expect(body.contains("Next known expiry:"))
        #expect(body.contains("Sep 6, 2026"))
        #expect(ResetNotificationCopy.announcementBody(scope: "Max").contains("Announced scope: Max"))
        #expect(!ResetNotificationCopy.announcementBody(scope: nil).contains("your limits"))
    }

    @Test("only official usage and original status posts can be opened")
    func destinations() throws {
        #expect(ResetLinks.allowed(ResetLinks.codexUsage))
        #expect(ResetLinks.allowed(try #require(URL(string: "https://x.com/ClaudeDevs/status/2095967323412930677"))))
        for value in ["http://x.com/a/status/123", "https://x.com.evil.test/a/status/123", "https://chatgpt.com/other",
                      "https://chatgpt.com/codex/settings/usage?redirect=evil", "file:///tmp/a", "https://user@x.com/a/status/123"] {
            #expect(!ResetLinks.allowed(try #require(URL(string: value))))
        }
    }
}
