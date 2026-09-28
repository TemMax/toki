import Foundation
import TokiAccounts
import TokiCore
import TokiMenuBar

private struct SyntheticCredentials: CredentialProviding {
    let account: UsageAccount

    func currentCredential() async throws -> OAuthCredential {
        OAuthCredential(
            accessToken: "synthetic-token",
            refreshToken: nil,
            expiresAt: nil,
            source: .vault,
            account: account
        )
    }
}

/// Lets the probe step past the real reset-metadata cadence without waiting ten minutes.
private final class ProbeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date()
    var now: Date { lock.withLock { current } }
    func passResetsInterval() {
        lock.withLock { current += LimitsService.defaultResetsRefreshInterval + 1 }
    }
}

private struct StubResponse: Sendable {
    let statusCode: Int?
    let body: Data
    let error: URLError?

    static func http(_ statusCode: Int, _ body: String = "") -> Self {
        Self(statusCode: statusCode, body: Data(body.utf8), error: nil)
    }

    static func transport(_ code: URLError.Code) -> Self {
        Self(statusCode: nil, body: Data(), error: URLError(code))
    }
}

private final class ResponseScript: @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [StubResponse] = []
    private var served = 0

    func replace(with responses: [StubResponse]) {
        lock.withLock {
            self.responses = responses
            served = 0
        }
    }

    func next() -> StubResponse {
        lock.withLock {
            precondition(!responses.isEmpty, "Unexpected synthetic usage request")
            served += 1
            return responses.removeFirst()
        }
    }

    var servedCount: Int { lock.withLock { served } }
}

private final class UsageURLProtocol: URLProtocol, @unchecked Sendable {
    static let script = ResponseScript()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let stub = Self.script.next()
        if let error = stub.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: stub.statusCode!,
            httpVersion: nil,
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@main
struct ClaudeResetsProbe {
    private struct System {
        let live: LiveLimits
        let menu: MenuBarViewModel
        let signedIn: SignedInAccount
        let session: URLSession
        let clock: ProbeClock
    }

