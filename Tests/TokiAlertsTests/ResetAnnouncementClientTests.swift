import Foundation
import Testing
@testable import TokiAlerts
import TokiModels

@Suite("ResetAnnouncementClient", .serialized)
struct ResetAnnouncementClientTests {
    final class StubURLProtocol: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var statusCode = 200
        nonisolated(unsafe) static var responseData = Data()
        nonisolated(unsafe) static var lastRequest: URLRequest?

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            Self.lastRequest = request
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: Self.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Self.responseData)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    final class ProgressingURLProtocol: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var wasCancelled = false
        private var timer: DispatchSourceTimer?

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            Self.wasCancelled = false
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)

            let timer = DispatchSource.makeTimerSource(queue: .global())
            timer.schedule(deadline: .now(), repeating: .milliseconds(5))
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                self.client?.urlProtocol(self, didLoad: Data([0x20]))
            }
            self.timer = timer
            timer.resume()
        }

        override func stopLoading() {
            Self.wasCancelled = true
            timer?.cancel()
            timer = nil
        }
    }

    private func client(status: Int = 200, data: Data) -> ResetAnnouncementClient {
        StubURLProtocol.statusCode = status
        StubURLProtocol.responseData = data
        StubURLProtocol.lastRequest = nil
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return ResetAnnouncementClient(session: URLSession(configuration: configuration))
    }

    @Test("fetch uses the Codex public feed with a bounded request")
    func fetchesCodexFeed() async throws {
        let body = Data(#"{"events":[{"tweet_id":"301","tweet_url":"https://x.com/thsottiaux/status/301","announced_at":"2026-09-07T10:00:00Z","reset_type":"regular","source":"webhook"}]}"#.utf8)
        let events = try await client(data: body).fetch(provider: .codex)

        #expect(events.map(\.id) == ["301"])
        #expect(StubURLProtocol.lastRequest?.url?.absoluteString == "https://codex-resets.com/api/resets")
        #expect(StubURLProtocol.lastRequest?.timeoutInterval == 15)
        #expect(StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(StubURLProtocol.lastRequest?.httpShouldHandleCookies == false)
        #expect(StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test("fetch uses the Claude public feed")
    func fetchesClaudeFeed() async throws {
        let body = Data(#"{"providers":{"claude":{"events":[{"id":"302","date":"2026-09-07T10:00:00Z","kind":"reset","scope":"all","url":"https://x.com/ClaudeDevs/status/302","verification":"curated"}]}}}"#.utf8)
        let events = try await client(data: body).fetch(provider: .claudeCode)

        #expect(events.map(\.id) == ["302"])
        #expect(StubURLProtocol.lastRequest?.url?.absoluteString == "https://claude-resets.com/api/resets")
    }

    @Test("non-success HTTP responses throw")
    func rejectsHTTPFailure() async {
        let fetchClient = client(status: 503, data: Data(#"{"events":[]}"#.utf8))
        await #expect(throws: (any Error).self) {
            try await fetchClient.fetch(provider: .codex)
        }
    }

    @Test("responses larger than one mebibyte throw")
    func rejectsOversizedResponse() async {
        let prefix = Data(#"{"events":[],"padding":""#.utf8)
        let suffix = Data(#""}"#.utf8)
        var body = prefix
        body.append(Data(repeating: 0x61, count: 1_048_577 - prefix.count - suffix.count))
        body.append(suffix)
        let fetchClient = client(data: body)

        await #expect(throws: ResetAnnouncementError.responseTooLarge) {
            try await fetchClient.fetch(provider: .codex)
        }
    }

    @Test("a progressing response is cancelled at the total deadline")
    func cancelsProgressingResponseAtDeadline() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProgressingURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let fetchClient = ResetAnnouncementClient(session: session, timeoutInterval: 0.05)

        await #expect(throws: ResetAnnouncementError.timedOut) {
            try await fetchClient.fetch(provider: .codex)
        }
        try await Task.sleep(for: .milliseconds(20))
        #expect(ProgressingURLProtocol.wasCancelled)
    }
}
