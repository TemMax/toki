import Foundation
import TokiCore
import TokiAccounts

private let log = TokiLog.logger("accounts")

/// Watches `~/.claude.json` for account changes and reports them near-instantly.
///
/// The signed-in account is named by `oauthAccount.accountUuid`, which Claude Code writes on
/// `/login` (verified — it is the same field the whole feature keys on). Watching the file
/// via kqueue is instant, needs no polling, and never touches the Keychain, so it cannot
/// prompt. There is deliberately no attempt to watch the credential Keychain item: macOS has
/// no reliable API for that, and the config is the authority anyway.
///
/// The raw file-system watching lives in `FileWatcher`; this type adds the two things that
/// make it usable: it reads only the account and organization ids (off the main actor — the file is ~120 KB),
/// and it deduplicates via `AccountChangeDecision`, so the constant unrelated rewrites Claude
/// Code makes to this file don't turn into a storm of work.
@MainActor
final class ClaudeConfigWatcher {
    private let configURL: URL
    private let storedUuids: @Sendable () async -> Set<String>
    private let onChange: @MainActor (AccountChange) -> Void
    private var watcher: FileWatcher?
    /// The account we last acted on. Seeded with the account already signed in at start, so
    /// launching the app is never mistaken for a fresh login.
    private var lastSeen: UsageAccount?
    private var lifecycle: UInt64 = 0
    private var revision: UInt64 = 0

    private enum ConfigRead: Sendable {
        case identity(UsageAccount?)
        case unreadable
    }

    init(
        configURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude.json"),
        storedUuids: @escaping @Sendable () async -> Set<String>,
        onChange: @escaping @MainActor (AccountChange) -> Void
    ) {
        self.configURL = configURL
        self.storedUuids = storedUuids
        self.onChange = onChange
    }

    func start() {
        stop()
        let startedLifecycle = lifecycle
        Task { @MainActor in
            let initial = await Self.readIdentity(configURL)
            guard lifecycle == startedLifecycle else { return }
            if case let .identity(identity) = initial { lastSeen = identity }
            let watcher = FileWatcher(url: configURL, debounce: 0.3) { [weak self] in
                Task { @MainActor in await self?.handleChange() }
            }
            self.watcher = watcher
            watcher.start()
            // Close the gap between reading the initial value and registering kqueue.
            await handleChange()
        }
    }

    func stop() {
        lifecycle &+= 1
        watcher?.stop()
        watcher = nil
    }

    private func handleChange() async {
        revision &+= 1
        let startedRevision = revision
        let startedLifecycle = lifecycle
        let read = await Self.readIdentity(configURL)
        guard startedRevision == revision, startedLifecycle == lifecycle,
              case let .identity(identity) = read,
              identity != lastSeen else { return }
        let stored = await storedUuids()
        guard startedRevision == revision, startedLifecycle == lifecycle else { return }
        let decision = AccountChangeDecision.decide(
            newIdentity: identity, lastSeenIdentity: lastSeen, storedUuids: stored
        )
        lastSeen = identity
        onChange(decision)
    }

    /// Missing oauthAccount in valid JSON is logout. A malformed in-progress write is
    /// distinct and does not invent a new identity. Only identity fields are retained.
    private static func readIdentity(_ url: URL) async -> ConfigRead {
        await Task.detached(priority: .utility) {
            do {
                let data = try Data(contentsOf: url)
                guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return ConfigRead.unreadable
                }
                guard let oauth = root["oauthAccount"] as? [String: Any],
                      let identity = AccountIdentity.parse(oauthAccount: oauth) else {
                    return .identity(nil)
                }
                return .identity(UsageAccount(
                    accountUuid: identity.accountUuid, organizationUuid: identity.organizationUuid
                ))
            } catch CocoaError.fileReadNoSuchFile {
                log.debug("readIdentity: config removed; treating it as signed out")
                return .identity(nil)
            } catch {
                log.debug("readIdentity: config unreadable on this read: \(error: error)")
                return .unreadable
            }
        }.value
    }
}

