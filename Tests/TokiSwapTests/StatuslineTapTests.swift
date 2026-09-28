import Testing
import Foundation
@testable import TokiSwap

/// A throwaway home: `.claude/settings.json` plus the app-support paths the tap uses.
private struct Sandbox {
    let home: URL
    var settings: URL { home.appendingPathComponent(".claude/settings.json") }
    var tap: StatuslineTap {
        let support = home.appendingPathComponent("Library/Application Support/Toki")
        return StatuslineTap(
            settingsURL: settings,
            scriptURL: support.appendingPathComponent("statusline-tap.sh"),
            sampleURL: support.appendingPathComponent("statusline/latest.json"),
            backupsURL: support.appendingPathComponent("statusline/backups"),
            homeDirectory: home.path
        )
    }

    init(settings contents: String?) throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("toki-tap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        if let contents { try contents.write(to: settings, atomically: true, encoding: .utf8) }
    }

    func settingsText() throws -> String { try String(contentsOf: settings, encoding: .utf8) }
    func cleanUp() { try? FileManager.default.removeItem(at: home) }

    /// Runs `command` the way Claude Code does: through a shell, payload on stdin.
    func run(_ command: String, stdin: String) throws -> (output: String, status: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        input.fileHandleForWriting.write(Data(stdin.utf8))
        try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (String(decoding: data, as: UTF8.self), process.terminationStatus)
    }
}

private let userCommand = #"python3 "$HOME/my status.py" --label 'it'"'"'s' | tr a-z A-Z"#

private func settings(command: String) -> String {
    let encoded = String(decoding: try! JSONSerialization.data(
        withJSONObject: [command], options: [.withoutEscapingSlashes]), as: UTF8.self)
    return """
    {
      "model": "opus",
      "statusLine": {
        "type": "command",
        "command": \(encoded.dropFirst().dropLast()),
        "padding": 0
      },
      "hooks": {"Stop": [{"command": "echo \\"command\\": done"}]}
    }
    """
}

@Suite("StatuslineTap")
struct StatuslineTapTests {

    @Test("wrapping round-trips any command — quotes, spaces, dollars, pipes")
    func wrapRoundTrips() throws {
        let tap = try Sandbox(settings: nil).tap
        for command in [userCommand, "", "a'b''c'", #"echo "$(date)" \ `x`"#, "~/.claude/statusline.sh"] {
            let wrapped = tap.wrap(command)
            #expect(tap.original(fromTapped: wrapped) == command)
        }
        #expect(tap.original(fromTapped: userCommand) == nil)
        #expect(tap.original(fromTapped: tap.commandPrefix + " 'unterminated") == nil)
        #expect(tap.original(fromTapped: tap.commandPrefix + "'glued'") == nil)
    }

    @Test("the tapped command names the script through $HOME, so it reads the same on any machine")
    func commandUsesHome() throws {
        let tap = try Sandbox(settings: nil).tap
        #expect(tap.commandPrefix == #"/bin/sh "$HOME/Library/Application Support/Toki/statusline-tap.sh""#)
    }

    @Test("install rewrites only the status line command, leaving every other byte alone")
    func installSplicesCommandOnly() throws {
        let box = try Sandbox(settings: settings(command: userCommand))
        defer { box.cleanUp() }
        let before = try box.settingsText()

        #expect(try box.tap.install())

        let after = try box.settingsText()
        #expect(try box.tap.state() == .tapped(original: userCommand))
        let expected = before.replacingOccurrences(
            of: String(settings(command: userCommand).split(separator: "\n")[4]),
            with: String(settings(command: box.tap.wrap(userCommand)).split(separator: "\n")[4])
        )
        #expect(after == expected)
        #expect(after.contains(#""hooks": {"Stop": [{"command": "echo \"command\": done"}]}"#))
        #expect(FileManager.default.fileExists(atPath: box.tap.scriptURL.path))
    }

