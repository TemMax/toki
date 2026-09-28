/// Severity, ordered. `debug` is emitted only when verbose logging is on.
///
/// **The line between `debug` and `info` is "did anything change?", not "is this
/// interesting?"** A poll that ran and found the world unchanged — a gauge refresh with
/// nothing stale, a vault read that succeeded, a resolver that classified the account the
/// same way as last minute — is a heartbeat, and heartbeats go to `debug`. `info` is for
/// state that actually moved: a swap, an account going stale, a token expiring, a launch.
///
/// This is a retention rule, not a matter of taste. Toki polls continuously, so heartbeats
/// at `info` cost roughly 14 MB a day — enough to blow the 10 MB per-file cap daily and eat
/// the 30 MB directory budget in about two days. The user's three days of history would then
/// be spent proving the app was alive, and the error they wanted to report would have been
/// pruned to make room for it.
public enum LogLevel: Int, Sendable, Comparable, CaseIterable, CustomStringConvertible {
    case debug = 0, info, notice, error, fault

    public static func < (a: LogLevel, b: LogLevel) -> Bool { a.rawValue < b.rawValue }

    /// Fixed-width so columns line up in an exported file.
    public var description: String {
        switch self {
        case .debug:  return "DEBUG "
        case .info:   return "INFO  "
        case .notice: return "NOTICE"
        case .error:  return "ERROR "
        case .fault:  return "FAULT "
        }
    }
}
