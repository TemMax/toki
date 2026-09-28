/// Where a finished, already-scrubbed line goes.
///
/// Taken from swift-log's `LogHandler` idea, minus everything a menu-bar app does not need.
/// A sink NEVER scrubs: `TokiLog` runs `Redactor` once over the whole line before handing it
/// out, so a new sink cannot forget to.
import Foundation
import os

public protocol LogSink: Sendable {
    func write(_ line: String)
    func flush()
}

// MARK: - File

/// Owns the log directory: the current day's file, size rotation, and pruning.
///
/// Every write hops onto one serial queue, so ordering holds no matter which thread or actor
/// logged, and no caller ever blocks on disk I/O — a `catch` block in the credential refresh
/// path must not pay for an `fsync`. `flush()` is the synchronous barrier for the cases that
/// do need the bytes on disk (export, app termination).
public final class FileLogSink: LogSink, @unchecked Sendable {

    private let queue = DispatchQueue(label: "dev.komar.toki.logging")
    private let directory: URL
    private let policy: LogFileStore.Policy
    private let calendar: Calendar
    private let fileManager = FileManager.default

    // Everything below is touched only on `queue`.
    private var handle: FileHandle?
    private var currentDay: Date?
    private var currentIndex = 0
    private var currentBytes = 0

    public init(directory: URL,
                policy: LogFileStore.Policy = .init(),
                calendar: Calendar = .current) {
        self.directory = directory
        self.policy = policy
        self.calendar = calendar
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit { try? handle?.close() }

    public func write(_ line: String) {
        let payload = Data((line + "\n").utf8)
        queue.async { [self] in
            let today = calendar.startOfDay(for: Date())
            if currentDay != today {
                // A relaunch lands here, and the day's highest file may already be over the
                // cap from the previous session — so re-check the size after opening rather
                // than trusting that a fresh day means a fresh file.
                openFile(day: today, index: highestExistingIndex(for: today))
                if currentBytes + payload.count > policy.maxFileBytes {
                    openFile(day: today, index: currentIndex + 1)
                }
                prune(today: today)
            } else if currentBytes + payload.count > policy.maxFileBytes {
                openFile(day: today, index: currentIndex + 1)
                prune(today: today)
            }
            guard let handle else { return }
            do {
                try handle.write(contentsOf: payload)
                currentBytes += payload.count
            } catch {
                // A log line that cannot be written must never take the app down, and there
                // is nowhere left to report it to.
            }
        }
    }

    /// Synchronous barrier: returns only once everything queued before it is on disk.
    public func flush() {
        queue.sync { [self] in
            try? handle?.synchronize()
        }
    }

    // MARK: - Private (queue-confined)

    private func listing() -> [LogFileInfo] {
        let names = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.compactMap { name in
            guard let parsed = LogFileStore.parse(fileName: name, calendar: calendar) else { return nil }
            let attributes = try? fileManager.attributesOfItem(
                atPath: directory.appendingPathComponent(name).path)
            let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
            return LogFileInfo(name: name, date: parsed.date, index: parsed.index, byteSize: size)
        }
    }

    private func highestExistingIndex(for day: Date) -> Int {
        listing().filter { $0.date == day }.map(\.index).max() ?? 0
    }

    private func openFile(day: Date, index: Int) {
        try? handle?.close()
        handle = nil

        let name = LogFileStore.fileName(date: day, index: index, calendar: calendar)
        let url = directory.appendingPathComponent(name)
        if !fileManager.fileExists(atPath: url.path) {
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            fileManager.createFile(atPath: url.path, contents: nil)
        }
        guard let opened = try? FileHandle(forWritingTo: url) else { return }
        let end = (try? opened.seekToEnd()) ?? 0

        handle = opened
        currentDay = day
        currentIndex = index
        currentBytes = Int(end)
    }

    private func prune(today: Date) {
        let doomed = LogFileStore.filesToPrune(listing(), today: today,
                                               policy: policy, calendar: calendar)
        for file in doomed {
            try? fileManager.removeItem(at: directory.appendingPathComponent(file.name))
        }
    }
}

// MARK: - os.Logger

/// Mirrors the line into the unified log, so Console.app and a sysdiagnose see it too.
///
/// `%{public}@` is correct here and only here: the line arriving has already been through
/// `Redactor`. Marking it private instead would make it `<private>` in every export, which
/// is precisely the reason this module is not built on `os.Logger` alone.
public struct OSLogSink: LogSink {
    private let logger: os.Logger

    public init(subsystem: String = "dev.komar.toki", category: String = "toki") {
        self.logger = os.Logger(subsystem: subsystem, category: category)
    }

    public func write(_ line: String) {
        logger.log("\(line, privacy: .public)")
    }

    /// The unified log has no user-visible buffer to flush.
    public func flush() {}
}

// MARK: - Memory

/// For tests: everything written, in order.
public final class MemoryLogSink: LogSink, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    public init() {}

    public var lines: [String] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    public func write(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        storage.append(line)
    }

    public func flush() {}

    public func clear() {
        lock.lock(); defer { lock.unlock() }
        storage.removeAll()
    }
}
