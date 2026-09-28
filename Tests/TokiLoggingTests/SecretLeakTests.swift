import Foundation
import Testing
@testable import TokiLogging

/// `TokiLog.bootstrap` is deliberately once-per-process, and `swift test` runs every target
/// in one process — so exactly one place in the whole test bundle may call it. This is that
/// place: a `static let`, which Swift guarantees runs at most once however many suites or
/// parallel tests reach for it.
enum LogHarness {
    static let directory: URL = {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("toki-logging-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // File sink only: OSLogSink would put the same lines in the unified log, which a test
        // has no business writing to.
        TokiLog.bootstrap(directory: dir, sinks: [FileLogSink(directory: dir)])
        return dir
    }()

    /// Every byte this process has logged, concatenated.
    static func writtenBytes() -> String {
        TokiLog.flush()
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.sorted().compactMap {
            try? String(contentsOf: directory.appendingPathComponent($0), encoding: .utf8)
        }.joined()
    }
}

/// THE SENTINEL.
///
/// Everything else in this module is machinery; this is the property the machinery exists
/// for. Secrets are pushed through the logger by every route an author could plausibly
/// take — including the worst one, where the author mislabelled a live token as `.public` —
/// and then the file is read back and searched for them. If this suite fails, the feature has
/// failed, whatever else is green.
@Suite("Secret leak", .serialized)
struct SecretLeakTests {

    // Realistically shaped, and none of them real.
    private let apiKey = "sk-ant-oat01-AAAABBBBCCCCDDDDEEEEFFFFGGGGHHHHIIIIJJJJ"
    private let refreshBlob = #"{"refresh_token":"sk-ant-ort01-KKKKLLLLMMMMNNNNOOOOPPPPQQQQRRRR","expires_in":900}"#
    private let jwt = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJhY2N0LTQyIn0.QQQQWWWWEEEE"
    private let secretPath = "/Users/someone/Developer/private-client/session.jsonl"
    private let address = "someone@example.com"

    @Test("no secret pushed through any route survives into the log file")
    func nothingLeaks() {
        _ = LogHarness.directory
        let log = TokiLog.logger("leak-test")

        // 1. The worst case: the author mislabelled a live credential as public.
        log.error("mislabelled key \(apiKey, privacy: .public)")
        log.error("mislabelled body \(refreshBlob, privacy: .public)")
        log.error("mislabelled jwt \(jwt, privacy: .public)")
        log.error("mislabelled address \(address, privacy: .public)")
        log.error("mislabelled path \(secretPath, privacy: .public)")

        // 2. A secret that arrived inside a third-party error's description — the case no
        //    type system can see, and the reason the redactor exists at all.
        let wrapped = NSError(domain: "NSURLErrorDomain", code: -1009, userInfo: [
            NSLocalizedDescriptionKey: "refresh rejected",
            "responseBody": refreshBlob,
            "requestPath": secretPath,
        ])
        log.error("refresh failed \(error: wrapped)")

        // 3. The labelled forms, used correctly.
        log.notice("reading \(path: secretPath)")
        log.notice("reading \(path: URL(fileURLWithPath: secretPath))")
        log.notice("switching to \(account: address)")
        log.notice("credential \(apiKey, privacy: .redacted)")
        log.notice("credential \(apiKey, privacy: .hashed)")

        let bytes = LogHarness.writtenBytes()

        // The test must not be able to pass by writing nothing at all.
        #expect(bytes.contains("[leak-test]"), "the harness wrote no lines: \(bytes.count) bytes")
        #expect(bytes.contains("mislabelled key"))
        #expect(bytes.contains("refresh failed"))

        let forbidden: [(String, String)] = [
            ("the API key", apiKey),
            ("the sk-ant prefix", "sk-ant-"),
            ("the refresh token", "sk-ant-ort01-KKKKLLLLMMMMNNNNOOOOPPPPQQQQRRRR"),
            ("the JWT", jwt),
            ("the JWT header", "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"),
            ("the full path", secretPath),
            ("the home directory", "/Users/someone"),
            ("the user name", "someone"),
            ("the project directory name", "private-client"),
            ("the file name", "session.jsonl"),
            ("the e-mail address", address),
            ("the local part of the address", "someone@"),
        ]
        for (what, needle) in forbidden {
            #expect(!bytes.contains(needle), "\(what) leaked into the log:\n\(bytes)")
        }
    }

    @Test("the labelled routes leave the redaction markers behind, so the log stays diagnosable")
    func redactionIsVisible() {
        _ = LogHarness.directory
        let log = TokiLog.logger("leak-test")
        log.notice("marker check \(path: secretPath) \(account: address) \(apiKey, privacy: .redacted)")

        let bytes = LogHarness.writtenBytes()
        #expect(bytes.contains("path#"))
        #expect(bytes.contains("acct#"))
        #expect(bytes.contains("<redacted>"))
    }

