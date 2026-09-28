import Testing
import Foundation
import TokiKeychain
@testable import TokiSwap

private let ref = KeychainItemRef(service: "Claude Code-credentials", account: "example", modifiedAt: 1)
private let payload = Data(#"{"claudeAiOauth":{"accessToken":"tok"}}"#.utf8)

private final class SpyRunner: SubprocessRunning, @unchecked Sendable {
    var outcome: SubprocessOutcome = .success(Data(), duration: 0.05)
    private(set) var invocations: [[String]] = []
    func run(arguments: [String], timeout: TimeInterval) async -> SubprocessOutcome {
        invocations.append(arguments)
        return outcome
    }
}

@Suite("CredentialWriter")
struct CredentialWriterTests {

    @Test("unreadable verification is distinct from different credential bytes")
    func unavailableReadBack() async {
        let writer = CredentialWriter(runner: SpyRunner(), readBack: { _ in nil })
        await #expect(throws: CredentialWriteError.verificationUnavailable) {
            try await writer.write(payload, to: ref)
        }
    }

    @Test("malformed stored credentials never reach the keychain")
    func malformedInput() async {
        let runner = SpyRunner()
        let writer = CredentialWriter(runner: runner, readBack: { _ in payload })
        await #expect(throws: CredentialWriteError.invalidCredential) {
            try await writer.write(Data("7bBAD".utf8), to: ref)
        }
        #expect(runner.invocations.isEmpty)
    }

    @Test("rollback JSON read from security is compacted before writing")
    func normalizesRollback() async throws {
        let runner = SpyRunner()
        let withNewline = Data("{\n  \"claudeAiOauth\": {\"accessToken\": \"tok\"}\n}\n".utf8)
        let writer = CredentialWriter(runner: runner, readBack: { _ in payload })
        try await writer.write(withNewline, to: ref)
        let args = try #require(runner.invocations.first)
        let hex = try #require(args.last)
        #expect(!hex.contains("0A"))
    }

    @Test("issues exactly the command Claude Code issues, with the secret as hex")
    func issuesClaudeCodesOwnCommand() async throws {
        let runner = SpyRunner()
        let writer = CredentialWriter(runner: runner, readBack: { _ in payload })
        try await writer.write(payload, to: ref)

        let args = try #require(runner.invocations.first)
        #expect(args[0] == "add-generic-password")
        #expect(args.contains("-U"))
        #expect(args[args.firstIndex(of: "-a")! + 1] == "example")
        #expect(args[args.firstIndex(of: "-s")! + 1] == "Claude Code-credentials")
        let hex = args[args.firstIndex(of: "-X")! + 1]
        #expect(hex == payload.map { String(format: "%02X", $0) }.joined())
        // Any other writer would re-own the item's ACL partition and make Claude Code
        // itself start prompting.
        #expect(!args.contains("-w"))
    }

    @Test("a non-zero exit is reported, not swallowed")
    func failureIsReported() async {
        let runner = SpyRunner()
        runner.outcome = .failure(exitCode: 45)
        let writer = CredentialWriter(runner: runner, readBack: { _ in payload })
        await #expect(throws: CredentialWriteError.commandFailed(45)) {
            try await writer.write(payload, to: ref)
        }
    }

    @Test("a timeout is reported distinctly — it may mean a dialog appeared")
    func timeoutIsReported() async {
        let runner = SpyRunner()
        runner.outcome = .timedOut
        let writer = CredentialWriter(runner: runner, readBack: { _ in payload })
        await #expect(throws: CredentialWriteError.timedOut) {
            try await writer.write(payload, to: ref)
        }
    }

    @Test("a write that does not read back is a failure, not a success")
    func verifiesItsOwnWork() async {
        let runner = SpyRunner()
        let writer = CredentialWriter(runner: runner, readBack: { _ in Data("something else".utf8) })
        await #expect(throws: CredentialWriteError.verificationMismatch) {
            try await writer.write(payload, to: ref)
        }
    }
}
