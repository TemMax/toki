/// Secure local profiles for Codex's single active ChatGPT credential.
///
/// Codex itself owns login and token refresh. Toki only snapshots a user-selected live
/// `auth.json` into its own Keychain and atomically restores another saved snapshot when
/// asked to switch. The outgoing live blob is written back first so token rotation is not
/// lost while that account is inactive.
import CryptoKit
import Darwin
import Foundation
import LocalAuthentication
import Security
import TokiKeychain
import TokiLogging
import TokiModels

// MARK: - Models

public struct CodexAccountIdentity: Codable, Equatable, Sendable {
    public let id: String
    public let email: String?
    public let planType: String?
    public let isAPIKey: Bool

    public init(id: String, email: String?, planType: String?, isAPIKey: Bool = false) {
        self.id = id
        self.email = email
        self.planType = planType
        self.isAPIKey = isAPIKey
    }

    public var label: String {
        if let email, !email.isEmpty { return email }
        return isAPIKey ? "OpenAI API key" : "ChatGPT account"
    }
}

public struct CodexAccountProfile: Codable, Equatable, Sendable, Identifiable {
    public var id: String { identity.id }

    public var identity: CodexAccountIdentity
    public var alias: String?
    /// The complete Codex auth payload. It is persisted only in Toki's Keychain.
    public var authJSON: Data
    public var addedAt: Date
    public var lastActiveAt: Date?
    /// Last known quota gauges, collected in an isolated CODEX_HOME for inactive profiles.
    public var fiveHourUtilization: Double?
    public var weeklyUtilization: Double?
    public var gaugesFetchedAt: Date?
    public var gaugesAreStale: Bool?

    public init(
        identity: CodexAccountIdentity,
        alias: String? = nil,
        authJSON: Data,
        addedAt: Date,
        lastActiveAt: Date? = nil,
        fiveHourUtilization: Double? = nil,
        weeklyUtilization: Double? = nil,
        gaugesFetchedAt: Date? = nil,
        gaugesAreStale: Bool? = nil
    ) {
        self.identity = identity
        self.alias = alias
        self.authJSON = authJSON
        self.addedAt = addedAt
        self.lastActiveAt = lastActiveAt
        self.fiveHourUtilization = fiveHourUtilization
        self.weeklyUtilization = weeklyUtilization
        self.gaugesFetchedAt = gaugesFetchedAt
        self.gaugesAreStale = gaugesAreStale
    }

    public var displayLabel: String {
        if let alias, !alias.isEmpty { return alias }
        return identity.label
    }
}

public struct CodexAccountPresentation: Equatable, Sendable, Identifiable {
    public let id: String
    public let label: String
    public let email: String?
    public let planType: String?
    public let isActive: Bool
    public let isStored: Bool
    public let lastActiveAt: Date?
    public let fiveHour: Double?
    public let weekly: Double?
    public let gaugesFetchedAt: Date?
    public let gaugesAreStale: Bool

    public init(
        id: String,
        label: String,
        email: String?,
        planType: String?,
        isActive: Bool,
        isStored: Bool,
        lastActiveAt: Date?,
        fiveHour: Double? = nil,
        weekly: Double? = nil,
        gaugesFetchedAt: Date? = nil,
        gaugesAreStale: Bool = true
    ) {
        self.id = id
        self.label = label
        self.email = email
        self.planType = planType
        self.isActive = isActive
        self.isStored = isStored
        self.lastActiveAt = lastActiveAt
        self.fiveHour = fiveHour
        self.weekly = weekly
        self.gaugesFetchedAt = gaugesFetchedAt
        self.gaugesAreStale = gaugesAreStale
    }

    public static func make(profile: CodexAccountProfile, activeID: String?) -> Self {
        Self(
            id: profile.id,
            label: profile.displayLabel,
            email: profile.identity.email,
            planType: profile.identity.planType,
            isActive: profile.id == activeID,
            isStored: true,
            lastActiveAt: profile.lastActiveAt,
            fiveHour: profile.fiveHourUtilization,
            weekly: profile.weeklyUtilization,
            gaugesFetchedAt: profile.gaugesFetchedAt,
            gaugesAreStale: profile.gaugesAreStale ?? true
        )
    }