    @Test("a line carries the timestamp, level, label, message and function, in that order")
    func lineFormat() throws {
        _ = LogHarness.directory
        TokiLog.logger("swap").error("format probe \(7)")

        let bytes = LogHarness.writtenBytes()
        let line = try #require(bytes.split(separator: "\n").last { $0.contains("format probe") })

        let pattern = #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z  ERROR   \[swap\]  format probe 7  \(\w+\(\)\)$"#
        let regex = try NSRegularExpression(pattern: pattern)
        let str = String(line)
        #expect(regex.firstMatch(in: str, range: NSRange(str.startIndex..<str.endIndex, in: str)) != nil,
                "unexpected line shape: \(str)")
    }

    /// The salt is what would turn `acct#a3f1c204` back into an address. It lives in
    /// Application Support, not in the log directory, so archiving the logs cannot pick it up.
    @Test("the hash salt is not in the log directory")
    func saltIsOutsideTheLogDirectory() {
        _ = LogHarness.directory
        let names = (try? FileManager.default.contentsOfDirectory(atPath: LogHarness.directory.path)) ?? []

        #expect(!names.contains { $0.contains("salt") }, "found: \(names)")
        #expect(!HashSalt.fileURL.path.hasPrefix(LogHarness.directory.path))
        #expect(!HashSalt.fileURL.path.hasPrefix(TokiLog.defaultDirectory.path))
        #expect(HashSalt.fileURL.lastPathComponent == "logging-salt")
    }
}

@Suite("TokiLog bootstrap", .serialized)
struct TokiLogBootstrapTests {

    @Test("a second bootstrap is a no-op that logs a fault instead of crashing")
    func doubleBootstrapIsSurvivable() {
        _ = LogHarness.directory
        let decoy = MemoryLogSink()

        TokiLog.bootstrap(directory: FileManager.default.temporaryDirectory, sinks: [decoy])

        #expect(decoy.lines.isEmpty, "the second call must not take over the sinks")
        #expect(TokiLog.directory == LogHarness.directory, "the first bootstrap still owns the directory")
        #expect(LogHarness.writtenBytes().contains("bootstrap called twice"))
    }

    @Test("the default directory is ~/Library/Logs/Toki")
    func defaultDirectory() {
        #expect(TokiLog.defaultDirectory.pathComponents.suffix(3) == ["Library", "Logs", "Toki"])
    }

    @Test("verbosity is one stored value, and it moves the minimum level")
    func verbosityOwnsTheMinimumLevel() {
        let original = UserDefaults.standard.object(forKey: TokiLog.verboseDefaultsKey)
        defer {
            if let original {
                UserDefaults.standard.set(original, forKey: TokiLog.verboseDefaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: TokiLog.verboseDefaultsKey)
            }
            TokiLog.isVerbose = UserDefaults.standard.bool(forKey: TokiLog.verboseDefaultsKey)
        }

        TokiLog.isVerbose = true
        #expect(UserDefaults.standard.bool(forKey: TokiLog.verboseDefaultsKey))
        #expect(TokiLog.minimumLevel == .debug)

        TokiLog.isVerbose = false
        #expect(TokiLog.minimumLevel == .info)
        #expect(TokiLog.isVerbose == false)
    }

    /// The reason every `TokiLogger` method takes `@autoclosure`.
    ///
    /// Building a message is not free — `\(path:)` and `\(account:)` each hash their value —
    /// and the call sites where a `debug` line is most tempting are per-record loops. If the
    /// argument were evaluated eagerly, a filtered-out level would pay for every hash and
    /// then throw the string away. No linter can catch that, so the API has to. This test is
    /// what stops someone dropping the `@autoclosure` during a refactor and never noticing.
    ///
    /// Lives in this `.serialized` suite deliberately: it moves the process-wide verbosity,
    /// as `verbosityOwnsTheMinimumLevel` above does, and the two must not overlap.
    @Test("a filtered-out level never builds its message")
    func filteredLevelDoesNotBuildItsMessage() {
        _ = LogHarness.directory

        final class Counter {
            var value = 0
            func bump() -> String { value += 1; return "expensive" }
        }

        let original = UserDefaults.standard.object(forKey: TokiLog.verboseDefaultsKey)
        defer {
            if let original {
                UserDefaults.standard.set(original, forKey: TokiLog.verboseDefaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: TokiLog.verboseDefaultsKey)
            }
            TokiLog.isVerbose = UserDefaults.standard.bool(forKey: TokiLog.verboseDefaultsKey)
        }
        TokiLog.isVerbose = false
        #expect(TokiLog.minimumLevel == .info)

        let log = TokiLog.logger("autoclosure-probe")
        let counter = Counter()

        log.debug("below the minimum \(counter.bump(), privacy: .public)")
        #expect(counter.value == 0, "a dropped level must not evaluate its message")

        log.info("at the minimum \(counter.bump(), privacy: .public)")
        #expect(counter.value == 1, "a level that is emitted must evaluate exactly once")
    }

    @Test("levels are ordered so a minimum level can gate them")
    func levelOrdering() {
        #expect(LogLevel.allCases == [.debug, .info, .notice, .error, .fault])
        #expect(LogLevel.debug < LogLevel.info)
        #expect(LogLevel.error < LogLevel.fault)
        #expect(LogLevel.allCases.allSatisfy { $0.description.count == 6 },
                "fixed width keeps the columns lined up in an exported file")
    }
}
