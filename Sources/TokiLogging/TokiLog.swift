/// The bootstrap-once logging system, modelled on swift-log's `LoggingSystem`.
///
/// One process-wide set of sinks, configured once at launch; a `TokiLogger` per subsystem
/// after that. Before `bootstrap`, every log call is a silent no-op — library modules are
/// exercised by `swift test` with no app around them, and they must neither crash nor
/// scatter files into the developer's real `~/Library/Logs`.
import Foundation

public enum TokiLog {

    /// UserDefaults key behind `isVerbose`. The Settings toggle and this property are two
    /// readers of ONE stored value, never two copies that drift.
    public static let verboseDefaultsKey = "toki.verboseLogging"

    private static let state = State()

    // MARK: - Bootstrap

    /// Call once per process, before anything logs.
    ///
    /// A second call is a no-op that records a `fault` — never a crash. A debug harness, a
    /// snapshot run or a test can legitimately boot twice, and taking the app down over a
    /// logging misconfiguration would be the logging system causing the outage it exists to
    /// explain.
    public static func bootstrap(directory: URL = TokiLog.defaultDirectory,
                                 sinks: [any LogSink]? = nil) {
        let resolved = sinks ?? [FileLogSink(directory: directory), OSLogSink()]
        guard state.bootstrap(directory: directory, sinks: resolved) else {
            logger("logging").fault("bootstrap called twice; the second call was ignored")
            return
        }
        state.startObservingDefaults()
    }

    // MARK: - Loggers

    /// A logger for one subsystem, e.g. `TokiLog.logger("swap")`.
    ///
    /// `Sendable` and callable from any thread or actor. Deliberately NOT an actor: a `catch`
    /// block in synchronous code could then not log without `await`, which would mean the
    /// error paths — the ones worth logging — are the ones that cannot.
    public static func logger(_ label: StaticString) -> TokiLogger {
        TokiLogger(label: label.description)
    }

    // MARK: - Verbosity

    /// The single owner of the verbosity setting, backed by `toki.verboseLogging` in
    /// `UserDefaults.standard`. `TokiLog` observes `UserDefaults.didChangeNotification`, so a
    /// Settings toggle flipping the key moves the minimum level with no extra wiring.
    public static var isVerbose: Bool {
        get { state.isVerbose }
        set { state.isVerbose = newValue }
    }

    public static var minimumLevel: LogLevel { isVerbose ? .debug : .info }

    // MARK: - Directories

    /// `~/Library/Logs/Toki` — the macOS convention, which Console.app lists on its own, and
    /// deliberately not the Application Support directory `HashSalt` writes to.
    public static let defaultDirectory: URL = {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        return library
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("Toki", isDirectory: true)
    }()

    public static var directory: URL { state.directory ?? defaultDirectory }

    public static func flush() { state.sinks.forEach { $0.flush() } }

    // MARK: - Emission

    /// `2026-08-24T20:54:03.123Z  ERROR   [swap]  refresh failed  (refreshToken)`
    ///
    /// The redactor runs over the WHOLE finished line — timestamp, label, message, function —
    /// before it reaches any sink, so no field is exempt and no future field can forget.
    /// Both guards run BEFORE `message()` is called — that is the whole point of taking the
    /// message as a closure. An unbootstrapped process and a filtered-out level each cost one
    /// comparison and never build the string or hash anything.
    static func emit(_ level: LogLevel, label: String, message: () -> LogMessage, function: StaticString) {
        let sinks = state.sinks
        guard !sinks.isEmpty else { return }              // not bootstrapped: silent no-op
        guard level >= minimumLevel else { return }

        let line = Redactor.scrub(
            "\(timestamp(Date()))  \(level.description)  [\(label)]  \(message().rendered)  (\(function))")
        for sink in sinks { sink.write(line) }
    }

