import Foundation
import Testing
import TokiModels
@testable import TokiKeychain

/// Mutated only between completed resolutions; no live Keychain or process is used.
private final class RotatingClaudeItem: SubprocessRunning, @unchecked Sendable {
    var generation = 1
    var permitsCLI = true
    var ref: KeychainItemRef {
        KeychainItemRef(service: "Claude Code-credentials", account: "user", modifiedAt: Double(generation))
    }
    func run(arguments: [String], timeout: TimeInterval) async -> SubprocessOutcome {
        .success(Data("{\"claudeAiOauth\":{\"accessToken\":\"token-\(generation)\",\"expiresAt\":4102444800000}}".utf8), duration: 0.05)
    }
}

@Suite("Background Claude credential recovery")
struct BackgroundCredentialRecoveryTests {
    @Test("source rotation replaces a live cached token automatically; revoked access never returns the old token")
    func rotationThenRevocation() async throws {
        let item = RotatingClaudeItem()
        let cli = SecurityCLIReader(runner: item,
            gate: SubprocessGate(defaults: makeTestDefaults(#function)),
            backgroundKeychain: { source in item.permitsCLI && source == item.ref ? "/test/login" : nil })
        let ladder = SilentLadder(enumerate: { [item.ref] }, silentRead: { _ in nil },
                                  cliRead: { source, context in await cli.read(source, context: context) })
        let store = CredentialStore(
            envProvider: { nil }, fileProvider: { nil }, vault: TokenVault(store: FakeVaultStore()),
            ladderRunner: { context, force in await ladder.run(context: context, force: force) },
            ladderSource: { await ladder.currentSource() },
            interactiveRead: { Issue.record("Automatic recovery must not request native access"); return nil }
        )
        #expect(try await store.currentCredential(userInitiated: true).accessToken == "token-1")
        item.generation = 2
        #expect(try await store.currentCredential().accessToken == "token-2")
        #expect(try await store.currentCredential().accessToken == "token-2")
        item.generation = 3
        item.permitsCLI = false
        await #expect(throws: TokiError.keychainDenied) { _ = try await store.currentCredential() }
    }
}
