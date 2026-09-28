import Foundation
import TokiCore
import TokiAccounts
import TokiFixtures

@main struct SignedInAccountFixtureProbe {
    @MainActor static func main() async throws {
        let config = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let account = SignedInAccount(configURL: config)
        let fixture = AccountIdentity(
            accountUuid: "fixture", email: "ada@example.com", displayName: "Ada",
            organizationName: nil, organizationUuid: nil
        )
        account.identity = fixture
        account.runMode = .fixture(.publicReadme)
        await account.refresh()
        precondition(account.identity == fixture, "fixture identity was replaced by a real read")

        account.runMode = .live
        await account.refresh()
        precondition(account.identity == nil, "live mode did not read the real config")
    }
}
