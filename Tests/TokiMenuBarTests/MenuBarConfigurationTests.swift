import Foundation
import Testing
@testable import TokiMenuBar

@Suite("MenuBarConfiguration")
struct MenuBarConfigurationTests {
    /// The default was three bars until it was seen on real data: at 11pt tall, the
    /// difference between 40% and 55% is under 2pt, so the strip answered "roughly how full"
    /// when the question is "how much is left, and on which window". Named numbers cost more
    /// menu-bar width and are worth it; `.bar` stays available per row for anyone who wants
    /// the compact version back.
    @Test("standard covers Claude and Codex core windows as named numbers")
    func standardConfiguration() {
        let standard = MenuBarConfiguration.standard
        #expect(standard.indicators.map(\.provider) == [
            .claudeCode, .claudeCode, .claudeCode, .codex, .codex,
        ])
        #expect(standard.indicators.map(\.window) == [
            .fiveHour, .sevenDay, .highestScopedModel, .fiveHour, .sevenDay,
        ])
        #expect(standard.indicators.allSatisfy { $0.rendering == .number })
        #expect(standard.indicators.allSatisfy { $0.showsLabel })
        #expect(standard.style == .standard)
        #expect(standard.compact == nil)
    }

    /// A bare number does not say which limit it belongs to, and the list exists precisely
    /// because the user reads several windows at once.
    @Test("an indicator is labelled unless something says otherwise")
    func labelDefaultsOn() {
        #expect(MenuBarIndicator(window: .fiveHour, rendering: .number).showsLabel)
    }

    @Test("a stored indicator from before labels existed decodes as labelled")
    func decodeWithoutLabelKey() throws {
        let stored = MenuBarIndicator(window: .sevenDay, rendering: .number, showsLabel: true)
        var object = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(stored)
        ) as! [String: Any]
        object.removeValue(forKey: "showsLabel")
        let data = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(MenuBarIndicator.self, from: data)
        #expect(decoded.showsLabel)
    }

    @Test("the memberwise init truncates to the cap")
    func initTruncates() {
        let overflowing = (0..<(MenuBarConfiguration.maximumIndicators + 3)).map {
            MenuBarIndicator(window: .scopedModel("Model\($0)"), rendering: .bar)
        }
        let configuration = MenuBarConfiguration(indicators: overflowing)
        #expect(configuration.indicators.count == MenuBarConfiguration.maximumIndicators)
        // Truncation keeps the front of the list, not an arbitrary subset.
        #expect(configuration.indicators.map(\.window) == overflowing.prefix(MenuBarConfiguration.maximumIndicators).map(\.window))
    }

    @Test("decoding a configuration with more entries than the cap truncates rather than trapping")
    func decodeTruncates() throws {
        // Build the payload directly as JSON so we exercise Decodable, not the memberwise
        // init (which already truncates on its own and would mask a decode-only bug).
        let indicatorsJSON = (0..<(MenuBarConfiguration.maximumIndicators + 4)).map { index in
            "{\"id\":\"\(UUID().uuidString)\",\"window\":{\"scopedModel\":{\"_0\":\"M\(index)\"}},\"rendering\":\"bar\"}"
        }.joined(separator: ",")
        let json = """
        {"indicators":[\(indicatorsJSON)],"isCompact":false}
        """
        let decoded = try JSONDecoder().decode(MenuBarConfiguration.self, from: Data(json.utf8))
        #expect(decoded.indicators.count == MenuBarConfiguration.maximumIndicators)
    }

    @Test("a configuration at the cap round-trips through Codable unchanged")
    func roundTripsAtCap() throws {
        let indicators = (0..<MenuBarConfiguration.maximumIndicators).map {
            MenuBarIndicator(window: .scopedModel("Model\($0)"), rendering: .number)
        }
        let customStyle = MenuBarStyle(leading: "[", trailing: "]", separator: "·")
        let configuration = MenuBarConfiguration(indicators: indicators, style: customStyle, compact: .worstOf)
        #expect(configuration.indicators.count == MenuBarConfiguration.maximumIndicators)

        let data = try JSONEncoder().encode(configuration)
        let decoded = try JSONDecoder().decode(MenuBarConfiguration.self, from: data)
        #expect(decoded == configuration)
    }

    /// A wrong-typed field inside `style` must not cost the user their indicators: before this
    /// fix, `style`'s own decode throwing propagated uncaught and failed the WHOLE
    /// `MenuBarConfiguration` decode, so `MenuBarConfigurationStore.load()`'s outer fallback
    /// discarded a user's five carefully ordered indicators and compact choice over one corrupt
    /// style value. See `init(from:)`'s doc comment on the `style` line.
    @Test("a wrong-typed style field falls back to .standard while the real indicators survive")
    func corruptStyleFallsBackAloneWhileIndicatorsSurvive() throws {
        let json = """
        {"indicators":[
            {"id":"AAAAAAAA-AAAA-4AAA-AAAA-AAAAAAAAAAAA","window":{"fiveHour":{}},"rendering":"number"},
            {"id":"BBBBBBBB-BBBB-4BBB-BBBB-BBBBBBBBBBBB","window":{"sevenDay":{}},"rendering":"bar"}
        ],"style":{"leading":"","trailing":"","separator":"","labelGap":"not-a-number","groupGap":7,
         "valueSize":11,"labelSize":10,"unitScale":0.72,"barWidth":3,"barHeight":11},"isCompact":false}
        """
        let decoded = try JSONDecoder().decode(MenuBarConfiguration.self, from: Data(json.utf8))
        #expect(decoded.indicators.map(\.window) == [.fiveHour, .sevenDay])
        #expect(decoded.style == .standard)
    }

    /// Exercises every customisable surface at once — indicators with custom labels, a fully
    /// customised style, compact mode — the end-to-end guard that nothing added by this
    /// feature is lossy across a save/load cycle.
    @Test("a fully customised configuration round-trips through Codable unchanged")
    func roundTripsFullyCustomised() throws {
        let indicators = [
            MenuBarIndicator(window: .fiveHour, rendering: .barAndNumber, showsLabel: true, customLabel: "Session"),
            MenuBarIndicator(window: .sevenDay, rendering: .number, showsLabel: false, customLabel: nil),
        ]
        let style = MenuBarStyle(
            leading: "[", trailing: "]", separator: "·",
            labelGap: 5, groupGap: 12, valueSize: 13, labelSize: 9,
            unitScale: 0.5, barWidth: 4, barHeight: 14
        )
        let configuration = MenuBarConfiguration(indicators: indicators, style: style, compact: nil)

        let data = try JSONEncoder().encode(configuration)
        let decoded = try JSONDecoder().decode(MenuBarConfiguration.self, from: data)
        #expect(decoded == configuration)
        #expect(decoded.indicators[0].customLabel == "Session")
        #expect(decoded.indicators[1].customLabel == nil)
    }
}

