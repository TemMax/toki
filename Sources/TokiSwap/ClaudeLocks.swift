/// Claude Code's own lock protocol, reimplemented so a swap can never land inside
/// one of its credential mutations.
import Foundation
import TokiLogging

private let log = TokiLog.logger("swap")

public struct LockDescriptor: Sendable, Equatable {
    public let path: URL
    /// A lock whose mtime is older than this belongs to a dead process.
    public let staleAfter: TimeInterval
    /// While held, the mtime is touched this often so nobody judges it stale.
    public let updateEvery: TimeInterval

    public init(path: URL, staleAfter: TimeInterval, updateEvery: TimeInterval) {
        self.path = path
        self.staleAfter = staleAfter
        self.updateEvery = updateEvery
    }
}

/// The lock files Claude Code 2.1.223 actually uses, with its own timings.
public enum ClaudeLocks {
    /// Wraps every credential write to secure storage — the lock that matters for a swap.
    public static func storageWrite(configDir: URL) -> LockDescriptor {
        LockDescriptor(
            path: configDir.appendingPathComponent(".storage-write"),
            staleAfter: 15, updateEvery: 5
        )
    }

    /// Wraps Claude Code's read→refresh→save cycle.
    public static func oauthRefresh(configDir: URL) -> LockDescriptor {
        LockDescriptor(
            path: configDir.appendingPathComponent(".oauth_refresh.lock"),
            staleAfter: 60, updateEvery: 5
        )
    }

    /// Toki' own cross-process lock: a Debug build and the installed Release must not
    /// interleave sync-back and write the live credential into the wrong slot.
    public static func tokiSwap(configDir: URL) -> LockDescriptor {
        LockDescriptor(
            path: configDir.appendingPathComponent(".toki-swap.lock"),
            staleAfter: 60, updateEvery: 5
        )
    }
}

public struct LockToken: Sendable, Equatable {
    let path: URL
    let id: UUID
}

public enum LockError: Error, Equatable {
    case busy(URL)
}

/// proper-lockfile's ownership stamp, written inside the lock directory by whoever
/// created it. `.storage-write` goes stale after 15 s, which a lid close or a scheduler
/// stall exceeds easily; without the stamp a holder whose lock was broken meanwhile
/// would delete the directory of whoever re-acquired it, and two writers would run
/// against the credential item at once.
let lockOwnerStampName = "toki-lock-owner"

/// `nil` for a lock created by anyone but us — Claude Code's own locks are unstamped.
func lockOwner(at path: URL) -> UUID? {
    guard
        // no-log: an unstamped lock is Claude Code's own, and a missing stamp is the
        // routine answer to "is this ours?", not a failure worth a line.
        let data = try? Data(contentsOf: path.appendingPathComponent(lockOwnerStampName)),
        let text = String(data: data, encoding: .utf8)
    else { return nil }
    return UUID(uuidString: text.trimmingCharacters(in: .whitespacesAndNewlines))
}

/// Acquires and holds locks using proper-lockfile semantics: the lock IS a directory,
/// created with `mkdir` (atomic), refreshed by touching its mtime, broken when stale.
public actor LockBroker {
    private var refreshers: [UUID: Task<Void, Never>] = [:]
    private let clock: @Sendable () -> Date

    public init(clock: @escaping @Sendable () -> Date = { Date() }) {
        self.clock = clock
    }

    public func acquire(_ descriptor: LockDescriptor, timeout: TimeInterval) async throws -> LockToken {
        let deadline = clock().addingTimeInterval(timeout)
        repeat {
            let id = UUID()
            if tryCreate(descriptor.path, owner: id) {
                let token = LockToken(path: descriptor.path, id: id)
                startRefreshing(token, every: descriptor.updateEvery)
                log.info("lock acquired \(path: descriptor.path)")
                return token
            }
            if breakIfStale(descriptor) { continue }
            // no-log: the only error is this task's own cancellation, which the loop
            // condition handles and which says nothing about the lock.
            try? await Task.sleep(for: .milliseconds(100))
        } while clock() < deadline

        log.notice("lock refused after \(timeout)s of contention \(path: descriptor.path)")
        throw LockError.busy(descriptor.path)
    }

    public func release(_ token: LockToken) {
        refreshers[token.id]?.cancel()
        refreshers[token.id] = nil
        // Our lock may have been broken as stale and re-acquired by someone else while
        // we held the token; deleting by path alone would hand them a lock we own.
        guard lockOwner(at: token.path) == token.id else {
            log.notice("lock not released: it was broken and re-acquired meanwhile \(path: token.path)")
            return
        }
        do {
            try FileManager.default.removeItem(at: token.path)
            log.info("lock released \(path: token.path)")
        } catch {
            log.notice("""
                lock directory could not be removed and will block until it goes stale \
                code=\((error as NSError).code) \(path: token.path)
                """)
        }
    }

    private func tryCreate(_ path: URL, owner: UUID) -> Bool {
        do {
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
        } catch {
            // Expected under normal operation: somebody else holds this lock.
            log.info("lock is held by another process \(path: path)")
            return false
        }
        do {
            try Data(owner.uuidString.utf8).write(to: path.appendingPathComponent(lockOwnerStampName))
            return true
        } catch {
            log.notice("lock owner stamp could not be written code=\((error as NSError).code) \(path: path)")
            // An unstamped lock could never be released safely, so give it straight back.
            do {
                try FileManager.default.removeItem(at: path)
            } catch {
                log.error("""
                    an unstamped lock directory could not be removed and will block every swap \
                    until it goes stale code=\((error as NSError).code) \(path: path)
                    """)
            }
            return false
        }
    }

    private func breakIfStale(_ descriptor: LockDescriptor) -> Bool {
        let owner = lockOwner(at: descriptor.path)
        guard
            let modified = modificationDate(of: descriptor.path),
            clock().timeIntervalSince(modified) > descriptor.staleAfter
        else { return false }
        // Re-check owner and mtime right before deleting: between the two stats the
        // holder may have refreshed the lock, or a third process may have broken and
        // re-acquired it. The window cannot be closed without an atomic primitive —
        // `release`'s ownership check is what keeps whatever slips through harmless.
        guard
            lockOwner(at: descriptor.path) == owner,
            modificationDate(of: descriptor.path) == modified
        else { return false }
        do {
            try FileManager.default.removeItem(at: descriptor.path)
            log.notice("broke a lock left behind by a dead holder \(path: descriptor.path)")
        } catch {
            log.notice("""
                a stale lock could not be broken code=\((error as NSError).code) \
                \(path: descriptor.path)
                """)
        }
        return true
    }

    private func modificationDate(of path: URL) -> Date? {
        // no-log: a missing lock directory is the ordinary answer here, not a failure.
        let attrs = try? FileManager.default.attributesOfItem(atPath: path.path)
        return attrs?[.modificationDate] as? Date
    }

    private func startRefreshing(_ token: LockToken, every interval: TimeInterval) {
        refreshers[token.id] = Task.detached { [path = token.path, id = token.id] in
            while !Task.isCancelled {
                // no-log: the only error is this task's own cancellation, checked below.
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { return }
                // Once the lock has been broken and re-created it belongs to someone
                // else; keeping its mtime fresh would prop up a stranger's lock.
                guard lockOwner(at: path) == id else { return }
                do {
                    try FileManager.default.setAttributes(
                        [.modificationDate: Date()], ofItemAtPath: path.path
                    )
                } catch {
                    log.notice("""
                        held lock could not be kept fresh and may be broken as stale \
                        code=\((error as NSError).code) \(path: path)
                        """)
                }
            }
        }
    }
}
