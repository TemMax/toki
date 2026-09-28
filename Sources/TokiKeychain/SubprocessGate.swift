/// Decides whether the `/usr/bin/security` reader may run, and in which context.
import Foundation
import TokiLogging

private let log = TokiLog.logger("keychain")

/// Background reads require existing access; only user-initiated reads may deliberately
/// request a new Keychain grant.
enum LadderContext: Sendable {
    case background
    case userInitiated
}

/// Allowlist gate for the subprocess reader.
///
/// The subprocess reads Claude Code's item silently today because that item's ACL
/// partition is `apple-tool` (Claude Code creates it via `security add-generic-password`).
/// Background reads require a fresh ACL preflight. Prior successful reads are retained
/// only as diagnostics and never become authority for a future background invocation.
final class SubprocessGate: @unchecked Sendable {
    /// A silent read returns in milliseconds; anything slower suggests a dialog was shown.
    static let verificationThreshold: TimeInterval = 2

    /// Debug and Release share one UserDefaults domain (same bundle id). A Debug
    /// run that times out must not strip the release build's background trust —
    /// each build config earns and keeps its own flag.
    #if DEBUG
    static let defaultsKey = "toki.subprocessVerifiedSilent.debug"
    #else
    static let defaultsKey = "toki.subprocessVerifiedSilent"
    #endif

    private static var suspensionKey: String { defaultsKey + ".backgroundSuspended" }

    private let defaults: UserDefaults
    private let keychainUnlocked: @Sendable () -> Bool

    /// - Parameter keychainUnlocked: reports whether Keychain data can be read without
    ///   user interaction right now. `CredentialStore` wires this to the vault item probe
    ///   (`KeychainVaultStore.isReadableWithoutInteraction()`); the permissive default
    ///   suits tests and any caller with no item to probe.
    init(
        defaults: UserDefaults = .standard,
        keychainUnlocked: @escaping @Sendable () -> Bool = { true }
    ) {
        self.defaults = defaults
        self.keychainUnlocked = keychainUnlocked
    }

    var isVerified: Bool { defaults.bool(forKey: Self.defaultsKey) }

    func allows(_ context: LadderContext, currentACLPermitsRead: Bool = false) -> Bool {
        // A locked keychain is precisely the condition that would raise a dialog (or
        // hang), and it must surface as `.locked`, not burn the verification flag.
        guard keychainUnlocked() else { return false }
        switch context {
        case .userInitiated: return true
        case .background: return currentACLPermitsRead && !defaults.bool(forKey: Self.suspensionKey)
        }
    }

    func recordSuccess(duration: TimeInterval, context: LadderContext = .userInitiated) {
        guard duration < Self.verificationThreshold else {
            // Slowness only signals a dialog where one could appear. A background read runs
            // only after the ACL preflight proved it silent, so a slow one is a busy machine —
            // suspending on it once left the gauges frozen until the user re-granted access.
            if context == .userInitiated { suspendBackground() }
            return
        }
        if context == .userInitiated { defaults.set(false, forKey: Self.suspensionKey) }
        defaults.set(true, forKey: Self.defaultsKey)
    }

    /// A timeout means the read may have been blocked on a dialog: stop trusting it in
    /// the background until another user-initiated run proves it silent again.
    func recordTimeout() {
        defaults.set(false, forKey: Self.defaultsKey)
        suspendBackground()
    }

    func suspendBackground() {
        log.notice("SubprocessGate: background security reads suspended until an explicit read succeeds")
        defaults.set(true, forKey: Self.suspensionKey)
    }

}
