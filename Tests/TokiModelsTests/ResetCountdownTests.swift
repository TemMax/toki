import Testing
import Foundation
@testable import TokiModels

/// The one formatter every surface uses for "when does this window reset" — the popover,
/// the Usage strip and the account cards must never word the same fact differently.
@Suite("ResetCountdown")
struct ResetCountdownTests {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("no reset date yields no text rather than an invented one")
    func nilDateYieldsNil() {
        #expect(ResetCountdown.text(for: nil, now: now) == nil)
    }

    @Test("under an hour reports minutes only")
    func minutesOnly() {
        #expect(ResetCountdown.text(for: now.addingTimeInterval(14 * 60), now: now) == "resets in ~14m")
    }

    @Test("over an hour reports hours and minutes")
    func hoursAndMinutes() {
        let date = now.addingTimeInterval(2 * 3600 + 29 * 60)
        #expect(ResetCountdown.text(for: date, now: now) == "resets in ~2h 29m")
    }

    @Test("a whole number of hours still shows the zero minutes, matching the popover")
    func wholeHours() {
        #expect(ResetCountdown.text(for: now.addingTimeInterval(3 * 3600), now: now) == "resets in ~3h 0m")
    }

    @Test("a window that has already elapsed reads as resetting now, never negative")
    func elapsedReadsAsNow() {
        #expect(ResetCountdown.text(for: now.addingTimeInterval(-60), now: now) == "resets now")
        #expect(ResetCountdown.text(for: now, now: now) == "resets now")
    }

    /// Under a minute is "now", not "~0m". Integer division made the old code count down to
    /// a zero it still prefixed with "in".
    @Test("less than a minute reads as now, never as ~0m")
    func subMinuteReadsAsNow() {
        #expect(ResetCountdown.text(for: now.addingTimeInterval(30), now: now) == "resets now")
        #expect(ResetCountdown.text(for: now.addingTimeInterval(59), now: now) == "resets now")
        #expect(ResetCountdown.text(for: now.addingTimeInterval(60), now: now) == "resets in ~1m")
    }

    @Test("just under a day still reports hours and minutes")
    func justUnderADay() {
        let date = now.addingTimeInterval(23 * 3600 + 59 * 60)
        #expect(ResetCountdown.text(for: date, now: now) == "resets in ~23h 59m")
    }

    @Test("exactly a day rolls over into days, dropping minutes")
    func exactlyADayRollsOver() {
        let date = now.addingTimeInterval(24 * 3600)
        #expect(ResetCountdown.text(for: date, now: now) == "resets in ~1d 0h")
    }

    @Test("just over a day still shows one day plus the extra hour")
    func justOverADay() {
        let date = now.addingTimeInterval(25 * 3600)
        #expect(ResetCountdown.text(for: date, now: now) == "resets in ~1d 1h")
    }

    @Test("a multi-day window like the weekly gauge rolls hours into days")
    func multiDayWindowRollsIntoDays() {
        let date = now.addingTimeInterval(113 * 3600 + 22 * 60)
        #expect(ResetCountdown.text(for: date, now: now) == "resets in ~4d 17h")
    }
}
