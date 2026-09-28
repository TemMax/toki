import Testing
import Foundation
import TokiModels
@testable import TokiKeychain

private let ref = KeychainItemRef(
    service: "Claude Code-credentials", account: "u", modifiedAt: 1_700_000_000
)
private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

@Suite("VaultPayload")
struct VaultPayloadTests {

    @Test("round-trips through JSON without losing the source identity")
    func roundTrip() throws {
        let payload = VaultPayload(
            accessToken: "tok", expiresAt: t0.addingTimeInterval(3600), source: ref, capturedAt: t0
        )
        let decoded = try VaultPayload.decode(try VaultPayload.encode(payload))
        #expect(decoded == payload)
        #expect(decoded.source.modifiedAt == 1_700_000_000)
    }

    @Test("never persists the refresh token")
    func refreshTokenIsNotPersisted() throws {
        let payload = VaultPayload(accessToken: "tok", expiresAt: nil, source: ref, capturedAt: t0)
        let json = String(data: try VaultPayload.encode(payload), encoding: .utf8) ?? ""
        #expect(!json.lowercased().contains("refresh"))
    }

    @Test("is live well before expiry and dead inside the 90 s guard")
    func livenessGuard() {
        let payload = VaultPayload(
            accessToken: "tok", expiresAt: t0.addingTimeInterval(3600), source: ref, capturedAt: t0
        )
        #expect(payload.isLive(now: t0))
        #expect(payload.isLive(now: t0.addingTimeInterval(3600 - 91)))
        #expect(!payload.isLive(now: t0.addingTimeInterval(3600 - 89)))
        #expect(!payload.isLive(now: t0.addingTimeInterval(7200)))
    }

    @Test("a payload without a known expiry is treated as live")
    func nilExpiryIsLive() {
        let payload = VaultPayload(accessToken: "tok", expiresAt: nil, source: ref, capturedAt: t0)
        #expect(payload.isLive(now: t0.addingTimeInterval(86_400)))
    }

    @Test("exposes a credential tagged with the vault source")
    func credentialIsTaggedVault() {
        let payload = VaultPayload(accessToken: "tok", expiresAt: nil, source: ref, capturedAt: t0)
        #expect(payload.credential.source == .vault)
        #expect(payload.credential.accessToken == "tok")
        #expect(payload.credential.refreshToken == nil)
    }
}
