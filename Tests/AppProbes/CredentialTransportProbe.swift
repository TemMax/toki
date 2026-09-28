import Foundation
@testable import TokiKeychain
import TokiAccounts
import TokiLogging
import TokiSwap

private struct ProbeLog: LogSink {
    func write(_ line: String) { FileHandle.standardError.write(Data((line + "\n").utf8)) }
    func flush() {}
}

private enum ProbeError: Error { case failed(String) }
private func require(_ value: Bool, _ message: String) throws {
    if !value { throw ProbeError.failed(message) }
}

// Every mutation is pinned to an ephemeral test keychain; never the login keychain.
private struct PinnedRunner: SubprocessRunning {
    let path: String
    func run(arguments: [String], timeout: TimeInterval) async -> SubprocessOutcome {
        await ProcessRunner().run(arguments: arguments + [path], timeout: timeout)
    }
}

// Synchronous storage is protected because SwapService's dependencies are Sendable.
private final class ProbeSlots: SlotStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var slots: [String: AccountSlot] = [:]
    func loadAll() throws -> [AccountSlot] { lock.withLock { Array(slots.values) } }
    func load(accountUuid: String) throws -> AccountSlot? { lock.withLock { slots[accountUuid] } }
    func save(_ slot: AccountSlot) throws { lock.withLock { slots[slot.identity.accountUuid] = slot } }
    func delete(accountUuid: String) throws { lock.withLock { slots[accountUuid] = nil } }
    func loadQuarantine() throws -> [QuarantineEntry] { [] }
    func saveQuarantine(_ entry: QuarantineEntry, now: Date) throws {
        throw ProbeError.failed("known outgoing account must not be quarantined")
    }
    func deleteQuarantine(id: String) throws {}
}

private struct ProbeLive: LiveCredentialAccess {
    let verifier: CredentialVerificationReader
    let ref: KeychainItemRef
    func readLive() async -> (json: Data, ref: KeychainItemRef)? {
        guard let json = await verifier.read(ref) else { return nil }
        return (json, ref)
    }
}

private struct UnusedOracle: ProfileLookup {
    func owner(ofToken token: String) async throws -> AccountIdentity {
        throw ProbeError.failed("known lineage must not need network lookup")
    }
}

private actor FailFirstVerification {
    private(set) var reads = 0
    func read(_ ref: KeychainItemRef, verifier: CredentialVerificationReader) async -> Data? {
        reads += 1
        let actual = await verifier.read(ref)
        return reads == 1 ? nil : actual
    }
}