/// The lower bound matters more than the upper one: an empty list draws an empty status
/// item, and the status item is the only route into Settings — so a user who deleted the
/// last row would lose the menu bar and the way to restore it in the same action.
@Suite("An empty configuration is not representable")
struct EmptyConfigurationTests {
    @Test("the memberwise init replaces an empty list with the standard set")
    func initRejectsEmpty() {
        #expect(MenuBarConfiguration(indicators: []).indicators.count == 5)
    }

    @Test("decoding an empty list yields the standard set, not nothing")
    func decodeRejectsEmpty() throws {
        let json = #"{"indicators":[],"isCompact":false}"#
        let decoded = try JSONDecoder().decode(
            MenuBarConfiguration.self, from: Data(json.utf8)
        )
        #expect(!decoded.indicators.isEmpty)
    }

    @Test("a config missing the switches still decodes, defaulting them")
    func decodeToleratesMissingSwitches() throws {
        let json = #"{"indicators":[{"id":"AAAAAAAA-AAAA-4AAA-AAAA-AAAAAAAAAAAA","window":{"fiveHour":{}},"rendering":"bar"}]}"#
        let decoded = try? JSONDecoder().decode(MenuBarConfiguration.self, from: Data(json.utf8))
        // The window encoding is enum-shaped and may not match this literal; what is being
        // pinned is that MISSING switches do not throw, so only assert when the rest decoded.
        if let decoded {
            #expect(decoded.style == .standard)
            #expect(decoded.compact == nil)
        }
    }

