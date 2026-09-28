import Foundation
import Testing
@testable import TokiMenuBar

@Suite("MenuBarStyle.standard")
struct MenuBarStyleStandardTests {
    /// Field-by-field regression guard against `App/Sources/MenuBarStripView.swift`'s
    /// hardcoded values before `MenuBarStyle` existed — the whole reason this type is safe to
    /// ship is that nobody who never opens Settings sees any difference.
    @Test("reproduces today's hardcoded appearance exactly")
    func matchesTodaysHardcodedValues() {
        let standard = MenuBarStyle.standard
        #expect(standard.leading == "")
        #expect(standard.trailing == "")
        #expect(standard.separator == "")
        #expect(standard.labelGap == 3) // gap (2) + 1
        #expect(standard.groupGap == 7)
        #expect(standard.valueSize == 11) // TypeScale.Role.label's step
        #expect(standard.labelSize == 10) // TypeScale.Role.caption's step
        #expect(standard.unitScale == 0.72)
        #expect(standard.barWidth == 3)
        #expect(standard.barHeight == 11)
    }
}

@Suite("MenuBarStyle numeric clamping")
struct MenuBarStyleClampingTests {
    @Test("labelGap clamps at both ends, through the init and through Decodable")
    func labelGapClamps() throws {
        #expect(MenuBarStyle(labelGap: -5).labelGap == MenuBarStyle.minimumLabelGap)
        #expect(MenuBarStyle(labelGap: 999).labelGap == MenuBarStyle.maximumLabelGap)
        #expect(try decoded(["labelGap": -5]).labelGap == MenuBarStyle.minimumLabelGap)
        #expect(try decoded(["labelGap": 999]).labelGap == MenuBarStyle.maximumLabelGap)
    }

    @Test("groupGap clamps at both ends, through the init and through Decodable")
    func groupGapClamps() throws {
        #expect(MenuBarStyle(groupGap: -5).groupGap == MenuBarStyle.minimumGroupGap)
        #expect(MenuBarStyle(groupGap: 999).groupGap == MenuBarStyle.maximumGroupGap)
        #expect(try decoded(["groupGap": -5]).groupGap == MenuBarStyle.minimumGroupGap)
        #expect(try decoded(["groupGap": 999]).groupGap == MenuBarStyle.maximumGroupGap)
    }

    @Test("valueSize clamps at both ends, through the init and through Decodable")
    func valueSizeClamps() throws {
        #expect(MenuBarStyle(valueSize: -5).valueSize == MenuBarStyle.minimumValueSize)
        #expect(MenuBarStyle(valueSize: 999).valueSize == MenuBarStyle.maximumValueSize)
        #expect(try decoded(["valueSize": -5]).valueSize == MenuBarStyle.minimumValueSize)
        #expect(try decoded(["valueSize": 999]).valueSize == MenuBarStyle.maximumValueSize)
    }

    @Test("labelSize clamps at both ends, through the init and through Decodable")
    func labelSizeClamps() throws {
        #expect(MenuBarStyle(labelSize: -5).labelSize == MenuBarStyle.minimumLabelSize)
        #expect(MenuBarStyle(labelSize: 999).labelSize == MenuBarStyle.maximumLabelSize)
        #expect(try decoded(["labelSize": -5]).labelSize == MenuBarStyle.minimumLabelSize)
        #expect(try decoded(["labelSize": 999]).labelSize == MenuBarStyle.maximumLabelSize)
    }

    @Test("unitScale clamps at both ends, through the init and through Decodable")
    func unitScaleClamps() throws {
        #expect(MenuBarStyle(unitScale: -5).unitScale == MenuBarStyle.minimumUnitScale)
        #expect(MenuBarStyle(unitScale: 999).unitScale == MenuBarStyle.maximumUnitScale)
        #expect(try decoded(["unitScale": -5]).unitScale == MenuBarStyle.minimumUnitScale)
        #expect(try decoded(["unitScale": 999]).unitScale == MenuBarStyle.maximumUnitScale)
    }

