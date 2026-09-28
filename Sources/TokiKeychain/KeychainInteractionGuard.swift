import Foundation
import Security
import TokiLogging

private let interactionLog = TokiLog.logger("keychain")

/// Serializes Toki's Security.framework reads while temporarily controlling the legacy
/// process-wide interaction flag. The flag is restored before releasing the lock.
public enum KeychainInteractionGuard {
    private static let lock = NSLock()

    public static func performNoninteractive<T>(operation: () -> T) -> T? {
        performNoninteractive(
            getAllowed: {
                var allowed = DarwinBoolean(false)
                guard SecKeychainGetUserInteractionAllowed(&allowed) == errSecSuccess else {
                    return nil
                }
                return allowed.boolValue
            },
            setAllowed: {
                SecKeychainSetUserInteractionAllowed($0) == errSecSuccess
            },
            operation: operation
        )
    }

    static func performNoninteractive<T>(
        getAllowed: () -> Bool?,
        setAllowed: (Bool) -> Bool,
        operation: () -> T
    ) -> T? {
        lock.lock()
        defer { lock.unlock() }
        guard let wasAllowed = getAllowed() else {
            interactionLog.error("KeychainInteractionGuard: interaction state unavailable")
            return nil
        }
        guard setAllowed(false) else {
            interactionLog.error("KeychainInteractionGuard: failed to disable interaction")
            return nil
        }
        defer {
            if !setAllowed(wasAllowed) {
                interactionLog.error("KeychainInteractionGuard: failed to restore interaction state")
            }
        }
        return operation()
    }

    static func performSerialized<T>(_ operation: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }
}
