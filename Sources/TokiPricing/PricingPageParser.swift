/// PricingPageParser — extracts `RatePeriod` rows from the official Anthropic pricing
/// page's server-rendered HTML, so a live refresh can merge fresh rates into the local
/// rate history without ever retroactively repricing already-recorded usage.
import Foundation
import TokiModels

public enum PricingPageParser {

    /// The official Claude pricing page. Server-rendered HTML containing one or more
    /// `<table>` elements; the relevant table has a header row mentioning
    /// "Base Input Tokens" and "Output Tokens".
    public static let pricingURL = URL(string: "https://platform.claude.com/docs/en/about-claude/pricing")!

    /// Parses the pricing page HTML into rate periods. Never throws: rows that fail to
    /// parse or fail validation are skipped so a single malformed row can't poison the
    /// rest of the result. Returns `[]` when the expected table can't be found or no
    /// row survives validation.
    public static func parse(html: String) -> [RatePeriod] {
        guard let tableHTML = pricingTable(in: html) else { return [] }
        let rows = extractRows(from: tableHTML)
        guard rows.count > 1 else { return [] }

        // First row is the header; parse every subsequent row independently.
        return rows.dropFirst().compactMap { rowHTML in
            parseRow(rowHTML)
        }
    }

    // MARK: - Table selection

    /// Finds the `<table>...</table>` whose first row's text mentions both
    /// "Base Input" and "Output" (case-insensitive), i.e. the pricing table.
    private static func pricingTable(in html: String) -> String? {
        for tableHTML in matches(of: tableRegex, in: html) {
            let rows = extractRows(from: tableHTML)
            guard let headerRow = rows.first else { continue }
            let headerCells = extractCells(from: headerRow)
            let headerText = headerCells.joined(separator: " ").lowercased()
            if headerText.contains("base input") && headerText.contains("output") {
                return tableHTML
            }
        }
        return nil
    }

    // MARK: - Row parsing

    /// Parses a single `<tr>` into a `RatePeriod`, or nil when the row is malformed or
    /// fails validation.
    private static func parseRow(_ rowHTML: String) -> RatePeriod? {
        let cells = extractCells(from: rowHTML)
        guard cells.count >= 6 else { return nil }

        guard
            let inputPerMTok = parsePrice(cells[1]),
            let cacheWrite5mPerMTok = parsePrice(cells[2]),
            let cacheWrite1hPerMTok = parsePrice(cells[3]),
            let cacheReadPerMTok = parsePrice(cells[4]),
            let outputPerMTok = parsePrice(cells[5])
        else { return nil }

        guard
            isValidRate(inputPerMTok), isValidRate(outputPerMTok),
            isValidRate(cacheWrite5mPerMTok), isValidRate(cacheWrite1hPerMTok),
            isValidRate(cacheReadPerMTok)
        else { return nil }

        let (modelPrefix, effectiveFrom, effectiveUntil) = parseLabel(cells[0])
        guard modelPrefix.hasPrefix("claude-") else { return nil }

        return RatePeriod(
            modelPrefix: modelPrefix,
            inputPerMTok: inputPerMTok,
            outputPerMTok: outputPerMTok,
            cacheWrite5mPerMTok: cacheWrite5mPerMTok,
            cacheWrite1hPerMTok: cacheWrite1hPerMTok,
            cacheReadPerMTok: cacheReadPerMTok,
            effectiveFrom: effectiveFrom,
            effectiveUntil: effectiveUntil
        )
    }

    /// A rate must be finite, positive, and below the sanity ceiling of 1000 USD/MTok.
    private static func isValidRate(_ value: Double) -> Bool {
        value.isFinite && value > 0 && value < 1000
    }

    // MARK: - Label parsing (model name + effective-date window)

    /// Splits a label cell like "Claude Sonnet 5through August 31, 2026" into a
    /// hyphenated model prefix and an effective-date window.
    private static func parseLabel(_ label: String) -> (modelPrefix: String, from: Date?, until: Date?) {
        var from: Date?
        var until: Date?

        if let match = firstMatch(of: dateWindowRegex, in: label), match.count >= 3 {
            let kind = match[1].lowercased()
            if let date = parseLongDate(match[2]) {
                let day = startOfDayUTC(date)
                if kind == "through" {
                    until = addDaysUTC(day, 1)
                } else if kind == "starting" {
                    from = day
                }
            }
        }

        var cleanName = label.replacingOccurrences(
            of: dateWindowStripRegex, with: "", options: .regularExpression
        )
        cleanName = cleanName.replacingOccurrences(
            of: "\\([^)]*\\)", with: "", options: .regularExpression
        )
        cleanName = cleanName.trimmingCharacters(in: .whitespacesAndNewlines)

        let prefix = modelPrefix(from: cleanName)
        return (prefix, from, until)
    }