/// Codex counterpart to `ClaudeConfigWatcher`. It watches only auth.json's stable identity
/// fingerprint; token bytes are never retained, surfaced or logged.
@MainActor
final class CodexAuthWatcher {
    private let authURL: URL
    private let storedIDs: @Sendable () async -> Set<String>
    private let onChange: @MainActor (AccountChange) -> Void
    private var watcher: FileWatcher?
    private var lastSeen: String?

    init(
        authURL: URL = CodexAuthFile.liveURL(),
        storedIDs: @escaping @Sendable () async -> Set<String>,
        onChange: @escaping @MainActor (AccountChange) -> Void
    ) {
        self.authURL = authURL
        self.storedIDs = storedIDs
        self.onChange = onChange
    }

    func start() {
        Task { @MainActor in
            lastSeen = await Self.readIdentityID(authURL)
            let watcher = FileWatcher(url: authURL, debounce: 0.3) { [weak self] in
                Task { @MainActor in await self?.handleChange() }
            }
            self.watcher = watcher
            watcher.start()
        }
    }

    func stop() {
        watcher?.stop()
        watcher = nil
    }

    private func handleChange() async {
        let newID = await Self.readIdentityID(authURL)
        let decision = AccountChangeDecision.decide(
            newUuid: newID,
            lastSeenUuid: lastSeen,
            storedUuids: await storedIDs()
        )
        if decision != .ignore { lastSeen = newID }
        onChange(decision)
    }

    private static func readIdentityID(_ url: URL) async -> String? {
        await Task.detached(priority: .utility) {
            do {
                let data = try CodexAuthFile.read(from: url)
                return try CodexAuthBlob.identity(from: data).id
            } catch {
                // Atomic auth-file replacement can make a watcher read land between the
                // rename and settle events. The next callback retries, so this is debug.
                log.debug("Codex auth identity unreadable on this watcher pass: \(error: error)")
                return nil
            }
        }.value
    }
}

/// kqueue-based single-file watcher. Re-arms across atomic renames (a temp-file + rename,
/// which is how safe writers — including Toki — replace a file) and coalesces write bursts
/// into one settled callback. Proven against a temp file before shipping: 30 writes collapsed
/// to a handful of callbacks, and the watch survived every atomic replace.
final class FileWatcher: @unchecked Sendable {
    private let url: URL
    private let debounce: TimeInterval
    private let onSettled: @Sendable () -> Void
    private let queue = DispatchQueue(label: "dev.komar.toki.filewatch")
    private var source: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1
    private var pending: DispatchWorkItem?
    private var stopped = false

    init(url: URL, debounce: TimeInterval, onSettled: @escaping @Sendable () -> Void) {
        self.url = url
        self.debounce = debounce
        self.onSettled = onSettled
    }

    func start() { queue.async { self.arm() } }

    func stop() {
        queue.async {
            self.stopped = true
            self.pending?.cancel()
            self.source?.cancel()
            self.source = nil
        }
    }

    private func arm() {
        guard !stopped else { return }
        fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else {
            // Missing auth.json is a normal, potentially long-lived state for a
            // keyring-backed Codex login. One retry per second still notices a new file
            // promptly without turning that state into a 20 Hz filesystem poll.
            queue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.arm() }
            return
        }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename, .delete, .attrib],
            queue: queue
        )
        src.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = src.data
            self.scheduleSettled()
            // An atomic write replaces the inode; the old fd is now dead, so re-arm.
            if flags.contains(.rename) || flags.contains(.delete) { src.cancel() }
        }
        src.setCancelHandler { [weak self] in
            guard let self else { return }
            if self.fd >= 0 { close(self.fd); self.fd = -1 }
            // A cancel from stop() clears `source`; a cancel from a rename leaves it set, which
            // is the signal to re-arm on the replacement file.
            if self.source != nil { self.source = nil; self.arm() }
        }
        source = src
        src.resume()
    }

    private func scheduleSettled() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onSettled() }
        pending = work
        queue.asyncAfter(deadline: .now() + debounce, execute: work)
    }
}
