import Foundation

/// A `URLProtocol` that answers per-path and records what was asked.
///
/// A copy of the stub in `TokiLimitsTests` (each test target keeps its own — they are
/// internal, and sharing one would couple two suites' setup), extended in the two ways this
/// module needs: one poll hits TWO endpoints, so responses are keyed by path; and the whole
/// point of the client is the conditional GET, so request headers are captured and asserted.
///
/// No test in this target performs real network I/O — every session is built from
/// `URLSession.stubbed`, which routes exclusively through this class.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {

    struct Stub {
        var statusCode: Int
        var body: String = ""
        var etag: String?
    }

    /// Keyed by URL path, e.g. `/api/v2/status.json`.
    nonisolated(unsafe) static var stubs: [String: Stub] = [:]
    /// When set, every request fails with it — the "status page unreachable" case.
    nonisolated(unsafe) static var failure: (any Error)?
    /// Every request served, in order, with headers intact.
    nonisolated(unsafe) static var requests: [URLRequest] = []

    static var requestCount: Int { requests.count }

    static func reset() {
        stubs = [:]
        failure = nil
        requests = []
    }

    static func requests(forPath path: String) -> [URLRequest] {
        requests.filter { $0.url?.path == path }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)

        if let failure = Self.failure {
            client?.urlProtocol(self, didFailWithError: failure)
            return
        }

        let url = request.url ?? URL(string: "https://example.com")!
        guard let stub = Self.stubs[url.path] else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }

        var headers = ["Content-Type": "application/json"]
        if let etag = stub.etag { headers["ETag"] = etag }

        let response = HTTPURLResponse(
            url: url,
            statusCode: stub.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !stub.body.isEmpty {
            client?.urlProtocol(self, didLoad: Data(stub.body.utf8))
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

extension URLSession {
    /// A session backed by `StubURLProtocol`, so no real network request is ever made.
    static var stubbed: URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }
}
