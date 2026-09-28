import Foundation

/// The one locale every number in Toki is rendered in.
///
/// Deliberately NOT `Locale.current`. The API reports spend in a currency code, but the
/// *conventions* around it — decimal separator, grouping, symbol placement — used to follow
/// whatever the machine was set to, so an English-language interface rendered
/// `100 000,00 US$` and `4 180` next to labels reading "Total Cost" and "API Calls". Mixed
/// conventions read as a bug, and did: it was reported as one.
///
/// `en_US` rather than `en_US_POSIX`: POSIX is a stable *machine* format and produces
/// unhelpful currency output. `en_US` gives `$51.15`, `€51.15`, `4,180` — the shape a
/// developer tool with an English UI should show, whatever the currency turns out to be.
public enum DisplayFormat {
    public static let locale = Locale(identifier: "en_US")
}

// MARK: - Compact token counts

/// Compact decimal token units used across the app: K, M, B, T and Q.
///
/// Token billing uses decimal millions, so these are powers of 1,000 rather than binary
/// units. `Double` magnitude avoids the `abs(Int.min)` overflow trap.
public struct TokenCountFormat: FormatStyle {
    public init() {}

    public func format(_ value: Int) -> String {
        let magnitude = abs(Double(value))
        let units: [(threshold: Double, suffix: String)] = [
            (1_000_000_000_000_000, "Q"),
            (1_000_000_000_000, "T"),
            (1_000_000_000, "B"),
            (1_000_000, "M"),
            (1_000, "K"),
        ]
        guard let unit = units.first(where: { magnitude >= $0.threshold }) else {
            return String(value)
        }
        let compact = Double(value) / unit.threshold
        let rounded = (compact * 10).rounded(.toNearestOrAwayFromZero) / 10
        return rounded.formatted(
            .number
                .precision(.fractionLength(0...1))
                .grouping(.never)
                .locale(DisplayFormat.locale)
        ) + unit.suffix
    }
}

public extension FormatStyle where Self == TokenCountFormat {
    /// Compact token-count style: `Text(count, format: .tokenCount)`.
    static var tokenCount: TokenCountFormat { .init() }
}

public extension Double {
    /// The amount as currency, in the display locale. `code` defaults to USD because that
    /// is what the usage API reports unless it says otherwise.
    func currencyString(code: String = "USD", fractionDigits: Int = 2) -> String {
        formatted(
            .currency(code: code)
            .precision(.fractionLength(fractionDigits))
            .locale(DisplayFormat.locale)
        )
    }
}

public extension BinaryInteger {
    /// The value with grouping separators, in the display locale — `4,180`, never `4 180`.
    var groupedString: String {
        Int(self).formatted(.number.locale(DisplayFormat.locale))
    }
}

public extension DisplayFormat {
    /// Resident memory, compactly: `148 MB` below a gigabyte, `1.2 GB` at or above it.
    ///
    /// Hand-rolled rather than `ByteCountFormatter`, which takes its decimal separator from
    /// the machine and rendered `1,22 GB` beside English labels on a European locale — the
    /// same defect `DisplayFormat` exists to prevent, in a corner the first pass missed.
    ///
    /// Binary units (1024), matching `ByteCountFormatter.countStyle = .memory`, because this
    /// reports resident memory and that is the convention every process viewer on the
    /// platform uses. One decimal for gigabytes, none for megabytes: a process at 148.3 MB
    /// is not meaningfully different from one at 148, but 1.2 GB versus 1.9 GB is.
    static func memory(bytes: UInt64) -> String {
        let megabyte = 1024.0 * 1024
        let gigabyte = megabyte * 1024
        let value = Double(bytes)
        if value >= gigabyte {
            return (value / gigabyte).formatted(
                .number.precision(.fractionLength(1)).locale(locale)
            ) + " GB"
        }
        return (value / megabyte).formatted(
            .number.precision(.fractionLength(0)).locale(locale)
        ) + " MB"
    }
}

public extension DisplayFormat {
    /// The caption under a trend chart: `"Sep 1"` for one day, `"Aug 26 – Sep 1"` for a
    /// span of days, `"00:00 – 15:00"` for an hourly series.
    ///
    /// Hourly ranges print clock times, not the date, because on an hour-bucketed chart the
    /// date is the one thing every point has in common — `"Sep 1"` under twenty-four hourly
    /// points says nothing the range selector has not already said.
    ///
    /// Formats through `DisplayFormat.locale`, not the machine's: the rest of the interface
    /// is en_US by deliberate choice (see this file's header), and a caption that alone
    /// followed the system locale is the same defect in a smaller place. That fixes 24-hour
    /// clock times too, which is what an activity chart wants regardless of the machine's
    /// AM/PM preference.
    static func bucketRangeLabel(first: Date?, last: Date?, size: BucketSize) -> String {
        guard let first, let last else { return "" }
        let formatter = DateFormatter()
        formatter.locale = locale
        switch size {
        case .hour:
            formatter.dateFormat = "HH:mm"
            let start = formatter.string(from: first)
            let end = formatter.string(from: last)
            return start == end ? start : "\(start) – \(end)"
        case .day:
            formatter.dateFormat = "MMM d"
            let start = formatter.string(from: first)
            let end = formatter.string(from: last)
            return start == end ? start : "\(start) – \(end)"
        }
    }
}
