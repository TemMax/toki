import Testing
import Foundation
@testable import TokiSwap

private func tempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("toki-locks-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite("ClaudeLocks")
struct ClaudeLocksTests {

    @Test("lock file names and timings match Claude Code 2.1.223")
    func descriptorsMatchClaudeCode() throws {
        let dir = URL(fileURLWithPath: "/tmp/cfg")
        let storage = ClaudeLocks.storageWrite(configDir: dir)
        #expect(storage.path.lastPathComponent == ".storage-write")
        #expect(storage.staleAfter == 15)
        let refresh = ClaudeLocks.oauthRefresh(configDir: dir)
        #expect(refresh.path.lastPathComponent == ".oauth_refresh.lock")
        #expect(refresh.staleAfter == 60)
        #expect(refresh.updateEvery == 5)
    }

    @Test("acquiring creates the lock directory and releasing removes it")
    func acquireCreatesDirectory() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let broker = LockBroker()
        let descriptor = ClaudeLocks.storageWrite(configDir: dir)

        let token = try await broker.acquire(descriptor, timeout: 1)
        #expect(FileManager.default.fileExists(atPath: descriptor.path.path))
        await broker.release(token)
        #expect(!FileManager.default.fileExists(atPath: descriptor.path.path))
    }

    @Test("a lock held by someone else makes acquisition fail, not corrupt")
    func contentionFails() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let descriptor = ClaudeLocks.storageWrite(configDir: dir)
        // Simulate Claude Code holding its own write lock right now.
        try FileManager.default.createDirectory(at: descriptor.path, withIntermediateDirectories: false)

        let broker = LockBroker()
        await #expect(throws: LockError.busy(descriptor.path)) {
            _ = try await broker.acquire(descriptor, timeout: 0.3)
        }
    }

    @Test("a stale lock is broken and re-acquired")
    func staleLockIsBroken() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let descriptor = ClaudeLocks.storageWrite(configDir: dir)
        try FileManager.default.createDirectory(at: descriptor.path, withIntermediateDirectories: false)
        // Age it past the staleness window — a crashed process leaves exactly this.
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-120)], ofItemAtPath: descriptor.path.path
        )

        let broker = LockBroker()
        let token = try await broker.acquire(descriptor, timeout: 1)
        await broker.release(token)
    }

    @Test("a held lock keeps its mtime fresh so others do not judge it stale")
    func heldLockIsRefreshed() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        var descriptor = ClaudeLocks.storageWrite(configDir: dir)
        descriptor = LockDescriptor(path: descriptor.path, staleAfter: 15, updateEvery: 0.1)

        let broker = LockBroker()
        let token = try await broker.acquire(descriptor, timeout: 1)

        func mtime() -> Date? {
            try? FileManager.default
                .attributesOfItem(atPath: descriptor.path.path)[.modificationDate] as? Date
        }
        let first = mtime()

        // Poll for the refresh rather than sleeping a fixed 350ms and asserting once.
        //
        // The fixed sleep failed roughly two runs in three when the whole suite ran in
        // parallel: the 100ms refresh task simply did not get scheduled inside the window
        // on a saturated machine. In isolation it passed every time — which is the signature
        // of a timing-sensitive test, not of a broken refresher. Production uses
        // `updateEvery: 5` against `staleAfter: 15`, a margin this test's 3.5x does not have.
        //
        // Waiting for the condition keeps the assertion exactly as strong (the mtime must
        // actually advance) while removing the dependency on scheduler latency.
        var second = first
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
            second = mtime()
            if let second, let first, second > first { break }
        }
        await broker.release(token)

        #expect(first != nil && second != nil)
        #expect(second! > first!, "the held lock's mtime never advanced within 5s")
    }

    @Test("a holder whose lock was broken as stale cannot delete the new holder's lock")
    func releaseOnlyDeletesItsOwnLock() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // `updateEvery` is long enough that the first holder's refresher never fires and
        // undoes the ageing below — a lid close or a stalled scheduler looks the same.
        let descriptor = LockDescriptor(
            path: dir.appendingPathComponent(".storage-write"), staleAfter: 15, updateEvery: 600
        )

        let first = LockBroker()
        let firstToken = try await first.acquire(descriptor, timeout: 1)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-120)], ofItemAtPath: descriptor.path.path
        )

        let second = LockBroker()
        let secondToken = try await second.acquire(descriptor, timeout: 1)
        #expect(lockOwner(at: descriptor.path) == secondToken.id)

        await first.release(firstToken)

        #expect(FileManager.default.fileExists(atPath: descriptor.path.path))
        #expect(lockOwner(at: descriptor.path) == secondToken.id)

        await second.release(secondToken)
        #expect(!FileManager.default.fileExists(atPath: descriptor.path.path))
    }
}
