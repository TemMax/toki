/// CredentialStore — resolves the Claude Code OAuth credential without nagging the user.
///
/// Toki used to read Claude Code's Keychain item on nearly every poll, which is why the
/// macOS authorization dialog could come back when Claude Code replaced its item during a
/// refresh and the replacement no longer carried a prior access grant. The item's secret
/// is read through a native path configured to suppress UI, with a CLI fallback when a
/// fresh ACL preflight confirms existing access. The result is cached in Toki's own
/// Keychain item (`TokenVault`).
///
/// Resolution order:
///  1. `CLAUDE_CODE_OAUTH_TOKEN`
///  2. the vault — the hot path
///  3. native read, then the ACL-checked CLI (memoized per modification date)
///  4. `~/.claude/.credentials.json` — only while its token is live
///  5. the interactive read — user-initiated contexts only
///
/// The file sits below the Keychain-derived sources because Claude Code 2.1.223 treats
/// its own Keychain item as primary and the file as a fallback. Once accounts can be
/// swapped, a leftover fallback file holds the previous account's still-unexpired token,
/// so preferring it would make Toki report the wrong account's usage.
import Foundation
import Security
import LocalAuthentication
import TokiModels
import TokiLogging

private let log = TokiLog.logger("keychain")

// MARK: - Internal JSON shape

/// Decodable mirror of the credential JSON stored in the Keychain and
/// `~/.claude/.credentials.json`.
struct CredentialFile: Decodable {
    struct OAuthEntry: Decodable {
        let accessToken: String
        let refreshToken: String?
        /// Epoch milliseconds.
        let expiresAt: Double?
        let scopes: [String]?
    }

    let claudeAiOauth: OAuthEntry?
}

// MARK: - Provider closure types

typealias EnvProvider = @Sendable () -> String?
typealias FileProvider = @Sendable () -> OAuthCredential?
typealias LadderRunner = @Sendable (LadderContext, Bool) async -> LadderResult
typealias LadderSourceProvider = @Sendable () async -> KeychainItemRef?
typealias LadderInvalidator = @Sendable () async -> Void
typealias InteractiveReader = @Sendable () -> OAuthCredential?
typealias RawLadderRunner = @Sendable (LadderContext, Bool) async -> RawCredentialResult
typealias InteractiveRawReader = @Sendable () -> Data?
typealias NowProvider = @Sendable () -> Date
typealias DevSkipProvider = @Sendable () -> Bool

// MARK: - CredentialStore

public struct CredentialStore: CredentialOnboarding {
    private let envProvider: EnvProvider
    private let fileProvider: FileProvider
    private let vault: TokenVault
    private let ladderRunner: LadderRunner
    private let ladderSource: LadderSourceProvider
    private let ladderInvalidator: LadderInvalidator
    private let interactiveRead: InteractiveReader
    private let rawLadderRunner: RawLadderRunner
    private let interactiveRawRead: InteractiveRawReader
    private let now: NowProvider
    private let devSkip: DevSkipProvider

    // MARK: Public init (wires real implementations)

    public init() {
        let vaultStore = KeychainVaultStore()
        // The subprocess is barred whenever Keychain data needs interaction to read —
        // that is the one state in which it could raise an unlock dialog or hang.
        let gate = SubprocessGate(
            keychainUnlocked: { vaultStore.isReadableWithoutInteraction() ?? true }
        )
        let cli = SecurityCLIReader(gate: gate)
        let ladder = SilentLadder(
            enumerate: { Self.enumerateClaudeItems() },
            silentRead: { Self.silentItemRead($0) },
            cliRead: { ref, context in await cli.read(ref, context: context) }
        )

        self.envProvider = { ProcessInfo.processInfo.environment["CLAUDE_CODE_OAUTH_TOKEN"] }
        self.fileProvider = { Self.realFileCredential() }
        self.vault = TokenVault(store: vaultStore)
        self.ladderRunner = { context, force in await ladder.run(context: context, force: force) }
        self.ladderSource = { await ladder.currentSource() }
        self.ladderInvalidator = { await ladder.invalidate() }
        self.interactiveRead = { Self.interactiveKeychainRead() }
        self.rawLadderRunner = { context, force in
            await ladder.readRaw(context: context, force: force)
        }
        self.interactiveRawRead = { Self.interactiveKeychainDataRead() }
        self.now = { Date() }
        self.devSkip = { ProcessInfo.processInfo.environment["TOKI_SKIP_ONBOARDING"] == "1" }
    }

