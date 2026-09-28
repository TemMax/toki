import Foundation
import Testing
@testable import TokiAlerts

@Suite("Reset expiry display")
struct ResetDateFormatTests {
    @Test("the same expiry changes calendar day in the user's time zone")
    func localDay() throws {
        let date = try #require(ISO8601DateFormatter().date(from: "2026-09-07T00:30:00Z"))
        let locale = Locale(identifier: "en_GB")
        let warsaw = ResetDateFormat.string(date: date, locale: locale, timeZone: try #require(TimeZone(identifier: "Europe/Warsaw")))
        let la = ResetDateFormat.string(date: date, locale: locale, timeZone: try #require(TimeZone(identifier: "America/Los_Angeles")))
        #expect(warsaw.contains("7 Sep 2026"))
        #expect(warsaw.contains("02:30"))
        #expect(la.contains("6 Sep 2026"))
        #expect(la.contains("17:30"))
    }

    @Test("repeated local hour during DST fall-back is disambiguated by the zone")
    func daylightSaving() throws {
        let formatter = ISO8601DateFormatter()
        let first = try #require(formatter.date(from: "2026-10-25T00:30:00Z"))
        let second = try #require(formatter.date(from: "2026-10-25T01:30:00Z"))
        let zone = try #require(TimeZone(identifier: "Europe/Warsaw"))
        let a = ResetDateFormat.string(date: first, locale: Locale(identifier: "en_GB"), timeZone: zone)
        let b = ResetDateFormat.string(date: second, locale: Locale(identifier: "en_GB"), timeZone: zone)
        #expect(a.contains("02:30"))
        #expect(b.contains("02:30"))
        #expect(a != b)
    }
}
