import Foundation
import Testing
@testable import TokiLogging

@Suite("LogMessage privacy")
struct LogMessagePrivacyTests {

    private enum SampleError: Error { case notAuthenticated }

    private let hex8 = try! NSRegularExpression(pattern: "^[0-9a-f]{8}$")

    private func isHex8(_ s: Substring) -> Bool {
        let str = String(s)
        return hex8.firstMatch(in: str, range: NSRange(str.startIndex..<str.endIndex, in: str)) != nil
    }

    // MARK: - Labelled strings

    @Test(".public renders the string as written")
    func publicRendersVerbatim() {
        #expect(LogMessage("model \("claude-opus-4", privacy: .public)").rendered
                == "model claude-opus-4")
    }

    @Test(".redacted renders a fixed placeholder, never a shortened form of the value")
    func redactedIsAPlaceholder() {
        let rendered = LogMessage("token \("sk-ant-oat01-SECRETVALUE", privacy: .redacted)").rendered
        #expect(rendered == "token <redacted>")
        #expect(!rendered.contains("SECRET"))
    }

    @Test(".hashed renders value#<8 hex> and never any part of the input")
    func hashedShape() throws {
        let rendered = LogMessage("\("someone@example.com", privacy: .hashed)").rendered
        let parts = rendered.split(separator: "#")

        #expect(parts.count == 2)
        #expect(parts.first == "value")
        #expect(isHex8(try #require(parts.last)), "unexpected token: \(rendered)")
        #expect(!rendered.contains("someone"))
        #expect(!rendered.contains("example"))
    }

    @Test(".hashed is stable for one input and different for another")
    func hashedIsStableAndDistinguishing() {
        let a1 = LogMessage("\("alice@example.com", privacy: .hashed)").rendered
        let a2 = LogMessage("\("alice@example.com", privacy: .hashed)").rendered
        let b = LogMessage("\("bob@example.com", privacy: .hashed)").rendered

        #expect(a1 == a2, "the same value must correlate across lines")
        #expect(a1 != b, "two accounts must not collapse into one token")
    }

    // MARK: - Always-hashed forms

    @Test("a path renders as path#<8 hex> — not the path, not the file name, not the extension")
    func pathIsAlwaysHashed() throws {
        let raw = "/Users/someone/Developer/private-client/session.jsonl"
        let fromString = LogMessage("\(path: raw)").rendered
        let fromURL = LogMessage("\(path: URL(fileURLWithPath: raw))").rendered

        for rendered in [fromString, fromURL] {
            let parts = rendered.split(separator: "#")
            #expect(parts.first == "path")
            #expect(isHex8(try #require(parts.last)), "unexpected token: \(rendered)")
            for leak in ["someone", "Developer", "private-client", "session", "jsonl", "/"] {
                #expect(!rendered.contains(leak), "\(leak) leaked into \(rendered)")
            }
        }
        #expect(fromString == fromURL, "the same location must produce the same token either way")
    }

    @Test("two different paths get two different tokens")
    func pathsAreDistinguishable() {
        #expect(LogMessage("\(path: "/Users/a/x.jsonl")").rendered
                != LogMessage("\(path: "/Users/a/y.jsonl")").rendered)
    }

    @Test("an account renders as acct#<8 hex>, stable per account")
    func accountIsAlwaysHashed() throws {
        let rendered = LogMessage("\(account: "someone@example.com")").rendered
        let parts = rendered.split(separator: "#")

        #expect(parts.first == "acct")
        #expect(isHex8(try #require(parts.last)))
        #expect(!rendered.contains("@"))
        #expect(rendered == LogMessage("\(account: "someone@example.com")").rendered)
        #expect(rendered != LogMessage("\(account: "other@example.com")").rendered)
    }

    /// The token is `<kind>#SHA256(salt ‖ value)`: the kind labels what the line is talking
    /// about, it is not mixed into the digest. So the same string logged as an account and as
    /// a hashed value correlates — which is the point of hashing at all — while the prefix
    /// still says which route it came in by.
    @Test("the kind is a label on a digest taken over the value alone")
    func kindLabelsWithoutSplittingTheDigest() {
        let asAccount = LogMessage("\(account: "someone@example.com")").rendered
        let asHashed = LogMessage("\("someone@example.com", privacy: .hashed)").rendered

        #expect(asAccount.split(separator: "#").first == "acct")
        #expect(asHashed.split(separator: "#").first == "value")
        #expect(asAccount.split(separator: "#").last == asHashed.split(separator: "#").last)
        #expect(asAccount != asHashed)
    }

    // MARK: - Errors

    @Test("an NSError renders its domain and code, and its description is scrubbed")
    func nsErrorShape() {
        let error = NSError(domain: "NSURLErrorDomain", code: -1009,
                            userInfo: [NSLocalizedDescriptionKey:
                                        "offline while fetching /Users/someone/Library/x"])
        let rendered = LogMessage("\(error: error)").rendered

        #expect(rendered.contains("domain=NSURLErrorDomain"))
        #expect(rendered.contains("code=-1009"))
        #expect(!rendered.contains("/Users/someone"))
        #expect(rendered.contains("<redacted:path>"))
    }

    @Test("a Swift enum error renders its case name — the diagnostic worth having")
    func swiftEnumErrorRendersCaseName() {
        #expect(LogMessage("\(error: SampleError.notAuthenticated)").rendered
                .contains("notAuthenticated"))
    }

    // MARK: - Label-free overloads

    @Test("the safe-by-construction interpolations render as specified")
    func safeOverloads() {
        let s: StaticString = "literal"
        #expect(LogMessage("\(42)").rendered == "42")
        #expect(LogMessage("\(UInt64(18_446_744_073_709_551_615))").rendered == "18446744073709551615")
        #expect(LogMessage("\(1.5)").rendered == "1.500")
        #expect(LogMessage("\(true) \(false)").rendered == "true false")
        #expect(LogMessage("\(s)").rendered == "literal")
        #expect(LogMessage("\(LogLevel.notice)").rendered == "NOTICE")
    }

    @Test("a plain string literal message needs no interpolation at all")
    func stringLiteral() {
        #expect(LogMessage("refresh failed").rendered == "refresh failed")
    }
}
