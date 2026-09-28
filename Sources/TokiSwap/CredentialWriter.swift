/// Writes Claude Code's credential item — the one mutation that can hurt the CLI.
import Foundation
import TokiKeychain
import TokiLogging

private let log = TokiLog.logger("swap")

public enum CredentialWriteError: Error, Equatable {
    case commandFailed(Int32)
    case timedOut
    case verificationUnavailable
    case invalidCredential
    case verificationMismatch
}

/// Issues byte-for-byte the command Claude Code 2.1.223 issues for its own writes:
///
///     security add-generic-password -U -a <account> -s <service> -X <hex>
///
/// Using any other writer (notably `SecItemUpdate`) would make Toki the item's owner,
/// change its ACL partition, and start prompting the user *inside Claude Code* — curing
/// Toki' own prompt problem by transplanting it into the CLI. The secret travels in
/// argv as hex, exactly as it already does whenever Claude Code refreshes its token.
public struct CredentialWriter: Sendable {
    public static let timeout: TimeInterval = 10

    private let runner: any SubprocessRunning
    private let readBack: @Sendable (KeychainItemRef) async -> Data?

    public init(
        runner: any SubprocessRunning = ProcessRunner(),
        readBack: @escaping @Sendable (KeychainItemRef) async -> Data?
    ) {
        self.runner = runner
        self.readBack = readBack
    }

    public func write(_ credentialJSON: Data, to ref: KeychainItemRef) async throws {
        let canonical: Data
        do {
            canonical = try CredentialJSON.canonical(credentialJSON)
        } catch {
            log.error("credential write refused: input is not a JSON object")
            throw CredentialWriteError.invalidCredential
        }
        let hex = canonical.map { String(format: "%02X", $0) }.joined()
        let arguments = [
            "add-generic-password", "-U", "-a", ref.account, "-s", ref.service, "-X", hex,
        ]

        log.info("writing Claude Code's credential item")
        switch await runner.run(arguments: arguments, timeout: Self.timeout) {
        case .success:
            break
        case let .failure(code):
            log.error("the credential write command failed exit=\(Int(code))")
            throw CredentialWriteError.commandFailed(code)
        case .timedOut:
            log.error("the credential write command timed out after \(Self.timeout)s; the bytes may still have landed")
            throw CredentialWriteError.timedOut
        }

        // Verify rather than trust: a silent partial write would leave Claude Code
        // holding a corrupt credential, which is worse than a failed swap.
        guard let written = await readBack(ref) else {
            log.error("credential verification unavailable: fresh read could not be authorized or completed")
            throw CredentialWriteError.verificationUnavailable
        }
        guard let verified = try? CredentialJSON.canonical(written), verified == canonical else {
            log.error("credential verification mismatch: fresh read differs from the intended JSON")
            throw CredentialWriteError.verificationMismatch
        }
        log.info("credential item written and verified")
    }
}