    // MARK: Internal testability init

    /// Designated internal initializer used by tests. All providers are injected so tests
    /// never touch the real Keychain, filesystem, or environment.
    init(
        envProvider: @escaping EnvProvider,
        fileProvider: @escaping FileProvider,
        vault: TokenVault,
        ladderRunner: @escaping LadderRunner,
        ladderSource: @escaping LadderSourceProvider,
        interactiveRead: @escaping InteractiveReader,
        ladderInvalidator: @escaping LadderInvalidator = {},
        rawLadderRunner: @escaping RawLadderRunner = { _, _ in .blocked },
        interactiveRawRead: @escaping InteractiveRawReader = { nil },
        now: @escaping NowProvider = { Date() },
        devSkip: @escaping DevSkipProvider = { false }
    ) {
        self.envProvider = envProvider
        self.fileProvider = fileProvider
        self.vault = vault
        self.ladderRunner = ladderRunner
        self.ladderSource = ladderSource
        self.ladderInvalidator = ladderInvalidator
        self.interactiveRead = interactiveRead
        self.rawLadderRunner = rawLadderRunner
        self.interactiveRawRead = interactiveRawRead
        self.now = now
        self.devSkip = devSkip
    }

    // MARK: CredentialProviding

    public func currentCredential() async throws -> OAuthCredential {
        try await currentCredential(userInitiated: false)
    }

    /// - Parameter userInitiated: true only for explicit connection or access repair,
    ///   so the subprocess and — as a last resort —
    ///   the prompting read are allowed. Background callers must pass false: they may
    ///   never cause a dialog.
    public func currentCredential(userInitiated: Bool) async throws -> OAuthCredential {
        try await currentCredential(userInitiated: userInitiated, forceRefresh: false)
    }

