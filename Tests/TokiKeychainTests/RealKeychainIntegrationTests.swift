import Testing
import Foundation
@testable import TokiKeychain

/// Integration checks against the REAL Claude Code Keychain item.
///
/// The whole feature rests on two empirical claims about this machine's Keychain, neither
/// of which is guaranteed by Apple: the attributes enumeration never prompts, and reading
/// the secret through `/usr/bin/security` is silent because Claude Code creates its item
/// via that same tool (so the item's ACL partition is `apple-tool`). These tests assert
/// both. They run only with `TOKI_RUN_REAL_KEYCHAIN_TESTS=1` and skip when no Claude Code
/// item exists, so ordinary unit-test runs never touch a user's credential item.
private var realKeychainTestsEnabled: Bool {
    ProcessInfo.processInfo.environment["TOKI_RUN_REAL_KEYCHAIN_TESTS"] == "1"
        && !CredentialStore.enumerateClaudeItems().isEmpty
}

@Suite("Real keychain integration", .serialized, .enabled(if: realKeychainTestsEnabled))
struct RealKeychainIntegrationTests {

    @Test("enumerating Claude Code items returns a usable identity without prompting")
    func enumerationIsSilentAndComplete() throws {
        let items = CredentialStore.enumerateClaudeItems()
        let selected = try #require(KeychainItemRef.select(from: items))
        #expect(selected.service.hasPrefix(KeychainItemRef.claudeServicePrefix))
        #expect(!selected.account.isEmpty)
        // The modification date is the change detector; without it the ladder would
        // re-harvest on every poll.
        #expect(selected.modifiedAt > 0)
    }

    @Test("the security subprocess reads the credential silently and fast")
    func subprocessReadIsSilent() async throws {
        let ref = try #require(KeychainItemRef.select(from: CredentialStore.enumerateClaudeItems()))

        let outcome = await ProcessRunner().run(
            arguments: ["find-generic-password", "-s", ref.service, "-a", ref.account, "-w"],
            timeout: SecurityCLIReader.timeout
        )

        guard case let .success(data, duration) = outcome else {
            Issue.record("expected a successful silent read, got \(outcome)")
            return
        }
        // A dialog would have made this take seconds of human time; the gate uses the same
        // threshold to decide whether the path may be trusted from a background poll.
        #expect(duration < SubprocessGate.verificationThreshold)
        #expect(!data.isEmpty)

        // The payload must be the credential JSON — either readable, or the known
        // mcpOAuth-only layout, which the ladder reports separately.
        let parsed = try? CredentialStore.parseCredentialJSON(data)
        if let parsed {
            #expect(!parsed.accessToken.isEmpty)
        } else {
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            #expect(root?["claudeAiOauth"] == nil, "parse failed on a payload that has claudeAiOauth")
        }
    }

}