    @Test("installing twice is a no-op; uninstall restores the original file exactly")
    func installIsIdempotentAndReversible() throws {
        let box = try Sandbox(settings: settings(command: userCommand))
        defer { box.cleanUp() }
        let original = try box.settingsText()

        #expect(try box.tap.install())
        let tapped = try box.settingsText()
        #expect(try !box.tap.install())
        #expect(try box.settingsText() == tapped)

        #expect(try box.tap.uninstall())
        #expect(try box.settingsText() == original)
        #expect(try !box.tap.uninstall())
    }

    @Test("without a status line Toki adds its own silent one, and removing it restores the file",
          arguments: [
            #"{"model":"opus"}"#,
            "{\n    \"model\": \"opus\",\n    \"hooks\": {}\n}\n",
            "{}",
            "{\n}\n",
          ])
    func silentStatusLineRoundTrips(contents: String) throws {
        let box = try Sandbox(settings: contents)
        defer { box.cleanUp() }

        #expect(try box.tap.install())
        #expect(try box.tap.state() == .tapped(original: ""))
        let root = try #require(try JSONSerialization.jsonObject(with: Data(box.settingsText().utf8)) as? [String: Any])
        let statusLine = try #require(root["statusLine"] as? [String: String])
        #expect(statusLine == ["type": "command", "command": box.tap.commandPrefix])
        #expect(try !box.tap.install())

        #expect(try box.tap.uninstall())
        let restored = try box.settingsText()
        if contents.contains("model") {
            #expect(restored == contents)
        } else {
            let object = try JSONSerialization.jsonObject(with: Data(restored.utf8)) as? [String: Any]
            #expect(object?.isEmpty == true)
        }
        #expect(try box.tap.state() == .noStatusLine)
    }

    @Test("indentation follows the file's own members")
    func silentStatusLineIndentation() throws {
        let box = try Sandbox(settings: "{\n    \"model\": \"opus\"\n}\n")
        defer { box.cleanUp() }
        #expect(try box.tap.install())
        #expect(try box.settingsText().contains("\n    \"statusLine\": {\n        \"type\": \"command\",\n"))
    }

    @Test("no settings file: Toki creates one holding only its silent status line, and empties it again")
    func silentStatusLineCreatesFile() throws {
        let box = try Sandbox(settings: nil)
        defer { box.cleanUp() }
        #expect(try box.tap.install())
        #expect(try box.tap.state() == .tapped(original: ""))
        #expect(try box.tap.uninstall())
        let object = try JSONSerialization.jsonObject(with: Data(box.settingsText().utf8)) as? [String: Any]
        #expect(object?.isEmpty == true)
    }

    @Test("an empty command is filled in and set back to empty; extra keys are kept")
    func emptyCommandIsFilled() throws {
        let contents = #"{"statusLine": {"type": "command", "command": "", "padding": 2}}"#
        let box = try Sandbox(settings: contents)
        defer { box.cleanUp() }
        #expect(try box.tap.install())
        #expect(try box.tap.state() == .tapped(original: ""))
        #expect(try box.tap.uninstall())
        #expect(try box.settingsText() == contents)
    }

