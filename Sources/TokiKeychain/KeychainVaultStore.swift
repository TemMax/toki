/// Login-keychain persistence for the vault payload.
import Foundation
import Security
import LocalAuthentication
import TokiModels
import TokiLogging

private let log = TokiLog.logger("keychain")

/// Reads and writes Toki' OWN generic-password item.
///
/// Because Toki creates the item, it normally remains directly accessible to Toki. Writes
/// use `SecItemUpdate` when the item exists so its access control is preserved.
struct KeychainVaultStore: VaultStoring {
    let service: String
    let account: String

    /// Debug builds use a separate item: a differently signed Debug binary must not
    /// contend for the release item's ACL.
    static var defaultService: String {
        #if DEBUG
        return KeychainNamespace.prefix + "credentials.debug"
        #else
        return KeychainNamespace.prefix + "credentials"
        #endif
    }

    init(service: String = KeychainVaultStore.defaultService, account: String = NSUserName()) {
        self.service = service
        self.account = account
    }

    private var baseQuery: [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
    }

    /// Barred from raising a consent dialog: this store sits on background poll
    /// loops, and its item's ACL names Toki, so a dialog can only mean a foreign
    /// ACL or a locked keychain — cases where failing is correct and prompting
    /// from nowhere is not.
    private var noInteraction: LAContext {
        let context = LAContext()
        context.interactionNotAllowed = true
        return context
    }

    func load() throws -> VaultPayload? {
        var query = baseQuery
        query[kSecMatchLimit] = kSecMatchLimitOne
        query[kSecReturnData] = true
        query[kSecUseAuthenticationContext] = noInteraction

        guard let outcome = KeychainInteractionGuard.performNoninteractive(operation: {
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            return (status, result as? Data)
        }) else { throw TokiError.keychainDenied }
        let (status, data) = outcome
        switch status {
        case errSecSuccess:
            guard let data else {
                log.debug("KeychainVaultStore: vault read succeeded with no data")
                return nil
            }
            do {
                let payload = try VaultPayload.decode(data)
                log.debug("KeychainVaultStore: vault read succeeded")
                return payload
            } catch {
                // corrupt payload → re-harvest
                log.error("KeychainVaultStore: vault payload undecodable \(error: error)")
                return nil
            }
        case errSecItemNotFound:
            log.info("KeychainVaultStore: vault read found no item")
            return nil
        default:
            log.error("KeychainVaultStore: vault read failed status=\(Int(status))")
            throw TokiError.keychainDenied
        }
    }

    func save(_ payload: VaultPayload) throws {
        let data = try VaultPayload.encode(payload)
        var updateQuery = baseQuery
        updateQuery[kSecUseAuthenticationContext] = noInteraction
        guard let updateStatus = KeychainInteractionGuard.performNoninteractive(operation: {
            SecItemUpdate(updateQuery as CFDictionary, [kSecValueData: data] as CFDictionary)
        }) else { throw TokiError.keychainDenied }
        if updateStatus == errSecSuccess {
            log.debug("KeychainVaultStore: vault write succeeded (update)")
            return
        }
        guard updateStatus == errSecItemNotFound else {
            log.error("KeychainVaultStore: vault update failed status=\(Int(updateStatus))")
            throw TokiError.keychainDenied
        }

        var addQuery = baseQuery
        addQuery[kSecValueData] = data
        addQuery[kSecAttrSynchronizable] = false
        addQuery[kSecAttrLabel] = "Toki — cached Claude Code token"
        addQuery[kSecUseAuthenticationContext] = noInteraction
        guard let addStatus = KeychainInteractionGuard.performNoninteractive(operation: {
            SecItemAdd(addQuery as CFDictionary, nil)
        }) else { throw TokiError.keychainDenied }
        guard addStatus == errSecSuccess else {
            log.error("KeychainVaultStore: vault add failed status=\(Int(addStatus))")
            throw TokiError.keychainDenied
        }
        log.debug("KeychainVaultStore: vault write succeeded (create)")
    }

    /// Whether Keychain data can currently be read without user interaction, probed
    /// against Toki' own item: `true` when the read succeeds, `false` when it would need
    /// interaction (a locked keychain), and nil when there is no item to probe yet.
    ///
    /// A locked keychain is the one condition under which the `security` subprocess could
    /// raise an unlock dialog or hang, so the ladder consults this before spawning it.
    func isReadableWithoutInteraction() -> Bool? {
        let context = LAContext()
        context.interactionNotAllowed = true
        var query = baseQuery
        query[kSecMatchLimit] = kSecMatchLimitOne
        query[kSecReturnData] = true
        query[kSecUseAuthenticationContext] = context

        guard let status = KeychainInteractionGuard.performNoninteractive(operation: {
            var result: CFTypeRef?
            return SecItemCopyMatching(query as CFDictionary, &result)
        }) else { return false }
        switch status {
        case errSecSuccess:
            return true
        case errSecInteractionNotAllowed, errSecAuthFailed:
            log.info("KeychainVaultStore: readable-without-interaction probe blocked status=\(Int(status))")
            return false
        default:
            // no item yet (or an unrelated failure): nothing to conclude
            return nil
        }
    }

    func clear() throws {
        var query = baseQuery
        query[kSecUseAuthenticationContext] = noInteraction
        guard let status = KeychainInteractionGuard.performNoninteractive(operation: {
            SecItemDelete(query as CFDictionary)
        }) else { throw TokiError.keychainDenied }
        guard status == errSecSuccess || status == errSecItemNotFound else {
            log.error("KeychainVaultStore: vault clear failed status=\(Int(status))")
            throw TokiError.keychainDenied
        }
        log.info("KeychainVaultStore: vault cleared status=\(Int(status))")
    }
}
