import Foundation
import Testing
@testable import TokiKeychain

private let item = KeychainItemRef(service: "dummy-credential", account: "dummy", modifiedAt: 1)
private final class VerificationRunner: SubprocessRunning, @unchecked Sendable {
    var output = Data("{\"token\":\"before\"}\n".utf8)
    var calls = 0
    func run(arguments: [String], timeout: TimeInterval) async -> SubprocessOutcome {
        calls += 1
        return .success(output, duration: 0.01)
    }
}

@Suite("Fresh credential verification")
struct CredentialVerificationReaderTests {
    @Test("post-write ACL preflight uses new metadata for the same item")
    func postWriteMetadata() async {
        let runner = VerificationRunner()
        let changed = KeychainItemRef(service: item.service, account: item.account, modifiedAt: 2)
        let reader = CredentialVerificationReader(silentRead: { _ in nil }, cliReader: SecurityCLIReader(
            runner: runner, gate: SubprocessGate(defaults: makeTestDefaults(#function)),
            backgroundKeychain: { source in source == changed ? "/dummy/keychain" : nil }
        ), refreshRef: { _ in changed })
        #expect(await reader.read(item) == Data(#"{"token":"before"}"#.utf8))
    }

    @Test("metadata refresh never verifies a different account's item")
    func changedItemIsRejected() async {
        let runner = VerificationRunner()
        let reader = CredentialVerificationReader(silentRead: { _ in nil }, cliReader: SecurityCLIReader(
            runner: runner, gate: SubprocessGate(defaults: makeTestDefaults(#function)),
            backgroundKeychain: { _ in "/dummy/keychain" }
        ), refreshRef: { _ in KeychainItemRef(service: item.service, account: "other", modifiedAt: 2) })
        #expect(await reader.read(item) == nil)
        #expect(runner.calls == 0)
    }

    @Test("direct-read denial uses authorized CLI and never a memoized value")
    func authorizedFallbackIsFresh() async {
        let runner = VerificationRunner()
        let reader = CredentialVerificationReader(silentRead: { _ in nil }, cliReader: SecurityCLIReader(
            runner: runner, gate: SubprocessGate(defaults: makeTestDefaults(#function)),
            backgroundKeychain: { _ in "/dummy/keychain" }
        ))
        #expect(await reader.read(item) == Data(#"{"token":"before"}"#.utf8))
        runner.output = Data("{\"token\":\"after\"}\n".utf8)
        #expect(await reader.read(item) == Data(#"{"token":"after"}"#.utf8))
    }

    @Test("verification cannot open an authorization dialog when CLI access is absent")
    func deniedFallbackDoesNotRun() async {
        let runner = VerificationRunner()
        let reader = CredentialVerificationReader(silentRead: { _ in nil }, cliReader: SecurityCLIReader(
            runner: runner, gate: SubprocessGate(defaults: makeTestDefaults(#function)),
            backgroundKeychain: { _ in nil }
        ))
        #expect(await reader.read(item) == nil)
        #expect(runner.calls == 0)
    }
}