    @Test("a status line Toki does not understand is left alone",
          arguments: [#"{"statusLine": "echo hi"}"#, #"{"statusLine": {"type": "static", "text": "x"}}"#,
                      #"{"statusLine": {"type": "command", "command": 3}}"#])
    func unsupportedStatusLineLeftAlone(contents: String) throws {
        let box = try Sandbox(settings: contents)
        defer { box.cleanUp() }
        #expect(try box.tap.state() == .unsupported)
        #expect(try !box.tap.install())
        #expect(try box.settingsText() == contents)
    }

    @Test("removal handles the status line as first, middle or only member")
    func removalPositions() throws {
        for (before, after) in [
            (#"{"statusLine": {"type": "command", "command": "x"}, "a": 1}"#, #"{"a": 1}"#),
            (#"{"a": 1, "statusLine": {"type": "command", "command": "x"}, "b": 2}"#, #"{"a": 1, "b": 2}"#),
            (#"{ "statusLine": {"type": "command", "command": "x"} }"#, "{\n}"),
        ] {
            #expect(try StatuslineTap.removingStatusLine(from: before) == after)
        }
    }

    @Test("every edit first saves the file as it was, keeping the newest ten")
    func backupsPrecedeEveryEdit() throws {
        let box = try Sandbox(settings: settings(command: userCommand))
        defer { box.cleanUp() }
        let original = try box.settingsText()

        #expect(try box.tap.install())
        let tapped = try box.settingsText()
        #expect(try box.tap.uninstall())

        func backups() throws -> [String] {
            try FileManager.default.contentsOfDirectory(atPath: box.tap.backupsURL.path).sorted()
        }
        let saved = try backups().map {
            try String(contentsOf: box.tap.backupsURL.appendingPathComponent($0), encoding: .utf8)
        }
        #expect(saved == [original, tapped])
        let mode = try FileManager.default.attributesOfItem(
            atPath: box.tap.backupsURL.appendingPathComponent(try backups()[0]).path)[.posixPermissions] as? Int
        #expect(mode == 0o600)

        for _ in 0..<12 {
            try box.tap.install()
            try box.tap.uninstall()
        }
        #expect(try backups().count == StatuslineTap.backupLimit)
    }

    @Test("Toki's silent status line prints nothing and still records the payload")
    func silentScriptPrintsNothing() throws {
        let box = try Sandbox(settings: #"{"model":"opus"}"#)
        defer { box.cleanUp() }
        #expect(try box.tap.install())
        let payload = #"{"rate_limits":{"seven_day":{"used_percentage":3,"resets_at":1}}}"#
        let result = try box.run(box.tap.commandPrefix, stdin: payload)
        #expect(result.output.isEmpty)
        #expect(result.status == 0)
        #expect(try String(contentsOf: box.tap.sampleURL, encoding: .utf8) == payload + "\n")
    }

    @Test("an unparseable settings file is refused, not rewritten")
    func malformedSettingsRefused() throws {
        let box = try Sandbox(settings: #"{"statusLine": {"type": "command", "command": "x"},"#)
        defer { box.cleanUp() }
        #expect(throws: StatuslineTapError.malformed) { try box.tap.install() }
        #expect(try box.settingsText() == #"{"statusLine": {"type": "command", "command": "x"},"#)
    }

    @Test("a symlinked settings file is edited through the link, which stays a link")
    func symlinkPreserved() throws {
        let box = try Sandbox(settings: nil)
        defer { box.cleanUp() }
        let real = box.home.appendingPathComponent("dotfiles-settings.json")
        try settings(command: userCommand).write(to: real, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: box.settings, withDestinationURL: real)

        #expect(try box.tap.install())

        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: box.settings.path) == real.path)
        #expect(try box.tap.state() == .tapped(original: userCommand))
    }

    @Test("the installed command records the payload privately and shows the user's own output")
    func tappedCommandRunsOriginal() throws {
        let original = #"printf 'seen:'; cat; echo "it's $HOME"; exit 3"#
        let box = try Sandbox(settings: settings(command: original))
        defer { box.cleanUp() }
        #expect(try box.tap.install())
        guard case .tapped = try box.tap.state() else { Issue.record("not tapped"); return }
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: box.settings)) as? [String: Any]
        let command = try #require((root?["statusLine"] as? [String: Any])?["command"] as? String)

        let payload = #"{"rate_limits":{"five_hour":{"used_percentage":12,"resets_at":1}}}"#
        let result = try box.run(command, stdin: payload)

        #expect(result.output == "seen:\(payload)\nit's \(box.home.path)\n")
        #expect(result.status == 3)
        #expect(try String(contentsOf: box.tap.sampleURL, encoding: .utf8) == payload + "\n")
        let mode = try FileManager.default.attributesOfItem(atPath: box.tap.sampleURL.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }
}