    public func currentCredential(
        userInitiated: Bool, forceRefresh: Bool
    ) async throws -> OAuthCredential {
        let started = Date()
        let context: LadderContext = userInitiated ? .userInitiated : .background
        log.info(
            "CredentialStore: resolve started interaction=\(userInitiated) force=\(forceRefresh)"
        )

        // 1. Environment override.
        if let raw = envProvider() {
            return OAuthCredential(
                accessToken: raw, refreshToken: nil, expiresAt: nil, source: .environment
            )
        }

        // 2. The vault — the hot path, always silent. Ranked above the credentials file
        //    because Claude Code's own storage is Keychain-primary with the file as a
        //    fallback (verified against 2.1.223): a leftover file can hold a previous
        //    account's still-unexpired token and would otherwise shadow the live one.
        //
        //    Served only while Claude Code's item is unchanged. The cached token stays
        //    valid for ~8 h, so without this check signing into a different account is
        //    invisible for hours: the vault keeps answering with the previous account's
        //    token and the gauges keep showing the previous account's usage. The check is
        //    an attributes-only read — it never touches the secret and never prompts.
        if !forceRefresh, let payload = await vault.livePayload(now: now()) {
            if await sourceIsUnchanged(since: payload.source) {
                return payload.credential
            }
        }

        // 3. The ladder. Interaction permission and memo bypass are independent choices.
        let vaultGeneration = await vault.generation()
        let ladderResult = await ladderRunner(context, forceRefresh)
        switch ladderResult {
        case let .harvested(token, expiresAt, source):
            let resolvedAt = now()
            guard await ladderSource() == source,
                  await vault.accepts(token: token, expiresAt: expiresAt, now: resolvedAt),
                  await vault.capture(
                    accessToken: token, expiresAt: expiresAt, source: source, now: resolvedAt,
                    expectedGeneration: vaultGeneration
                  ) else {
                log.info("CredentialStore: harvested credential rejected")
                throw TokiError.credentialsNotFound
            }
            return OAuthCredential(
                accessToken: token, refreshToken: nil, expiresAt: expiresAt,
                source: .claudeKeychain
            )
        case .unsupportedLayout, .notFound, .blocked:
            break
        }

        let blocksUnconfirmedFallback = await vault.blocksUnconfirmedFallback()

        // 4. The credentials file — Claude Code's own fallback, so ours too. Only while its
        //    token is live: a stale leftover must not be served ahead of the vault's own.
        let file = blocksUnconfirmedFallback ? nil : fileProvider()
        if let file, Self.isLive(file, now: now()) {
            return file
        }

        // 5. The prompting read — user-initiated contexts only.
        if userInitiated, let sourceBefore = await ladderSource() {
            let interactiveGeneration = await vault.generation()
            if let prompted = interactiveRead() {
                let resolvedAt = now()
                guard await ladderSource() == sourceBefore,
                      Self.isLive(prompted, now: resolvedAt),
                      await vault.accepts(
                        token: prompted.accessToken, expiresAt: prompted.expiresAt, now: resolvedAt
                      ),
                      await vault.capture(
                        accessToken: prompted.accessToken, expiresAt: prompted.expiresAt,
                        source: sourceBefore, now: resolvedAt,
                        expectedGeneration: interactiveGeneration
                      ) else {
                    throw TokiError.credentialsNotFound
                }
                return prompted
            }
        }

        log.info(
            "CredentialStore: resolve unavailable interaction=\(userInitiated) force=\(forceRefresh) duration=\(Date().timeIntervalSince(started))"
        )
        if ladderResult == .blocked, await ladderSource() != nil {
            throw TokiError.keychainDenied
        }
        throw TokiError.credentialsNotFound
    }

    /// Returns Claude Code's complete credential JSON for account adoption or swap.
    /// Background reads only use the native noninteractive path. Explicit user actions
    /// may use the interactive fallback. The selected item must remain unchanged through
    /// the operation so data from a replaced account is never adopted.
    public func readRawCredential(
        userInitiated: Bool = false, forceRefresh: Bool = false
    ) async throws -> (json: Data, ref: KeychainItemRef) {
        let started = Date()
        let context: LadderContext = userInitiated ? .userInitiated : .background
        log.info(
            "CredentialStore: raw read started interaction=\(userInitiated) force=\(forceRefresh)"
        )
        let result = await rawLadderRunner(context, forceRefresh)
        switch result {
        case let .harvested(data, source):
            guard await ladderSource() == source else {
                log.error(
                    "CredentialStore: raw read rejected sourceChanged=true duration=\(Date().timeIntervalSince(started))"
                )
                throw TokiError.credentialsNotFound
            }
            log.info(
                "CredentialStore: raw read completed path=noninteractive generation=\(source.modifiedAt) duration=\(Date().timeIntervalSince(started))"
            )
            return (data, source)
        case .notFound, .blocked:
            break
        }

        if userInitiated,
           let sourceBefore = await ladderSource(),
           let data = interactiveRawRead(),
           await ladderSource() == sourceBefore {
            log.info(
                "CredentialStore: raw read completed path=interactive generation=\(sourceBefore.modifiedAt) duration=\(Date().timeIntervalSince(started))"
            )
            return (data, sourceBefore)
        }
        log.info(
            "CredentialStore: raw read unavailable interaction=\(userInitiated) duration=\(Date().timeIntervalSince(started))"
        )
        if result == .blocked, await ladderSource() != nil {
            throw TokiError.keychainDenied
        }
        throw TokiError.credentialsNotFound
    }

    public func invalidateCache() async {
        await vault.clear()
        await ladderInvalidator()
    }

    /// Records that `credential` was rejected with a 401 so the next resolution does not
    /// hand back the same dead token. Source-aware: only vault-backed tokens are marked.
    public func markCredentialRejected(_ credential: OAuthCredential) async {
        guard credential.source.isVaultBacked else { return }
        await vault.markDead(token: credential.accessToken)
    }

