import Testing
import Foundation
@testable import TokiSwap

private func tempConfig(_ contents: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("toki-config-\(UUID().uuidString).json")
    try contents.write(to: url, atomically: true, encoding: .utf8)
    return url
}

private let sample = """
{
  "firstKey": 1,
  "oauthAccount": {"accountUuid": "old-uuid", "emailAddress": "old@x.y"},
  "projects": {"/Users/me/repo": {"allowedTools": ["Bash"]}},
  "lastKey": "keep me"
}
"""

@Suite("ClaudeConfigEditor")
struct ClaudeConfigEditorTests {

    @Test("reads the oauthAccount block")
    func readsOAuthAccount() throws {
        let url = try tempConfig(sample)
        defer { try? FileManager.default.removeItem(at: url) }
        let block = try #require(try ClaudeConfigEditor(configURL: url).readOAuthAccount())
        #expect(block["accountUuid"] as? String == "old-uuid")
    }

    @Test("replaces only the oauthAccount block, leaving every other byte alone")
    func replacesOnlyOAuthAccount() throws {
        let url = try tempConfig(sample)
        defer { try? FileManager.default.removeItem(at: url) }

        try ClaudeConfigEditor(configURL: url).replaceOAuthAccount(
            with: ["accountUuid": "new-uuid", "emailAddress": "new@x.y"]
        )

        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("new-uuid"))
        #expect(!text.contains("old-uuid"))
        // Everything else must survive verbatim — key order included. A reordered
        // 118 KB config would show up as a spurious diff in the user's own file.
        #expect(text.contains(#""projects": {"/Users/me/repo": {"allowedTools": ["Bash"]}}"#))
        #expect(text.contains(#""lastKey": "keep me""#))
        #expect(text.firstIndex(of: "f")! < text.range(of: "oauthAccount")!.lowerBound)

        let root = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        #expect((root?["oauthAccount"] as? [String: Any])?["accountUuid"] as? String == "new-uuid")
        #expect(root?["lastKey"] as? String == "keep me")
    }

    @Test("nested braces and strings containing braces do not confuse the splice")
    func handlesNestedBracesAndStrings() throws {
        let tricky = """
        {"oauthAccount": {"displayName": "a}b{c", "nested": {"deep": {"x": 1}}}, "after": 2}
        """
        let url = try tempConfig(tricky)
        defer { try? FileManager.default.removeItem(at: url) }

        try ClaudeConfigEditor(configURL: url).replaceOAuthAccount(with: ["accountUuid": "z"])

        let root = try JSONSerialization.jsonObject(
            with: try Data(contentsOf: url)
        ) as? [String: Any]
        #expect((root?["oauthAccount"] as? [String: Any])?["accountUuid"] as? String == "z")
        #expect(root?["after"] as? Int == 2)
    }

    @Test("a config without oauthAccount is reported, not silently patched")
    func missingBlockIsAnError() throws {
        let url = try tempConfig(#"{"other": 1}"#)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: ConfigEditError.noOAuthAccount) {
            try ClaudeConfigEditor(configURL: url).replaceOAuthAccount(with: ["accountUuid": "z"])
        }
    }

    @Test("the original file survives a failed write")
    func writeIsAtomic() throws {
        let url = try tempConfig(sample)
        defer { try? FileManager.default.removeItem(at: url) }
        let before = try String(contentsOf: url, encoding: .utf8)

        #expect(throws: ConfigEditError.self) {
            try ClaudeConfigEditor(configURL: url).replaceOAuthAccount(
                with: ["bad": Date()]   // not JSON-serialisable
            )
        }
        #expect(try String(contentsOf: url, encoding: .utf8) == before)
    }

    @Test("a nested oauthAccount inside user data never anchors the splice")
    func nestedDecoyIsLeftAlone() throws {
        let decoy = #""env": {"oauthAccount": {"accountUuid": "decoy", "note": "user data"}}"#
        let withDecoy = """
        {
          "mcpServers": {"gh": {\(decoy)}},
          "oauthAccount": {"accountUuid": "old-uuid", "emailAddress": "old@x.y"},
          "lastKey": "keep me"
        }
        """
        let url = try tempConfig(withDecoy)
        defer { try? FileManager.default.removeItem(at: url) }

        try ClaudeConfigEditor(configURL: url).replaceOAuthAccount(with: ["accountUuid": "new-uuid"])

        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains(decoy))
        let root = try #require(
            try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        )
        #expect((root["oauthAccount"] as? [String: Any])?["accountUuid"] as? String == "new-uuid")
        #expect(!text.contains("old-uuid"))
    }

    @Test("a string value equal to the key does not anchor the splice")
    func stringValueMatchingTheKeyIsNotAnAnchor() throws {
        let url = try tempConfig(
            #"{"note": "oauthAccount", "oauthAccount": {"accountUuid": "old-uuid"}}"#
        )
        defer { try? FileManager.default.removeItem(at: url) }

        try ClaudeConfigEditor(configURL: url).replaceOAuthAccount(with: ["accountUuid": "new-uuid"])

        let root = try #require(
            try JSONSerialization.jsonObject(with: try Data(contentsOf: url)) as? [String: Any]
        )
        #expect((root["oauthAccount"] as? [String: Any])?["accountUuid"] as? String == "new-uuid")
        #expect(root["note"] as? String == "oauthAccount")
    }

    @Test(
        "a non-object oauthAccount is its own error, not a missing block",
        arguments: [#"{"oauthAccount": null}"#, #"{"oauthAccount": []}"#, #"{"oauthAccount": "x"}"#]
    )
    func nonObjectValueIsItsOwnError(contents: String) throws {
        let url = try tempConfig(contents)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: ConfigEditError.oauthAccountNotAnObject) {
            try ClaudeConfigEditor(configURL: url).replaceOAuthAccount(with: ["accountUuid": "z"])
        }
    }

    @Test("a failed rename leaves no copy of the config behind")
    func failedRenameLeavesNoStagingCopy() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("toki-config-dir-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(".claude.json")
        try sample.write(to: url, atomically: true, encoding: .utf8)
        // An immutable destination is the cheapest way to make `replaceItemAt` fail
        // after the staging copy has already been written.
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: url.path)
        defer {
            try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: url.path)
            try? FileManager.default.removeItem(at: directory)
        }

        #expect(throws: (any Error).self) {
            try ClaudeConfigEditor(configURL: url).replaceOAuthAccount(
                with: ["accountUuid": "new-uuid"]
            )
        }

        let leftovers = try FileManager.default
            .contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix(".claude.json.toki-") }
        #expect(leftovers.isEmpty)
    }

    @Test("the staging copy is created private to the user")
    func stagingCopyIsPrivate() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("toki-staging-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }

        try ClaudeConfigEditor.writeStagingCopy(Data(sample.utf8), to: url)

        let mode = try #require(
            FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        )
        #expect(mode.intValue == 0o600)
    }
}
