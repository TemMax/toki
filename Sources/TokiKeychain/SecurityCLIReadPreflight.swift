import Foundation
import Security
import TokiLogging

private let log = TokiLog.logger("keychain")

/// Checks today's ACL, not a historical successful read. Only metadata is read here.
/// The returned path pins the CLI to the keychain whose item was inspected.
///
/// This is a preflight, not an atomic no-UI primitive: macOS offers no noninteractive
/// flag for /usr/bin/security. An external ACL change or lock between this check and
/// the read can still require interaction. The reader's circuit breaker stops retries.
enum SecurityCLIReadPreflight {
    struct ACL {
        let authorizations: [String]
        let promptFlags: UInt32
        let trustsSecurity: Bool
        let description: String?
    }

    static func authorizedKeychain(for source: KeychainItemRef) -> String? {
        KeychainInteractionGuard.performNoninteractive {
            inspect(source)
        } ?? nil
    }

    private static func inspect(_ source: KeychainItemRef) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: source.service, kSecAttrAccount: source.account,
            kSecReturnAttributes: true, kSecReturnRef: true, kSecMatchLimit: kSecMatchLimitAll
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[CFString: Any]], items.count == 1,
              let item = items.first,
              KeychainItemRef.from(attributes: [item]) == [source],
              let rawRef = item[kSecValueRef], CFGetTypeID(rawRef as CFTypeRef) == SecKeychainItemGetTypeID()
        else { return nil }
        let itemRef = rawRef as! SecKeychainItem
        var keychain: SecKeychain?
        var status: SecKeychainStatus = 0
        guard SecKeychainItemCopyKeychain(itemRef, &keychain) == errSecSuccess, let keychain,
              SecKeychainGetStatus(keychain, &status) == errSecSuccess,
              status & UInt32(kSecUnlockStateStatus) != 0 else { return nil }

        var access: SecAccess?
        var rawACLs: CFArray?
        guard SecKeychainItemCopyAccess(itemRef, &access) == errSecSuccess, let access,
              SecAccessCopyACLList(access, &rawACLs) == errSecSuccess,
              let acls = rawACLs as? [SecACL] else { return nil }
        var entries: [ACL] = []
        for acl in acls {
            guard let authorizations = SecACLCopyAuthorizations(acl) as? [String] else { return nil }
            var apps: CFArray?
            var description: CFString?
            var flags = SecKeychainPromptSelector(rawValue: 0)
            guard SecACLCopyContents(acl, &apps, &description, &flags) == errSecSuccess else { return nil }
            // A nil application list allows every application. Require an explicit
            // security entry instead; unknown ACL forms do not enable background reads.
            let trusted = (apps as? [SecTrustedApplication] ?? []).contains { app in
                guard let validateApplication else { return false }
                return "/usr/bin/security".withCString { validateApplication(app, $0) == errSecSuccess }
            }
            entries.append(ACL(authorizations: authorizations, promptFlags: UInt32(flags.rawValue),
                               trustsSecurity: trusted, description: description as String?))
        }
        guard permitsBackgroundRead(entries) else { return nil }
        var path = [CChar](repeating: 0, count: Int(PATH_MAX))
        var length = UInt32(path.count)
        guard SecKeychainGetPath(keychain, &length, &path) == errSecSuccess else { return nil }
        let keychainPath = String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        guard keychainPath.hasPrefix("/") else { return nil }
        log.debug("SecurityCLIReadPreflight: current item permits security read")
        return keychainPath
    }

    static func permitsBackgroundRead(_ acls: [ACL]) -> Bool {
        let decrypt = acls.contains {
            $0.authorizations.contains("ACLAuthorizationDecrypt") && $0.promptFlags == 0 && $0.trustsSecurity
        }
        let partitions = acls.filter { $0.authorizations.contains("ACLAuthorizationPartitionID") }
        guard decrypt, partitions.count == 1, let partition = partitions.first,
              partition.promptFlags == 0, let description = partition.description,
              let identifiers = partitionIdentifiers(description) else { return false }
        return identifiers.contains("apple-tool:")
    }

    /// Partition ACL descriptions contain a hex-encoded plist, not human-readable text.
    static func partitionIdentifiers(_ hex: String) -> [String]? {
        let characters = Array(hex.utf8)
        guard !characters.isEmpty, characters.count <= 65_536, characters.count.isMultiple(of: 2) else { return nil }
        var bytes = Data()
        for index in stride(from: 0, to: characters.count, by: 2) {
            guard let byte = UInt8(String(decoding: characters[index...index + 1], as: UTF8.self), radix: 16)
            else { return nil }
            bytes.append(byte)
        }
        do {
            let plist = try PropertyListSerialization.propertyList(from: bytes, format: nil)
            return (plist as? [String: Any])?["Partitions"] as? [String]
        } catch {
            log.debug("SecurityCLIReadPreflight: unrecognized partition metadata")
            return nil
        }
    }

    // The legacy validation symbol is not exposed by recent SDK headers. Resolve it
    // optionally and fail closed if unavailable; comparing a stored path alone would
    // miss an obsolete code requirement after a system update.
    private typealias ValidateApplication = @convention(c) (CFTypeRef, UnsafePointer<CChar>?) -> OSStatus
    private static let validateApplication: ValidateApplication? = {
        guard let framework = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
              let symbol = dlsym(framework, "SecTrustedApplicationValidateWithPath") else { return nil }
        return unsafeBitCast(symbol, to: ValidateApplication.self)
    }()
}
