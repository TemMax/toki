/// ISO8601Timestamp — allocation-free parsing of the one timestamp shape transcripts use.
import Foundation

/// Parses `YYYY-MM-DDTHH:MM:SS[.fraction]Z` — the exact shape Claude Code and Codex write —
/// without a formatter.
///
/// `ISO8601DateFormatter` goes through ICU and costs microseconds per call; with one timestamp
/// per record that was a measurable share of an index pass. Anything outside this shape (an
/// offset instead of `Z`, a missing field) returns `nil`, and `TranscriptParser.parseTimestamp`
/// falls back to the formatters, so accepting less here only costs speed, never records.
///
/// Fractions are kept to the millisecond — the index stores milliseconds.
enum ISO8601Timestamp {
    static func parse(_ string: String) -> Date? {
        var string = string
        return string.withUTF8 { parse(UnsafeRawBufferPointer($0)) }
    }

    static func parse(_ s: UnsafeRawBufferPointer) -> Date? {
        // Minimal: 2026-06-29T16:30:01Z (20 bytes).
        guard s.count >= 20, s.count <= 40 else { return nil }
        func digits(_ at: Int, _ n: Int) -> Int? {
            var value = 0
            for i in at..<(at + n) {
                let d = Int(s[i]) &- 48
                guard d >= 0, d <= 9 else { return nil }
                value = value * 10 + d
            }
            return value
        }
        guard s[4] == UInt8(ascii: "-"), s[7] == UInt8(ascii: "-"),
              s[10] == UInt8(ascii: "T") || s[10] == UInt8(ascii: "t"),
              s[13] == UInt8(ascii: ":"), s[16] == UInt8(ascii: ":"),
              let year = digits(0, 4), let month = digits(5, 2), let day = digits(8, 2),
              let hour = digits(11, 2), let minute = digits(14, 2), let second = digits(17, 2),
              (1...12).contains(month), day >= 1, day <= daysInMonth(year: year, month: month),
              hour <= 23, minute <= 59, second <= 59
        else { return nil }

        var index = 19
        var millis = 0
        if s[index] == UInt8(ascii: ".") {
            index += 1
            let fractionStart = index
            while index < s.count, s[index] >= 48, s[index] <= 57 {
                if index - fractionStart < 3 { millis = millis * 10 + Int(s[index] - 48) }
                index += 1
            }
            let fractionDigits = index - fractionStart
            guard fractionDigits > 0 else { return nil }
            if fractionDigits < 3 {
                for _ in fractionDigits..<3 { millis *= 10 }
            }
        }
        guard index == s.count - 1, s[index] == UInt8(ascii: "Z") || s[index] == UInt8(ascii: "z") else {
            return nil
        }

        let days = daysFromCivil(year: year, month: month, day: day)
        let seconds = Int64(days) * 86_400 + Int64(hour * 3600 + minute * 60 + second)
        return Date(timeIntervalSince1970: Double(seconds * 1000 + Int64(millis)) / 1000)
    }

    private static func daysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 2:
            let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
            return leap ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }

    /// Days since 1970-01-01 in the proleptic Gregorian calendar (Howard Hinnant's
    /// `days_from_civil`).
    private static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }
}
