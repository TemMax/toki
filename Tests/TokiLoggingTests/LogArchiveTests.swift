import Foundation
import Testing
@testable import TokiLogging

@Suite("LogArchive")
struct LogArchiveTests {

    private func manifest() -> DiagnosticManifest {
        DiagnosticManifest(appVersion: "1.2.3",
                           buildNumber: "456",
                           osVersion: "Version 14.5 (Build 23F79)",
                           architecture: "arm64",
                           locale: "en_US",
                           timeZone: "America/Los_Angeles",
                           exportedAt: Date(timeIntervalSince1970: 1_756_000_000))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LogArchiveTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Unzips `zipURL` into a fresh temporary directory via `/usr/bin/unzip` and returns the
    /// directory it was extracted into, alongside the raw `-l` listing (for the report).
    @discardableResult
    private func unzip(_ zipURL: URL) throws -> (directory: URL, listing: String) {
        let destination = try makeTemporaryDirectory()

        let list = Process()
        list.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        list.arguments = ["-l", zipURL.path]
        let listPipe = Pipe()
        list.standardOutput = listPipe
        try list.run()
        list.waitUntilExit()
        let listing = String(data: listPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        let extract = Process()
        extract.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        extract.arguments = ["-q", zipURL.path, "-d", destination.path]
        try extract.run()
        extract.waitUntilExit()
        #expect(extract.terminationStatus == 0)

        return (destination, listing)
    }

    private func findFile(named name: String, under directory: URL) -> Bool {
        guard let enumerator = FileManager.default.enumerator(at: directory,
                                                              includingPropertiesForKeys: nil)
        else { return false }
        for case let url as URL in enumerator where url.lastPathComponent == name {
            return true
        }
        return false
    }

    private func readFile(named name: String, under directory: URL) throws -> String {
        guard let enumerator = FileManager.default.enumerator(at: directory,
                                                              includingPropertiesForKeys: nil)
        else { throw CocoaError(.fileNoSuchFile) }
        for case let url as URL in enumerator where url.lastPathComponent == name {
            return try String(contentsOf: url, encoding: .utf8)
        }
        throw CocoaError(.fileNoSuchFile)
    }

    @Test("only real log files and the manifest survive; a stray file does not")
    func archivesOnlyLogFilesAndManifest() throws {
        let logDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: logDirectory) }

        try "line one\n".write(to: logDirectory.appendingPathComponent("toki-2026-08-24.log"),
                                atomically: true, encoding: .utf8)
        try "line two\n".write(to: logDirectory.appendingPathComponent("toki-2026-08-23.log"),
                                atomically: true, encoding: .utf8)
        try "not ours\n".write(to: logDirectory.appendingPathComponent("notes.txt"),
                                atomically: true, encoding: .utf8)

        let zipURL = try LogArchive.makeArchive(logDirectory: logDirectory, manifest: manifest())
        defer { try? FileManager.default.removeItem(at: zipURL) }

        #expect(FileManager.default.fileExists(atPath: zipURL.path))

        let (extractedDirectory, listing) = try unzip(zipURL)
        defer { try? FileManager.default.removeItem(at: extractedDirectory) }

        // Pasted into the report as required.
        print("unzip -l \(zipURL.lastPathComponent):\n\(listing)")

        #expect(findFile(named: "toki-2026-08-24.log", under: extractedDirectory))
        #expect(findFile(named: "toki-2026-08-23.log", under: extractedDirectory))
        #expect(findFile(named: "manifest.txt", under: extractedDirectory))
        #expect(!findFile(named: "notes.txt", under: extractedDirectory))
    }

    @Test("an empty log directory still produces an archive containing the manifest")
    func emptyDirectoryStillProducesManifest() throws {
        let logDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: logDirectory) }

        let zipURL = try LogArchive.makeArchive(logDirectory: logDirectory, manifest: manifest())
        defer { try? FileManager.default.removeItem(at: zipURL) }

        let (extractedDirectory, _) = try unzip(zipURL)
        defer { try? FileManager.default.removeItem(at: extractedDirectory) }

        #expect(findFile(named: "manifest.txt", under: extractedDirectory))
    }

    @Test("a missing log directory is not an error and still produces a manifest-only archive")
    func missingDirectoryStillProducesManifest() throws {
        let missingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LogArchiveTests-missing-\(UUID().uuidString)", isDirectory: true)

        let zipURL = try LogArchive.makeArchive(logDirectory: missingDirectory, manifest: manifest())
        defer { try? FileManager.default.removeItem(at: zipURL) }

        let (extractedDirectory, _) = try unzip(zipURL)
        defer { try? FileManager.default.removeItem(at: extractedDirectory) }

        #expect(findFile(named: "manifest.txt", under: extractedDirectory))
    }

    /// A file the archiver cannot read is skipped so one bad file does not cost the user the
    /// rest of the archive — but skipping it silently is worse than the original problem: an
    /// archive quietly missing the day the bug happened reads as "Toki logged nothing", and
    /// sends the report off in the wrong direction. The manifest has to say so.
    ///
    /// Root can read a `000` file, so this asserts nothing useful when run as root — it is
    /// skipped there rather than passing vacuously.
    @Test("a log file that cannot be read is named in the manifest instead of vanishing")
    func unreadableFileIsRecordedInTheManifest() throws {
        try #require(NSUserName() != "root", "chmod 000 does not stop root from reading")

        let logDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: logDirectory) }

        let readable = logDirectory.appendingPathComponent("toki-2026-08-24.log")
        let unreadable = logDirectory.appendingPathComponent("toki-2026-08-23.log")
        try "readable line\n".write(to: readable, atomically: true, encoding: .utf8)
        try "secret line\n".write(to: unreadable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: Int16(0o000))],
                                              ofItemAtPath: unreadable.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: Int16(0o600))],
                                                   ofItemAtPath: unreadable.path)
        }

        let zipURL = try LogArchive.makeArchive(logDirectory: logDirectory, manifest: manifest())
        defer { try? FileManager.default.removeItem(at: zipURL) }

        let (extractedDirectory, _) = try unzip(zipURL)
        defer { try? FileManager.default.removeItem(at: extractedDirectory) }

        #expect(findFile(named: "toki-2026-08-24.log", under: extractedDirectory),
                "the readable file still ships")
        #expect(!findFile(named: "toki-2026-08-23.log", under: extractedDirectory),
                "the unreadable file is not in the archive")

        let manifestText = try readFile(named: "manifest.txt", under: extractedDirectory)
        #expect(manifestText.contains("toki-2026-08-23.log"),
                "the skipped file must be named in the manifest:\n\(manifestText)")
        #expect(!manifestText.contains("secret line"),
                "naming the file must not mean shipping its contents")
    }

    @Test("the rendered manifest carries no identifying value")
    func manifestHasNoIdentifyingFields() {
        let rendered = manifest().render()

        #expect(!rendered.contains(NSUserName()))
        #expect(!rendered.contains(ProcessInfo.processInfo.hostName))
        #expect(!rendered.contains(FileManager.default.homeDirectoryForCurrentUser.path))
    }
}
