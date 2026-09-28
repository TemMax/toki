/// Turning "Toki did something odd" into one file a user can attach to an issue.
///
/// The whole flow is: flush → archive → ask where to put it → move it there. The archive is
/// built by `LogArchive`, which copies only files this app's own log store wrote plus a
/// `DiagnosticManifest` — never the hash salt, never anything else that happens to live
/// beside them — so nothing here has to decide what is safe to ship.
///
/// The staged zip lands in the temporary directory and is owned by this type from that
/// moment on: every exit path below deletes it, including cancel. Leaving a zip of a user's
/// logs behind in `/tmp` because they pressed Escape is exactly the kind of thing a
/// diagnostics feature must not do.
import AppKit
import Foundation
import TokiCore
import UniformTypeIdentifiers

@MainActor
final class LogExportService {

    private let log = TokiLog.logger("log-export")

    // MARK: - Export

    /// Flush → archive → `NSSavePanel` → move into place.
    ///
    /// Only the panel and the alert are main-actor work; the copying and zipping run off the
    /// main actor, because a long-lived install's log directory is megabytes and the user is
    /// looking at a live menu-bar app while this happens.
    func exportLogs() async {
        // Before anything else: the buffered lines still in memory are the ones written
        // closest to the failure being reported, so an unflushed export ships everything
        // except the part that matters.
        TokiLog.flush()

        let manifest = Self.currentManifest()
        let logDirectory = TokiLog.directory

        let archive: URL
        do {
            archive = try await Task.detached(priority: .userInitiated) {
                try LogArchive.makeArchive(logDirectory: logDirectory, manifest: manifest)
            }.value
        } catch {
            log.error("could not build the log archive: \(error: error)")
            present(failure: "Toki couldn\u{2019}t build the log archive.", error: error)
            return
        }

        // Covers every path below — cancel, a failed move, and the successful move (where
        // the source no longer exists and the removal is a harmless no-op).
        defer { try? FileManager.default.removeItem(at: archive) }

        guard let destination = await requestDestination() else {
            log.info("log export cancelled by the user")
            return
        }

        do {
            // The panel has already asked about replacing an existing file; `moveItem`
            // refuses to overwrite, so honour that answer here.
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: archive, to: destination)
        } catch {
            log.error("could not save the log archive: \(error: error)")
            present(failure: "Toki couldn\u{2019}t save the log archive.", error: error)
            return
        }

        log.info("log archive exported")
    }

    // MARK: - Reveal

    /// Opens the log directory in Finder.
    ///
    /// The directory is created first: on a fresh install nothing has been written yet, and
    /// showing the user a "folder doesn't exist" error when they ask to see their logs
    /// reads as a bug in the diagnostics rather than as an empty folder.
    func revealLogs() {
        let directory = TokiLog.directory
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            log.error("could not create the log directory: \(error: error)")
        }

        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        if files.isEmpty {
            NSWorkspace.shared.open(directory)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting(files.sorted { $0.path < $1.path })
        }
    }

    // MARK: - Save panel

    /// `nil` when the user cancelled.
    private func requestDestination() async -> URL? {
        let panel = NSSavePanel()
        panel.title = "Export Toki Logs"
        panel.message = "Choose where to save the diagnostic archive."
        panel.nameFieldStringValue = "toki-logs-\(Self.dayStamp(Date())).zip"
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false

        let response = await withCheckedContinuation { (continuation: CheckedContinuation<NSApplication.ModalResponse, Never>) in
            panel.begin { continuation.resume(returning: $0) }
        }
        guard response == .OK else { return nil }
        return panel.url
    }

    // MARK: - Failure presentation

    private func present(failure: String, error: any Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = failure
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - Manifest

    /// Build constants plus machine-model facts — nothing that identifies the person.
    private static func currentManifest() -> DiagnosticManifest {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return DiagnosticManifest(
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                ?? "unknown",
            buildNumber: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
                ?? "unknown",
            osVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            architecture: Self.architecture,
            locale: Locale.current.identifier,
            timeZone: TimeZone.current.identifier,
            exportedAt: Date()
        )
    }

    private static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    /// `yyyy-MM-dd` in the user's own calendar — this one is a file name they are about to
    /// read, unlike the archive's internal UTC stamp.
    private static func dayStamp(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
