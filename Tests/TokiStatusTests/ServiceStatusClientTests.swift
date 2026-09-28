import Foundation
import Testing
@testable import TokiStatus

/// Serialized: `StubURLProtocol` holds its stubs and its request log in static storage, so
/// two of these running at once would read each other's traffic.
@Suite("ServiceStatusClient", .serialized)
struct ServiceStatusClientTests {

    @Test("OpenAI checks the summary even when the page-wide signal is unchanged")
    func directSummaryDetectsComponentChanges() async throws {
        StubURLProtocol.reset()
        stubBothOK(summary: StatusFixtures.summaryOperational)
        let client = ServiceStatusClient(
            session: .stubbed, baseURL: URL(string: "https://status.example.test")!,
            pollsSummaryDirectly: true
        )
        #expect(await client.poll() == .operational)
        StubURLProtocol.stubs[statusPath] = .init(statusCode: 304)
        StubURLProtocol.stubs[summaryPath] = .init(
            statusCode: 200, body: StatusFixtures.summaryDegraded, etag: #""summary-v2""#
        )
        #expect(await client.poll()?.severity == .degraded)
        #expect(StubURLProtocol.requests(forPath: statusPath).isEmpty)
        #expect(StubURLProtocol.requests(forPath: summaryPath).last?
            .value(forHTTPHeaderField: "If-None-Match") == #""summary-v1""#)
        StubURLProtocol.stubs[summaryPath] = .init(statusCode: 304)
        #expect(await client.poll() == nil)
    }

    private let statusPath = "/api/v2/status.json"
    private let summaryPath = "/api/v2/summary.json"

    private func makeClient() -> ServiceStatusClient {
        ServiceStatusClient(session: .stubbed, baseURL: URL(string: "https://status.example.test")!)
    }

    private func stubBothOK(summary: String = StatusFixtures.summaryMonitoring) {
        StubURLProtocol.stubs = [
            statusPath: .init(statusCode: 200, body: StatusFixtures.statusMinor, etag: #""status-v1""#),
            summaryPath: .init(statusCode: 200, body: summary, etag: #""summary-v1""#),
        ]
    }

    @Test("the first poll asks unconditionally and returns the parsed status")
    func firstPollIsUnconditional() async throws {
        StubURLProtocol.reset()
        stubBothOK()

        let status = await makeClient().poll()

        #expect(status?.severity == .degraded)
        #expect(status?.incident?.id == "q7txxvbsftgq")
        #expect(StubURLProtocol.requestCount == 2)
        let first = try #require(StubURLProtocol.requests(forPath: statusPath).first)
        #expect(first.value(forHTTPHeaderField: "If-None-Match") == nil,
                "nothing has been seen yet, so there is no ETag to be conditional on")
        #expect(first.value(forHTTPHeaderField: "Accept") == "application/json")
    }

    /// The reason polling every 30–60 s all day is defensible at all: once the ETags are held,
    /// the steady state is one 304 with no body, and `summary.json` is never touched.
    @Test("the second poll sends the captured ETag and a 304 costs a single request")
    func secondPollIsConditional() async throws {
        StubURLProtocol.reset()
        stubBothOK()
        let client = makeClient()
        _ = await client.poll()

        StubURLProtocol.stubs[statusPath] = .init(statusCode: 304)
        let second = await client.poll()

        #expect(second == nil, "nothing changed, so the caller keeps its last known value")
        let conditional = try #require(StubURLProtocol.requests(forPath: statusPath).last)
        #expect(conditional.value(forHTTPHeaderField: "If-None-Match") == #""status-v1""#)
        #expect(StubURLProtocol.requests(forPath: summaryPath).count == 1,
                "a 304 on the cheap signal must not spend a 7 KB summary fetch")
        #expect(StubURLProtocol.requestCount == 3)
    }

