import Foundation
import Testing
@testable import TokiLogging

@Suite("Redactor")
struct RedactorTests {

    // MARK: - One case per pattern

    @Test("a named secret inside a JSON blob keeps its key and loses its value")
    func namedJSONSecrets() {
        for key in ["access_token", "refresh_token", "id_token", "client_secret", "password"] {
            let line = #"{"\#(key)": "hunter2-the-actual-value"}"#
            let scrubbed = Redactor.scrub(line)
            #expect(scrubbed.contains("\"\(key)\":\"<redacted>\""),
                    "\(key) should keep its shape: \(scrubbed)")
            #expect(!scrubbed.contains("hunter2-the-actual-value"))
        }
    }

    @Test("an Anthropic key is replaced wherever it appears in the line")
    func anthropicKey() {
        let scrubbed = Redactor.scrub("using sk-ant-oat01-AbCdEfGhIjKlMnOpQrStUv now")
        #expect(scrubbed == "using <redacted:api-key> now")
    }

    @Test("a JWT goes, with or without a signature segment")
    func jwt() {
        let signed = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjMifQ.dBjftJeZ4CVPmB92K27u"
        #expect(Redactor.scrub("bearer \(signed)") == "bearer <redacted:jwt>")

        let unsigned = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjMifQ"
        #expect(Redactor.scrub("bearer \(unsigned)") == "bearer <redacted:jwt>")
    }

    @Test("an e-mail address goes")
    func email() {
        #expect(Redactor.scrub("account someone@example.com failed")
                == "account <redacted:email> failed")
        #expect(Redactor.scrub("first.last+tag@sub.example.co.uk")
                == "<redacted:email>")
    }

    @Test("a home or temp path goes, and stops at the delimiter it was quoted with")
    func paths() {
        #expect(Redactor.scrub("reading /Users/someone/Developer/private-client/session.jsonl")
                == "reading <redacted:path>")
        #expect(Redactor.scrub("dir=/var/folders/x1/abc/T/toki, ok")
                == "dir=<redacted:path>, ok")
        #expect(Redactor.scrub("dir=/private/var/folders/x1/abc/T/toki ok")
                == "dir=<redacted:path> ok")
    }

    /// The home volume is not the only place a user's files live, and this pattern is the
    /// BACKSTOP — it matters precisely when a path arrives inside something we did not
    /// format, where `\(path:)` never got a chance to hash it. A transcript on an external
    /// drive surfacing through `NSErrorFailingURLKey` is the realistic case, and
    /// `/Volumes/<client name>/…` is exactly the kind of thing that must not reach a public
    /// bug report.
    @Test("a path outside the home volume goes too")
    func pathsOutsideTheHomeVolume() {
        #expect(Redactor.scrub("reading /Volumes/Work/ClientName/session.jsonl")
                == "reading <redacted:path>")
        #expect(Redactor.scrub("reading /home/someone/project/notes.jsonl")
                == "reading <redacted:path>")
        #expect(Redactor.scrub("scratch /tmp/toki-export-1.zip done")
                == "scratch <redacted:path> done")
    }

    /// Foundation hands us file URLs, not bare paths, on a read failure — and it does so
    /// inside an error description, which is the one place the type-level guarantee cannot
    /// reach. Matched before the bare-path form so the scheme goes with the path instead of
    /// leaving `file://` stranded in front of the marker.
    @Test("a file URL goes whole, scheme included, whatever volume it names")
    func fileURLs() {
        #expect(Redactor.scrub("NSErrorFailingURLKey=file:///Volumes/Work/ClientName/session.jsonl")
                == "NSErrorFailingURLKey=<redacted:path>")
        #expect(Redactor.scrub("url file:///Users/someone/a.jsonl end")
                == "url <redacted:path> end")
    }

    /// The pattern list is deliberately prefix-based rather than "any absolute path": these
    /// two are hard-coded routes the status poller logs on purpose, and redacting them would
    /// buy nothing and cost every status line its meaning.
    @Test("a hard-coded API route is not a file path and survives")
    func apiRoutesSurvive() {
        let line = "status poll /api/v2/summary.json returned status 200"
        #expect(Redactor.scrub(line) == line)
    }

    @Test("anything long enough to be an opaque credential goes")
    func opaque() {
        let blob = "QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVphYmNkZWY"   // 43 base64 chars
        #expect(Redactor.scrub("cookie \(blob) end") == "cookie <redacted:opaque> end")
    }

    @Test("a short ordinary word is left alone — the log has to stay readable")
    func shortWordsSurvive() {
        let line = "refresh failed for slot 2 after 3 attempts"
        #expect(Redactor.scrub(line) == line)
    }

    // MARK: - Ordering

    /// The reason the generic base64 pattern is last. Run first, it would match the inside of
    /// the quoted value and the structured `"refresh_token":"<redacted>"` replacement would
    /// never fire — the line would still be safe, but it would stop being diagnosable.
    @Test("a JSON blob carrying an sk-ant token loses both the value and the prefix")
    func orderingKeepsShapeAndStillRemovesEverything() {
        let json = #"{"refresh_token":"sk-ant-oat01-AAAABBBBCCCCDDDDEEEEFFFFGGGGHHHH","expires":900}"#
        let scrubbed = Redactor.scrub(json)

        #expect(!scrubbed.contains("sk-ant-"), "the API-key prefix must not survive: \(scrubbed)")
        #expect(!scrubbed.contains("AAAABBBB"), "the value must not survive: \(scrubbed)")
        #expect(scrubbed.contains(#""refresh_token":"<redacted>""#),
                "the structured replacement should still be the one that ran: \(scrubbed)")
        #expect(scrubbed.contains("\"expires\":900"), "harmless fields survive: \(scrubbed)")
    }

    @Test("scrubbing twice changes nothing the first pass did not already handle")
    func idempotent() {
        let line = #"{"access_token":"sk-ant-oat01-ZZZZZZZZZZZZ"} for someone@example.com at /Users/x/y"#
        let once = Redactor.scrub(line)
        #expect(Redactor.scrub(once) == once)
    }
}
