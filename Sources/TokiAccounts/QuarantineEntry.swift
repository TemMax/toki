/// A credential Toki found in Claude Code's storage but could not attribute.
import Foundation

/// Preserved rather than overwritten: those bytes may be the only live copy of some
/// account's refresh token. Surfaced in the UI so they can be adopted or deleted,
/// never left as invisible Keychain litter.
public struct QuarantineEntry: Codable, Equatable, Sendable {
    /// Stable id — the credential's lineage fingerprint prefix, so the same stray
    /// credential is never stored twice.
    public let id: String
    public let credentialJSON: Data
    public let foundAt: Date
    /// Owner label from the profile endpoint, when it could be reached.
    public let ownerLabel: String?

    public init(id: String, credentialJSON: Data, foundAt: Date, ownerLabel: String?) {
        self.id = id
        self.credentialJSON = credentialJSON
        self.foundAt = foundAt
        self.ownerLabel = ownerLabel
    }
}
