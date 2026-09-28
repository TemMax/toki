/// The per-install secret behind every `#a3f1c204` correlation token.
///
/// A bare `SHA256(email)` would be useless: the space of e-mail addresses is small enough to
/// brute-force, so an unsalted digest is the address. Salting with 32 random bytes that never
/// leave this Mac makes the token unrecoverable, still stable within one install (so two
/// lines about the same account correlate), and *not* comparable across installs (so two
/// users' logs cannot be joined).
///
/// The salt lives in `~/Library/Application Support/Toki/logging-salt`, deliberately NOT in
/// the log directory: log export archives `~/Library/Logs/Toki`, so there is no code path,
/// present or future, in which zipping the logs also ships the key that would undo them.
import CryptoKit
import Foundation
import Security

public enum HashSalt {

    /// `~/Library/Application Support/Toki/logging-salt` — outside the log directory by design.
    public static let fileURL: URL = {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base
            .appendingPathComponent("Toki", isDirectory: true)
            .appendingPathComponent("logging-salt", isDirectory: false)
    }()

    /// Read once per process. `static let` so concurrent first callers cannot each generate a
    /// salt and race to write it — Swift guarantees a lazy static runs exactly once.
    private static let salt: Data = load()

    /// `<kind>#<8 lowercase hex>` — the first four bytes of `SHA256(salt ‖ utf8(value))`.
    ///
    /// Four bytes is the deliberate trade: enough that two accounts on one install will not
    /// collide in practice, short enough that a line stays readable.
    public static func token(kind: String, value: String) -> String {
        var input = salt
        input.append(contentsOf: Array(value.utf8))
        let digest = SHA256.hash(data: input)
        let hex = digest.prefix(4).map { String(format: "%02x", $0) }.joined()
        return "\(kind)#\(hex)"
    }

    // MARK: - Salt file

    private static func load() -> Data {
        let fm = FileManager.default
        if let existing = try? Data(contentsOf: fileURL), existing.count == 32 {
            return existing
        }
        let fresh = randomBytes(count: 32)
        try? fm.createDirectory(at: fileURL.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
        // Owner read/write only: the salt is the one thing that would let someone reverse a
        // token back to the address it came from.
        fm.createFile(atPath: fileURL.path, contents: fresh,
                      attributes: [.posixPermissions: NSNumber(value: Int16(0o600))])
        try? fm.setAttributes([.posixPermissions: NSNumber(value: Int16(0o600))],
                              ofItemAtPath: fileURL.path)
        return fresh
    }

    private static func randomBytes(count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        guard status == errSecSuccess else {
            // Never observed in practice; a non-random salt is still vastly better than
            // logging the raw value, and taking the app down over it would be absurd.
            return Data((0..<count).map { _ in UInt8.random(in: .min ... .max) })
        }
        return Data(bytes)
    }
}
