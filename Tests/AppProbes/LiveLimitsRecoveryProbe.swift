import Foundation
import TokiCore
import TokiAccounts
import TokiMenuBar

actor AuthorizedCredential: CredentialProviding {
    var forcedReads = 0
    func currentCredential() async throws -> OAuthCredential {
        try await currentCredential(userInitiated: false, forceRefresh: false)
    }
    func currentCredential(userInitiated: Bool, forceRefresh: Bool) async throws -> OAuthCredential {
        if forceRefresh {
            forcedReads += 1
            throw TokiError.keychainDenied
        }
        return OAuthCredential(accessToken: "fixture-token", refreshToken: nil, expiresAt: nil, source: .vault,
                               account: UsageAccount(accountUuid: "fixture", organizationUuid: "org"))
    }
}
actor SwitchingAuthorizedCredential: CredentialProviding {
    private var accountID = "account-a"
    func select(_ account: String) { accountID = account }
    func currentCredential() async throws -> OAuthCredential {
        try await currentCredential(userInitiated: false, forceRefresh: false)
    }
    func currentCredential(userInitiated: Bool, forceRefresh: Bool) async throws -> OAuthCredential {
        OAuthCredential(accessToken: "fixture-\(accountID)", refreshToken: nil, expiresAt: nil,
                        source: .vault,
                        account: UsageAccount(accountUuid: accountID, organizationUuid: "org"))
    }
}
final class Responses: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func next() -> Int { lock.withLock { count += 1; return count } }
    var served: Int { lock.withLock { count } }
}
final class UsageTransport: URLProtocol, @unchecked Sendable {
    static let responses = Responses()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        switch request.url?.absoluteString {
        case "https://api.anthropic.com/api/oauth/usage":
            let count = Self.responses.next()
            client?.urlProtocol(self, didLoad: Data("{\"five_hour\":{\"utilization\":\(count * 10),\"resets_at\":null}}".utf8))
        case "https://api.anthropic.com/api/oauth/usage?cedar_ember=1&skip_spend=1":
            client?.urlProtocol(self, didLoad: Data("{\"cedar_ember\":{\"eligible\":false,\"grants\":[]}}".utf8))
        default:
            preconditionFailure("Unexpected URL: \(request.url?.absoluteString ?? "nil")")
        }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
@main struct RecoveryProbe {
    @MainActor static func main() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [UsageTransport.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let credential = AuthorizedCredential()
        let controller = UsageRefreshController(
            minimumInterval: 0, firstRateLimitInterval: 0, repeatedRateLimitInterval: 0
        )
        let service = LimitsService(credentials: credential, session: session,
                                    cache: LimitsCache(fileURL: dir.appendingPathComponent("claude.json")),
                                    refreshController: controller)
        let signedIn = SignedInAccount(configURL: dir.appendingPathComponent("unused.json"))
        signedIn.identity = AccountIdentity(accountUuid: "fixture", email: nil, displayName: nil,
                                             organizationName: nil, organizationUuid: "org")
        let live = LiveLimits(limits: service,
                              codex: CodexLimitsService(cache: LimitsCache(fileURL: dir.appendingPathComponent("codex.json")),
                                                        refreshController: controller),
                              signedIn: signedIn)
        for expected in [0.1, 0.2] {
            live.refreshNow()
            try await waitFor(live, utilization: expected)
        }
        live.state = .needsAccess
        live.credentialAccessDidRecover()
        try await waitFor(live, utilization: 0.3)
        let forced = await credential.forcedReads
        precondition(forced == 0, "ordinary refresh or repair completion re-read protected credentials")
        let lastSnapshot = live.limits
        live.state = .stale(lastSnapshot!.fetchedAt)
        precondition(live.limits?.fetchedAt == lastSnapshot?.fetchedAt && live.limits?.fiveHour?.utilization == 0.3, "stale usage disappeared from app consumers")
        signedIn.identity = AccountIdentity(accountUuid: "other", email: nil, displayName: nil,
                                             organizationName: nil, organizationUuid: "org")
        precondition(live.limits == nil, "previous account usage leaked to the new account")
        live.stop()
        try await verifyAccountReturnRetainsSnapshot(session: session, directory: dir)
        print("PASS: real LiveLimits refreshes fetch new HTTP usage without forced credential reads; repair publishes immediately")
    }
    @MainActor static func verifyAccountReturnRetainsSnapshot(session: URLSession, directory: URL) async throws {
        let controller = UsageRefreshController()
        let credential = SwitchingAuthorizedCredential()
        let signedIn = SignedInAccount(configURL: directory.appendingPathComponent("unused-switch.json"))
        func identity(_ id: String) -> AccountIdentity {
            AccountIdentity(accountUuid: id, email: nil, displayName: nil,
                            organizationName: nil, organizationUuid: "org")
        }
        signedIn.identity = identity("account-a")
        let live = LiveLimits(
            limits: LimitsService(credentials: credential, session: session,
                                  cache: LimitsCache(fileURL: directory.appendingPathComponent("claude-switch.json")),
                                  refreshController: controller),
            codex: CodexLimitsService(cache: LimitsCache(fileURL: directory.appendingPathComponent("codex-switch.json")),
                                      refreshController: controller),
            signedIn: signedIn)
        let suite = "toki-switch-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let menu = MenuBarViewModel(
            live: live,
            configurationState: MenuBarConfigurationState(
                store: MenuBarConfigurationStore(defaults: defaults)),
            usageDisplayState: UsageDisplayConfigurationState(
                store: UsageDisplayConfigurationStore(defaults: defaults)),
            availableProviders: [.claudeCode]
        )
        let firstRequest = UsageTransport.responses.served + 1
        live.refreshNow()
        try await waitFor(live, utilization: Double(firstRequest) / 10)
        let firstSnapshot = live.limits!
        precondition(menu.currentClaudeResetLimits != nil, "fresh Claude reset projection missing")

        live.accountWillChange()
        await credential.select("account-b")
        // Simulate swap completion before the debounced config watcher updates the
        // observed identity. The old A snapshot must not be restored as B's.
        live.accountDidChange(expectedAccountID: "account-b")
        precondition(live.limits == nil, "stale signed-in identity restored A during a switch to B")
        precondition(menu.currentClaudeResetLimits == nil, "A reset leaked to B during identity lag")
        signedIn.identity = identity("account-b")
        try await waitFor(live, utilization: Double(firstRequest + 1) / 10)

        live.accountWillChange()
        signedIn.identity = identity("account-a")
        await credential.select("account-a")
        live.accountDidChange()
        precondition(live.limits?.fetchedAt == firstSnapshot.fetchedAt,
                     "return to account A did not restore its own snapshot")
        precondition(live.state == .stale(firstSnapshot.fetchedAt),
                     "returned account snapshot should be marked stale")
        precondition(menu.allowsStaleClaudeResetDisplay && menu.currentClaudeResetLimits != nil,
                     "return to A hid its last-known reset during the cooldown")
        try await Task.sleep(for: .milliseconds(100))
        precondition(UsageTransport.responses.served == firstRequest + 1,
                     "return to account A bypassed its 90-second cooldown")
        live.stop()
    }
    @MainActor static func waitFor(_ live: LiveLimits, utilization: Double) async throws {
        // Ten seconds, not two: `scripts/check.sh` runs this right after the whole test suite,
        // and a loaded machine can take longer than two seconds to answer one stubbed request.
        for _ in 0..<1000 {
            if live.limits?.fiveHour?.utilization == utilization { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NSError(domain: "LiveLimitsRecoveryProbe", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Expected fresh utilization \(utilization), got state \(live.state)"])
    }
}
