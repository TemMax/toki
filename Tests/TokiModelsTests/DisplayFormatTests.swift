import Testing
import Foundation
@testable import TokiModels

/// These pin the *shape* of every number the UI shows.
///
/// The bug they exist to prevent shipped once already: formatting followed
/// `Locale.current`, so on a machine set to a European locale an English-language interface
/// rendered `100 000,00 US$` beside a label reading "Total Cost", and `4 180` beside "API
/// Calls". Nothing failed — it just looked broken, and only in screenshots taken on a
/// machine configured that way.
@Suite("Display formatting is locale-independent")
struct DisplayFormatTests {

    @Test("currency uses a dot separator, a leading symbol, and no space")
    func currencyShape() {
        #expect((51.15).currencyString() == "$51.15")
        #expect((0.0).currencyString() == "$0.00")
        #expect((1234.5).currencyString() == "$1,234.50")
    }

    @Test("a non-USD code keeps the display conventions and only changes the symbol")
    func nonUSDCurrency() {
        let euros = (51.15).currencyString(code: "EUR")
        #expect(euros.contains("51.15"), "\(euros)")
        #expect(!euros.contains("51,15"), "European separators leaked in: \(euros)")
    }

    @Test("integers group with commas, never spaces")
    func integerShape() {
        #expect(4180.groupedString == "4,180")
        #expect(100.groupedString == "100")
        #expect(1_000_000.groupedString == "1,000,000")
    }

    @Test("token counts use decimal compact units through quadrillions")
    func compactTokenCounts() {
        #expect(999.formatted(.tokenCount) == "999")
        #expect(1_000.formatted(.tokenCount) == "1K")
        #expect(14_500.formatted(.tokenCount) == "14.5K")
        #expect(1_200_000.formatted(.tokenCount) == "1.2M")
        #expect(1_000_000_000.formatted(.tokenCount) == "1B")
        #expect(1_250_000_000.formatted(.tokenCount) == "1.3B")
        #expect(1_000_000_000_000.formatted(.tokenCount) == "1T")
        #expect(1_000_000_000_000_000.formatted(.tokenCount) == "1Q")
        #expect((-2_500_000_000).formatted(.tokenCount) == "-2.5B")
        #expect(Int.min.formatted(.tokenCount).hasSuffix("Q"))
    }

    /// The regression proper: the old code read `Locale.current`, so this suite would have
    /// passed on a US machine and failed on a European one. Formatting the same values
    /// through a deliberately hostile locale must not change the output.
    @Test("output does not change when the machine's locale would format differently")
    func immuneToSystemLocale() {
        let hostile = Locale(identifier: "de_DE")
        // What the old implementation would have produced on that machine:
        let wouldHaveBeen = (51.15).formatted(
            .currency(code: "USD").precision(.fractionLength(2)).locale(hostile)
        )
        #expect(wouldHaveBeen != "$51.15", "test is inert — de_DE now formats like en_US")
        #expect((51.15).currencyString() == "$51.15")
    }

    @Test("ExtraUsage formats through the display locale, not the machine's")
    func extraUsageAmount() {
        let extra = ExtraUsage(
            isEnabled: true,
            monthlyLimit: 100_000,
            usedCredits: 100_000,
            utilization: 1.0,
            currency: "USD",
            decimalPlaces: 2,
            spendLimitReached: true
        )
        #expect(extra.amountString(100_000) == "$100,000.00")
    }
}

/// Memory sizing was missed by the first locale pass: `ByteCountFormatter` renders
/// "1,22 GB" on a European machine, beside English labels, exactly like the currency bug.
@Suite("Memory formatting is locale-independent")
struct MemoryFormatTests {
    @Test("gigabytes use a dot and one decimal")
    func gigabytes() {
        #expect(DisplayFormat.memory(bytes: 1_310_720_000) == "1.2 GB")
        #expect(DisplayFormat.memory(bytes: 2 * 1024 * 1024 * 1024) == "2.0 GB")
    }

    @Test("megabytes are whole numbers")
    func megabytes() {
        #expect(DisplayFormat.memory(bytes: 155_189_248) == "148 MB")
        #expect(DisplayFormat.memory(bytes: 210_000_000) == "200 MB")
    }

    @Test("the boundary lands on GB, not 1024 MB")
    func boundary() {
        #expect(DisplayFormat.memory(bytes: 1024 * 1024 * 1024) == "1.0 GB")
        #expect(DisplayFormat.memory(bytes: 1024 * 1024 * 1024 - 1).hasSuffix("MB"))
    }

    @Test("output does not follow a machine that would format differently")
    func immuneToLocale() {
        let hostile = (1.2).formatted(.number.precision(.fractionLength(1)).locale(Locale(identifier: "de_DE")))
        #expect(hostile != "1.2", "test is inert — de_DE now formats like en_US")
        #expect(DisplayFormat.memory(bytes: 1_310_720_000) == "1.2 GB")
    }

    // MARK: - Trend caption

    private func utc(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    /// The formatter has to render in the SAME time zone the caller bucketed in, or the
    /// caption reads an hour or two off the chart it sits under. These pin the format and
    /// the collapsing rule; the zone is the machine's, as it is for the bucket dates.
    @Test("An hourly caption prints a 24-hour clock range")
    func hourlyCaptionIsAClockRange() {
        let calendar = Calendar.current
        let first = calendar.date(bySettingHour: 0, minute: 0, second: 0, of: Date())!
        let last = calendar.date(bySettingHour: 15, minute: 0, second: 0, of: Date())!

        #expect(DisplayFormat.bucketRangeLabel(first: first, last: last, size: .hour) == "00:00 – 15:00")
    }

    /// A 24-hour clock regardless of the machine's AM/PM preference — the caption follows
    /// `DisplayFormat.locale`, like every other number in the interface.
    @Test("An hourly caption uses 24-hour time, not AM/PM")
    func hourlyCaptionIs24Hour() {
        let calendar = Calendar.current
        let evening = calendar.date(bySettingHour: 21, minute: 0, second: 0, of: Date())!
        let label = DisplayFormat.bucketRangeLabel(first: evening, last: evening, size: .hour)

        #expect(label == "21:00")
        #expect(!label.contains("PM"))
        #expect(!label.contains("pm"))
    }

    @Test("A single-bucket range collapses to one value instead of repeating it")
    func singleBucketCaptionCollapses() {
        let noon = utc(2026, 9, 1, 12)
        #expect(DisplayFormat.bucketRangeLabel(first: noon, last: noon, size: .hour).contains("–") == false)
        #expect(DisplayFormat.bucketRangeLabel(first: noon, last: noon, size: .day) == "Sep 1")
    }

    @Test("A daily caption prints a month-and-day range")
    func dailyCaptionIsADateRange() {
        #expect(
            DisplayFormat.bucketRangeLabel(
                first: utc(2026, 8, 26, 12), last: utc(2026, 9, 1, 12), size: .day
            ) == "Aug 26 – Sep 1"
        )
    }

    /// Two days that share a month-and-day rendering (a year apart) still collapse, which
    /// is a deliberate limit of a caption that never prints the year — the range selector
    /// above it already says which period is in view.
    @Test("A missing endpoint yields an empty caption rather than a half range")
    func missingEndpointYieldsEmptyCaption() {
        #expect(DisplayFormat.bucketRangeLabel(first: nil, last: utc(2026, 9, 1), size: .day) == "")
        #expect(DisplayFormat.bucketRangeLabel(first: utc(2026, 9, 1), last: nil, size: .day) == "")
        #expect(DisplayFormat.bucketRangeLabel(first: nil, last: nil, size: .hour) == "")
    }
}
