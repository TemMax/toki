/// The JSON payload Toki stores in its OWN Keychain item.
import Foundation
import TokiModels

/// A harvested access token plus the identity of the Claude Code item it came from.
///
/// The refresh token is deliberately absent: Toki never refreshes (rotation would
/// desync the Claude Code CLI), so copying the longest-lived secret buys nothing.
struct VaultPayload: Codable, Equatable, Sendable {
    let accessToken: String
    let expiresAt: Date?
    /// Which Claude Code item this token was harvested from, and its `mdat` at capture.
    let source: KeychainItemRef
    let capturedAt: Date

    /// Seconds of head-room before the token's own expiry within which it is considered
    /// already dead, so a request is never sent with a token about to lapse.
    static let expiryGuard: TimeInterval = 90

    func isLive(now: Date, guardInterval: TimeInterval = VaultPayload.expiryGuard) -> Bool {
        guard let expiresAt else { return true }
        return now < expiresAt.addingTimeInterval(-guardInterval)
    }

    var credential: OAuthCredential {
        OAuthCredential(
            accessToken: accessToken, refreshToken: nil, expiresAt: expiresAt, source: .vault
        )
    }

    static func encode(_ payload: VaultPayload) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return try encoder.encode(payload)
    }

    static func decode(_ data: Data) throws -> VaultPayload {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(VaultPayload.self, from: data)
    }
}
