/// Persistent JSON cache for the last successfully fetched UsageLimits snapshot.
import Foundation
import TokiLogging
import TokiModels

// MARK: - LimitsCache

/// A lightweight, file-backed cache for the last known `UsageLimits` snapshot.
///
/// `save(_:)` encodes to JSON and writes atomically; any I/O error is swallowed
/// so a cache miss never crashes the app.  `load()` returns nil on any decode or
/// read failure — callers must treat nil as "no cached data".
///
/// Designed as a plain `struct` (not an actor) so it can be stored as a `let`
/// constant and called from the `LimitsService` actor without isolation overhead.
/// All file I/O is synchronous and short — appropriate for a small JSON document.
public struct LimitsCache: Sendable {

    // MARK: Properties

    private let fileURL: URL
    private let log = TokiLog.logger("limits")

    // MARK: Init

    /// Creates a cache backed by the given file URL.
    /// The parent directory is created if it does not already exist.
    public init(fileURL: URL) {
        self.fileURL = fileURL
        // Best-effort directory creation — do not throw; load()/save() handle absence.
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            // Never the path itself — just that creating it failed and the shape of why.
            log.error("limits cache directory creation failed \(error: error)")
        }
    }

    /// Creates a cache backed by the default location:
    /// `~/Library/Application Support/Toki/limits-cache.json`.
    public init() {
        self.init(fileURL: AppSupportDirectory.url.appendingPathComponent("limits-cache.json"))
    }

    // MARK: Public API

    /// Encodes `limits` to JSON and writes it to the backing file.
    /// Any encoding or write error is silently swallowed — the cache is best-effort.
    public func save(_ limits: UsageLimits) {
        let data: Data
        do {
            data = try JSONEncoder().encode(limits)
        } catch {
            log.error("limits cache encode failed \(error: error)")
            return
        }
        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            log.error("limits cache write failed \(error: error)")
        }
    }

    /// Decodes and returns the cached `UsageLimits`, or `nil` if the file is
    /// absent, unreadable, or contains invalid data.
    public func load() -> UsageLimits? {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            // Routine: no cache yet (first launch) reads as a missing-file error every time.
            log.debug("limits cache read miss \(error: error)")
            return nil
        }
        do {
            return try JSONDecoder().decode(UsageLimits.self, from: data)
        } catch {
            log.error("limits cache decode failed \(decodingDiagnostic(error), privacy: .public)")
            return nil
        }
    }

    /// Removes a snapshot after an account change so one account's limits can never be
    /// presented as another account's stale data.
    public func remove() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch {
            log.error("limits cache removal failed \(error: error)")
        }
    }
}
