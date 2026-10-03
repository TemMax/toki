import Foundation
import Testing
@testable import TokiAnalytics

/// A private defaults domain per test, removed afterwards. Never `.standard`: these tests must
/// not read or change the settings of the machine they run on.
private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
    let suite = "dev.komar.toki.tests.speed-visibility.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    try body(defaults)
}

@Suite("SpeedTableVisibilityStore")
struct SpeedTableVisibilityTests {
    @Test("Nothing saved loads as an empty set")
    func emptyDefault() {
        withDefaults { defaults in
            #expect(SpeedTableVisibilityStore(defaults: defaults).load() == [])
            #expect(defaults.object(forKey: "speed.hiddenModels") == nil, "loading must not write")
        }
    }

    @Test("A saved set is loaded back by another store on the same defaults")
    func roundTrip() {
        withDefaults { defaults in
            let hidden: Set<String> = ["claude-opus-5-5", "gpt-6-sol"]
            SpeedTableVisibilityStore(defaults: defaults).save(hidden)
            #expect(SpeedTableVisibilityStore(defaults: defaults).load() == hidden)
        }
    }

    @Test("The set is stored under speed.hiddenModels as a sorted string array")
    func storedSorted() {
        withDefaults { defaults in
            SpeedTableVisibilityStore(defaults: defaults).save(["b-model", "a-model", "c-model"])
            #expect(SpeedTableVisibilityStore.key == "speed.hiddenModels")
            #expect(defaults.array(forKey: "speed.hiddenModels") as? [String] == ["a-model", "b-model", "c-model"])
        }
    }

    @Test("Saving replaces the previous set, and an empty set loads as empty")
    func replaces() {
        withDefaults { defaults in
            let store = SpeedTableVisibilityStore(defaults: defaults)
            store.save(["a-model", "b-model"])
            store.save(["b-model"])
            #expect(store.load() == ["b-model"])
            store.save([])
            #expect(store.load() == [])
        }
    }

    @Test("Ids no report has are kept as saved")
    func unknownIdsKept() {
        withDefaults { defaults in
            // Written by an earlier launch, for a model this machine no longer has transcripts of.
            defaults.set(["model-from-an-old-launch", "", "claude-opus-5-5[1m]"], forKey: "speed.hiddenModels")
            let store = SpeedTableVisibilityStore(defaults: defaults)
            #expect(store.load() == ["model-from-an-old-launch", "", "claude-opus-5-5[1m]"])
            store.save(store.load().union(["gpt-6-sol"]))
            #expect(store.load() == ["model-from-an-old-launch", "", "claude-opus-5-5[1m]", "gpt-6-sol"])
        }
    }

    @Test("A value of another type under the key loads as empty instead of trapping")
    func wrongType() {
        withDefaults { defaults in
            defaults.set(42, forKey: "speed.hiddenModels")
            #expect(SpeedTableVisibilityStore(defaults: defaults).load() == [])
        }
    }
}