    /// "Claude Opus 4.8" -> "claude-opus-4-8"
    private static func modelPrefix(from name: String) -> String {
        let lowered = name.lowercased()
        let normalized = lowered.replacingOccurrences(
            of: "[^a-z0-9]+", with: " ", options: .regularExpression
        )
        let parts = normalized
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ")
            .map(String.init)
        return parts.joined(separator: "-")
    }

    /// Parses "August 31, 2026" / "September 1 2026" into a UTC date.
    private static func parseLongDate(_ text: String) -> Date? {
        let normalized = text.replacingOccurrences(of: ",", with: ",")
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "MMMM d, yyyy"
        if let date = formatter.date(from: normalized) {
            return date
        }
        // Tolerate a missing comma ("September 1 2026").
        formatter.dateFormat = "MMMM d yyyy"
        return formatter.date(from: normalized)
    }

    private static func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private static func startOfDayUTC(_ date: Date) -> Date {
        utcCalendar().startOfDay(for: date)
    }

    private static func addDaysUTC(_ date: Date, _ days: Int) -> Date {
        utcCalendar().date(byAdding: .day, value: days, to: date) ?? date
    }

    // MARK: - HTML primitives

    private static let tableRegex = try! NSRegularExpression(
        pattern: "<table[^>]*>.*?</table>", options: [.caseInsensitive, .dotMatchesLineSeparators]
    )
    private static let rowRegex = try! NSRegularExpression(
        pattern: "<tr[^>]*>.*?</tr>", options: [.caseInsensitive, .dotMatchesLineSeparators]
    )
    private static let cellRegex = try! NSRegularExpression(
        pattern: "<(td|th)[^>]*>(.*?)</(td|th)>", options: [.caseInsensitive, .dotMatchesLineSeparators]
    )
    private static let tagStripRegex = try! NSRegularExpression(
        pattern: "<[^>]+>", options: []
    )
    private static let priceRegex = try! NSRegularExpression(
        pattern: "\\$\\s*([0-9]+(?:\\.[0-9]+)?)", options: []
    )
    private static let dateWindowRegex = try! NSRegularExpression(
        pattern: "(through|starting)\\s+([A-Za-z]+\\s+\\d{1,2},?\\s+\\d{4})", options: [.caseInsensitive]
    )
    private static let dateWindowStripRegex = "(?i)(through|starting).*$"

    /// Returns every `<table>...</table>` block in `html`.
    private static func matches(of regex: NSRegularExpression, in text: String) -> [String] {
        let nsrange = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, options: [], range: nsrange).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            return String(text[range])
        }
    }

    /// Returns every `<tr>...</tr>` block within a table's HTML.
    private static func extractRows(from tableHTML: String) -> [String] {
        matches(of: rowRegex, in: tableHTML)
    }

    /// Returns the cleaned (tag-stripped, entity-unescaped, trimmed) text of every
    /// `<td>`/`<th>` cell within a row's HTML.
    private static func extractCells(from rowHTML: String) -> [String] {
        let nsrange = NSRange(rowHTML.startIndex..<rowHTML.endIndex, in: rowHTML)
        let cellMatches = cellRegex.matches(in: rowHTML, options: [], range: nsrange)
        return cellMatches.compactMap { match in
            guard match.numberOfRanges >= 3, let innerRange = Range(match.range(at: 2), in: rowHTML) else {
                return nil
            }
            let inner = String(rowHTML[innerRange])
            return cleanCellText(inner)
        }
    }

    /// Strips tags, unescapes HTML entities, and trims whitespace from cell inner-HTML.
    private static func cleanCellText(_ inner: String) -> String {
        let stripped = stripTags(inner)
        let unescaped = unescapeEntities(stripped)
        return unescaped.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripTags(_ text: String) -> String {
        let nsrange = NSRange(text.startIndex..<text.endIndex, in: text)
        return tagStripRegex.stringByReplacingMatches(in: text, options: [], range: nsrange, withTemplate: "")
    }

    private static func unescapeEntities(_ text: String) -> String {
        var result = text
        let entities: [(String, String)] = [
            ("&amp;", "&"),
            ("&lt;", "<"),
            ("&gt;", ">"),
            ("&#36;", "$"),
            ("&#39;", "'"),
            ("&quot;", "\""),
            ("&nbsp;", " "),
        ]
        for (entity, replacement) in entities {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }
        return result
    }

    /// Extracts the first price (e.g. "$2.50") from a cell, returning its numeric value.
    private static func parsePrice(_ cell: String) -> Double? {
        guard let match = firstMatch(of: priceRegex, in: cell), match.count >= 2 else { return nil }
        return Double(match[1])
    }

    /// Runs `regex` against `text` and returns the matched groups as strings
    /// (index 0 is the whole match), or nil when there is no match.
    private static func firstMatch(of regex: NSRegularExpression, in text: String) -> [String]? {
        let nsrange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: nsrange) else { return nil }
        var groups: [String] = []
        for i in 0..<match.numberOfRanges {
            if let range = Range(match.range(at: i), in: text) {
                groups.append(String(text[range]))
            } else {
                groups.append("")
            }
        }
        return groups
    }
}