    @Test("barWidth clamps at both ends, through the init and through Decodable")
    func barWidthClamps() throws {
        #expect(MenuBarStyle(barWidth: -5).barWidth == MenuBarStyle.minimumBarWidth)
        #expect(MenuBarStyle(barWidth: 999).barWidth == MenuBarStyle.maximumBarWidth)
        #expect(try decoded(["barWidth": -5]).barWidth == MenuBarStyle.minimumBarWidth)
        #expect(try decoded(["barWidth": 999]).barWidth == MenuBarStyle.maximumBarWidth)
    }

    @Test("barHeight clamps at both ends, through the init and through Decodable")
    func barHeightClamps() throws {
        #expect(MenuBarStyle(barHeight: -5).barHeight == MenuBarStyle.minimumBarHeight)
        #expect(MenuBarStyle(barHeight: 999).barHeight == MenuBarStyle.maximumBarHeight)
        #expect(try decoded(["barHeight": -5]).barHeight == MenuBarStyle.minimumBarHeight)
        #expect(try decoded(["barHeight": 999]).barHeight == MenuBarStyle.maximumBarHeight)
    }

    /// Builds a `MenuBarStyle` payload with every field but the ones under test defaulted to
    /// `standard`'s own values, so each clamping test only has to name the field it's probing.
    private func decoded(_ overrides: [String: Double]) throws -> MenuBarStyle {
        var object: [String: Any] = [
            "leading": "", "trailing": "", "separator": "",
            "labelGap": 3, "groupGap": 7, "valueSize": 11, "labelSize": 10,
            "unitScale": 0.72, "barWidth": 3, "barHeight": 11,
        ]
        for (key, value) in overrides { object[key] = value }
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(MenuBarStyle.self, from: data)
    }
}

@Suite("MenuBarStyle non-finite values fall back to the default")
struct MenuBarStyleNonFiniteTests {
    /// `min`/`max` both propagate NaN — every comparison against NaN is false — so without an
    /// explicit `isFinite` guard `clamp` would hand a NaN point size straight to SwiftUI
    /// despite the type's doc comment promising every numeric field is bounded on both ends.
    /// Covers every numeric field with `.nan`, `.infinity` and `-.infinity`: the two
    /// infinities are expected to clamp normally (they compare correctly against finite
    /// bounds), only NaN needs the fallback — asserting all three side by side is what proves
    /// that distinction rather than assuming it.
    @Test("labelGap")
    func labelGapNonFinite() {
        #expect(MenuBarStyle(labelGap: .nan).labelGap == MenuBarStyle.standard.labelGap)
        #expect(MenuBarStyle(labelGap: .infinity).labelGap == MenuBarStyle.maximumLabelGap)
        #expect(MenuBarStyle(labelGap: -.infinity).labelGap == MenuBarStyle.minimumLabelGap)
    }

    @Test("groupGap")
    func groupGapNonFinite() {
        #expect(MenuBarStyle(groupGap: .nan).groupGap == MenuBarStyle.standard.groupGap)
        #expect(MenuBarStyle(groupGap: .infinity).groupGap == MenuBarStyle.maximumGroupGap)
        #expect(MenuBarStyle(groupGap: -.infinity).groupGap == MenuBarStyle.minimumGroupGap)
    }

    @Test("valueSize")
    func valueSizeNonFinite() {
        #expect(MenuBarStyle(valueSize: .nan).valueSize == MenuBarStyle.standard.valueSize)
        #expect(MenuBarStyle(valueSize: .infinity).valueSize == MenuBarStyle.maximumValueSize)
        #expect(MenuBarStyle(valueSize: -.infinity).valueSize == MenuBarStyle.minimumValueSize)
    }

    @Test("labelSize")
    func labelSizeNonFinite() {
        #expect(MenuBarStyle(labelSize: .nan).labelSize == MenuBarStyle.standard.labelSize)
        #expect(MenuBarStyle(labelSize: .infinity).labelSize == MenuBarStyle.maximumLabelSize)
        #expect(MenuBarStyle(labelSize: -.infinity).labelSize == MenuBarStyle.minimumLabelSize)
    }

    @Test("unitScale")
    func unitScaleNonFinite() {
        #expect(MenuBarStyle(unitScale: .nan).unitScale == MenuBarStyle.standard.unitScale)
        #expect(MenuBarStyle(unitScale: .infinity).unitScale == MenuBarStyle.maximumUnitScale)
        #expect(MenuBarStyle(unitScale: -.infinity).unitScale == MenuBarStyle.minimumUnitScale)
    }

