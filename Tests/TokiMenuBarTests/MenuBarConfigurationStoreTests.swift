import Foundation
import Testing
@testable import TokiMenuBar

/// Fresh, isolated defaults per test so a stored configuration can't leak between cases —
/// mirrors `makeTestDefaults` in `Tests/TokiKeychainTests/SubprocessGateTests.swift`.
private func makeTestDefaults(_ name: String) -> UserDefaults {
    let suite = "toki.tests.menuBarConfigurationStore.\(name)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return defaults
}

@Suite("MenuBarConfigurationStore")
struct MenuBarConfigurationStoreTests {
    @Test("load returns .standard when nothing has been saved")
    func loadWithNothingStored() {
        let store = MenuBarConfigurationStore(defaults: makeTestDefaults("nothingStored"))
        #expect(store.load() == .standard)
    }

    @Test("load returns .standard when the stored bytes are garbage, not throwing")
    func loadWithCorruptBytes() {
        let defaults = makeTestDefaults("corruptBytes")
        // Deliberately not valid JSON at all.
        let garbage = Data([0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0xFF, 0x12, 0x34])
        defaults.set(garbage, forKey: "toki.menuBarConfiguration")

        let store = MenuBarConfigurationStore(defaults: defaults)
        #expect(store.load() == .standard)
    }

    @Test("load returns .standard when the JSON is well-formed but the type rejects it")
    func loadWithRejectedPayload() {
        let defaults = makeTestDefaults("rejectedPayload")
        // Valid JSON, right shape — but an `IndicatorRendering` raw value this build's enum
        // doesn't know, so `MenuBarIndicator`'s Decodable throws rather than clamping.
        let json = """
        {"indicators":[{"id":"AAAAAAAA-AAAA-4AAA-AAAA-AAAAAAAAAAAA","window":{"fiveHour":{}},"rendering":"pulsing-hologram"}],"isCompact":false}
        """
        defaults.set(Data(json.utf8), forKey: "toki.menuBarConfiguration")

        let store = MenuBarConfigurationStore(defaults: defaults)
        #expect(store.load() == .standard)
    }

    @Test("load survives a corrupt style field: real indicators, standard style, not the whole .standard fallback")
    func loadWithCorruptStyleFieldKeepsIndicators() {
        let defaults = makeTestDefaults("corruptStyleField")
        let json = """
        {"indicators":[
            {"id":"AAAAAAAA-AAAA-4AAA-AAAA-AAAAAAAAAAAA","window":{"extraUsage":{}},"rendering":"number"}
        ],"style":{"leading":"","trailing":"","separator":"","labelGap":"not-a-number","groupGap":7,
         "valueSize":11,"labelSize":10,"unitScale":0.72,"barWidth":3,"barHeight":11},"isCompact":false}
        """
        defaults.set(Data(json.utf8), forKey: "toki.menuBarConfiguration")

        let store = MenuBarConfigurationStore(defaults: defaults)
        let loaded = store.load()
        #expect(loaded.indicators.map(\.window) == [.extraUsage])
        #expect(loaded.style == .standard)
        // Not the outer .standard fallback wholesale — that would also replace the indicators.
        #expect(loaded != .standard)
    }

    @Test("save then load round-trips a non-standard configuration")
    func saveThenLoadRoundTrips() {
        let store = MenuBarConfigurationStore(defaults: makeTestDefaults("roundTrips"))
        let configuration = MenuBarConfiguration(
            indicators: [MenuBarIndicator(window: .extraUsage, rendering: .number)],
            style: MenuBarStyle(leading: "[", trailing: "]"),
            compact: .worstOf
        )
        store.save(configuration)
        #expect(store.load() == configuration)
    }

    @Test("save persists across separate store instances sharing the same defaults suite")
    func savePersistsAcrossInstances() {
        let defaults = makeTestDefaults("sharedSuite")
        let configuration = MenuBarConfiguration(
            indicators: [MenuBarIndicator(window: .sevenDay, rendering: .barAndNumber)],
            style: MenuBarStyle(separator: "·"),
            compact: nil
        )
        MenuBarConfigurationStore(defaults: defaults).save(configuration)
        #expect(MenuBarConfigurationStore(defaults: defaults).load() == configuration)
    }
}
