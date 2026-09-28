import Foundation
import Testing
@testable import TokiAccounts

private final class MemoryCodexProfileStore: CodexProfileStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: CodexAccountProfile]
    var failingSaves: Set<Int> = []
    private var saveCount = 0

    init(_ profiles: [CodexAccountProfile] = []) {
        values = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
    }

    func loadAll() throws -> [CodexAccountProfile] {
        lock.withLock { Array(values.values) }
    }

    func load(id: String) throws -> CodexAccountProfile? {
        lock.withLock { values[id] }
    }

    func save(_ profile: CodexAccountProfile) throws {
        try lock.withLock {
            saveCount += 1
            if failingSaves.contains(saveCount) { throw CodexAccountError.keychainFailure(-1) }
            values[profile.id] = profile
        }
    }

    func delete(id: String) throws {
        _ = lock.withLock { values.removeValue(forKey: id) }
    }
}

private func codexAuth(
    email: String,
    userID: String,
    accountID: String,
    access: String,
    refresh: String
) throws -> Data {
    let header = Data(#"{"alg":"none"}"#.utf8).base64URLEncoded()
    let payload = try JSONSerialization.data(withJSONObject: [
        "sub": "subject-\(userID)",
        "email": email,
        "https://api.openai.com/user_id": userID,
    ]).base64URLEncoded()
    let idToken = "\(header).\(payload).signature"
    return try JSONSerialization.data(withJSONObject: [
        "tokens": [
            "access_token": access,
            "refresh_token": refresh,
            "id_token": idToken,
            "account_id": accountID,
        ],
        "last_refresh": "2026-09-04T12:00:00Z",
    ])
}

private extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

@Suite("Codex account profiles")
struct CodexAccountProfileTests {
    @Test("identity is stable across token rotation")
    func stableIdentity() throws {
        let before = try codexAuth(
            email: "dev@example.com", userID: "user-1", accountID: "workspace-1",
            access: "access-1", refresh: "refresh-1"
        )
        let after = try codexAuth(
            email: "dev@example.com", userID: "user-1", accountID: "workspace-1",
            access: "access-2", refresh: "refresh-2"
        )

        #expect(try CodexAuthBlob.identity(from: before).id == CodexAuthBlob.identity(from: after).id)
        #expect(CodexAuthBlob.identityMatches(before, after))
        #expect(try CodexAuthBlob.identity(from: before).email == "dev@example.com")
    }

    @Test("workspace participates in identity")
    func workspaceIdentity() throws {
        let personal = try codexAuth(
            email: "dev@example.com", userID: "user-1", accountID: "personal",
            access: "a", refresh: "r"
        )
        let business = try codexAuth(
            email: "dev@example.com", userID: "user-1", accountID: "business",
            access: "b", refresh: "s"
        )

        #expect(try CodexAuthBlob.identity(from: personal).id != CodexAuthBlob.identity(from: business).id)
        #expect(!CodexAuthBlob.identityMatches(personal, business))
    }

    @Test("App Server email metadata does not destabilize token-claim identity")
    func appServerEmailDoesNotChangeIdentity() throws {
        let header = Data(#"{"alg":"none"}"#.utf8).base64URLEncoded()
        let payload = try JSONSerialization.data(withJSONObject: [
            "sub": "subject-user-1",
            "https://api.openai.com/user_id": "user-1",
        ]).base64URLEncoded()
        let auth = try JSONSerialization.data(withJSONObject: [
            "tokens": [
                "access_token": "access",
                "refresh_token": "refresh",
                "id_token": "\(header).\(payload).signature",
                "account_id": "workspace-1",
            ],
        ])

        let withMetadata = try CodexAuthBlob.identity(
            from: auth,
            accountEmail: "dev@example.com"
        )
        let fromFileAlone = try CodexAuthBlob.identity(from: auth)

        #expect(withMetadata.id == fromFileAlone.id)
        #expect(withMetadata.email == "dev@example.com")
        #expect(CodexAuthBlob.identityMatches(auth, auth))
    }

    @Test("switch writes back rotated outgoing auth and activates target atomically")
    func switchesProfiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("toki-codex-switch-\(UUID().uuidString)")
        let liveURL = root.appendingPathComponent(".codex/auth.json")
        defer { try? FileManager.default.removeItem(at: root) }

        let storedA = try codexAuth(
            email: "a@example.com", userID: "a", accountID: "personal-a",
            access: "old-a", refresh: "old-refresh-a"
        )
        let liveRotatedA = try codexAuth(
            email: "a@example.com", userID: "a", accountID: "personal-a",
            access: "new-a", refresh: "new-refresh-a"
        )
        let storedB = try codexAuth(
            email: "b@example.com", userID: "b", accountID: "personal-b",
            access: "b", refresh: "refresh-b"
        )
        let identityA = try CodexAuthBlob.identity(from: storedA)
        let identityB = try CodexAuthBlob.identity(from: storedB)
        let profileA = CodexAccountProfile(
            identity: identityA, authJSON: storedA, addedAt: .distantPast
        )
        let profileB = CodexAccountProfile(
            identity: identityB, authJSON: storedB, addedAt: .distantPast
        )
        let store = MemoryCodexProfileStore([profileA, profileB])
        try CodexAuthFile.writeAtomically(liveRotatedA, to: liveURL)

        try CodexProfileSwitcher(store: store, liveAuthURL: liveURL).swap(
            to: identityB.id,
            now: Date(timeIntervalSince1970: 1_788_541_200)
        )

        #expect(try CodexAuthFile.read(from: liveURL) == storedB)
        #expect(try store.load(id: identityA.id)?.authJSON == liveRotatedA)
        #expect(try store.load(id: identityB.id)?.lastActiveAt == Date(timeIntervalSince1970: 1_788_541_200))
        let attributes = try FileManager.default.attributesOfItem(atPath: liveURL.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test("profile failures preserve live auth and report failed rollback", arguments: [false, true])
    func reportsFailedRollback(restoreFails: Bool) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("toki-codex-rollback-\(UUID().uuidString)")
        let liveURL = root.appendingPathComponent("auth.json")
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try codexAuth(email: "a@x.test", userID: "a", accountID: "a", access: "a", refresh: "ra")
        let b = try codexAuth(email: "b@x.test", userID: "b", accountID: "b", access: "b", refresh: "rb")
        let profileA = CodexAccountProfile(identity: try CodexAuthBlob.identity(from: a), authJSON: a, addedAt: .distantPast)
        let profileB = CodexAccountProfile(identity: try CodexAuthBlob.identity(from: b), authJSON: b, addedAt: .distantPast)
        let store = MemoryCodexProfileStore([profileA, profileB])
        store.failingSaves = restoreFails ? [2, 3] : [2] // Activation fails; optionally fail outgoing restoration too.
        try CodexAuthFile.writeAtomically(a, to: liveURL)
        let originalInode = try FileManager.default.attributesOfItem(atPath: liveURL.path)[.systemFileNumber] as? NSNumber
        do {
            try CodexProfileSwitcher(store: store, liveAuthURL: liveURL).swap(to: profileB.id)
            Issue.record("failed profile save must throw")
        } catch {
            #expect(error as? CodexAccountError == (restoreFails ? .rollbackFailed : .keychainFailure(-1)))
            if restoreFails { #expect(error.localizedDescription.contains("couldn't be restored")) }
        }
        #expect(try CodexAuthFile.read(from: liveURL) == a)
        let afterInode = try FileManager.default.attributesOfItem(atPath: liveURL.path)[.systemFileNumber] as? NSNumber
        #expect(originalInode == afterInode, "a pre-activation failure must leave the live file untouched")
        #expect(try store.load(id: profileB.id) == profileB, "other restores must still be attempted")
        if !restoreFails { #expect(try store.load(id: profileA.id) == profileA) }
    }

    @Test("an unmanaged live login is never overwritten")
    func refusesUnmanagedLiveLogin() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("toki-codex-unmanaged-\(UUID().uuidString)")
        let liveURL = root.appendingPathComponent(".codex/auth.json")
        defer { try? FileManager.default.removeItem(at: root) }

        let unmanaged = try codexAuth(
            email: "new@example.com", userID: "new", accountID: "new",
            access: "new", refresh: "new"
        )
        let targetAuth = try codexAuth(
            email: "saved@example.com", userID: "saved", accountID: "saved",
            access: "saved", refresh: "saved"
        )
        let identity = try CodexAuthBlob.identity(from: targetAuth)
        let store = MemoryCodexProfileStore([
            CodexAccountProfile(identity: identity, authJSON: targetAuth, addedAt: .distantPast),
        ])
        try CodexAuthFile.writeAtomically(unmanaged, to: liveURL)

        #expect(throws: CodexAccountError.unmanagedActiveAccount) {
            try CodexProfileSwitcher(store: store, liveAuthURL: liveURL).swap(to: identity.id)
        }
        #expect(try CodexAuthFile.read(from: liveURL) == unmanaged)
    }

    @Test("a symlink managed by another profile tool is never replaced")
    func refusesSymlink() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("toki-codex-symlink-\(UUID().uuidString)")
        let liveURL = root.appendingPathComponent(".codex/auth.json")
        let managedURL = root.appendingPathComponent("managed-auth.json")
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(
            at: liveURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let original = Data("managed elsewhere".utf8)
        try original.write(to: managedURL)
        try FileManager.default.createSymbolicLink(
            atPath: liveURL.path,
            withDestinationPath: managedURL.path
        )

        #expect(throws: CodexAccountError.unsupportedSymlink) {
            try CodexAuthFile.writeAtomically(Data("replacement".utf8), to: liveURL)
        }
        #expect(try Data(contentsOf: managedURL) == original)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: liveURL.path) == managedURL.path)
    }
}
