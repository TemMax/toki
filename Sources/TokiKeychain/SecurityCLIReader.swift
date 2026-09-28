/// Reads Claude Code's Keychain item through `/usr/bin/security`.
import Foundation
import TokiLogging

private let log = TokiLog.logger("keychain")

public enum SubprocessOutcome: Sendable, Equatable {
    case success(Data, duration: TimeInterval)
    case failure(exitCode: Int32)
    case timedOut
}

/// Spawns a process and returns its stdout. Abstracted so tests never spawn anything.
public protocol SubprocessRunning: Sendable {
    func run(arguments: [String], timeout: TimeInterval) async -> SubprocessOutcome
}

/// The `security find-generic-password -w` path.
///
/// This reads Claude Code's item without the macOS authorization dialog because the item's
/// ACL often trusts `/usr/bin/security`. Background reads require a current ACL and
/// unlock-state preflight; user-initiated reads can request authorization.
struct SecurityCLIReader: Sendable {
    static let timeout: TimeInterval = 10

    private let runner: any SubprocessRunning
    private let gate: SubprocessGate
    private let backgroundKeychain: @Sendable (KeychainItemRef) -> String?

    init(
        runner: any SubprocessRunning = ProcessRunner(), gate: SubprocessGate,
        backgroundKeychain: @escaping @Sendable (KeychainItemRef) -> String? = { SecurityCLIReadPreflight.authorizedKeychain(for: $0) }
    ) {
        self.runner = runner
        self.gate = gate
        self.backgroundKeychain = backgroundKeychain
    }

    /// Returns the raw credential JSON, or nil when the gate bars the read or the read
    /// fails. Background failures suspend automatic CLI reads until a fast explicit read.
    func read(_ ref: KeychainItemRef, context: LadderContext) async -> Data? {
        let keychain = context == .background ? backgroundKeychain(ref) : nil
        guard gate.allows(context, currentACLPermitsRead: keychain != nil) else {
            log.info("SecurityCLIReader: gate blocked security invocation")
            return nil
        }

        // Service and account come from the attributes enumeration — never from a computed
        // username, which can differ from the item's account.
        var arguments = ["find-generic-password", "-s", ref.service, "-a", ref.account, "-w"]
        if let keychain { arguments.append(keychain) }
        log.info("SecurityCLIReader: invoking security find-generic-password")
        switch await runner.run(arguments: arguments, timeout: Self.timeout) {
        case let .success(data, duration):
            log.info("SecurityCLIReader: security invocation exited 0 in \(duration)s")
            gate.recordSuccess(duration: duration, context: context)
            guard let credential = CredentialJSON.fromSecurityOutput(data) else {
                log.error("SecurityCLIReader: output is not a credential JSON object")
                return nil
            }
            return credential
        case .timedOut:
            log.error("SecurityCLIReader: security invocation timed out")
            gate.recordTimeout()
            return nil
        case let .failure(exitCode):
            if context == .background { gate.suspendBackground() }
            log.error("SecurityCLIReader: security invocation failed exitCode=\(Int(exitCode))")
            return nil
        }
    }
}

/// Real `Process`-based runner: argument array (never a shell string), stdout through a
/// `Pipe` (never a temp file), hard timeout followed by `SIGKILL`.
public struct ProcessRunner: SubprocessRunning {
    public init() {}

    public func run(arguments: [String], timeout: TimeInterval) async -> SubprocessOutcome {
        await withCheckedContinuation { continuation in
            Task.detached {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
                process.arguments = arguments
                process.environment = ["HOME": NSHomeDirectory()]
                let stdout = Pipe()
                process.standardOutput = stdout
                process.standardError = Pipe()

                let started = Date()
                do {
                    try process.run()
                } catch {
                    log.error("ProcessRunner: security process failed to launch \(error: error)")
                    continuation.resume(returning: .failure(exitCode: -1))
                    return
                }

                // Watchdog: killing the client is expected to dismiss any dialog the read
                // might have raised. That behavior is undocumented, which is why a
                // background read requires an ACL preflight and stops retrying on failure.
                let watchdog = Task.detached {
                    try await Task.sleep(for: .seconds(timeout))
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }

                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                watchdog.cancel()
                let duration = Date().timeIntervalSince(started)

                if process.terminationReason == .uncaughtSignal {
                    continuation.resume(returning: .timedOut)
                } else if process.terminationStatus == 0 {
                    continuation.resume(returning: .success(data, duration: duration))
                } else {
                    continuation.resume(returning: .failure(exitCode: process.terminationStatus))
                }
            }
        }
    }
}