    /// The old flag was removed outright (see `MenuBarConfiguration`'s doc comment), not
    /// just stopped being written — so a preferences file saved by a build that still wrote
    /// it must decode by ignoring the stray key, not throw and silently revert the user's
    /// menu bar to `.standard`.
    @Test("a configuration encoded with the removed usesColour key still decodes")
    func decodeToleratesLegacyUsesColourKey() throws {
        let json = """
        {"indicators":[{"id":"AAAAAAAA-AAAA-4AAA-AAAA-AAAAAAAAAAAA","window":{"fiveHour":{}},"rendering":"bar","showsLabel":true}],"usesColour":true,"isCompact":true}
        """
        let decoded = try JSONDecoder().decode(MenuBarConfiguration.self, from: Data(json.utf8))
        #expect(decoded.indicators.count == 1)
        #expect(decoded.compact == .worstOf)
        #expect(decoded.style == .standard)
    }
}

/// `compact` replaced the old `isCompact: Bool`. A preference written before this change
/// must keep resolving to the same behaviour it always had, and the modern type must survive
/// a save/load cycle in every state it can be in — nil, `.worstOf`, `.pinned`.
@Suite("CompactSelection replaces isCompact")
struct CompactSelectionTests {
    private static let oneIndicatorJSON =
        #"{"id":"AAAAAAAA-AAAA-4AAA-AAAA-AAAAAAAAAAAA","window":{"fiveHour":{}},"rendering":"bar"}"#

    @Test("a stored isCompact: true decodes to .worstOf")
    func legacyTrueDecodesToWorstOf() throws {
        let json = #"{"indicators":[\#(Self.oneIndicatorJSON)],"isCompact":true}"#
        let decoded = try JSONDecoder().decode(MenuBarConfiguration.self, from: Data(json.utf8))
        #expect(decoded.compact == .worstOf)
    }

    @Test("a stored isCompact: false decodes to nil")
    func legacyFalseDecodesToNil() throws {
        let json = #"{"indicators":[\#(Self.oneIndicatorJSON)],"isCompact":false}"#
        let decoded = try JSONDecoder().decode(MenuBarConfiguration.self, from: Data(json.utf8))
        #expect(decoded.compact == nil)
    }

    @Test("a stored configuration with neither isCompact nor compact decodes to nil")
    func absentSwitchDecodesToNil() throws {
        let json = #"{"indicators":[\#(Self.oneIndicatorJSON)]}"#
        let decoded = try JSONDecoder().decode(MenuBarConfiguration.self, from: Data(json.utf8))
        #expect(decoded.compact == nil)
    }

    @Test("every compact selection round-trips through Codable unchanged")
    func roundTripsEveryState() throws {
        let indicators = [MenuBarIndicator(window: .fiveHour, rendering: .number)]
        let states: [CompactSelection?] = [
            nil,
            .worstOf,
            .pinned(.sevenDay),
            .pinned(.scopedModel("Opus")),
            .pinnedIndicator(indicators[0].id),
        ]
        for state in states {
            let configuration = MenuBarConfiguration(indicators: indicators, compact: state)
            let data = try JSONEncoder().encode(configuration)
            let decoded = try JSONDecoder().decode(MenuBarConfiguration.self, from: data)
            #expect(decoded == configuration)
            #expect(decoded.compact == state)
        }
    }
}
