/// Bundling logs (plus the non-identifying diagnostic manifest) into one zip a user can
/// attach to a bug report.
///
/// Zipping goes through `NSFileCoordinator`'s `.forUploading` reading intent rather than an
/// external dependency or a `zip`/`ditto` subprocess: coordinating a read on a directory with
/// that option hands the accessor a temporary zip archive of it, which is copied out before
/// the block returns (the coordinator reclaims that temporary URL once the block exits).
import Foundation

public enum LogArchive {

    /// Flushes the logger, stages the log files plus a manifest into a temporary
    /// directory, and zips that directory. Returns the URL of the zip, which the
    /// caller owns and must move or delete.
    public static func makeArchive(
        logDirectory: URL = TokiLog.directory,
        manifest: DiagnosticManifest
    ) throws -> URL {
        TokiLog.flush()

        let fileManager = FileManager.default
        let calendar = Calendar.current

        // A scratch root that holds only our staging folder, so it can be removed as a
        // whole afterwards without touching anything else in the system temp directory.
        let scratchRoot = fileManager.temporaryDirectory
            .appendingPathComponent("toki-log-archive-\(UUID().uuidString)", isDirectory: true)
        let stagingDirectory = scratchRoot
            .appendingPathComponent("toki-logs-\(Self.dayStamp(manifest.exportedAt))", isDirectory: true)
        try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)

        defer { try? fileManager.removeItem(at: scratchRoot) }

        // Only files this module wrote — anything else in the log directory is not ours
        // and is not shipped. A missing or empty directory is not an error: the manifest
        // alone is still worth having.
        let names = (try? fileManager.contentsOfDirectory(atPath: logDirectory.path)) ?? []
        var skipped: [String] = []
        for name in names.sorted() {
            guard LogFileStore.parse(fileName: name, calendar: calendar) != nil else { continue }
            let source = logDirectory.appendingPathComponent(name)
            let destination = stagingDirectory.appendingPathComponent(name)
            do {
                try fileManager.copyItem(at: source, to: destination)
            } catch {
                // One unreadable file must not cost the user the rest of the archive — but it
                // must not vanish silently either. An archive quietly missing the day the bug
                // happened reads as "Toki logged nothing", and the report goes off in the
                // wrong direction. The name alone is a date, so recording it identifies
                // nobody.
                skipped.append(name)
            }
        }

        var manifestText = manifest.render()
        if !skipped.isEmpty {
            manifestText += """

                log files that could not be read and are NOT in this archive:
                \(skipped.map { "  \($0)" }.joined(separator: "\n"))

                """
        }

        let manifestURL = stagingDirectory.appendingPathComponent("manifest.txt")
        try manifestText.write(to: manifestURL, atomically: true, encoding: .utf8)

        let zipDestination = fileManager.temporaryDirectory
            .appendingPathComponent("toki-logs-\(Self.dayStamp(manifest.exportedAt))-\(UUID().uuidString).zip")

        var coordinationError: NSError?
        var copyError: (any Error)?
        NSFileCoordinator().coordinate(readingItemAt: stagingDirectory,
                                       options: [.forUploading],
                                       error: &coordinationError) { zippedURL in
            do {
                try fileManager.copyItem(at: zippedURL, to: zipDestination)
            } catch {
                copyError = error
            }
        }

        if let coordinationError { throw coordinationError }
        if let copyError { throw copyError }

        return zipDestination
    }

    /// `yyyy-MM-dd`, UTC, so the archive's top-level folder name does not depend on the
    /// caller's current time zone.
    private static func dayStamp(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