    public static func makeLiveUnstored(identity: CodexAccountIdentity) -> Self {
        Self(
            id: identity.id,
            label: identity.label,
            email: identity.email,
            planType: identity.planType,
            isActive: true,
            isStored: false,
            lastActiveAt: nil,
            gaugesAreStale: true
        )
    }
}

// MARK: - Auth parsing

public enum CodexAccountError: Error, Equatable, Sendable {
    case authFileNotFound
    case invalidAuthFile
    case missingIdentity
    case unsupportedSymlink
    case unmanagedActiveAccount
    case ambiguousActiveAccount
    case profileNotFound
    case cannotRemoveActiveProfile
    case keychainFailure(Int32)
    case fileFailure(String)
    case rollbackFailed
}

extension CodexAccountError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .authFileNotFound:
            return "Codex auth.json wasn't found. Sign in with Codex using file credential storage first."
        case .invalidAuthFile:
            return "Codex auth.json does not contain a usable login."
        case .missingIdentity:
            return "The Codex account could not be identified safely."
        case .unsupportedSymlink:
            return "Codex auth.json is managed by another profile tool; Toki left it unchanged."
        case .unmanagedActiveAccount:
            return "Save the current Codex account before switching away from it."
        case .ambiguousActiveAccount:
            return "The active Codex login matches more than one stored profile."
        case .profileNotFound:
            return "That Codex account is no longer stored."
        case .cannotRemoveActiveProfile:
            return "Switch to another Codex account before removing the active one."
        case let .keychainFailure(status):
            return "The Codex account Keychain operation failed (\(status))."
        case let .fileFailure(message):
            return "Codex auth.json could not be updated: \(message)"
        case .rollbackFailed:
            return "The Codex switch failed and some saved account data couldn't be restored. Check your accounts before switching again."
        }
    }
}

public enum CodexAuthBlob {
    /// Extracts only stable identity claims. Token strings are never returned or logged.
    public static func identity(
        from data: Data,
        accountEmail: String? = nil,
        planType: String? = nil
    ) throws -> CodexAccountIdentity {
        guard case let .success(decoded) = Result(catching: {
                  try JSONSerialization.jsonObject(with: data)
              }),
              let root = decoded as? [String: Any] else {
            throw CodexAccountError.invalidAuthFile
        }

        if let apiKey = nonEmpty(root["OPENAI_API_KEY"]) {
            return CodexAccountIdentity(
                id: digest("api-key|\(apiKey)"),
                email: nil,
                planType: nil,
                isAPIKey: true
            )
        }

        guard let tokens = root["tokens"] as? [String: Any],
              token(tokens, "access_token", "accessToken") != nil,
              token(tokens, "refresh_token", "refreshToken") != nil else {
            throw CodexAccountError.invalidAuthFile
        }

        let idToken = token(tokens, "id_token", "idToken")
        let claims = idToken.flatMap(jwtClaims) ?? [:]
        let email = nonEmpty(accountEmail)
            ?? nonEmpty(claims["email"])
        let accountID = token(tokens, "account_id", "accountId")
            ?? nonEmpty(claims["https://api.openai.com/account_id"])
        let userID = nonEmpty(claims["https://api.openai.com/user_id"])
            ?? nonEmpty(claims["sub"])

        // Keep workspace/account id in the identity when present: one ChatGPT login may
        // expose personal and Business workspaces with independent Codex limits.
        // Prefer claims embedded in the credential itself. App Server metadata is a useful
        // display/fallback identity, but including it alongside stable token claims would
        // make the same auth blob hash differently when App Server is temporarily offline.
        // The account/workspace id remains part of the key so personal and Business
        // workspaces under one login stay independently switchable.
        let stableClaims = [userID, accountID].compactMap { $0 }
        let identityParts = stableClaims.isEmpty
            ? [email?.lowercased()].compactMap { $0 }
            : stableClaims
        guard !identityParts.isEmpty else { throw CodexAccountError.missingIdentity }

        return CodexAccountIdentity(
            id: digest("oauth|" + identityParts.joined(separator: "|")),
            email: email,
            planType: nonEmpty(planType),
            isAPIKey: false
        )
    }

    public static func identityMatches(_ lhs: Data, _ rhs: Data) -> Bool {
        guard case let .success(left) = Result(catching: { try identity(from: lhs) }),
              case let .success(right) = Result(catching: { try identity(from: rhs) }) else {
            return false
        }
        return left.id == right.id
    }

