import Foundation
import Testing
@testable import TokiMenuBar

@Suite("MenuBarIndicator.customLabel")
struct MenuBarIndicatorCustomLabelTests {
    @Test("nil by default: the derived label wins until the user overrides it")
    func defaultsToNil() {
        #expect(MenuBarIndicator(window: .fiveHour, rendering: .number).customLabel == nil)
    }

    @Test("trims surrounding whitespace")
    func trimsWhitespace() {
        #expect(MenuBarIndicator(window: .fiveHour, rendering: .number, customLabel: "  Session  ").customLabel == "Session")
    }

    @Test("a whitespace-only label resolves to nil, not an empty-but-present string")
    func whitespaceOnlyBecomesNil() {
        #expect(MenuBarIndicator(window: .fiveHour, rendering: .number, customLabel: "   ").customLabel == nil)
        #expect(MenuBarIndicator(window: .fiveHour, rendering: .number, customLabel: "").customLabel == nil)
    }

    @Test("caps at maximumCustomLabelLength")
    func capsLength() {
        let overlong = String(repeating: "x", count: 200)
        let indicator = MenuBarIndicator(window: .fiveHour, rendering: .number, customLabel: overlong)
        #expect(indicator.customLabel?.count == MenuBarIndicator.maximumCustomLabelLength)
        #expect(indicator.customLabel == String(overlong.prefix(MenuBarIndicator.maximumCustomLabelLength)))
    }

    @Test("strips control characters such as newlines and tabs")
    func stripsControlCharacters() {
        let indicator = MenuBarIndicator(window: .fiveHour, rendering: .number, customLabel: "Ses\nsion\t!")
        #expect(indicator.customLabel == "Session!")
    }

    @Test("sanitizing applies through Decodable too")
    func decodableSanitizes() throws {
        let overlong = String(repeating: "y", count: 200)
        let json = """
        {"id":"AAAAAAAA-AAAA-4AAA-AAAA-AAAAAAAAAAAA","window":{"fiveHour":{}},"rendering":"number","customLabel":"\(overlong)"}
        """
        let decoded = try JSONDecoder().decode(MenuBarIndicator.self, from: Data(json.utf8))
        #expect(decoded.customLabel?.count == MenuBarIndicator.maximumCustomLabelLength)
    }

    @Test("absent in a configuration saved before this field existed decodes to nil")
    func decodeToleratesMissingKey() throws {
        let json = """
        {"id":"AAAAAAAA-AAAA-4AAA-AAAA-AAAAAAAAAAAA","window":{"fiveHour":{}},"rendering":"number","showsLabel":true}
        """
        let decoded = try JSONDecoder().decode(MenuBarIndicator.self, from: Data(json.utf8))
        #expect(decoded.customLabel == nil)
    }

    @Test("round-trips unchanged through Codable")
    func roundTrips() throws {
        let indicator = MenuBarIndicator(window: .sevenDay, rendering: .bar, customLabel: "Weekly")
        let data = try JSONEncoder().encode(indicator)
        let decoded = try JSONDecoder().decode(MenuBarIndicator.self, from: data)
        #expect(decoded == indicator)
        #expect(decoded.customLabel == "Weekly")
    }
}
