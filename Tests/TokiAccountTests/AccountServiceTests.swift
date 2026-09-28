import Foundation
import Testing
@testable import TokiAccount

@Suite("AccountService & ActiveAccount")
struct AccountServiceTests {

    // MARK: - Fixture helper

    /// Writes `json` to a unique temp file and returns its URL. The file is left
    /// on disk for the duration of the test process (temp dir is cleaned by the OS).
    private func fixture(_ json: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("toki-account-\(UUID().uuidString).json")
        try json.data(using: .utf8)!.write(to: url)
        return url
    }

    // MARK: - label composition

    @Test("label joins all present parts with a middle dot, in name/email/org order")
    func labelJoinsAllParts() {
        let account = ActiveAccount(displayName: "Alex", email: "alex@example.com", organizationName: "Example Org")
        #expect(account.label == "Alex · alex@example.com · Example Org")
    }

    @Test("label drops the organization when it is absent")
    func labelDropsMissingOrganization() {
        let account = ActiveAccount(displayName: "Alex", email: "alex@example.com", organizationName: nil)
        #expect(account.label == "Alex · alex@example.com")
    }

    @Test("label keeps only the email when it is the sole identity")
    func labelEmailOnly() {
        let account = ActiveAccount(displayName: nil, email: "alex@example.com", organizationName: nil)
        #expect(account.label == "alex@example.com")
    }

    @Test("label is nil when no part is present")
    func labelNilWhenEmpty() {
        let account = ActiveAccount(displayName: nil, email: nil, organizationName: nil)
        #expect(account.label == nil)
    }

    // MARK: - reading ~/.claude.json

    @Test("reads name, email, and organization from oauthAccount")
    func readsFullIdentity() throws {
        let url = try fixture("""
        {
          "oauthAccount": {
            "accountUuid": "dddddddd-dddd-4ddd-dddd-dddddddddddd",
            "emailAddress": "alex@example.com",
            "displayName": "Alex",
            "organizationName": "Example Org",
            "accessToken": "secret-should-not-be-read"
          },
          "someOtherKey": 123
        }
        """)

        let account = AccountService.read(claudeJSON: url)
        #expect(account?.displayName == "Alex")
        #expect(account?.email == "alex@example.com")
        #expect(account?.organizationName == "Example Org")
        #expect(account?.label == "Alex · alex@example.com · Example Org")
    }

    @Test("omits the organization when the personal account has none")
    func readsPersonalAccount() throws {
        let url = try fixture("""
        { "oauthAccount": { "emailAddress": "solo@example.com", "displayName": "Solo" } }
        """)

        let account = AccountService.read(claudeJSON: url)
        #expect(account?.organizationName == nil)
        #expect(account?.label == "Solo · solo@example.com")
    }

    @Test("blank identity strings are treated as absent")
    func trimsBlankStrings() throws {
        let url = try fixture("""
        { "oauthAccount": { "emailAddress": "  ", "displayName": "  Alex  ", "organizationName": "" } }
        """)

        let account = AccountService.read(claudeJSON: url)
        #expect(account?.email == nil)
        #expect(account?.organizationName == nil)
        #expect(account?.displayName == "Alex")
        #expect(account?.label == "Alex")
    }

    @Test("returns nil when oauthAccount is missing")
    func nilWhenNoOAuthAccount() throws {
        let url = try fixture(#"{ "numStartups": 5, "projects": {} }"#)
        #expect(AccountService.read(claudeJSON: url) == nil)
    }

    @Test("returns nil when oauthAccount carries no usable identity string")
    func nilWhenNoIdentity() throws {
        let url = try fixture(#"{ "oauthAccount": { "accountUuid": "abc", "organizationRole": "owner" } }"#)
        #expect(AccountService.read(claudeJSON: url) == nil)
    }

    @Test("returns nil for a missing file")
    func nilWhenFileMissing() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("toki-account-does-not-exist-\(UUID().uuidString).json")
        #expect(AccountService.read(claudeJSON: url) == nil)
    }

    @Test("returns nil for malformed JSON")
    func nilWhenMalformed() throws {
        let url = try fixture("{ this is not json ")
        #expect(AccountService.read(claudeJSON: url) == nil)
    }
}
