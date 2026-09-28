import Testing
import Foundation
import TokiModels
@testable import TokiPricing

@Suite("PricingPageParser")
struct PricingPageParserTests {

    // MARK: - HTML fixtures

    /// A decoy table that lacks the "Base Input" / "Output" header — must be skipped.
    private static let decoyTable = """
    <table>
      <tr><th>Plan</th><th>Price</th></tr>
      <tr><td>Pro</td><td>$20 / month</td></tr>
    </table>
    """

    /// The real pricing table, mirroring the structure of the official page.
    private static let pricingTable = """
    <table>
      <tr>
        <th>Model</th>
        <th>Base Input Tokens</th>
        <th>5m Cache Writes</th>
        <th>1h Cache Writes</th>
        <th>Cache Hits &amp; Refreshes</th>
        <th>Output Tokens</th>
      </tr>
      <tr>
        <td>Claude Opus 4.8</td>
        <td>$5 / MTok</td>
        <td>$6.25 / MTok</td>
        <td>$10 / MTok</td>
        <td>$0.50 / MTok</td>
        <td>$25 / MTok</td>
      </tr>
      <tr>
        <td>Claude Haiku 3.5 (retired, except on Bedrock and Google Cloud)</td>
        <td>$0.80 / MTok</td>
        <td>$1 / MTok</td>
        <td>$1.60 / MTok</td>
        <td>$0.08 / MTok</td>
        <td>$4 / MTok</td>
      </tr>
      <tr>
        <td>Claude Sonnet 5through August 31, 2026</td>
        <td>$2 / MTok</td>
        <td>$2.50 / MTok</td>
        <td>$4 / MTok</td>
        <td>$0.20 / MTok</td>
        <td>$10 / MTok</td>
      </tr>
      <tr>
        <td>Claude Sonnet 5starting September 1, 2026</td>
        <td>$3 / MTok</td>
        <td>$3.75 / MTok</td>
        <td>$6 / MTok</td>
        <td>$0.30 / MTok</td>
        <td>$15 / MTok</td>
      </tr>
      <tr>
        <td>Llama 4 Maverick</td>
        <td>$0.50 / MTok</td>
        <td>$0.60 / MTok</td>
        <td>$1 / MTok</td>
        <td>$0.05 / MTok</td>
        <td>$2 / MTok</td>
      </tr>
      <tr>
        <td>Claude Mystery Model</td>
        <td>not priced</td>
        <td>$1 / MTok</td>
        <td>$2 / MTok</td>
        <td>$0.10 / MTok</td>
        <td>$5 / MTok</td>
      </tr>
    </table>
    """

    private static func fullPage(withDecoy: Bool = true) -> String {
        let decoy = withDecoy ? decoyTable : ""
        return """
        <html><body>
        <h1>Pricing</h1>
        \(decoy)
        \(pricingTable)
        </body></html>
        """
    }

    // MARK: - Date helpers

    /// Builds a UTC date from calendar components.
    private static func utcDate(year: Int, month: Int, day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        return calendar.date(from: components)!
    }

    // MARK: - Table selection / row parsing

    @Test("selects the table with Base Input / Output headers, ignoring the decoy")
    func selectsCorrectTable() {
        let periods = PricingPageParser.parse(html: Self.fullPage())
        // Should not contain anything derived from the decoy "Plan/Price" table.
        #expect(!periods.contains { $0.modelPrefix == "pro" })
        #expect(periods.contains { $0.modelPrefix == "claude-opus-4-8" })
    }

    @Test("Opus 4.8 row parses with correct rates and no date window")
    func opusRow() {
        let periods = PricingPageParser.parse(html: Self.fullPage())
        let opus = periods.first { $0.modelPrefix == "claude-opus-4-8" }
        #expect(opus != nil)
        #expect(opus?.inputPerMTok == 5)
        #expect(opus?.outputPerMTok == 25)
        #expect(opus?.cacheWrite5mPerMTok == 6.25)
        #expect(opus?.cacheWrite1hPerMTok == 10)
        #expect(opus?.cacheReadPerMTok == 0.50)
        #expect(opus?.effectiveFrom == nil)
        #expect(opus?.effectiveUntil == nil)
    }

    @Test("Haiku 3.5 row strips the parenthetical suffix and parses $0.80 input")
    func haikuRow() {
        let periods = PricingPageParser.parse(html: Self.fullPage())
        let haiku = periods.first { $0.modelPrefix == "claude-haiku-3-5" }
        #expect(haiku != nil)
        #expect(haiku?.inputPerMTok == 0.80)
        #expect(haiku?.outputPerMTok == 4)
        #expect(haiku?.cacheWrite5mPerMTok == 1.0)
        #expect(haiku?.cacheWrite1hPerMTok == 1.60)
        #expect(haiku?.cacheReadPerMTok == 0.08)
    }

