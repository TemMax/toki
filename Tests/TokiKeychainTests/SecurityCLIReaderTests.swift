import Testing
import Foundation
@testable import TokiKeychain

private let ref = KeychainItemRef(service: "Claude Code-credentials", account: "u", modifiedAt: 1)

private final class FakeRunner: SubprocessRunning, @unchecked Sendable {
    var outcome: SubprocessOutcome
    private(set) var invocations: [[String]] = []
    init(outcome: SubprocessOutcome) { self.outcome = outcome }
    func run(arguments: [String], timeout: TimeInterval) async -> SubprocessOutcome {
        invocations.append(arguments)
        return outcome
    }
}

@Suite("SecurityCLIReader")
struct SecurityCLIReaderTests {

    @Test("malformed hex and non-object JSON cannot become credentials",
          arguments: ["7bBAD\n", "7bzz7d\n", "5b5d\n", "null\n", "\n"])
    func rejectsInvalidOutput(output: String) async {
        let runner = FakeRunner(outcome: .success(Data(output.utf8), duration: 0.01))
        let reader = SecurityCLIReader(runner: runner,
            gate: SubprocessGate(defaults: makeTestDefaults(#function)),
            backgroundKeychain: { _ in "/test/login" })
        #expect(await reader.read(ref, context: .background) == nil)
    }

    @Test("security output framing never becomes part of the stored credential",
          arguments: ["{\"probe\":\"dummy\"}\n", "7b2270726f6265223a2264756d6d79227d0a\n"])
    func decodesTransport(output: String) async {
        let runner = FakeRunner(outcome: .success(Data(output.utf8), duration: 0.05))
        let reader = SecurityCLIReader(runner: runner,
            gate: SubprocessGate(defaults: makeTestDefaults(#function)),
            backgroundKeychain: { _ in "/test/login" })
        let result = await reader.read(ref, context: .background)
        let data = try? JSONSerialization.jsonObject(with: result ?? Data()) as? [String: String]
        #expect(data == ["probe": "dummy"])
        if output.hasPrefix("{") {
            #expect(result == Data(#"{"probe":"dummy"}"#.utf8))
        }
    }

    @Test("a rotated Claude token recovers in background through the currently authorized keychain")
    func backgroundRecovery() async {
        let raw = Data(#"{"claudeAiOauth":{"accessToken":"rotated","expiresAt":4102444800000}}"#.utf8)
        let runner = FakeRunner(outcome: .success(raw, duration: 0.05))
        let reader = SecurityCLIReader(
            runner: runner, gate: SubprocessGate(defaults: makeTestDefaults(#function)),
            backgroundKeychain: { source in source == ref ? "/test/login.keychain-db" : nil }
        )
        let ladder = SilentLadder(enumerate: { [ref] }, silentRead: { _ in nil },
                                  cliRead: { source, context in await reader.read(source, context: context) })
        #expect(await ladder.run(context: .background, force: false) == .harvested(
            token: "rotated", expiresAt: Date(timeIntervalSince1970: 4102444800), from: ref
        ))
        #expect(runner.invocations.first?.last == "/test/login.keychain-db")
    }

    @Test("revoking the current ACL prevents another background subprocess despite a previous success")
    func revokedACL() async {
        let runner = FakeRunner(outcome: .success(Data("{}".utf8), duration: 0.1))
        let gate = SubprocessGate(defaults: makeTestDefaults(#function))
        let permitted = SecurityCLIReader(runner: runner, gate: gate, backgroundKeychain: { _ in "/test/login" })
        #expect(await permitted.read(ref, context: .background) != nil)
        let revoked = SecurityCLIReader(runner: runner, gate: gate, backgroundKeychain: { _ in nil })
        #expect(await revoked.read(ref, context: .background) == nil)
        #expect(runner.invocations.count == 1)
    }

    // A preflighted background read cannot have shown a dialog, so a slow success is just a
    // busy machine. Suspending on it once froze the gauges for thirteen hours.
    @Test("a slow background success after the ACL preflight keeps background reads running")
    func slowBackgroundSuccessDoesNotSuspend() async {
        let defaults = makeTestDefaults(#function)
        let runner = FakeRunner(outcome: .success(Data("{}".utf8), duration: 3.1))
        let reader = SecurityCLIReader(runner: runner, gate: SubprocessGate(defaults: defaults),
                                       backgroundKeychain: { _ in "/test/login" })
        #expect(await reader.read(ref, context: .background) != nil)
        runner.outcome = .success(Data("{}".utf8), duration: 0.05)
        let restarted = SecurityCLIReader(runner: runner, gate: SubprocessGate(defaults: defaults),
                                          backgroundKeychain: { _ in "/test/login" })
        #expect(await restarted.read(ref, context: .background) != nil)
        #expect(runner.invocations.count == 2)
    }

    @Test("a slow user-initiated success still suspends background reads — it may have been a dialog")
    func slowUserInitiatedSuccessSuspends() async {
        let defaults = makeTestDefaults(#function)
        let runner = FakeRunner(outcome: .success(Data("{}".utf8), duration: 5))
        let reader = SecurityCLIReader(runner: runner, gate: SubprocessGate(defaults: defaults),
                                       backgroundKeychain: { _ in "/test/login" })
        #expect(await reader.read(ref, context: .userInitiated) != nil)
        #expect(await reader.read(ref, context: .background) == nil)
        #expect(runner.invocations.count == 1)
    }

    @Test("background failures suspend retries across restart until explicit recovery",
          arguments: [SubprocessOutcome.timedOut, .failure(exitCode: 36)])
    func backgroundCircuitBreaker(outcome: SubprocessOutcome) async {
        let defaults = makeTestDefaults("circuit-\(String(describing: outcome))")
        let runner = FakeRunner(outcome: outcome)
        let reader = SecurityCLIReader(runner: runner, gate: SubprocessGate(defaults: defaults),
                                       backgroundKeychain: { _ in "/test/login" })
        _ = await reader.read(ref, context: .background)
        runner.outcome = .success(Data("{}".utf8), duration: 0.1)
        let restarted = SecurityCLIReader(runner: runner, gate: SubprocessGate(defaults: defaults),
                                          backgroundKeychain: { _ in "/test/login" })
        #expect(await restarted.read(ref, context: .background) == nil)
        #expect(runner.invocations.count == 1)
        #expect(await restarted.read(ref, context: .userInitiated) != nil)
        #expect(await restarted.read(ref, context: .background) != nil)
        #expect(runner.invocations.count == 3)
    }

    @Test("an authorized ACL cannot override a locked keychain")
    func authorizedButLocked() async {
        let runner = FakeRunner(outcome: .success(Data("{}".utf8), duration: 0.1))
        let reader = SecurityCLIReader(runner: runner,
            gate: SubprocessGate(defaults: makeTestDefaults(#function), keychainUnlocked: { false }),
            backgroundKeychain: { _ in "/test/login" })
        #expect(await reader.read(ref, context: .background) == nil)
        #expect(runner.invocations.isEmpty)
    }

    @Test("passes the discovered service AND account, never a computed username")
    func passesDiscoveredIdentity() async {
        let runner = FakeRunner(outcome: .success(Data("{}".utf8), duration: 0.1))
        let gate = SubprocessGate(defaults: makeTestDefaults(#function), keychainUnlocked: { true })
        let reader = SecurityCLIReader(runner: runner, gate: gate, backgroundKeychain: { _ in nil })

        _ = await reader.read(ref, context: .userInitiated)

        let args = runner.invocations.first ?? []
        #expect(args.contains("find-generic-password"))
        #expect(args.contains("Claude Code-credentials"))
        #expect(args.contains("u"))
        #expect(args.contains("-w"))
    }

    @Test("never spawns from background, even after a successful user read")
    func backgroundIsGated() async {
        let runner = FakeRunner(outcome: .success(Data("{}".utf8), duration: 0.1))
        let gate = SubprocessGate(defaults: makeTestDefaults(#function), keychainUnlocked: { true })
        let reader = SecurityCLIReader(runner: runner, gate: gate, backgroundKeychain: { _ in nil })

        #expect(await reader.read(ref, context: .background) == nil)
        #expect(runner.invocations.isEmpty)

        _ = await reader.read(ref, context: .userInitiated)
        #expect(await reader.read(ref, context: .background) == nil)
        #expect(runner.invocations.count == 1)
    }

    @Test("a timeout yields no data and revokes verification")
    func timeoutRevokes() async {
        let runner = FakeRunner(outcome: .success(Data("{}".utf8), duration: 0.1))
        let gate = SubprocessGate(defaults: makeTestDefaults(#function), keychainUnlocked: { true })
        let reader = SecurityCLIReader(runner: runner, gate: gate, backgroundKeychain: { _ in nil })
        _ = await reader.read(ref, context: .userInitiated)
        #expect(gate.isVerified)

        runner.outcome = .timedOut
        #expect(await reader.read(ref, context: .userInitiated) == nil)
        #expect(!gate.isVerified)
    }

    @Test("a non-zero exit yields no data without revoking verification")
    func failureIsNotRevocation() async {
        let runner = FakeRunner(outcome: .failure(exitCode: 44))
        let gate = SubprocessGate(defaults: makeTestDefaults(#function), keychainUnlocked: { true })
        let reader = SecurityCLIReader(runner: runner, gate: gate, backgroundKeychain: { _ in nil })

        _ = await reader.read(ref, context: .userInitiated)   // records nothing
        gate.recordSuccess(duration: 0.1)

        #expect(await reader.read(ref, context: .background) == nil)
        #expect(gate.isVerified)
    }

    @Test("a locked keychain keeps the subprocess unspawned even in a user context")
    func lockedKeychainNeverSpawns() async {
        let runner = FakeRunner(outcome: .success(Data("{}".utf8), duration: 0.1))
        let gate = SubprocessGate(defaults: makeTestDefaults(#function), keychainUnlocked: { false })
        let reader = SecurityCLIReader(runner: runner, gate: gate, backgroundKeychain: { _ in nil })

        #expect(await reader.read(ref, context: .userInitiated) == nil)
        #expect(runner.invocations.isEmpty)
    }
}