    private static func token(_ object: [String: Any], _ keys: String...) -> String? {
        for key in keys {
            if let value = nonEmpty(object[key]) { return value }
        }
        return nil
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func jwtClaims(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let payload = Data(base64Encoded: base64) else { return nil }
        guard case let .success(decoded) = Result(catching: {
                  try JSONSerialization.jsonObject(with: payload)
              }) else {
            return nil
        }
        return decoded as? [String: Any]
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

// MARK: - Keychain store

public protocol CodexProfileStoring: Sendable {
    func loadAll() throws -> [CodexAccountProfile]
    func load(id: String) throws -> CodexAccountProfile?
    func save(_ profile: CodexAccountProfile) throws
    func delete(id: String) throws
}

public struct KeychainCodexProfileStore: CodexProfileStoring {
    public static let defaultServicePrefix: String = {
        #if DEBUG
        KeychainNamespace.prefix + "debug.codex.account."
        #else
        KeychainNamespace.prefix + "codex.account."
        #endif
    }()

    public static let defaultIndexService: String = {
        #if DEBUG
        KeychainNamespace.prefix + "debug.codex.accounts.index"
        #else
        KeychainNamespace.prefix + "codex.accounts.index"
        #endif
    }()

    private let servicePrefix: String
    private let indexService: String
    private let account: String

    public init(
        servicePrefix: String = Self.defaultServicePrefix,
        indexService: String = Self.defaultIndexService,
        account: String = NSUserName()
    ) {
        self.servicePrefix = servicePrefix
        self.indexService = indexService
        self.account = account
    }

    public func loadAll() throws -> [CodexAccountProfile] {
        let indexedIDs = Set(try read([String].self, service: indexService) ?? [])
        var ids = indexedIDs
        let discovered = KeychainEnumerator.items(servicePrefix: servicePrefix)
            .map { String($0.service.dropFirst(servicePrefix.count)) }
        ids.formUnion(discovered)
        if ids != indexedIDs {
            try write(ids.sorted(), service: indexService)
        }
        return try ids.compactMap { try load(id: $0) }.sorted { $0.addedAt < $1.addedAt }
    }

    public func load(id: String) throws -> CodexAccountProfile? {
        try read(CodexAccountProfile.self, service: servicePrefix + id)
    }

    public func save(_ profile: CodexAccountProfile) throws {
        var ids = Set(try read([String].self, service: indexService) ?? [])
        if ids.insert(profile.id).inserted {
            try write(ids.sorted(), service: indexService)
        }
        try write(profile, service: servicePrefix + profile.id)
    }

    public func delete(id: String) throws {
        try remove(service: servicePrefix + id)
        var ids = Set(try read([String].self, service: indexService) ?? [])
        if ids.remove(id) != nil { try write(ids.sorted(), service: indexService) }
    }

    private var noInteraction: LAContext {
        let context = LAContext()
        context.interactionNotAllowed = true
        return context
    }

    private func query(_ service: String) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecUseAuthenticationContext: noInteraction,
        ]
    }

    private func read<T: Decodable>(_ type: T.Type, service: String) throws -> T? {
        var request = query(service)
        request[kSecMatchLimit] = kSecMatchLimitOne
        request[kSecReturnData] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw CodexAccountError.keychainFailure(status)
        }
        guard case let .success(decoded) = Result(catching: {
                  try decoder.decode(T.self, from: data)
              }) else {
            throw CodexAccountError.keychainFailure(errSecDecode)
        }
        return decoded
    }

    private func write<T: Encodable>(_ value: T, service: String) throws {
        let data = try encoder.encode(value)
        let update = SecItemUpdate(query(service) as CFDictionary, [kSecValueData: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw CodexAccountError.keychainFailure(update) }

        var add = query(service)
        add[kSecValueData] = data
        add[kSecAttrSynchronizable] = false
        add[kSecAttrLabel] = "Toki — stored Codex account"
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw CodexAccountError.keychainFailure(status) }
    }

    private func remove(service: String) throws {
        let status = SecItemDelete(query(service) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CodexAccountError.keychainFailure(status)
        }
    }

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}

// MARK: - Live auth file and switch transaction