    @Test("Sonnet 5 introductory row: input 2 / output 10, open start, exclusive end")
    func sonnetIntroRow() {
        let periods = PricingPageParser.parse(html: Self.fullPage())
        let intro = periods.first {
            $0.modelPrefix == "claude-sonnet-5" && $0.effectiveUntil != nil
        }
        #expect(intro != nil)
        #expect(intro?.inputPerMTok == 2)
        #expect(intro?.outputPerMTok == 10)
        #expect(intro?.effectiveFrom == nil)
        #expect(intro?.effectiveUntil == Self.utcDate(year: 2026, month: 9, day: 1))
    }

    @Test("Sonnet 5 standard row: input 3 / output 15, effectiveFrom set, open end")
    func sonnetStandardRow() {
        let periods = PricingPageParser.parse(html: Self.fullPage())
        let standard = periods.first {
            $0.modelPrefix == "claude-sonnet-5" && $0.effectiveFrom != nil
        }
        #expect(standard != nil)
        #expect(standard?.inputPerMTok == 3)
        #expect(standard?.outputPerMTok == 15)
        #expect(standard?.effectiveFrom == Self.utcDate(year: 2026, month: 9, day: 1))
        #expect(standard?.effectiveUntil == nil)
    }

    @Test("non-Claude row and row with a missing price are both skipped")
    func bogusRowsSkipped() {
        let periods = PricingPageParser.parse(html: Self.fullPage())
        #expect(!periods.contains { $0.modelPrefix.contains("llama") })
        #expect(!periods.contains { $0.modelPrefix == "claude-mystery-model" })
        // Exactly 4 valid rows survive: Opus 4.8, Haiku 3.5, Sonnet intro, Sonnet standard.
        #expect(periods.count == 4)
    }

    @Test("missing pricing table returns empty array")
    func noPricingTableReturnsEmpty() {
        let periods = PricingPageParser.parse(html: Self.fullPage(withDecoy: false).replacingOccurrences(
            of: Self.pricingTable, with: Self.decoyTable
        ))
        #expect(periods.isEmpty)
    }

    @Test("empty or garbage HTML returns empty array")
    func garbageHTMLReturnsEmpty() {
        #expect(PricingPageParser.parse(html: "").isEmpty)
        #expect(PricingPageParser.parse(html: "<html><body>not a table</body></html>").isEmpty)
        #expect(PricingPageParser.parse(html: "asdf;lkj 1234 <<< >>>").isEmpty)
    }

    // MARK: - Window adjacency (no gap, no overlap across the boundary)

    @Test("introductory and standard Sonnet 5 windows are adjacent with no gap or overlap")
    func windowAdjacency() {
        let periods = PricingPageParser.parse(html: Self.fullPage())
        let intro = periods.first { $0.modelPrefix == "claude-sonnet-5" && $0.effectiveUntil != nil }!
        let standard = periods.first { $0.modelPrefix == "claude-sonnet-5" && $0.effectiveFrom != nil }!

        let midIntro = Self.utcDate(year: 2026, month: 7, day: 15)
        #expect(intro.isActive(on: midIntro) == true)
        #expect(standard.isActive(on: midIntro) == false)

        let midStandard = Self.utcDate(year: 2026, month: 9, day: 15)
        #expect(intro.isActive(on: midStandard) == false)
        #expect(standard.isActive(on: midStandard) == true)

        // The boundary day itself (Aug 31) belongs to the introductory window because
        // effectiveUntil is exclusive and set to the day *after* "through August 31".
        let boundaryDay = Self.utcDate(year: 2026, month: 8, day: 31)
        #expect(intro.isActive(on: boundaryDay) == true)
        #expect(standard.isActive(on: boundaryDay) == false)
    }


    // MARK: - Current page shape (Fable / Mythos rows)

