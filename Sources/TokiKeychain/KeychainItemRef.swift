/// Identity of a Keychain generic-password item, plus deterministic selection
/// among the Claude Code credential items.
import Foundation
import Security

/// A Keychain item identified by service + account, with its modification date.
///
/// `modifiedAt` (`kSecAttrModificationDate`) is the free, prompt-free change
/// detector: Claude Code rewriting the credential bumps it, so Toki can tell
/// "the token changed" without ever reading the secret.
public struct KeychainItemRef: Sendable, Equatable, Codable {
    public let service: String
    public let account: String
    /// Modification date as seconds since the epoch (0 when the attribute is absent).
    public let modifiedAt: Double

    public init(service: String, account: String, modifiedAt: Double) {
        self.service = service
        self.account = account
        self.modifiedAt = modifiedAt
    }

    /// Service-name prefix Claude Code uses for its credential item.
    static let claudeServicePrefix = "Claude Code-credentials"

    /// The Claude Code credential item this machine is using, chosen deterministically.
    public static func selectClaudeItem() -> KeychainItemRef? {
        select(from: CredentialStore.enumerateClaudeItems())
    }

    /// Picks one item deterministically: the exact service name wins; otherwise the
    /// lexicographically smallest service, then account. Keychain enumeration order is
    /// not guaranteed, and a wobbling choice would fake a token change every poll.
    static func select(from candidates: [KeychainItemRef]) -> KeychainItemRef? {
        if let exact = candidates
            .filter({ $0.service == claudeServicePrefix })
            .min(by: { $0.account < $1.account }) {
            return exact
        }
        return candidates.min {
            $0.service == $1.service ? $0.account < $1.account : $0.service < $1.service
        }
    }

    /// Converts a raw `SecItemCopyMatching` attributes array into refs, keeping only
    /// Claude Code credential items.
    static func from(attributes: [[CFString: Any]]) -> [KeychainItemRef] {
        attributes.compactMap { item in
            guard
                let service = item[kSecAttrService] as? String,
                service.hasPrefix(claudeServicePrefix)
            else { return nil }
            let account = item[kSecAttrAccount] as? String ?? ""
            let modified = (item[kSecAttrModificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            return KeychainItemRef(service: service, account: account, modifiedAt: modified)
        }
    }
}