public enum CodexAuthFile {
    public static func liveURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        let home = environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? homeDirectory.appendingPathComponent(".codex", isDirectory: true)
        return home.appendingPathComponent("auth.json")
    }

    public static func read(from url: URL) throws -> Data {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CodexAccountError.authFileNotFound
        }
        do { return try Data(contentsOf: url) }
        catch { throw CodexAccountError.fileFailure(error.localizedDescription) }
    }

    /// Replaces auth.json with one rename in the same directory. The temporary file is born
    /// mode 0600, so there is no interval where token bytes are world-readable.
    public static func writeAtomically(_ data: Data, to url: URL) throws {
        let manager = FileManager.default
        let directory = url.deletingLastPathComponent()
        do {
            try manager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            TokiLog.logger("codex-accounts").error(
                "Creating the Codex auth directory failed \(error: error)"
            )
            throw CodexAccountError.fileFailure(error.localizedDescription)
        }

        var info = stat()
        if lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFLNK {
            throw CodexAccountError.unsupportedSymlink
        }

        let temporary = directory.appendingPathComponent(".auth.json.toki-\(UUID().uuidString)")
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw CodexAccountError.fileFailure(String(cString: strerror(errno)))
        }
        var completed = false
        defer {
            Darwin.close(descriptor)
            if !completed {
                do {
                    try manager.removeItem(at: temporary)
                } catch {
                    TokiLog.logger("codex-accounts").debug(
                        "Removing a temporary Codex auth file failed \(error: error)"
                    )
                }
            }
        }

        try data.withUnsafeBytes { buffer in
            guard var pointer = buffer.baseAddress else { return }
            var remaining = buffer.count
            while remaining > 0 {
                let count = Darwin.write(descriptor, pointer, remaining)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else {
                    throw CodexAccountError.fileFailure(String(cString: strerror(errno)))
                }
                pointer = pointer.advanced(by: count)
                remaining -= count
            }
        }
        guard fsync(descriptor) == 0 else {
            throw CodexAccountError.fileFailure(String(cString: strerror(errno)))
        }
        guard rename(temporary.path, url.path) == 0 else {
            throw CodexAccountError.fileFailure(String(cString: strerror(errno)))
        }
        completed = true
    }
}

public struct CodexProfileSwitcher: Sendable {
    private let store: any CodexProfileStoring
    private let liveAuthURL: URL

    public init(store: any CodexProfileStoring, liveAuthURL: URL = CodexAuthFile.liveURL()) {
        self.store = store
        self.liveAuthURL = liveAuthURL
    }

    /// Saves the outgoing (possibly refreshed) auth, then atomically activates the target.
    /// A failed atomic activation leaves the live file untouched. Touched Keychain
    /// profiles are restored, with a distinct error if any restoration fails.
    public func swap(to targetID: String, now: Date = Date()) throws {
        let profiles = try store.loadAll()
        guard var target = profiles.first(where: { $0.id == targetID }) else {
            throw CodexAccountError.profileNotFound
        }
        let liveData = try CodexAuthFile.read(from: liveAuthURL)
        let matches = profiles.filter { CodexAuthBlob.identityMatches($0.authJSON, liveData) }
        guard matches.count <= 1 else { throw CodexAccountError.ambiguousActiveAccount }
        guard let outgoing = matches.first else { throw CodexAccountError.unmanagedActiveAccount }
        if outgoing.id == targetID { return }

        var refreshedOutgoing = outgoing
        refreshedOutgoing.authJSON = liveData
        refreshedOutgoing.lastActiveAt = now
        let outgoingBefore = outgoing
        let targetBefore = target

        do {
            try store.save(refreshedOutgoing)
            target.lastActiveAt = now
            try store.save(target)
            try CodexAuthFile.writeAtomically(target.authJSON, to: liveAuthURL)
        } catch {
            TokiLog.logger("codex-accounts").error(
                "Codex profile activation failed; rolling back \(error: error)"
            )
            // Activation is the final operation and cannot throw after its atomic
            // rename. On failure the original live file is intact; rewriting it would
            // needlessly trigger watchers and could overwrite a concurrent Codex login.
            var restorationFailed = false
            for profile in [outgoingBefore, targetBefore] {
                do {
                    try store.save(profile)
                } catch {
                    restorationFailed = true
                    TokiLog.logger("codex-accounts").error(
                        "Restoring a saved Codex profile failed \(error: error)"
                    )
                }
            }
            if restorationFailed { throw CodexAccountError.rollbackFailed }
            throw error
        }
    }
}
