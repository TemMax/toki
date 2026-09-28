/// The one place that decides where Toki keeps its own files.
///
/// Everything durable lives here — the rate-limit cache, the daily activity rollup, the
/// price history and the transcript index.
import Foundation
import TokiLogging

private let log = TokiLog.logger("models")

public enum AppSupportDirectory {
    public static let currentName = "Toki"

    /// `~/Library/Application Support/Toki`, created on first use.
    ///
    /// A `static let` so the lookup runs at most once per launch no matter how many stores
    /// ask for it concurrently — Swift guarantees lazy statics are initialized exactly once.
    public static let url: URL = {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return resolve(base: base)
    }()

    /// Testable core of the above.
    public static func resolve(base: URL, fileManager: FileManager = .default) -> URL {
        let current = base.appendingPathComponent(currentName, isDirectory: true)
        do {
            try fileManager.createDirectory(at: current, withIntermediateDirectories: true)
        } catch {
            log.error("app support directory creation failed \(error: error)")
        }
        return current
    }
}
