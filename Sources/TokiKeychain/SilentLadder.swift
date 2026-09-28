/// Access-checked read path for Claude Code's Keychain item.
import Foundation
import TokiModels
import TokiLogging

private let log = TokiLog.logger("keychain")

enum LadderResult: Sendable, Equatable {
    /// A token was read silently.
    case harvested(token: String, expiresAt: Date?, from: KeychainItemRef)
    /// The item exists but carries no `claudeAiOauth` block (unsupported Claude Code layout).
    case unsupportedLayout
    /// No Claude Code credential item exists.
    case notFound
    /// No read path was authorized in this context.
    case blocked
}

enum RawCredentialResult: Sendable, Equatable {
    case harvested(data: Data, from: KeychainItemRef)
    case notFound
    case blocked
}

/// Runs the read steps in order and remembers what it already harvested.
///
/// The memo is the reason an idle Claude Code costs nothing: once a given modification
/// date has been harvested (or found unreadable in a non-blocking way), the ladder
/// short-circuits until that date changes. Without it, a machine whose token expired
/// while Claude Code was not running would re-read the Keychain on every poll forever.
actor SilentLadder {
    private let enumerate: @Sendable () -> [KeychainItemRef]
    private let silentRead: @Sendable (KeychainItemRef) -> Data?
    private let cliRead: @Sendable (KeychainItemRef, LadderContext) async -> Data?

    private var memo: (source: KeychainItemRef, result: LadderResult)?

    init(
        enumerate: @escaping @Sendable () -> [KeychainItemRef],
        silentRead: @escaping @Sendable (KeychainItemRef) -> Data?,
        cliRead: @escaping @Sendable (KeychainItemRef, LadderContext) async -> Data?
    ) {
        self.enumerate = enumerate
        self.silentRead = silentRead
        self.cliRead = cliRead
    }

    /// The Claude Code item currently selected, for prompt-free change detection.
    func currentSource() -> KeychainItemRef? {
        KeychainItemRef.select(from: enumerate())
    }

    func invalidate() {
        memo = nil
    }

    func run(context: LadderContext, force: Bool) async -> LadderResult {
        guard let source = KeychainItemRef.select(from: enumerate()) else {
            log.info("SilentLadder: rung attempted → no Claude Code item found")
            return .notFound
        }

        if !force, let memo, memo.source == source {
            log.debug("SilentLadder: rung served from memo")
            return memo.result
        }

        let result = await read(source, context: context)
        guard KeychainItemRef.select(from: enumerate()) == source else {
            log.info("SilentLadder: source changed during read")
            return .blocked
        }
        switch result {
        case .harvested:
            log.info("SilentLadder: rung attempted → harvested")
        case .unsupportedLayout:
            log.info("SilentLadder: rung attempted → unsupported layout")
        case .notFound:
            log.info("SilentLadder: rung attempted → not found")
        case .blocked:
            log.info("SilentLadder: rung attempted → blocked")
        }
        // `blocked` is contextual, not a property of the item: memoizing it would suppress
        // the later user-initiated attempt that could succeed.
        if result != .blocked {
            memo = (source, result)
        }
        return result
    }

    /// Reads the complete credential document for account capture. This intentionally
    /// bypasses the access-token memo because adoption also needs refresh-token fields.
    func readRaw(context: LadderContext, force: Bool) async -> RawCredentialResult {
        guard let source = KeychainItemRef.select(from: enumerate()) else { return .notFound }
        if let data = silentRead(source) {
            guard KeychainItemRef.select(from: enumerate()) == source else { return .blocked }
            return .harvested(data: data, from: source)
        }
        if let data = await cliRead(source, context) {
            guard KeychainItemRef.select(from: enumerate()) == source else { return .blocked }
            return .harvested(data: data, from: source)
        }
        return .blocked
    }

    private func read(_ source: KeychainItemRef, context: LadderContext) async -> LadderResult {
        if let data = silentRead(source) {
            log.info("SilentLadder: silent SecItem rung succeeded")
            return Self.interpret(data, source: source)
        }
        if let data = await cliRead(source, context) {
            log.info("SilentLadder: security CLI rung succeeded")
            return Self.interpret(data, source: source)
        }
        log.info("SilentLadder: both silent and CLI rungs failed")
        return .blocked
    }

    private static func interpret(_ data: Data, source: KeychainItemRef) -> LadderResult {
        do {
            let credential = try CredentialStore.parseCredentialJSON(data)
            return .harvested(
                token: credential.accessToken, expiresAt: credential.expiresAt, from: source
            )
        } catch {
            // The item is there but holds no readable `claudeAiOauth` block — e.g. a Claude
            // Code version that keeps only `mcpOAuth` here. Distinct from "not logged in".
            log.info("SilentLadder: item found but unsupported layout \(error: error)")
            return .unsupportedLayout
        }
    }
}