    @MainActor
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("toki-claude-resets-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let suiteName = "toki-claude-resets-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw NSError(domain: "ClaudeResetsProbe", code: 1)
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let claudeAccount = UsageAccount(accountUuid: "claude-a", organizationUuid: "org")
        let system = makeSystem(
            directory: directory,
            defaults: defaults,
            account: claudeAccount,
            cacheName: "main"
        )
        defer { system.session.invalidateAndCancel() }

        var failures: [String] = []
        func require(_ condition: Bool, _ message: String) {
            if !condition { failures.append(message) }
        }
        func claudeCount(_ limits: UsageLimits?) -> Int? {
            limits?.claudeResets?.totalResets
        }

        UsageURLProtocol.script.replace(with: [
            .http(200, primaryBody(utilization: 25)),
            .http(200, resetBody(count: 2)),
            .http(200, primaryBody(utilization: 35)),
            .http(429, #"{"error":"rate_limited"}"#),
            .http(429, #"{"error":"rate_limited"}"#),
            .http(200, primaryBody(utilization: 45)),
            .http(200, resetBody(count: 5)),
            .transport(.notConnectedToInternet),
            .http(401, #"{"error":"unauthorized"}"#),
            .http(200, primaryBody(utilization: 55)),
            .http(404),
        ])

        system.live.refreshNow()
        try await waitForRequests(2)
        try await waitFor("initial success") { system.live.state == .ok }
        let firstSnapshot = system.live.limits
        require(claudeCount(system.menu.currentClaudeResetLimits) == 2,
                "initial production fetch did not project the Claude reset count")

        system.live.codexLimits = UsageLimits(
            windows: [], extra: nil, fetchedAt: Date(),
            bankedResets: BankedResets(availableCount: 7, credits: nil)
        )
        system.live.codexState = .ok

        // The reset request is due again, and only it is rate limited: the fresh gauges are
        // published as current, carrying the account's last known reset count.
        system.clock.passResetsInterval()
        system.live.refreshNow()
        try await waitForRequests(4)
        try await waitFor("supplemental rate limit") {
            system.live.state == .ok && system.live.limits?.fiveHour?.utilization == 0.35
        }
        let partialSnapshot = system.live.limits
        require(partialSnapshot?.fetchedAt != firstSnapshot?.fetchedAt,
                "supplemental rate limit discarded the fresh gauges for the older snapshot")
        require(system.live.failure == nil,
                "a rate-limited reset request marked fresh usage as failed")
        require(claudeCount(system.menu.currentClaudeResetLimits) == 2,
                "supplemental rate limit hid the retained active-account reset count")

        // Now the usage request itself is rate limited: the last snapshot stays, marked stale,
        // and its reset count remains presentable past the freshness ceiling.
        system.live.refreshNow()
        try await waitForRequests(5)
        try await waitFor("main rate limit") { system.live.failure == .rateLimited }
        require(system.live.limits?.fetchedAt == partialSnapshot?.fetchedAt,
                "main rate limit changed the retained snapshot")
        require(system.menu.allowsStaleClaudeResetDisplay,
                "rate-limited stale feed did not enable last-known reset presentation")
        require(claudeCount(system.menu.currentClaudeResetLimits) == 2,
                "main rate limit lost the retained count")
        if let retained = system.menu.currentClaudeResetLimits,
           let resets = retained.claudeResets {
            let afterFreshnessCeiling = retained.fetchedAt.addingTimeInterval(211)
            require(
                resets.displayState(
                    fetchedAt: retained.fetchedAt,
                    now: afterFreshnessCeiling,
                    allowsStale: system.menu.allowsStaleClaudeResetDisplay
                ) == .balance(2),
                "rate-limited reset count did not remain present beyond 210 seconds"
            )
            require(
                resets.displayState(fetchedAt: retained.fetchedAt, now: afterFreshnessCeiling) == .hidden,
                "strict domain presentation default was weakened"
            )
        } else {
            failures.append("rate-limited stale projection had no reset metadata")
        }

        var hiddenConfiguration = system.menu.usageDisplayConfiguration
        hiddenConfiguration[.claudeCode].isEnabled = false
        system.menu.usageDisplayConfiguration = hiddenConfiguration
        require(system.menu.currentClaudeResetLimits == nil,
                "provider-wide Claude disable exposed retained reset metadata")
        hiddenConfiguration[.claudeCode].isEnabled = true
        hiddenConfiguration[.claudeCode].hiddenWindowIDs = ["session"]
        hiddenConfiguration[.claudeCode].showsExtraUsage = false
        system.menu.usageDisplayConfiguration = hiddenConfiguration
        require(system.menu.displayedLimits(for: .claudeCode) == nil,
                "all filtered gauge windows unexpectedly produced a limits tile")
        require(claudeCount(system.menu.currentClaudeResetLimits) == 2,
                "gauge filtering hid provider-enabled retained reset state")

        let missingClaude = MenuBarViewModel(
            live: system.live,
            configurationState: MenuBarConfigurationState(
                store: MenuBarConfigurationStore(defaults: defaults)
            ),
            usageDisplayState: UsageDisplayConfigurationState(
                store: UsageDisplayConfigurationStore(defaults: defaults)
            ),
            availableProviders: [.codex]
        )
        require(missingClaude.currentClaudeResetLimits == nil,
                "missing Claude provider exposed retained reset metadata")

        system.signedIn.identity = identity(accountUuid: "claude-b")
        require(system.menu.currentClaudeResetLimits == nil,
                "previous-account Claude reset state leaked across an identity transition")
        system.signedIn.identity = identity(accountUuid: claudeAccount.accountUuid)

        system.clock.passResetsInterval()
        system.live.refreshNow()
        try await waitForRequests(7)
        try await waitFor("recovery success") {
            system.live.state == .ok && claudeCount(system.live.limits) == 5
        }
        require(claudeCount(system.menu.currentClaudeResetLimits) == 5,
                "recovery did not replace the retained count with the new value")
        require(system.live.limits?.fetchedAt != firstSnapshot?.fetchedAt,
                "recovery did not publish a new snapshot timestamp")
        require(!system.menu.allowsStaleClaudeResetDisplay,
                "successful recovery left the stale rate-limit presentation flag enabled")

        system.live.codexState = .error("fixture Codex failure")
        require(claudeCount(system.menu.currentClaudeResetLimits) == 5,
                "Codex failure hid independent Claude reset state")
        system.live.codexState = .ok

        var projectedConfiguration = system.menu.usageDisplayConfiguration
        projectedConfiguration[.claudeCode].hiddenWindowIDs = []
        projectedConfiguration[.claudeCode].showsExtraUsage = true
        system.menu.usageDisplayConfiguration = projectedConfiguration
        require(
            system.menu.displayedLimits(for: .claudeCode)?.claudeResets
                == system.live.limits?.claudeResets,
            "display projection dropped Claude reset metadata"
        )

        for state: LiveLimits.State in [
            .loading,
            .stale(Date()),
            .notLoggedIn,
            .needsAccess,
            .error("fixture"),
        ] {
            system.live.state = state
            require(system.menu.currentClaudeResetLimits == nil,
                    "non-ok non-rate-limited Claude state exposed reset metadata: \(state)")
        }
        system.live.state = .ok

        system.live.refreshNow()
        try await waitFor("network failure") { system.live.failure == .network }
        require(system.menu.currentClaudeResetLimits == nil,
                "generic network failure exposed retained reset metadata")
        require(system.menu.currentCodexResetLimits?.bankedResets?.availableCount == 7,
                "Claude network failure hid independent Codex reset state")

        system.live.refreshNow()
        try await waitFor("authorization failure") { system.live.failure == .authorization }
        require(system.menu.currentClaudeResetLimits == nil,
                "authorization failure exposed retained reset metadata")
        require(system.menu.currentCodexResetLimits?.bankedResets?.availableCount == 7,
                "Claude authorization failure hid independent Codex reset state")

        system.clock.passResetsInterval()
        system.live.refreshNow()
        try await waitFor("success without reset metadata") { system.live.state == .ok }
        require(system.live.limits?.claudeResets == nil,
                "successful response without reset metadata resurrected an old reset payload")
        require(system.menu.currentClaudeResetLimits == nil,
                "successful response without reset metadata exposed an old reset count")

        let partialSystem = makeSystem(
            directory: directory,
            defaults: defaults,
            account: claudeAccount,
            cacheName: "partial"
        )
        defer { partialSystem.session.invalidateAndCancel() }
        UsageURLProtocol.script.replace(with: [
            .http(200, primaryBody(utilization: 65)),
            .http(429, #"{"error":"rate_limited"}"#),
        ])
        partialSystem.live.refreshNow()
        try await waitForRequests(2)
        try await waitFor("first supplemental rate limit") {
            partialSystem.live.state == .ok
        }
        require(partialSystem.live.limits?.fiveHour?.utilization == 0.65,
                "first supplemental rate limit discarded ordinary usage")
        require(partialSystem.live.failure == nil,
                "first supplemental rate limit marked fresh usage as failed")
        require(partialSystem.live.limits?.claudeResets == nil,
                "first rate limit without prior data invented reset metadata")
        require(partialSystem.menu.currentClaudeResetLimits == nil,
                "first rate limit without prior data exposed a reset count")

        let emptySystem = makeSystem(
            directory: directory,
            defaults: defaults,
            account: claudeAccount,
            cacheName: "empty"
        )
        defer { emptySystem.session.invalidateAndCancel() }
        UsageURLProtocol.script.replace(with: [.http(429, #"{"error":"rate_limited"}"#)])
        emptySystem.live.refreshNow()
        try await waitForRequests(1)
        try await waitFor("empty first main rate limit") {
            emptySystem.live.failure == .rateLimited
        }
        require(emptySystem.live.limits == nil,
                "first main rate limit manufactured a usage snapshot")
        require(emptySystem.menu.currentClaudeResetLimits == nil,
                "first main rate limit without prior data exposed a reset count")
        require(!emptySystem.menu.allowsStaleClaudeResetDisplay,
                "first main rate limit without stale data enabled stale presentation")

        system.live.stop()
        partialSystem.live.stop()
        emptySystem.live.stop()
        guard failures.isEmpty else {
            for failure in failures { print("FAIL: \(failure)") }
            exit(1)
        }
        print("PASS: production primary success + supplemental reset -> supplemental 429 keeps usage fresh with the retained reset count -> main 429 -> recovery publishes a new count, respects presentation guards, and preserves Codex independence")
    }

    @MainActor
    private static func makeSystem(
        directory: URL,
        defaults: UserDefaults,
        account: UsageAccount,
        cacheName: String
    ) -> System {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [UsageURLProtocol.self]
        let session = URLSession(configuration: config)
        let signedIn = SignedInAccount(configURL: directory.appendingPathComponent("unused-\(cacheName).json"))
        signedIn.identity = identity(accountUuid: account.accountUuid)
        let clock = ProbeClock()
        let live = LiveLimits(
            limits: LimitsService(
                credentials: SyntheticCredentials(account: account),
                session: session,
                cache: LimitsCache(fileURL: directory.appendingPathComponent("claude-\(cacheName).json")),
                refreshController: UsageRefreshController(
                    minimumInterval: 0, firstRateLimitInterval: 0, repeatedRateLimitInterval: 0
                ),
                now: { clock.now }
            ),
            codex: CodexLimitsService(
                cache: LimitsCache(fileURL: directory.appendingPathComponent("codex-\(cacheName).json")),
                refreshController: UsageRefreshController()
            ),
            signedIn: signedIn
        )
        return System(
            live: live,
            menu: MenuBarViewModel(
                live: live,
                configurationState: MenuBarConfigurationState(
                    store: MenuBarConfigurationStore(defaults: defaults)
                ),
                usageDisplayState: UsageDisplayConfigurationState(
                    store: UsageDisplayConfigurationStore(defaults: defaults)
                ),
                availableProviders: [.claudeCode, .codex]
            ),
            signedIn: signedIn,
            session: session,
            clock: clock
        )
    }

    private static func identity(accountUuid: String) -> AccountIdentity {
        AccountIdentity(
            accountUuid: accountUuid,
            email: "fixture@example.com",
            displayName: "Fixture",
            organizationName: "Synthetic",
            organizationUuid: "org"
        )
    }

    private static func primaryBody(utilization: Int) -> String {
        """
        {
          "five_hour": {"utilization": \(utilization), "resets_at": null}
        }
        """
    }

    private static func resetBody(count: Int) -> String {
        """
        {
          "cedar_ember": {
            "eligible": true,
            "grants": [{
              "id": "grant",
              "label": "Weekly reset",
              "resets_total": \(count),
              "resets_left": \(count),
              "usable_now": true
            }],
            "next_grant_id": "grant"
          }
        }
        """
    }

    private static func waitForRequests(_ count: Int) async throws {
        for _ in 0..<300 {
            if UsageURLProtocol.script.servedCount >= count { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NSError(
            domain: "ClaudeResetsProbe",
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for \(count) requests"]
        )
    }

    @MainActor
    private static func waitFor(
        _ description: String,
        condition: @MainActor () -> Bool
    ) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NSError(
            domain: "ClaudeResetsProbe",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for \(description)"]
        )
    }
}
