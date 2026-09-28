import Testing
import Foundation
@testable import TokiModels

@Suite("CredentialSource")
struct CredentialSourceTests {

    @Test("OAuthCredential carries its provenance")
    func credentialCarriesSource() {
        let cred = OAuthCredential(
            accessToken: "tok", refreshToken: nil, expiresAt: nil, source: .vault
        )
        #expect(cred.source == .vault)
    }

    @Test("OAuthCredential defaults to the Claude Code keychain source")
    func credentialDefaultsToKeychain() {
        let cred = OAuthCredential(accessToken: "tok", refreshToken: nil, expiresAt: nil)
        #expect(cred.source == .claudeKeychain)
    }

    @Test("Only vault-backed sources may be dead-marked on a 401")
    func deadMarkEligibility() {
        #expect(CredentialSource.vault.isVaultBacked)
        #expect(CredentialSource.claudeKeychain.isVaultBacked)
        #expect(!CredentialSource.environment.isVaultBacked)
        #expect(!CredentialSource.file.isVaultBacked)
    }
}