    @Test("the summary request carries its own ETag, and its 304 also returns nil")
    func summaryIsConditionalToo() async throws {
        StubURLProtocol.reset()
        stubBothOK()
        let client = makeClient()
        _ = await client.poll()

        // The indicator moved again, but the summary body did not.
        StubURLProtocol.stubs[statusPath] = .init(statusCode: 200,
                                                  body: StatusFixtures.statusNone,
                                                  etag: #""status-v2""#)
        StubURLProtocol.stubs[summaryPath] = .init(statusCode: 304)

        #expect(await client.poll() == nil)
        let conditional = try #require(StubURLProtocol.requests(forPath: summaryPath).last)
        #expect(conditional.value(forHTTPHeaderField: "If-None-Match") == #""summary-v1""#)
    }

    @Test("a changed signal fetches the summary again and reports the new severity")
    func changedSignalRefetches() async throws {
        StubURLProtocol.reset()
        stubBothOK(summary: StatusFixtures.summaryDegraded)
        let client = makeClient()
        #expect(await client.poll()?.severity == .degraded)

        StubURLProtocol.stubs[statusPath] = .init(statusCode: 200,
                                                  body: StatusFixtures.statusNone,
                                                  etag: #""status-v2""#)
        StubURLProtocol.stubs[summaryPath] = .init(statusCode: 200,
                                                   body: StatusFixtures.summaryOperational,
                                                   etag: #""summary-v2""#)

        let resolved = await client.poll()
        #expect(resolved == .operational)
        #expect(StubURLProtocol.requests(forPath: summaryPath).count == 2)
    }

    /// The fixture → live switch discards the store's last value; the client must be able to
    /// forget its conditional state with it, or the next poll 304s past a live incident.
    @Test("resetETags makes the next poll unconditional again")
    func resetETagsForgetsConditionalState() async throws {
        StubURLProtocol.reset()
        stubBothOK()
        let client = makeClient()
        _ = await client.poll()

        await client.resetETags()
        let status = await client.poll()

        #expect(status != nil, "an unchanged page must still be re-read in full after a reset")
        let statusRetry = try #require(StubURLProtocol.requests(forPath: statusPath).last)
        #expect(statusRetry.value(forHTTPHeaderField: "If-None-Match") == nil)
        let summaryRetry = try #require(StubURLProtocol.requests(forPath: summaryPath).last)
        #expect(summaryRetry.value(forHTTPHeaderField: "If-None-Match") == nil)
        #expect(StubURLProtocol.requests(forPath: summaryPath).count == 2)
    }

    @Test("a server error returns nil rather than a fabricated verdict")
    func serverError() async {
        StubURLProtocol.reset()
        StubURLProtocol.stubs = [statusPath: .init(statusCode: 500)]

        #expect(await makeClient().poll() == nil)
        #expect(StubURLProtocol.requests(forPath: summaryPath).isEmpty)
    }

    @Test("a connection failure returns nil and never throws")
    func connectionFailure() async {
        StubURLProtocol.reset()
        StubURLProtocol.failure = URLError(.notConnectedToInternet)

        #expect(await makeClient().poll() == nil)
    }

    /// The regression the ETag-commit ordering exists to prevent: the signal moves (an
    /// incident just started), the summary fetch fails once, and a client that had already
    /// kept the new status ETag would be told 304 on every later poll — reporting nothing
    /// for as long as the page happens not to change again.
    @Test("a failed summary fetch does not advance the status ETag, so the next poll retries unconditionally")
    func summaryFailureRetriesUnconditionally() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.stubs = [
            statusPath: .init(statusCode: 200, body: StatusFixtures.statusMinor, etag: #""s1""#),
            summaryPath: .init(statusCode: 500),
        ]
        let client = makeClient()

        #expect(await client.poll() == nil)

        // The page has NOT changed since — the stub would honour `If-None-Match: "s1"` with
        // a 304 — so only a client that refused to remember "s1" ever sees the summary.
        StubURLProtocol.stubs[summaryPath] = .init(statusCode: 200,
                                                   body: StatusFixtures.summaryDegraded,
                                                   etag: #""m1""#)
        let status = await client.poll()

        #expect(status?.severity == .degraded)
        let retry = try #require(StubURLProtocol.requests(forPath: statusPath).last)
        #expect(retry.value(forHTTPHeaderField: "If-None-Match") == nil,
                "the ETag of a poll whose summary was never heard must not become conditional state")
    }

    /// The status page serving something unparseable must not be able to clear a live banner.
    @Test("an unparseable summary returns nil and does not remember its ETag")
    func unparseableSummary() async {
        StubURLProtocol.reset()
        StubURLProtocol.stubs = [
            statusPath: .init(statusCode: 200, body: StatusFixtures.statusMinor, etag: #""s""#),
            summaryPath: .init(statusCode: 200, body: "{}", etag: #""m""#),
        ]
        let client = makeClient()

        #expect(await client.poll() == nil)

        // Next round the summary is readable again — and must be asked for unconditionally,
        // because the bad response was never accepted as a cached state.
        StubURLProtocol.stubs[statusPath] = .init(statusCode: 200,
                                                  body: StatusFixtures.statusNone,
                                                  etag: #""s2""#)
        StubURLProtocol.stubs[summaryPath] = .init(statusCode: 200,
                                                   body: StatusFixtures.summaryOutage,
                                                   etag: #""m2""#)
        #expect(await client.poll()?.severity == .outage)
        #expect(StubURLProtocol.requests(forPath: summaryPath).last?
            .value(forHTTPHeaderField: "If-None-Match") == nil)
    }
}