    /// Drops the cached token after an account swap: it belonged to the previous account.
    ///
    /// The actor installs an in-memory barrier before attempting persistent deletion, so a
    /// Keychain error cannot resurrect the previous account's token during this process.
    public func invalidateVault() async {
        await vault.clear()
    }

    /// Direct noninteractive read. Callers needing an authorized CLI fallback use
    /// CredentialVerificationReader instead.
    public static func silentRead(_ ref: KeychainItemRef) -> Data? { silentItemRead(ref) }

    // MARK: CredentialOnboarding

    /// Mirrors the resolution pipeline exactly, without ever prompting, so the onboarding
    /// gate and the resolver can never disagree about whether credentials are available.
    public func accessState() async -> CredentialAccessState {
        // Dev override: re-signing during local development invalidates the Keychain ACL
        // entry on every rebuild, which would otherwise nag.
        if devSkip() { return .available }

        if envProvider() != nil { return .available }
        if let payload = await vault.livePayload(now: now()),
           await sourceIsUnchanged(since: payload.source) {
            return .available
        }

        let ladderState: CredentialAccessState
        let vaultGeneration = await vault.generation()
        switch await ladderRunner(.background, false) {
        case let .harvested(token, expiresAt, source):
            let resolvedAt = now()
            guard await ladderSource() == source,
                  await vault.accepts(token: token, expiresAt: expiresAt, now: resolvedAt),
                  await vault.capture(
                    accessToken: token, expiresAt: expiresAt, source: source, now: resolvedAt,
                    expectedGeneration: vaultGeneration
                  ) else {
                return .needsAuthorization
            }
            return .available
        case .unsupportedLayout:
            ladderState = .unsupportedLayout
        case .notFound:
            ladderState = .notFound
        case .blocked:
            ladderState = .needsAuthorization
        }

        // The file is consulted only after the Keychain paths, matching `currentCredential`.
        // Its verdict still wins over the ladder's failure: a live file means Toki can work.
        let blocksUnconfirmedFallback = await vault.blocksUnconfirmedFallback()
        if !blocksUnconfirmedFallback,
           let file = fileProvider(), Self.isLive(file, now: now()) { return .available }
        return ladderState
    }

    // MARK: Helpers

    /// Whether Claude Code's credential item still looks exactly as it did when the
    /// cached token was harvested.
    ///
    /// Compares the whole item identity, not just the modification date: a different
    /// service or account means a different item was selected, which is as much a change
    /// as a rewrite. A missing item is unknown provenance and therefore fails closed.
    private func sourceIsUnchanged(since captured: KeychainItemRef) async -> Bool {
        guard let current = await ladderSource() else { return false }
        return current == captured
    }

    private static func isLive(_ credential: OAuthCredential, now: Date) -> Bool {
        guard let expiresAt = credential.expiresAt else { return true }
        return now < expiresAt.addingTimeInterval(-VaultPayload.expiryGuard)
    }

    // MARK: JSON parsing (internal, pure — tested in isolation)

    /// Parses a `{ claudeAiOauth: { accessToken, refreshToken, expiresAt, scopes } }` JSON
    /// blob into an `OAuthCredential`.
    ///
    /// - Parameters:
    ///   - data: Raw UTF-8 JSON bytes from the Keychain or credentials file.
    ///   - source: Provenance to tag the resulting credential with.
    /// - Returns: A populated `OAuthCredential`.
    /// - Throws: `TokiError.credentialsNotFound` when the `claudeAiOauth` key is absent,
    ///   or `TokiError.decoding(_)` when the JSON is malformed.
    static func parseCredentialJSON(
        _ data: Data, source: CredentialSource = .claudeKeychain
    ) throws -> OAuthCredential {
        let decoder = JSONDecoder()
        let file: CredentialFile
        do {
            file = try decoder.decode(CredentialFile.self, from: data)
        } catch {
            log.error("CredentialStore: credential JSON decode failed \(error: error)")
            throw TokiError.decoding("CredentialStore: JSON decode failed: \(error)")
        }

        guard let entry = file.claudeAiOauth else {
            throw TokiError.credentialsNotFound
        }

        let expiresAt = entry.expiresAt.map { Date(timeIntervalSince1970: $0 / 1000.0) }
        return OAuthCredential(
            accessToken: entry.accessToken,
            refreshToken: entry.refreshToken,
            expiresAt: expiresAt,
            source: source
        )
    }

