/// The compile-time half of the "a secret cannot reach a log file" guarantee.
///
/// `LogMessage` replaces `String`'s interpolation with its own `StringInterpolation` type, so
/// the ONLY interpolations that exist inside a log call are the ones declared below. That is
/// the whole point of not importing a logging library: swift-log's `Logger.Message` wraps a
/// plain `String`, so `logger.error("\(credential)")` compiles there and writes the secret.
///
/// ────────────────────────────────────────────────────────────────────────────────────────
/// DELIBERATE GAP — DO NOT "FIX" IT.
///
/// There is no `appendInterpolation(_ value: String)` overload. Its absence is the feature:
/// `logger.info("user \(name)")` must fail to compile so the author is forced to write
/// `\(name, privacy: .public)` / `.redacted` / `.hashed` and think about it for one second.
/// Adding an unlabelled `String` overload — even "just for a literal-ish value", even to
/// silence one build error — removes the only compile-time protection this module has.
///
/// A test cannot assert this property, because a test that asserts it would itself have to
/// contain the code that does not compile. A source linter checks `LogMessage.swift` for the
/// overload's absence instead. If you are here because a call site does not build: label the
/// interpolation at the call site, do not widen this type.
/// ────────────────────────────────────────────────────────────────────────────────────────
import Foundation

public struct LogMessage: ExpressibleByStringLiteral, ExpressibleByStringInterpolation, Sendable {
    public let rendered: String

    public init(stringLiteral value: String) { self.rendered = value }
    public init(stringInterpolation: StringInterpolation) { self.rendered = stringInterpolation.out }

    public struct StringInterpolation: StringInterpolationProtocol {
        var out: String

        public init(literalCapacity: Int, interpolationCount: Int) {
            out = ""
            out.reserveCapacity(literalCapacity + interpolationCount * 16)
        }

        public mutating func appendLiteral(_ literal: String) { out += literal }

        // MARK: - Safe by construction: no privacy label required.

        public mutating func appendInterpolation(_ value: Int) { out += String(value) }
        public mutating func appendInterpolation(_ value: UInt64) { out += String(value) }
        public mutating func appendInterpolation(_ value: Double) { out += String(format: "%.3f", value) }
        public mutating func appendInterpolation(_ value: Bool) { out += value ? "true" : "false" }
        public mutating func appendInterpolation(_ value: StaticString) { out += value.description }
        public mutating func appendInterpolation(_ value: LogLevel) { out += value.description }

        // MARK: - A String MUST declare its privacy.

        /// There is deliberately NO unlabelled `String` overload — see the type comment.
        public mutating func appendInterpolation(_ value: String, privacy: LogPrivacy) {
            switch privacy {
            case .public:
                // Written as-is *here*; `Redactor` still runs over the finished line, so a
                // value mislabelled `.public` is caught by the second layer.
                out += value
            case .redacted:
                out += "<redacted>"
            case .hashed:
                out += HashSalt.token(kind: "value", value: value)
            }
        }

        // MARK: - Never rendered verbatim, whatever the caller wants.

        /// A file system location. Always `path#<8 hex>`; never the path, never the file
        /// name, never the extension — a transcript file name carries the session id, and a
        /// project directory name carries a client's name.
        public mutating func appendInterpolation(path value: URL) {
            out += HashSalt.token(kind: "path", value: value.standardizedFileURL.path)
        }

        public mutating func appendInterpolation(path value: String) {
            out += HashSalt.token(kind: "path", value: value)
        }

        /// An account, identified by e-mail or display name. Always `acct#<8 hex>`.
        public mutating func appendInterpolation(account value: String) {
            out += HashSalt.token(kind: "acct", value: value)
        }

        // MARK: - Errors.

        /// Renders the error's *shape*, not its contents.
        ///
        /// `localizedDescription` of an unknown error is the classic leak: `URLError`,
        /// `NSError` from a system framework and any third-party error are free to paste a
        /// URL, a header or a whole response body into it. So: the `NSError` bridge's
        /// `domain`/`code` (always safe — a domain string and an integer), then
        /// `String(describing:)` put through `Redactor.scrub`.
        ///
        /// `String(describing:)` rather than `localizedDescription` because for a Swift enum
        /// — which is what nearly every error in this codebase is — it yields the case name,
        /// e.g. `notAuthenticated`, which is exactly the diagnostic wanted. `TokiLogging`
        /// has no dependency on `TokiModels` (that is what lets every module depend on it
        /// without a cycle), so it cannot name `TokiError` and match on it.
        public mutating func appendInterpolation(error value: any Error) {
            let ns = value as NSError
            out += "domain=\(ns.domain) code=\(ns.code) "
            out += Redactor.scrub(String(describing: value))
        }
    }
}
