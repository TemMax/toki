import Testing
import Foundation
import Security

/// Proves the two claims the swap writer depends on, against a THROWAWAY Keychain
/// item created exactly the way Claude Code creates its own: `security
/// add-generic-password`. Claude Code's real item is never touched here.
@Suite("Write-path spike", .serialized)
struct WritePathSpikeTests {

    static let service = "dev.komar.toki.spike-credentials.\(UUID().uuidString.prefix(8))"
    static var account: String { NSUserName() }

    /// A payload the size of a real Claude Code credential (~4 KB), so the argv
    /// limit is exercised rather than assumed.
    static func payload(marker: String) -> Data {
        let filler = String(repeating: "a", count: 3800)
        let json = #"{"claudeAiOauth":{"accessToken":"\#(marker)","refreshToken":"\#(filler)"}}"#
        return Data(json.utf8)
    }

    static func run(_ args: [String]) -> (code: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        try? p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined()
    }

    @Test("security -U writes a 4 KB secret and stays silently readable afterwards")
    func writeIsSilentAndReadable() throws {
        defer { _ = Self.run(["delete-generic-password", "-a", Self.account, "-s", Self.service]) }
        _ = Self.run(["delete-generic-password", "-a", Self.account, "-s", Self.service])

        // Create the item the way Claude Code does.
        let first = Self.payload(marker: "tok-one")
        let started = Date()
        let create = Self.run([
            "add-generic-password", "-U", "-a", Self.account, "-s", Self.service,
            "-X", Self.hex(first),
        ])
        #expect(create.code == 0)

        // Update it — this is the operation the swap performs.
        let second = Self.payload(marker: "tok-two")
        let update = Self.run([
            "add-generic-password", "-U", "-a", Self.account, "-s", Self.service,
            "-X", Self.hex(second),
        ])
        #expect(update.code == 0)
        // A dialog would cost seconds of human time; a silent write is milliseconds.
        #expect(Date().timeIntervalSince(started) < 2)

        // Read back through the same path Claude Code reads with.
        let read = Self.run(["find-generic-password", "-a", Self.account, "-s", Self.service, "-w"])
        #expect(read.code == 0)
        #expect(read.out.contains("tok-two"), "the 4 KB payload must survive argv intact")
        #expect(!read.out.contains("tok-one"))
    }

    // OBSERVED, and the reason the swap writer uses the `security` CLI: after a native
    // `SecItemUpdate`, `security find-generic-password` on the same item RAISES THE MACOS
    // AUTHORIZATION DIALOG. Measured here as exit 128 with empty output — 128 is
    // `errSecUserCanceled` (-128 truncated to a process exit status), i.e. the dialog was
    // dismissed. The native write re-owns the item's ACL, so `/usr/bin/security` is no
    // longer a trusted reader. Applied to Claude Code's real item that would mean the CLI
    // prompting the user for its own credential — the exact failure this feature exists to
    // remove, transplanted into Claude Code.
    //
    // Disabled, and it must stay disabled: running it pops a password dialog at whoever is
    // at the keyboard. Kept as executable documentation of the experiment, never as a gate.
    @Test(
        "a SecItemUpdate-written item is still readable by the security CLI",
        .disabled("documents why the CLI writer is mandatory; outcome is non-deterministic")
    )
    func nativeUpdateKeepsCLIReadable() throws {
        // Documents WHY the writer uses the CLI: if this ever fails, a native write
        // has broken the apple-tool partition and Claude Code would start prompting.
        defer { _ = Self.run(["delete-generic-password", "-a", Self.account, "-s", Self.service]) }
        _ = Self.run(["delete-generic-password", "-a", Self.account, "-s", Self.service])
        _ = Self.run([
            "add-generic-password", "-U", "-a", Self.account, "-s", Self.service,
            "-X", Self.hex(Self.payload(marker: "cli-written")),
        ])

        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.service,
            kSecAttrAccount: Self.account,
        ]
        let status = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData: Self.payload(marker: "native-written")] as CFDictionary
        )
        #expect(status == errSecSuccess)

        let read = Self.run(["find-generic-password", "-a", Self.account, "-s", Self.service, "-w"])
        #expect(read.code == 0, "CLI read after a native write — status \(read.code)")
        #expect(read.out.contains("native-written"))
    }
}
