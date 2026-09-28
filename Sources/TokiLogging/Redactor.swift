/// The run-time half of the "a secret cannot reach a log file" guarantee.
///
/// `LogMessage` stops a secret an author *knows about* (a `String` has to declare its
/// privacy or it does not compile). `Redactor` catches the ones nobody knew about: a token
/// pasted into some third-party `Error`'s description, a JSON body echoed back by a server,
/// a home directory inside a URL. It runs over every finished line, unconditionally,
/// whatever privacy label the author chose.
import Foundation

public enum Redactor {

    /// Ordered: structured patterns first, the generic base64-ish one last. Reversed, the
    /// generic pattern would swallow the inside of a `"access_token": "…"` pair and the
    /// structured replacement would never get to run — the line would still be safe, but it
    /// would lose the shape (`"access_token":"<redacted>"`) that makes a log readable.
    ///
    /// `NSRegularExpression` is compiled once here rather than per call: scrubbing runs on
    /// every single line, and recompiling seven patterns per line is a real cost.
    /// `nonisolated(unsafe)` because `NSRegularExpression` is documented as thread-safe for
    /// concurrent matching but is not marked `Sendable`.
    private nonisolated(unsafe) static let patterns: [(regex: NSRegularExpression, template: String)] = {
        let sources: [(String, String)] = [
            // 1. Named secrets inside a JSON blob, keyed by the field name.
            (#""(access_token|refresh_token|id_token|client_secret|password)"\s*:\s*"[^"]*""#,
             #""$1":"<redacted>""#),
            // 2. Anthropic API keys / OAuth tokens.
            (#"sk-ant-[A-Za-z0-9_\-]{10,}"#, "<redacted:api-key>"),
            // 3. JWTs (header.payload[.signature]).
            (#"eyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]+(\.[A-Za-z0-9_\-]*)?"#, "<redacted:jwt>"),
            // 4. E-mail addresses — an account identifier is personal data.
            (#"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#, "<redacted:email>"),
            // 5. `file://` URLs, whatever they point at. These arrive from Foundation rather
            //    than from us — `NSErrorFailingURLKey` on a read failure is the usual route —
            //    so the prefix list below cannot be relied on to have anticipated the volume.
            //    Matched before the bare-path form so the scheme goes with the path.
            (#"file://[^\s"',)\]]*"#, "<redacted:path>"),
            // 6. File system locations that carry the user's name or a project name.
            //
            //    Prefix-based on purpose, not "any absolute path": `/api/v2/summary.json` is a
            //    hard-coded route we log deliberately, and a generic path pattern would eat it
            //    and make the status-poll lines useless. So the list enumerates the places a
            //    *user's* files actually live — including the ones outside the home volume,
            //    which is how a project on an external drive ends up in a log line.
            (#"(/Users/|/home/|/Volumes/|/private/var/folders/|/var/folders/|/private/tmp/|/tmp/)[^\s"',)\]]*"#,
             "<redacted:path>"),
            // 6. Anything long enough to be an opaque credential, last so it cannot eat the above.
            (#"\b[A-Za-z0-9+/]{32,}={0,2}\b"#, "<redacted:opaque>"),
        ]
        return sources.map { source, template in
            // Force-try: these six literals are fixed at compile time. If one of them stops
            // compiling the module is broken and a crash at launch is the correct signal.
            (try! NSRegularExpression(pattern: source), template)
        }
    }()

    /// Scrub one finished log line. Idempotent enough to be run twice without harm.
    public static func scrub(_ line: String) -> String {
        var out = line
        for (regex, template) in patterns {
            let range = NSRange(out.startIndex..<out.endIndex, in: out)
            out = regex.stringByReplacingMatches(in: out, range: range, withTemplate: template)
        }
        return out
    }
}