@main
struct CredentialTransportProbe {
    static func main() async throws {
        TokiLog.bootstrap(sinks: [ProbeLog()])
        let previousVerbosity = TokiLog.isVerbose
        TokiLog.isVerbose = true
        defer { TokiLog.isVerbose = previousVerbosity }
        let keychain = CommandLine.arguments[1]
        let service = "Claude Code-credentials-toki-probe-" + UUID().uuidString
        let ref = KeychainItemRef(service: service, account: "dummy", modifiedAt: 0)
        let runner = PinnedRunner(path: keychain)
        let initial = Data(#"{"claudeAiOauth":{"accessToken":"dummy-original"}}"#.utf8)
        let result = await runner.run(arguments: ["add-generic-password", "-a", ref.account,
            "-s", service, "-X", initial.map { String(format: "%02x", $0) }.joined()], timeout: 10)
        guard case .success = result else { throw ProbeError.failed("create dummy item") }

        // `security create-keychain` produces a legacy temporary keychain without
        // partition ACL entries. The fixture grants security access when creating the
        // item; inject that known preflight result, retaining the real CLI and direct read.
        // Production preflight denial/metadata pinning are covered by Swift tests.
        let suite = "toki-transport-probe-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let verifier = CredentialVerificationReader(
            silentRead: { CredentialStore.silentRead($0) },
            cliReader: SecurityCLIReader(gate: SubprocessGate(defaults: defaults),
                backgroundKeychain: { source in
                    source.service == service && source.account == "dummy" ? keychain : nil
                }),
            refreshRef: { source in
                CredentialStore.enumerateClaudeItems().first {
                    $0.service == source.service && $0.account == source.account
                }
            }
        )
        // This harness has no access grant: this is the failure mode of the release logs.
        try require(CredentialStore.silentRead(ref) == nil, "probe unexpectedly has direct access")
        let originalRead = await verifier.read(ref)
        try require(originalRead == initial, "authorized fallback must strip CLI framing")
        let writer = CredentialWriter(runner: runner, readBack: { await verifier.read($0) })
        let target = Data("{\n  \"claudeAiOauth\": {\"accessToken\": \"dummy-target\"}\n}\n".utf8)
        try await writer.write(target, to: ref)
        let targetRead = await verifier.read(ref)
        try require(targetRead == Data(#"{"claudeAiOauth":{"accessToken":"dummy-target"}}"#.utf8),
                    "writer must emit compact JSON and verify through fallback")

        // A raw legacy item can contain a newline already. Read the CLI's hex transport,
        // then restore the original item using the same writer used during rollback.
        let legacy = initial + Data([10])
        let legacyWrite = await runner.run(arguments: ["add-generic-password", "-U", "-a", ref.account,
            "-s", service, "-X", legacy.map { String(format: "%02x", $0) }.joined()], timeout: 10)
        guard case .success = legacyWrite else { throw ProbeError.failed("legacy fixture write") }
        let legacyRead = await verifier.read(ref)
        try require(legacyRead == legacy, "CLI hex output must decode without losing item bytes")
        try await writer.write(legacyRead ?? Data(), to: ref)
        let restored = await verifier.read(ref)
        try require(restored == initial, "rollback must restore CLI-readable compact JSON")
        // Exercise the transaction itself: the target write lands, its verification
        // fails once, and SwapService must restore a legacy newline-bearing original.
        let outgoing = Data(#"{"claudeAiOauth":{"accessToken":"dummy-a","refreshToken":"dummy-r-a"}}"#.utf8)
        let incoming = Data(#"{"claudeAiOauth":{"accessToken":"dummy-b","refreshToken":"dummy-r-b"}}"#.utf8)
        let seeded = await runner.run(arguments: ["add-generic-password", "-U", "-a", ref.account,
            "-s", service, "-X", (outgoing + Data([10])).map { String(format: "%02x", $0) }.joined()], timeout: 10)
        guard case .success = seeded else { throw ProbeError.failed("transaction fixture write") }
        let store = ProbeSlots()
        for (uuid, json) in [("a", outgoing), ("b", incoming)] {
            try store.save(AccountSlot(
                identity: AccountIdentity(accountUuid: uuid, email: nil, displayName: nil,
                    organizationName: nil, organizationUuid: nil), alias: nil,
                credentialJSON: json, previousCredentialJSON: nil,
                lineage: Lineage.fingerprint(credentialJSON: json)!, addedAt: Date(),
                lastActiveAt: nil, lastRefreshAt: nil, health: .ok))
        }
        let directory = URL(fileURLWithPath: keychain).deletingLastPathComponent()
        let configURL = directory.appendingPathComponent(".claude.json")
        let configBytes = Data(#"{"oauthAccount":{"accountUuid":"a"}}"#.utf8)
        try configBytes.write(to: configURL)
        let failure = FailFirstVerification()
        let transaction = SwapService(dependencies: SwapDependencies(
            store: store, live: ProbeLive(verifier: verifier, ref: ref),
            writer: CredentialWriter(runner: runner, readBack: { await failure.read($0, verifier: verifier) }),
            config: ClaudeConfigEditor(configURL: configURL), oracle: UnusedOracle(),
            locks: LockBroker(), configDir: directory,
            fallbackFileURL: directory.appendingPathComponent(".credentials.json"),
            credentialItemRef: { ref }, onVaultInvalidated: {}))
        do {
            _ = try await transaction.swap(to: "b")
            throw ProbeError.failed("injected verification failure must abort the transaction")
        } catch SwapError.writeFailed {
            // Expected only after the verified restore succeeds.
        }
        let rolledBack = await verifier.read(ref)
        try require(rolledBack == outgoing, "failed transaction must restore compact outgoing credentials")
        try require(await failure.reads == 2, "target and rollback verification must both run")
        try require(try Data(contentsOf: configURL) == configBytes, "failed transaction must preserve config")
        print("PASS: actual security IO, denied direct reads, authorized verification, legacy hex and failed-transaction rollback")
    }
}
