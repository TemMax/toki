import Foundation
import Testing
import TokiModels
@testable import TokiLimits

private final class MutableNow: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_000)

    func read() -> Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value.addTimeInterval(seconds) } }
}

private actor CodexSelection {
    private var id = "account-a"
    func select(_ value: String) { id = value }
    func read() -> String { id }
}

private struct BoundCredential: CredentialProviding {
    func currentCredential() async throws -> OAuthCredential {
        OAuthCredential(
            accessToken: "synthetic", refreshToken: nil, expiresAt: nil,
            account: UsageAccount(accountUuid: "account-a", organizationUuid: nil)
        )
    }
}

private struct SwitchingCredential: CredentialProviding {
    func currentCredential() async throws -> OAuthCredential {
        try await currentCredential(userInitiated: false, forceRefresh: false)
    }
    func currentCredential(userInitiated: Bool, forceRefresh: Bool) async throws -> OAuthCredential {
        OAuthCredential(
            accessToken: forceRefresh ? "new-account-token" : "old-account-token",
            refreshToken: nil, expiresAt: nil,
            account: UsageAccount(
                accountUuid: forceRefresh ? "new-account" : "old-account",
                organizationUuid: nil
            )
        )
    }
}

private final class CountedUsageProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var calls = 0
    static func reset() { lock.withLock { calls = 0 } }
    static var count: Int { lock.withLock { calls } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.withLock { Self.calls += 1 }
        let body = request.url?.query == nil
            ? #"{"five_hour":{"utilization":25,"resets_at":null}}"#
            : #"{"cedar_ember":{"eligible":false,"grants":[]}}"#
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class ExpiredUsageProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var calls = 0
    static func reset() { lock.withLock { calls = 0 } }
    static var count: Int { lock.withLock { calls } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.withLock { Self.calls += 1 }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite("Shared usage request cadence", .serialized)
struct UsageRefreshControllerTests {
    @Test("Codex restores only the returned account's snapshot while its permit cools down")
    func codexAccountReturn() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-switch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("codex-stub")
        try """
        #!/usr/bin/python3
        import json, sys
        for line in sys.stdin:
            request = json.loads(line)
            if "id" in request:
                result = {}
                if request.get("method") == "account/rateLimits/read":
                    result = {"rateLimits": {"limitId": "codex", "primary":
                        {"usedPercent": 20, "windowDurationMins": 300, "resetsAt": None},
                        "secondary": None}}
                print(json.dumps({"id": request["id"], "result": result}), flush=True)
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: executable.path
        )
        let selection = CodexSelection()
        let service = CodexLimitsService(
            client: CodexAppServerClient(executableURL: executable),
            cache: LimitsCache(fileURL: directory.appendingPathComponent("cache.json")),
            refreshController: UsageRefreshController(),
            accountID: { await selection.read() }
        )

        let a = try await service.fetchLimits()
        await selection.select("account-b")
        await service.accountDidChange()
        let b = try await service.fetchLimits()
        #expect(b.fetchedAt >= a.fetchedAt)
        await selection.select("account-a")
        await service.accountDidChange()
        let previous = await service.lastSnapshotForCurrentAccount()
        #expect(previous?.fetchedAt == a.fetchedAt)
        await #expect(throws: UsageRefreshDeferred.self) { try await service.fetchLimits() }
    }

    @Test("a 401 retry never sends a different account's token under the old permit")
    func switchedCredentialDuringRetry() async throws {
        ExpiredUsageProtocol.reset()
        let controller = UsageRefreshController()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ExpiredUsageProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("usage-switch-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: cacheURL) }
        let service = LimitsService(
            credentials: SwitchingCredential(), session: session,
            cache: LimitsCache(fileURL: cacheURL), refreshController: controller
        )

        await #expect(throws: CancellationError.self) { try await service.fetchLimits() }
        #expect(ExpiredUsageProtocol.count == 1)
    }

    @Test("an unchanged expired token cannot spend another permit on the next popover open")
    func repeatedUnauthorizedResponse() async throws {
        ExpiredUsageProtocol.reset()
        let clock = MutableNow()
        let controller = UsageRefreshController(now: { clock.read() })
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ExpiredUsageProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("usage-expired-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: cacheURL) }
        let service = LimitsService(
            credentials: BoundCredential(), session: session,
            cache: LimitsCache(fileURL: cacheURL), refreshController: controller
        )

        await #expect(throws: TokiError.tokenExpired) { try await service.fetchLimits() }
        #expect(ExpiredUsageProtocol.count == 1)
        await #expect(throws: UsageRefreshDeferred.self) { try await service.fetchLimits() }
        #expect(ExpiredUsageProtocol.count == 1)
        clock.advance(90)
        await #expect(throws: TokiError.tokenExpired) { try await service.fetchLimits() }
        #expect(ExpiredUsageProtocol.count == 2)
    }

    @Test("the real Claude feed preserves a snapshot without extra HTTP calls on rapid refresh")
    @MainActor
    func claudeFeedIntegration() async throws {
        CountedUsageProtocol.reset()
        let clock = MutableNow()
        let controller = UsageRefreshController(now: { clock.read() })
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CountedUsageProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("usage-controller-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: cacheURL) }
        let service = LimitsService(
            credentials: BoundCredential(), session: session,
            cache: LimitsCache(fileURL: cacheURL), refreshController: controller,
            now: { clock.read() }
        )
        let feed = LiveUsageFeed { _ in try await service.fetchLimits() }

        await feed.refresh()
        #expect(feed.state == .ok)
        #expect(CountedUsageProtocol.count == 2) // primary and reset-only requests
        let firstDate = feed.limits?.fetchedAt
        await feed.refresh()
        #expect(CountedUsageProtocol.count == 2)
        #expect(feed.state == .ok)
        #expect(feed.limits?.fetchedAt == firstDate)

        // The next usage poll reuses the resets it already has: one request, not two.
        clock.advance(90)
        await feed.refresh()
        #expect(CountedUsageProtocol.count == 3)

        clock.advance(LimitsService.defaultResetsRefreshInterval)
        await feed.refresh()
        #expect(CountedUsageProtocol.count == 5)
    }

    @Test("popover bursts and the background tick share one 90-second window")
    func rapidRefreshes() async {
        let clock = MutableNow()
        let controller = UsageRefreshController(now: { clock.read() })
        let key = UsageRefreshKey(provider: .claude, accountID: "account-a")

        let first = await controller.begin(key)
        #expect(first != nil)
        #expect(await controller.begin(key) == nil)
        if let first { await controller.finish(first, outcome: .success) }
        #expect(await controller.begin(key) == nil)
        clock.advance(89)
        #expect(await controller.begin(key) == nil)
        clock.advance(1)
        #expect(await controller.begin(key) != nil)
    }

    @Test("an account switch has its own cadence without resetting the previous account")
    func accountIsolation() async {
        let clock = MutableNow()
        let controller = UsageRefreshController(now: { clock.read() })
        let a = UsageRefreshKey(provider: .claude, accountID: "a")
        let b = UsageRefreshKey(provider: .claude, accountID: "b")
        let otherOrganization = UsageRefreshKey(
            provider: .claude, accountID: "a", organizationID: "another-org"
        )
        let codex = UsageRefreshKey(provider: .codex, accountID: "a")

        #expect(await controller.begin(a) != nil)
        #expect(await controller.begin(b) != nil)
        #expect(await controller.begin(otherOrganization) != nil)
        #expect(await controller.begin(codex) != nil)
        #expect(await controller.begin(a) == nil)
    }

    @Test("rate limits defer both manual and background requests, then recover")
    func rateLimitBackoff() async {
        let clock = MutableNow()
        let controller = UsageRefreshController(now: { clock.read() })
        let key = UsageRefreshKey(provider: .claude, accountID: "a")

        let first = await controller.begin(key)
        #expect(first != nil)
        if let first { await controller.finish(first, outcome: .rateLimited(retryAfter: 180)) }
        clock.advance(359)
        #expect(await controller.begin(key) == nil)
        clock.advance(1)
        let second = await controller.begin(key)
        #expect(second != nil)
        if let second { await controller.finish(second, outcome: .rateLimited(retryAfter: 180)) }
        clock.advance(719)
        #expect(await controller.begin(key) == nil)
        clock.advance(1)
        let recovered = await controller.begin(key)
        #expect(recovered != nil)
        if let recovered { await controller.finish(recovered, outcome: .success) }
        clock.advance(90)
        #expect(await controller.begin(key) != nil)
    }
}

@Suite("UsageRefreshController across launches")
struct UsageRefreshControllerPersistenceTests {

    private func scheduleURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("usage-schedule-\(UUID().uuidString)")
            .appendingPathComponent("usage-refresh-schedule.json")
    }

    private let key = UsageRefreshKey(provider: .claude, accountID: "account-a", organizationID: "org-a")

    @Test("A relaunch inside the 90-second floor does not ask again")
    func floorSurvivesRelaunch() async {
        let url = scheduleURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let clock = MutableNow()

        let first = UsageRefreshController(scheduleURL: url, now: { clock.read() })
        let permit = await first.begin(key)
        #expect(permit != nil)
        if let permit { await first.finish(permit, outcome: .success) }

        clock.advance(30)
        let relaunched = UsageRefreshController(scheduleURL: url, now: { clock.read() })
        #expect(await relaunched.begin(key) == nil)
        clock.advance(61)
        #expect(await relaunched.begin(key) != nil)
    }

    @Test("A relaunch during a 429 backoff keeps waiting, and the streak carries over")
    func backoffSurvivesRelaunch() async {
        let url = scheduleURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let clock = MutableNow()

        let first = UsageRefreshController(scheduleURL: url, now: { clock.read() })
        if let permit = await first.begin(key) {
            await first.finish(permit, outcome: .rateLimited(retryAfter: 180))
        }

        clock.advance(300)
        let relaunched = UsageRefreshController(scheduleURL: url, now: { clock.read() })
        #expect(await relaunched.begin(key) == nil, "360 s backoff, 300 s elapsed")
        clock.advance(61)
        let permit = await relaunched.begin(key)
        #expect(permit != nil)
        // A second 429 in a row is the repeated (720 s) backoff, not the first again.
        if let permit { await relaunched.finish(permit, outcome: .rateLimited(retryAfter: 0)) }
        clock.advance(700)
        #expect(await UsageRefreshController(scheduleURL: url, now: { clock.read() }).begin(key) == nil)
        clock.advance(21)
        #expect(await UsageRefreshController(scheduleURL: url, now: { clock.read() }).begin(key) != nil)
    }

    @Test("A saved wait is never longer than the longest wait the controller sets")
    func clockJumpIsCapped() async throws {
        let url = scheduleURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let clock = MutableNow()
        let first = UsageRefreshController(scheduleURL: url, now: { clock.read() })
        if let permit = await first.begin(key) { await first.finish(permit, outcome: .success) }

        // The clock moves a day backwards between launches.
        clock.advance(-86_400)
        let relaunched = UsageRefreshController(scheduleURL: url, now: { clock.read() })
        #expect(await relaunched.begin(key) == nil)
        clock.advance(721)
        #expect(await relaunched.begin(key) != nil)
    }

    @Test("Without a schedule file the cadence starts fresh")
    func noFile() async {
        let controller = UsageRefreshController(scheduleURL: scheduleURL())
        #expect(await controller.begin(key) != nil)
    }
}