    /// The rows the live page carries today for the Fable and Mythos generations. Two
    /// details are load-bearing and neither is cosmetic: the cache-hit cell ends in a
    /// FOOTNOTE DIGIT ("$0.25 / MTok1") that must not be read as part of the number, and
    /// the Mythos label carries a parenthetical that must be stripped before the prefix is
    /// derived. Fable 5 and Fable 5.1 also share every rate except cache reads ($1.00 vs
    /// $0.25), so a row that folded them together would be wrong by 4x on that one line.
    private static let fableTable = """
    <table>
      <tr>
        <th>Model</th>
        <th>Base input tokens</th>
        <th>5m cache writes</th>
        <th>1h cache writes</th>
        <th>Cache hits and refreshes</th>
        <th>Output tokens</th>
      </tr>
      <tr>
        <td>Claude Fable 5.1</td>
        <td>$10 / MTok</td>
        <td>$12.50 / MTok</td>
        <td>$20 / MTok</td>
        <td>$0.25 / MTok<sup>1</sup></td>
        <td>$50 / MTok</td>
      </tr>
      <tr>
        <td>Claude Mythos 5.1 (limited availability)</td>
        <td>$10 / MTok</td>
        <td>$12.50 / MTok</td>
        <td>$20 / MTok</td>
        <td>$0.25 / MTok<sup>1</sup></td>
        <td>$50 / MTok</td>
      </tr>
      <tr>
        <td>Claude Fable 5</td>
        <td>$10 / MTok</td>
        <td>$12.50 / MTok</td>
        <td>$20 / MTok</td>
        <td>$1 / MTok</td>
        <td>$50 / MTok</td>
      </tr>
      <tr>
        <td>Claude Opus 5</td>
        <td>$5 / MTok</td>
        <td>$6.25 / MTok</td>
        <td>$10 / MTok</td>
        <td>$0.50 / MTok</td>
        <td>$25 / MTok</td>
      </tr>
      <tr>
        <td>Claude Opus 5.5</td>
        <td>$4 / MTok</td>
        <td>$5 / MTok</td>
        <td>$8 / MTok</td>
        <td>$0.20 / MTok<sup>1</sup></td>
        <td>$20 / MTok</td>
      </tr>
    </table>
    """

    @Test("Claude Fable 5.1 parses to claude-fable-5-1 at $10 / $50 with a $0.25 cache read")
    func parsesFableFiveOne() throws {
        let periods = PricingPageParser.parse(html: Self.fableTable)
        let fable = try #require(periods.first { $0.modelPrefix == "claude-fable-5-1" })

        #expect(fable.inputPerMTok == 10)
        #expect(fable.outputPerMTok == 50)
        #expect(fable.cacheWrite5mPerMTok == 12.50)
        #expect(fable.cacheWrite1hPerMTok == 20)
        // The trailing footnote marker must not turn $0.25 into $0.251 or similar.
        #expect(fable.cacheReadPerMTok == 0.25)
        // No date window on this row.
        #expect(fable.effectiveFrom == nil)
        #expect(fable.effectiveUntil == nil)
    }

    @Test("Fable 5 and Fable 5.1 stay separate prefixes with different cache-read rates")
    func fableGenerationsStaySeparate() throws {
        let periods = PricingPageParser.parse(html: Self.fableTable)
        let fiveOne = try #require(periods.first { $0.modelPrefix == "claude-fable-5-1" })
        let five = try #require(periods.first { $0.modelPrefix == "claude-fable-5" })

        #expect(fiveOne.cacheReadPerMTok == 0.25)
        #expect(five.cacheReadPerMTok == 1.00)
        #expect(five.inputPerMTok == fiveOne.inputPerMTok)
        #expect(five.outputPerMTok == fiveOne.outputPerMTok)
    }

    @Test("A parenthetical availability note is stripped from the model prefix")
    func mythosParentheticalStripped() throws {
        let periods = PricingPageParser.parse(html: Self.fableTable)
        let mythos = try #require(periods.first { $0.modelPrefix == "claude-mythos-5-1" })

        #expect(mythos.inputPerMTok == 10)
        #expect(mythos.outputPerMTok == 50)
        #expect(mythos.cacheReadPerMTok == 0.25)
    }

    @Test("Claude Opus 5 parses to claude-opus-5, not a claude-opus-4 variant")
    func parsesOpusFive() throws {
        let periods = PricingPageParser.parse(html: Self.fableTable)
        let opus = try #require(periods.first { $0.modelPrefix == "claude-opus-5" })

        #expect(opus.inputPerMTok == 5)
        #expect(opus.outputPerMTok == 25)
        #expect(opus.cacheReadPerMTok == 0.50)
    }

    @Test("Claude Opus 5.5 parses all rates including the official cache-read footnote")
    func parsesOpusFiveFive() throws {
        let periods = PricingPageParser.parse(html: Self.fableTable)
        let opus = try #require(periods.first { $0.modelPrefix == "claude-opus-5-5" })

        #expect(opus.inputPerMTok == 4)
        #expect(opus.outputPerMTok == 20)
        #expect(opus.cacheWrite5mPerMTok == 5)
        #expect(opus.cacheWrite1hPerMTok == 8)
        #expect(opus.cacheReadPerMTok == 0.20)
    }
}
