import Testing
import Foundation
import TokiModels
@testable import TokiKeychain

// MARK: - Helpers

/// Builds a minimal credential JSON blob from the given parameters.
private func makeCredentialJSON(
    accessToken: String = "tok_abc",
    refreshToken: String? = "refresh_xyz",
    expiresAtMs: Double? = 1_700_000_000_000,
    scopes: [String]? = ["read"]
) throws -> Data {
    var inner: [String: Any] = ["accessToken": accessToken]
    if let rt = refreshToken { inner["refreshToken"] = rt }
    if let ms = expiresAtMs { inner["expiresAt"] = ms }
    if let sc = scopes { inner["scopes"] = sc }
    let root: [String: Any] = ["claudeAiOauth": inner]
    return try JSONSerialization.data(withJSONObject: root)
}

// MARK: - Test suite

@Suite("TokiKeychain")
struct TokiKeychainTests {

    // MARK: JSON parsing — happy path

    @Test("parseCredentialJSON: valid JSON produces correct OAuthCredential")
    func parseValidJSON() throws {
        let ms: Double = 1_700_000_000_000
        let data = try makeCredentialJSON(
            accessToken: "at_hello",
            refreshToken: "rt_world",
            expiresAtMs: ms
        )
        let cred = try CredentialStore.parseCredentialJSON(data)
        #expect(cred.accessToken == "at_hello")
        #expect(cred.refreshToken == "rt_world")
        // expiresAt should be ms / 1000 seconds since epoch
        let expected = Date(timeIntervalSince1970: ms / 1000.0)
        #expect(cred.expiresAt == expected)
    }

    @Test("parseCredentialJSON: milliseconds converted to Date correctly")
    func parseMsConversion() throws {
        // 1 000 000 ms → 1000 seconds since epoch
        let data = try makeCredentialJSON(
            accessToken: "tok",
            refreshToken: nil,
            expiresAtMs: 1_000_000
        )
        let cred = try CredentialStore.parseCredentialJSON(data)
        #expect(cred.expiresAt == Date(timeIntervalSince1970: 1000.0))
        #expect(cred.refreshToken == nil)
    }

    @Test("parseCredentialJSON: nil expiresAt is preserved")
    func parseNilExpiry() throws {
        let data = try makeCredentialJSON(expiresAtMs: nil)
        let cred = try CredentialStore.parseCredentialJSON(data)
        #expect(cred.expiresAt == nil)
    }

    // MARK: JSON parsing — error cases

    @Test("parseCredentialJSON: missing claudeAiOauth key throws credentialsNotFound")
    func parseMissingKey() throws {
        let json: [String: Any] = ["someOtherKey": "value"]
        let data = try JSONSerialization.data(withJSONObject: json)
        #expect(throws: TokiError.credentialsNotFound) {
            _ = try CredentialStore.parseCredentialJSON(data)
        }
    }

    @Test("parseCredentialJSON: null claudeAiOauth throws credentialsNotFound")
    func parseNullOAuth() throws {
        // JSONSerialization can't encode NSNull easily; use raw JSON bytes.
        let raw = #"{"claudeAiOauth": null}"#
        let data = Data(raw.utf8)
        #expect(throws: TokiError.credentialsNotFound) {
            _ = try CredentialStore.parseCredentialJSON(data)
        }
    }

    @Test("parseCredentialJSON: malformed JSON throws decoding error")
    func parseMalformedJSON() throws {
        let data = Data("not json at all {{".utf8)
        #expect(throws: TokiError.self) {
            _ = try CredentialStore.parseCredentialJSON(data)
        }
    }

    // MARK: Provenance tagging

    @Test("parseCredentialJSON: tags the credential with the requested source")
    func parseTagsSource() throws {
        let data = try makeCredentialJSON(accessToken: "tok")
        let fromFile = try CredentialStore.parseCredentialJSON(data, source: .file)
        #expect(fromFile.source == .file)
        #expect(try CredentialStore.parseCredentialJSON(data).source == .claudeKeychain)
    }
}