    // MARK: Real Keychain implementations

    /// Attributes-only enumeration: no `kSecReturnData`, so it can never prompt. This is
    /// what makes change detection free — the modification date comes back with it.
    static func enumerateClaudeItems() -> [KeychainItemRef] {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecMatchLimit: kSecMatchLimitAll,
            kSecReturnAttributes: true,
        ]
        let outcome = KeychainInteractionGuard.performSerialized {
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            return (status, result)
        }
        guard outcome.0 == errSecSuccess,
              let items = outcome.1 as? [[CFString: Any]]
        else { return [] }
        return KeychainItemRef.from(attributes: items)
    }

    /// Step (a) of the ladder: a data read that returns `errSecInteractionNotAllowed`
    /// instead of presenting UI. Succeeds while a previous "Always Allow" ACL entry
    /// survives. The supported way to suppress the dialog is an `LAContext` with
    /// `interactionNotAllowed` (`kSecUseAuthenticationUIFail` is deprecated since macOS 11).
    static func silentItemRead(_ ref: KeychainItemRef) -> Data? {
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: ref.service,
            kSecAttrAccount: ref.account,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecReturnData: true,
            kSecUseAuthenticationContext: context,
        ]
        guard let outcome = KeychainInteractionGuard.performNoninteractive(operation: {
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            return (status, result as? Data)
        }) else {
            log.error("CredentialStore: silent SecItem read could not install interaction guard")
            return nil
        }
        let (status, data) = outcome
        guard status == errSecSuccess else {
            // errSecInteractionNotAllowed here is the expected, silent "no surviving ACL
            // entry" case, not a surprise — logged at .info rather than .error so it does
            // not read as a problem on every poll where the ladder falls through to the CLI.
            log.info("CredentialStore: silent SecItem read did not yield data status=\(Int(status))")
            return nil
        }
        return data
    }

    /// The one path that may present the macOS dialog. Reached only from a user action.
    static func interactiveKeychainRead() -> OAuthCredential? {
        guard let data = interactiveKeychainDataRead() else { return nil }
        do {
            return try parseCredentialJSON(data)
        } catch {
            log.error("CredentialStore: interactive read parse failed \(error: error)")
            return nil
        }
    }

    static func interactiveKeychainDataRead() -> Data? {
        guard let ref = KeychainItemRef.select(from: enumerateClaudeItems()) else {
            log.info("CredentialStore: interactive read found no Claude Code item")
            return nil
        }
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: ref.service,
            kSecAttrAccount: ref.account,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecReturnData: true,
        ]
        let outcome = KeychainInteractionGuard.performSerialized {
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            return (status, result as? Data)
        }
        guard outcome.0 == errSecSuccess, let data = outcome.1 else {
            log.error("CredentialStore: interactive read failed status=\(Int(outcome.0))")
            return nil
        }
        return data
    }

    // MARK: Real file implementation

    static func realFileCredential() -> OAuthCredential? {
        let credURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude")
            .appendingPathComponent(".credentials.json")
        let data: Data
        do {
            data = try Data(contentsOf: credURL)
        } catch {
            // The fallback file legitimately does not exist for most of the resolution
            // chain's callers (steps 1-3 usually satisfy the request first), so this is
            // logged at .debug rather than a level that would read as a real problem.
            log.debug("CredentialStore: fallback credentials file unreadable \(error: error)")
            return nil
        }
        do {
            return try parseCredentialJSON(data, source: .file)
        } catch {
            log.error("CredentialStore: fallback credentials file parse failed \(error: error)")
            return nil
        }
    }
}
