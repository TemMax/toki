import Foundation
import Testing
@testable import TokiAlerts

@Suite("Reset notification settings")
struct ResetSettingsTests {
    @Test("adding reset alerts preserves existing preferences and starts the new switches enabled")
    func migration() throws {
        let old = Data(#"{"rules":[],"onSwap":false,"onCodexServiceStatus":false}"#.utf8)
        let settings = try JSONDecoder().decode(NotificationSettings.self, from: old)
        let data = try JSONEncoder().encode(settings)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["onBankedResets"] as? Bool == true)
        #expect(json["onOpenAIResets"] as? Bool == true)
        #expect(json["onClaudeResets"] as? Bool == true)
        #expect(settings.rules.isEmpty)
        #expect(!settings.onSwap)
        #expect(!settings.onCodexServiceStatus)
    }
}