    /// ISO-8601 UTC with milliseconds. Built from `Calendar` components rather than a
    /// `DateFormatter` because formatting happens on the caller's thread and `DateFormatter`
    /// is a mutable reference type; `Calendar` is a `Sendable` value.
    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar
    }()

    static func timestamp(_ date: Date) -> String {
        let c = utc.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond],
                                   from: date)
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ",
                      c.year ?? 0, c.month ?? 0, c.day ?? 0,
                      c.hour ?? 0, c.minute ?? 0, c.second ?? 0,
                      (c.nanosecond ?? 0) / 1_000_000)
    }

    // MARK: - Process-wide state

    /// A lock-guarded box rather than a global `var`: `TokiLog` is reachable from every
    /// thread and actor in the app, and Swift 6 will not let a mutable global be.
    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var _sinks: [any LogSink] = []
        private var _directory: URL?
        private var _verbose: Bool?
        private var observer: (any NSObjectProtocol)?

        /// `false` if a bootstrap already happened.
        func bootstrap(directory: URL, sinks: [any LogSink]) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard _sinks.isEmpty else { return false }
            _sinks = sinks
            _directory = directory
            _verbose = UserDefaults.standard.bool(forKey: TokiLog.verboseDefaultsKey)
            return true
        }

        var sinks: [any LogSink] {
            lock.lock(); defer { lock.unlock() }
            return _sinks
        }

        var directory: URL? {
            lock.lock(); defer { lock.unlock() }
            return _directory
        }

        var isVerbose: Bool {
            get {
                lock.lock(); defer { lock.unlock() }
                if let _verbose { return _verbose }
                let stored = UserDefaults.standard.bool(forKey: TokiLog.verboseDefaultsKey)
                _verbose = stored
                return stored
            }
            set {
                UserDefaults.standard.set(newValue, forKey: TokiLog.verboseDefaultsKey)
                lock.lock(); defer { lock.unlock() }
                _verbose = newValue
            }
        }

        /// Anything else writing the key — the Settings toggle, `defaults write`, a synced
        /// value — moves the minimum level here too, without a second copy of the setting.
        func startObservingDefaults() {
            lock.lock()
            guard observer == nil else { lock.unlock(); return }
            lock.unlock()

            let token = NotificationCenter.default.addObserver(
                forName: UserDefaults.didChangeNotification,
                object: UserDefaults.standard,
                queue: nil
            ) { [weak self] _ in
                guard let self else { return }
                let stored = UserDefaults.standard.bool(forKey: TokiLog.verboseDefaultsKey)
                self.lock.lock()
                self._verbose = stored
                self.lock.unlock()
            }
            lock.lock()
            observer = token
            lock.unlock()
        }
    }
}

/// One subsystem's entry point. A value type holding nothing but its label, so passing it
/// across isolation boundaries costs nothing and needs no `await`.
///
/// **Every message is `@autoclosure`, and that is load-bearing rather than a micro-
/// optimisation.** Building a `LogMessage` is not free: `\(path:)` and `\(account:)` each run
/// SHA-256 over the salt plus the value. As a plain parameter the argument is evaluated at
/// the call site, so a `debug` line would pay for its hashes in full and then be dropped by
/// the level check — and the call sites where that matters most are per-record loops, which
/// is exactly where someone would reach for `debug`. Deferring construction means a filtered
/// level costs one comparison. `scripts/lint-error-logging.sh` cannot catch this class of
/// mistake, so the API has to make it impossible instead.
public struct TokiLogger: Sendable {
    let label: String

    public func debug(_ message: @autoclosure () -> LogMessage, function: StaticString = #function) {
        TokiLog.emit(.debug, label: label, message: message, function: function)
    }

    public func info(_ message: @autoclosure () -> LogMessage, function: StaticString = #function) {
        TokiLog.emit(.info, label: label, message: message, function: function)
    }

    public func notice(_ message: @autoclosure () -> LogMessage, function: StaticString = #function) {
        TokiLog.emit(.notice, label: label, message: message, function: function)
    }

    public func error(_ message: @autoclosure () -> LogMessage, function: StaticString = #function) {
        TokiLog.emit(.error, label: label, message: message, function: function)
    }

    public func fault(_ message: @autoclosure () -> LogMessage, function: StaticString = #function) {
        TokiLog.emit(.fault, label: label, message: message, function: function)
    }
}