    @Test("barWidth")
    func barWidthNonFinite() {
        #expect(MenuBarStyle(barWidth: .nan).barWidth == MenuBarStyle.standard.barWidth)
        #expect(MenuBarStyle(barWidth: .infinity).barWidth == MenuBarStyle.maximumBarWidth)
        #expect(MenuBarStyle(barWidth: -.infinity).barWidth == MenuBarStyle.minimumBarWidth)
    }

    @Test("barHeight")
    func barHeightNonFinite() {
        #expect(MenuBarStyle(barHeight: .nan).barHeight == MenuBarStyle.standard.barHeight)
        #expect(MenuBarStyle(barHeight: .infinity).barHeight == MenuBarStyle.maximumBarHeight)
        #expect(MenuBarStyle(barHeight: -.infinity).barHeight == MenuBarStyle.minimumBarHeight)
    }

    // No Decodable-path test for non-finite values: `JSONDecoder` rejects a numeric literal
    // that overflows `Double` (e.g. `1e400`) as invalid JSON before it ever becomes a `Double`
    // — Foundation's JSON parser refuses to produce `.infinity`, and JSON has no spelling for
    // NaN at all. So a non-finite value can only ever reach `MenuBarStyle` through the
    // memberwise init, which `init(from:)` delegates to (see that initializer's own doc
    // comment) — the tests above already cover the one gate both paths share.
}

@Suite("MenuBarStyle free text")
struct MenuBarStyleFreeTextTests {
    @Test("leading, trailing and separator trim surrounding whitespace")
    func trimsWhitespace() {
        let style = MenuBarStyle(leading: "  [ ", trailing: " ] ", separator: " · ")
        #expect(style.leading == "[")
        #expect(style.trailing == "]")
        #expect(style.separator == "·")
    }

    @Test("free text caps at maximumFreeTextLength")
    func capsLength() {
        let style = MenuBarStyle(leading: "abcdefghij")
        #expect(style.leading.count == MenuBarStyle.maximumFreeTextLength)
        #expect(style.leading == String("abcdefghij".prefix(MenuBarStyle.maximumFreeTextLength)))
    }

    @Test("a newline or tab is stripped, not merely trimmed from the ends")
    func rejectsControlCharacters() {
        let style = MenuBarStyle(leading: "[\n\t]", separator: "a\nb")
        #expect(!style.leading.contains("\n"))
        #expect(!style.leading.contains("\t"))
        #expect(style.leading == "[]")
        #expect(style.separator == "ab")
    }

    @Test("a whitespace-only separator collapses to empty, the documented \"spacing alone\" state")
    func whitespaceOnlyCollapsesToEmpty() {
        #expect(MenuBarStyle(separator: "   ").separator == "")
    }

    @Test("free text is sanitized through Decodable too")
    func decodableSanitizes() throws {
        let json = """
        {"leading":" [\\n ","trailing":"]","separator":"","labelGap":3,"groupGap":7,
         "valueSize":11,"labelSize":10,"unitScale":0.72,"barWidth":3,"barHeight":11}
        """
        let decoded = try JSONDecoder().decode(MenuBarStyle.self, from: Data(json.utf8))
        #expect(decoded.leading == "[")
    }
}

@Suite("MenuBarStyle Codable round-trip")
struct MenuBarStyleRoundTripTests {
    @Test("a fully customised style survives Codable unchanged")
    func roundTrips() throws {
        let style = MenuBarStyle(
            leading: "[", trailing: "]", separator: "·",
            labelGap: 5, groupGap: 10, valueSize: 13, labelSize: 9,
            unitScale: 0.5, barWidth: 4, barHeight: 14
        )
        let data = try JSONEncoder().encode(style)
        let decoded = try JSONDecoder().decode(MenuBarStyle.self, from: data)
        #expect(decoded == style)
    }

    @Test("a style missing every key still decodes, defaulting to standard")
    func decodeToleratesEmptyPayload() throws {
        let decoded = try JSONDecoder().decode(MenuBarStyle.self, from: Data("{}".utf8))
        #expect(decoded == .standard)
    }
}
