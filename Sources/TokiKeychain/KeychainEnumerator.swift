/// Prompt-free enumeration of generic-password items by service prefix.
import Foundation
import Security

/// Lists Keychain items without ever reading their data, so it cannot prompt.
/// Shared by the credential ladder (Claude Code's item) and the account store
/// (Toki' own slot items).
///
/// **This is a best-effort listing, not an authoritative one.** A broad
/// `kSecMatchLimitAll` enumeration is unreliable while a `security` subprocess mutates
/// the Keychain: measured on macOS 26, it missed a just-written item in 30 of 60 rounds
/// under concurrent `security add`/`delete`, sometimes returning nothing at all, while an
/// exact service+account query missed 0 of 60. Toki spawns `security` itself, so callers
/// that need a complete list must key it off something they control (see
/// `KeychainSlotStore`, which keeps an index and fetches slots by exact query) and use
/// this only for discovery.
public enum KeychainEnumerator {
    /// Returns a snapshot that two consecutive reads agreed on, which removes the
    /// transient truncations without pretending the underlying call is atomic.
    public static func items(servicePrefix: String) -> [KeychainItemRef] {
        var previous: [KeychainItemRef]?
        for _ in 0..<3 {
            let snapshot = snapshot(servicePrefix: servicePrefix)
            if let previous, previous == snapshot { return snapshot }
            previous = snapshot
            Thread.sleep(forTimeInterval: 0.015)
        }
        return previous ?? []
    }

    private static func snapshot(servicePrefix: String) -> [KeychainItemRef] {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecMatchLimit: kSecMatchLimitAll,
            kSecReturnAttributes: true,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let raw = result as? [[CFString: Any]]
        else { return [] }

        return raw.compactMap { item in
            guard let service = item[kSecAttrService] as? String,
                  service.hasPrefix(servicePrefix)
            else { return nil }
            return KeychainItemRef(
                service: service,
                account: item[kSecAttrAccount] as? String ?? "",
                modifiedAt: (item[kSecAttrModificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            )
        }
    }
}
