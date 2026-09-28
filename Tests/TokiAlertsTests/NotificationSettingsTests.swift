import Foundation
import Testing
@testable import TokiAlerts
import TokiModels

@Suite("NotificationSettings")
struct NotificationSettingsTests {

    @Test("the standard settings ship three rules per provider at 90 percent")
    func standardRules() {
        let standard = NotificationSettings.standard
        #expect(standard.rules.count == 6)
        #expect(standard.rules.allSatisfy { $0.threshold == 0.9 })
        #expect(standard.rules.allSatisfy { $0.isEnabled })
        #expect(standard.rules.map(\.provider) == [
            .claudeCode, .claudeCode, .claudeCode, .codex, .codex, .codex,
        ])
        #expect(standard.rules.map(\.window) == [
            .fiveHour, .sevenDay, .highestScopedModel,
            .fiveHour, .sevenDay, .highestScopedModel,
        ])
    }

    @Test("every event toggle starts on, matching what the app did before")
    func standardToggles() {
        let standard = NotificationSettings.standard
        #expect(standard.onSwap)
        #expect(standard.onAllExhausted)
        #expect(standard.onNeedsReauth)
        #expect(standard.onNewAccount)
        #expect(standard.onServiceStatus)
        #expect(standard.onCodexServiceStatus)
    }

    /// The migration this field had to survive: a payload written by 1.2.0, before
    /// `onServiceStatus` existed. Every value the user had stored must come back untouched,
    /// and the new toggle must arrive on. If `onServiceStatus` were decoded strictly, this
    /// payload would throw, `NotificationSettingsStore.load()` would swallow it, and the
    /// user's three customised rules would be silently replaced by the defaults.
    @Test("a v1.2.0 payload with no onServiceStatus key keeps every stored value and gains the toggle on")
    func decodesPreServiceStatusPayload() throws {
        let stored = """
        {
          "rules": [
            {
              "id": "CCCCCCCC-CCCC-4CCC-CCCC-CCCCCCCCCCCC",
              "window": {"sevenDay": {}},
              "threshold": 0.75,
              "isEnabled": true
            }
          ],
          "onSwap": false,
          "onAllExhausted": true,
          "onNeedsReauth": false,
          "onNewAccount": true
        }
        """

        let decoded = try JSONDecoder().decode(NotificationSettings.self, from: Data(stored.utf8))

        #expect(decoded.rules.count == 1)
        #expect(decoded.rules.first?.window == .sevenDay)
        #expect(decoded.rules.first?.threshold == 0.75)
        #expect(decoded.onSwap == false)
        #expect(decoded.onAllExhausted)
        #expect(decoded.onNeedsReauth == false)
        #expect(decoded.onNewAccount)
        #expect(decoded.onServiceStatus, "a field the stored payload predates must default to on")
        #expect(decoded.onCodexServiceStatus, "Codex status must be additive for stored settings")
    }

    /// The guardrail, and the reason it is worth a test of its own.
    ///
    /// `NotificationSettingsStore.load()` returns `.standard` on ANY decode error, so a future
    /// field added with a strict `container.decode` would not crash and would not log — it
    /// would quietly wipe every existing user's rules and toggles on first launch. Decoding
    /// `{}` exercises exactly that: it succeeds only while every single field still has a
    /// decode default. Adding a strict field breaks this test, in CI, instead of in the wild.
    @Test("decoding an empty object yields exactly the standard settings, so every field has a decode default")
    func everyFieldHasADecodeDefault() throws {
        let decoded = try JSONDecoder().decode(NotificationSettings.self, from: Data("{}".utf8))
        #expect(decoded == .standard)
    }

    @Test("an empty store returns the standard settings, not empty ones")
    func emptyStore() {
        let defaults = UserDefaults(suiteName: "toki.tests.alerts.empty.\(UUID().uuidString)")!
        #expect(NotificationSettingsStore(defaults: defaults).load() == .standard)
    }

    @Test("settings survive a round trip")
    func roundTrip() {
        let defaults = UserDefaults(suiteName: "toki.tests.alerts.roundtrip.\(UUID().uuidString)")!
        let store = NotificationSettingsStore(defaults: defaults)
        var settings = NotificationSettings.standard
        settings.onSwap = false
        settings.rules = [AlertRule(window: .sevenDay, threshold: 0.5, isEnabled: false)]
        store.save(settings)
        #expect(store.load() == settings)
    }

    @Test("corrupt bytes fall back to standard rather than losing every notification")
    func corruptBytes() {
        let defaults = UserDefaults(suiteName: "toki.tests.alerts.corrupt.\(UUID().uuidString)")!
        defaults.set(Data("not json".utf8), forKey: "toki.notificationSettings")
        #expect(NotificationSettingsStore(defaults: defaults).load() == .standard)
    }
}
