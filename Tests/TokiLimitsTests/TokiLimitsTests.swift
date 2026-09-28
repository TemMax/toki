import Testing
import Foundation
import TokiModels
@testable import TokiLimits

// Legacy wire/credential tests exercise several responses in immediate succession.
// They explicitly disable cadence; controller behavior is covered by
// UsageRefreshControllerTests using the real service and a controllable clock.
private extension LimitsService {
    init(
        credentials: any CredentialProviding,
        userAgent: String = OAuthUsageClient.defaultUserAgent,
        session: URLSession = .shared,
        cache: LimitsCache = LimitsCache()
    ) {
        self.init(
            credentials: credentials, userAgent: userAgent, session: session, cache: cache,
            refreshController: UsageRefreshController(
                minimumInterval: 0, firstRateLimitInterval: 0, repeatedRateLimitInterval: 0
            ),
            resetsRefreshInterval: 0
        )
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool
    init(_ value: Bool) { stored = value }
    var value: Bool {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

private final class LockedClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ start: Date) { current = start }
    var now: Date { lock.withLock { current } }
    func advance(by seconds: TimeInterval) { lock.withLock { current += seconds } }
}

// MARK: - Helpers

/// Stub credential provider that always returns the same fixed token.
private struct FixedCredentialStore: CredentialProviding {
    let token: String

    func currentCredential() async throws -> OAuthCredential {
        OAuthCredential(accessToken: token, refreshToken: nil, expiresAt: nil)
    }
}

/// Credential provider that always throws tokenExpired.
private struct ExpiredCredentialStore: CredentialProviding {
    func currentCredential() async throws -> OAuthCredential {
        throw TokiError.tokenExpired
    }
}

private final class AccountChangingCredentialStore: CredentialProviding, @unchecked Sendable {
    var onValidate: (@Sendable () async -> Void)?

    func currentCredential() async throws -> OAuthCredential {
        OAuthCredential(
            accessToken: "tok-account-change",
            refreshToken: nil,
            expiresAt: nil,
            account: UsageAccount(accountUuid: "account-before", organizationUuid: "org-before")
        )
    }

    func validateCredential(_ credential: OAuthCredential) async throws {
        await onValidate?()
    }
}

/// Regression fake for the 401 retry path: hands out an expired token until the service
/// reports it rejected, then the rotated one — verifying that LimitsService marks the dead
/// token before re-resolving, so the retry cannot reuse it.
private final class RotatingCredentialStore: CredentialProviding, @unchecked Sendable {
    private let expiredToken = "expired_tok"
    private let freshToken   = "fresh_tok"

    /// Tokens the service reported as rejected, in order.
    var rejected: [String] = []
    /// Tracks which token was handed to the most-recent request.
    var lastTokenUsed: String?

    func currentCredential() async throws -> OAuthCredential {
        let token = rejected.isEmpty ? expiredToken : freshToken
        lastTokenUsed = token
        return OAuthCredential(
            accessToken: token, refreshToken: nil, expiresAt: nil, source: .vault
        )
    }

    func markCredentialRejected(_ credential: OAuthCredential) async {
        rejected.append(credential.accessToken)
    }
}

/// Always issues the same environment-sourced token, and records rejections.
private final class EnvSourcedCredentialStore: CredentialProviding, @unchecked Sendable {
    var rejected: [String] = []

    func currentCredential() async throws -> OAuthCredential {
        OAuthCredential(
            accessToken: "env-token", refreshToken: nil, expiresAt: nil, source: .environment
        )
    }

    func markCredentialRejected(_ credential: OAuthCredential) async {
        rejected.append(credential.accessToken)
    }
}

/// Spy credential store for the popover-refresh regression test: records whether the
/// resolution was made in a user-initiated context.
private final class SpyCredentialStore: CredentialProviding, @unchecked Sendable {
    var lastUserInitiated: Bool?
    var lastForceRefresh: Bool?
    var validationFailure: TokiError?
    var credentialAccount: UsageAccount?

    func currentCredential() async throws -> OAuthCredential {
        lastUserInitiated = false
        return OAuthCredential(accessToken: "tok", refreshToken: nil, expiresAt: nil)
    }

    func currentCredential(userInitiated: Bool) async throws -> OAuthCredential {
        lastUserInitiated = userInitiated
        return OAuthCredential(accessToken: "tok", refreshToken: nil, expiresAt: nil, account: credentialAccount)
    }

    func currentCredential(userInitiated: Bool, forceRefresh: Bool) async throws -> OAuthCredential {
        lastForceRefresh = forceRefresh
        return try await currentCredential(userInitiated: userInitiated)
    }

    func validateCredential(_ credential: OAuthCredential) async throws {
        if let validationFailure { throw validationFailure }
    }
}

// MARK: - URLProtocol stub

/// A URLProtocol subclass that returns a pre-configured response for any request.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    // Configure before each test — set statusCode + body.
    nonisolated(unsafe) static var statusCode: Int = 200
    nonisolated(unsafe) static var responseData: Data = Data()
    /// Number of requests served since the last `resetCount()` — lets a test assert that a
    /// doomed retry never went out at all.
    nonisolated(unsafe) static var requestCount = 0

    static func resetCount() { requestCount = 0 }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requestCount += 1
        let url = request.url ?? URL(string: "https://example.com")!
        let response = HTTPURLResponse(
            url: url,
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

/// Dedicated exact-URL router for the reset transport tests. Keeping it separate from the
/// legacy process-global stub prevents the other test suites from affecting request counts.
final class ResetRoutingURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (Int, Data))?

    static func reset() {
        requests = []
        requestHandler = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        do {
            let configured = try Self.requestHandler?(request) ?? (500, Data())
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://example.com")!,
                statusCode: configured.0,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: configured.1)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

extension URLSession {
    /// A session backed by StubURLProtocol so no real network requests are made.
    static var stubbed: URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    static var resetStubbed: URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ResetRoutingURLProtocol.self]
        return URLSession(configuration: config)
    }
}

// MARK: - Realistic body

private let realisticBody = """
{
    "cedar_ember": {
        "eligible": false,
        "ineligible_reason": "not_enrolled",
        "grants": []
    },
    "five_hour": {
        "utilization": 4.0,
        "resets_at": "2026-06-24T16:50:00.421248+00:00"
    },
    "seven_day": {
        "utilization": 70.0,
        "resets_at": "2026-06-26T21:00:00+00:00"
    },
    "seven_day_sonnet": {
        "utilization": 16.0,
        "resets_at": "2026-06-26T21:00:00+00:00"
    },
    "extra_usage": {
        "is_enabled": true,
        "monthly_limit": 100000,
        "used_credits": 74398.0,
        "utilization": 74.398
    }
}
"""

// Mirrors the live shape observed when the 5-hour window is unused: `resets_at`
// comes back `null`. Only the fields the client reads are kept here.
private let nullResetBody = """
{
    "five_hour": {
        "utilization": 0.0,
        "resets_at": null
    },
    "seven_day": {
        "utilization": 100.0,
        "resets_at": "2026-07-10T20:59:59.937434+00:00"
    },
    "extra_usage": {
        "is_enabled": true,
        "monthly_limit": 150000,
        "used_credits": 114507.0,
        "utilization": 76.338
    }
}
"""

// Real captured response (trimmed) exercising the new data-driven `limits[]`
// array. When present, `limits[]` takes precedence over the flat fields — so the
// `seven_day_opus`/`seven_day_sonnet: null` here are correctly ignored.
private let newFormatBody = """
{
  "five_hour": { "utilization": 75.0, "resets_at": "2026-07-10T02:49:59.905255+00:00" },
  "seven_day": { "utilization": 7.0, "resets_at": "2026-07-10T20:59:59.905281+00:00" },
  "seven_day_opus": null,
  "seven_day_sonnet": null,
  "extra_usage": { "is_enabled": true, "monthly_limit": 150000, "used_credits": 128626.0, "utilization": 85.75 },
  "limits": [
    { "kind": "session", "group": "session", "percent": 75, "severity": "warning", "resets_at": "2026-07-10T02:49:59.905255+00:00", "scope": null, "is_active": true },
    { "kind": "weekly_all", "group": "weekly", "percent": 7, "severity": "normal", "resets_at": "2026-07-10T20:59:59.905281+00:00", "scope": null, "is_active": false },
    { "kind": "weekly_scoped", "group": "weekly", "percent": 0, "severity": "normal", "resets_at": null, "scope": { "model": { "id": null, "display_name": "Fable" }, "surface": null }, "is_active": false }
  ]
}
"""

// A single `weekly_scoped` entry that is not is_active but has non-zero percent
// and a real reset time — must still resolve to isAvailable == true.
private let scopedActiveByPercentBody = """
{
  "limits": [
    { "kind": "weekly_scoped", "group": "weekly", "percent": 12, "resets_at": "2026-07-10T20:59:59.905281+00:00", "scope": { "model": { "id": null, "display_name": "Opus" } }, "is_active": false }
  ]
}
"""

// Flat fields only (no `limits` key) with all four windows populated — exercises
// the legacy fallback builder, which must emit them in canonical order.
private let legacyFallbackBody = """
{
  "five_hour":        { "utilization": 10.0, "resets_at": "2026-07-10T02:49:59.905255+00:00" },
  "seven_day":        { "utilization": 20.0, "resets_at": "2026-07-10T20:59:59.905281+00:00" },
  "seven_day_opus":   { "utilization": 30.0, "resets_at": "2026-07-10T20:59:59.905281+00:00" },
  "seven_day_sonnet": { "utilization": 40.0, "resets_at": "2026-07-10T20:59:59.905281+00:00" }
}
"""

// Real captured 2026-08 response shape (trimmed): `extra_usage` now carries currency,
// decimal_places and spend-limit status alongside the original four fields.
private let extraUsageDetailsBody = """
{
  "five_hour": { "utilization": 36.0, "resets_at": "2026-08-08T22:20:00.805338+00:00" },
  "extra_usage": {
    "is_enabled": true,
    "monthly_limit": 150000,
    "used_credits": 128626.0,
    "utilization": 85.75,
    "currency": "EUR",
    "decimal_places": 2,
    "disabled_reason": "spend_limit_reached",
    "user_disabled": false,
    "spend_limit_reached": true,
    "credits_ever_enabled": true,
    "daily": null,
    "weekly": null
  }
}
"""

// A zero-decimal currency: amounts arrive in whole units (decimal_places 0), so the
// cents→major-unit division must not happen.
private let extraUsageZeroDecimalBody = """
{
  "extra_usage": {
    "is_enabled": true,
    "monthly_limit": 5000,
    "used_credits": 1234.0,
    "utilization": 24.68,
    "currency": "JPY",
    "decimal_places": 0
  }
}
"""

// A `limits[]` array where one entry has a malformed `resets_at`. In the array
// path a bad reset must degrade to `nil` (no throw) and not drop siblings.
private let malformedResetInLimitsBody = """
{
  "limits": [
    { "kind": "session", "percent": 50, "resets_at": "not-a-date", "scope": null, "is_active": true },
    { "kind": "weekly_all", "percent": 5, "resets_at": "2026-07-10T20:59:59.905281+00:00", "scope": null, "is_active": false }
  ]
}
"""

// MARK: - Test suite

private let primaryUsageWithoutResets = """
{
  "five_hour": { "utilization": 25.0, "resets_at": "2026-09-22T12:00:00+00:00" },
  "extra_usage": { "is_enabled": true, "monthly_limit": 10000, "used_credits": 2500, "utilization": 25.0 }
}
"""

private let resetOnlyBody = """
{
  "cedar_ember": {
    "eligible": true,
    "ineligible_reason": "future_reason",
    "at_limit": true,
    "exhausted": ["five_hour", "future_limit"],
    "next_grant_id": "grant_2",
    "weekly_resets_at": "2026-09-29T12:00:00Z",
    "cooldown_until": null,
    "grants": [
      {
        "id": "grant_1",
        "label": "First",
        "resets_total": 3,
        "resets_left": 2,
        "starts_at": "2026-09-01T00:00:00Z",
        "ends_at": "2026-10-01T00:00:00Z",
        "clears": ["five_hour", "future_limit"],
        "paused": true,
        "usable_now": false,
        "use_requires_limit": false,
        "blocking": ["seven_day_opus"],
        "unknown_property": "ignored"
      },
      {
        "id": "grant_2",
        "resets_left": 4
      }
    ],
    "unknown_property": { "ignored": true }
  }
}
"""

private let primaryURL = "https://api.anthropic.com/api/oauth/usage"
private let resetURL = "https://api.anthropic.com/api/oauth/usage?cedar_ember=1&skip_spend=1"

// Serialized: StubURLProtocol holds process-global mutable state (statusCode/responseData),
// so tests must not run concurrently or they clobber each other's stubbed response.
/// An isolated cache file for a single test.
///
/// Every `LimitsService` built in these suites MUST be handed one: `LimitsService.init`
/// defaults to `LimitsCache()`, which resolves the real
/// `~/Library/Application Support/Toki` — so a plain test run would write to, and
/// migrate, the user's own data.
private func isolatedCache() -> LimitsCache {
    LimitsCache(
        fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("limits-cache-test-\(UUID().uuidString).json")
    )
}

@Suite("TokiLimits", .serialized)
struct TokiLimitsTests {

    // MARK: Claude saved resets

    @Test("LimitsService default compatible client header preserves surface-gated reset")
    func limitsServiceDefaultHeaderPreservesSurfaceGatedReset() async throws {
        ResetRoutingURLProtocol.reset()
        defer { ResetRoutingURLProtocol.reset() }
        ResetRoutingURLProtocol.requestHandler = { request in
            let headerIsCompatible = request.value(forHTTPHeaderField: "User-Agent") == "claude-cli/2.1.280 (external, cli)"
            switch request.url?.absoluteString {
            case primaryURL:
                return (200, Data(primaryUsageWithoutResets.utf8))
            case resetURL where headerIsCompatible:
                return (200, Data(#"{"cedar_ember":{"eligible":true,"grants":[{"id":"surface-grant","resets_left":1}]}}"#.utf8))
            case resetURL:
                return (200, Data(#"{"cedar_ember":{"eligible":false,"ineligible_reason":"surface","grants":[]}}"#.utf8))
            default:
                return (404, Data())
            }
        }

        let service = LimitsService(
            credentials: FixedCredentialStore(token: "synthetic-token"),
            session: .resetStubbed,
            cache: isolatedCache()
        )
        let limits = try await service.fetchLimits()

        #expect(limits.fiveHour?.utilization == 0.25)
        #expect(limits.extra?.usedCredits == 25)
        #expect(limits.claudeResets?.eligible == true)
        #expect(limits.claudeResets?.totalResets == 1)
    }

    @Test("OAuthUsageClient default and override headers reach both usage requests")
    func oauthUsageClientHeadersReachPrimaryAndSupplementalRequests() async throws {
        ResetRoutingURLProtocol.reset()
        defer { ResetRoutingURLProtocol.reset() }
        ResetRoutingURLProtocol.requestHandler = { request in
            (200, Data(
                request.url?.absoluteString == primaryURL
                    ? primaryUsageWithoutResets.utf8
                    : resetOnlyBody.utf8
            ))
        }

        _ = try await OAuthUsageClient(session: .resetStubbed).fetchUsage(token: "default-token")
        #expect(ResetRoutingURLProtocol.requests.map { $0.value(forHTTPHeaderField: "User-Agent") } == [
            "claude-cli/2.1.280 (external, cli)",
            "claude-cli/2.1.280 (external, cli)",
        ])

        ResetRoutingURLProtocol.reset()
        ResetRoutingURLProtocol.requestHandler = { request in
            (200, Data(
                request.url?.absoluteString == primaryURL
                    ? primaryUsageWithoutResets.utf8
                    : resetOnlyBody.utf8
            ))
        }

        _ = try await OAuthUsageClient(userAgent: "test-client/9.9", session: .resetStubbed)
            .fetchUsage(token: "override-token")
        #expect(ResetRoutingURLProtocol.requests.map { $0.value(forHTTPHeaderField: "User-Agent") } == [
            "test-client/9.9",
            "test-client/9.9",
        ])
    }

    @Test("primary usage decodes saved resets without a supplemental request")
    func primaryUsageDecodesClaudeResets() async throws {
        ResetRoutingURLProtocol.reset()
        defer { ResetRoutingURLProtocol.reset() }
        let resetEnvelope = try #require(
            JSONSerialization.jsonObject(with: Data(resetOnlyBody.utf8)) as? [String: Any]
        )
        let cedarEmber = try #require(resetEnvelope["cedar_ember"])
        let responseData = try JSONSerialization.data(withJSONObject: [
            "five_hour": ["utilization": 10, "resets_at": NSNull()],
            "cedar_ember": cedarEmber,
        ])
        ResetRoutingURLProtocol.requestHandler = { _ in (200, responseData) }

        let limits = try await OAuthUsageClient(session: .resetStubbed).fetchUsage(token: "synthetic-token")

        #expect(ResetRoutingURLProtocol.requests.count == 1)
        #expect(ResetRoutingURLProtocol.requests.first?.url?.absoluteString == primaryURL)
        #expect(ResetRoutingURLProtocol.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-token")
        #expect(ResetRoutingURLProtocol.requests.first?.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20")
        #expect(ResetRoutingURLProtocol.requests.first?.value(forHTTPHeaderField: "User-Agent") == "claude-cli/2.1.280 (external, cli)")
        #expect(ResetRoutingURLProtocol.requests.first?.timeoutInterval == 10)
        let resets = try #require(limits.claudeResets)
        #expect(resets.totalResets == 6)
        #expect(resets.ineligibleReason == "future_reason")
        #expect(resets.exhausted == ["five_hour", "future_limit"])
        #expect(resets.nextGrantID == "grant_2")
        let first = try #require(resets.grants?.first)
        #expect(first.clears == ["five_hour", "future_limit"])
        #expect(first.blocking == ["seven_day_opus"])
        let second = try #require(resets.grants?.last)
        #expect(second.label == "")
        #expect(second.resetsTotal == 0)
        #expect(second.paused == false)
        #expect(second.usableNow == false)
        #expect(second.useRequiresLimit == true)
    }

    @Test("missing primary reset uses exact reset-only endpoint and preserves usage")
    func missingPrimaryResetUsesSupplementalEndpoint() async throws {
        ResetRoutingURLProtocol.reset()
        defer { ResetRoutingURLProtocol.reset() }
        ResetRoutingURLProtocol.requestHandler = { request in
            switch request.url?.absoluteString {
            case primaryURL:
                return (200, Data(primaryUsageWithoutResets.utf8))
            case resetURL:
                return (200, Data(resetOnlyBody.utf8))
            default:
                return (404, Data())
            }
        }

        let limits = try await OAuthUsageClient(session: .resetStubbed).fetchUsage(token: "tok-test")

        #expect(ResetRoutingURLProtocol.requests.map { $0.url?.absoluteString } == [primaryURL, resetURL])
        #expect(ResetRoutingURLProtocol.requests[1].value(forHTTPHeaderField: "Authorization") == "Bearer tok-test")
        #expect(ResetRoutingURLProtocol.requests[1].value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20")
        #expect(ResetRoutingURLProtocol.requests[1].value(forHTTPHeaderField: "User-Agent") == "claude-cli/2.1.280 (external, cli)")
        #expect(ResetRoutingURLProtocol.requests[1].timeoutInterval == 10)
        #expect(limits.fiveHour?.utilization == 0.25)
        #expect(limits.extra?.usedCredits == 25)
        #expect(limits.claudeResets?.totalResets == 6)
    }

    @Test("null primary reset uses the targeted fallback")
    func nullPrimaryResetUsesSupplementalEndpoint() async throws {
        ResetRoutingURLProtocol.reset()
        defer { ResetRoutingURLProtocol.reset() }
        ResetRoutingURLProtocol.requestHandler = { request in
            if request.url?.absoluteString == primaryURL {
                return (200, Data(#"{"five_hour":{"utilization":5,"resets_at":null},"cedar_ember":null}"#.utf8))
            }
            return (200, Data(resetOnlyBody.utf8))
        }

        let limits = try await OAuthUsageClient(session: .resetStubbed).fetchUsage(token: "tok-null")

        #expect(ResetRoutingURLProtocol.requests.map { $0.url?.absoluteString } == [primaryURL, resetURL])
        #expect(limits.fiveHour?.utilization == 0.05)
        #expect(limits.claudeResets?.totalResets == 6)
    }

    @Test("malformed primary reset is replaced by a valid supplemental reset")
    func malformedPrimaryResetUsesSupplementalEndpoint() async throws {
        ResetRoutingURLProtocol.reset()
        defer { ResetRoutingURLProtocol.reset() }
        ResetRoutingURLProtocol.requestHandler = { request in
            if request.url?.absoluteString == primaryURL {
                let primary = #"{"five_hour":{"utilization":30,"resets_at":null},"cedar_ember":{"eligible":true,"grants":[{"id":"valid","resets_left":7},{"id":"bad id","resets_left":1}]}}"#
                return (200, Data(primary.utf8))
            }
            return (200, Data(resetOnlyBody.utf8))
        }

        let limits = try await OAuthUsageClient(session: .resetStubbed).fetchUsage(token: "tok-malformed")

        #expect(ResetRoutingURLProtocol.requests.map { $0.url?.absoluteString } == [primaryURL, resetURL])
        #expect(limits.fiveHour?.utilization == 0.30)
        #expect(limits.claudeResets?.totalResets == 6)
    }

    @Test("valid ineligible zero reset state does not trigger fallback")
    func knownZeroDoesNotTriggerFallback() async throws {
        ResetRoutingURLProtocol.reset()
        defer { ResetRoutingURLProtocol.reset() }
        ResetRoutingURLProtocol.requestHandler = { _ in (200, Data(realisticBody.utf8)) }

        let limits = try await OAuthUsageClient(session: .resetStubbed).fetchUsage(token: "tok-test")

        #expect(ResetRoutingURLProtocol.requests.count == 1)
        #expect(limits.claudeResets?.eligible == false)
        #expect(limits.claudeResets?.totalResets == 0)
    }

    @Test("eligible known-zero reset state does not trigger fallback")
    func eligibleKnownZeroDoesNotTriggerFallback() async throws {
        ResetRoutingURLProtocol.reset()
        defer { ResetRoutingURLProtocol.reset() }
        let body = #"{"five_hour":{"utilization":0,"resets_at":null},"cedar_ember":{"eligible":true,"grants":[]}}"#
        ResetRoutingURLProtocol.requestHandler = { _ in (200, Data(body.utf8)) }

        let limits = try await OAuthUsageClient(session: .resetStubbed).fetchUsage(token: "tok-zero")

        #expect(ResetRoutingURLProtocol.requests.count == 1)
        #expect(limits.claudeResets?.eligible == true)
        #expect(limits.claudeResets?.totalResets == 0)
    }

    @Test("supplemental failures preserve ordinary usage")
    func supplementalFailuresPreserveUsage() async throws {
        enum SupplementalFailure: CaseIterable {
            case unauthorized, rateLimited, malformed, transport
        }

        for failure in SupplementalFailure.allCases {
            ResetRoutingURLProtocol.reset()
            ResetRoutingURLProtocol.requestHandler = { request in
                if request.url?.absoluteString == primaryURL {
                    return (200, Data(primaryUsageWithoutResets.utf8))
                }
                switch failure {
                case .unauthorized: return (401, Data())
                case .rateLimited: return (429, Data())
                case .malformed: return (200, Data(#"{"cedar_ember":{"eligible":"yes"}}"#.utf8))
                case .transport: throw URLError(.cannotConnectToHost)
                }
            }

            let limits = try await OAuthUsageClient(session: .resetStubbed).fetchUsage(token: "tok-test")
            #expect(limits.fiveHour?.utilization == 0.25)
            #expect(limits.extra?.usedCredits == 25)
            #expect(limits.claudeResets == nil)
            if failure == .rateLimited {
                #expect(limits.supplementalRateLimit?.retryAfter == 180)
            } else {
                #expect(limits.supplementalRateLimit == nil)
            }
            #expect(ResetRoutingURLProtocol.requests.count == 2)
        }
        ResetRoutingURLProtocol.reset()
    }

    // The reset request is optional metadata. A 429 on it used to mark the fresh gauges
    // stale and back the whole account off for six minutes — 108 times on one day.
    @Test("supplemental 429 publishes complete usage with the account's last resets and caches it")
    func supplementalRateLimitKeepsUsageFresh() async throws {
        ResetRoutingURLProtocol.reset()
        defer { ResetRoutingURLProtocol.reset() }
        ResetRoutingURLProtocol.requestHandler = { request in
            if request.url?.absoluteString == primaryURL {
                return (200, Data(primaryUsageWithoutResets.utf8))
            }
            return (429, Data(#"{"error":"rate_limited"}"#.utf8))
        }

        let account = UsageAccount(accountUuid: "account-a", organizationUuid: "org-a")
        let oldFetchedAt = Date(timeIntervalSince1970: 1_750_000_000)
        let old = UsageLimits(
            windows: [RateLimitWindow(
                id: "session", title: "5-hour", utilization: 0.10,
                resetsAt: nil, isAvailable: true
            )],
            extra: nil,
            fetchedAt: oldFetchedAt,
            account: account,
            bankedResets: nil,
            claudeResets: ClaudeResetStatus(
                eligible: true,
                grants: [ClaudeResetGrant(id: "old", resetsLeft: 3)]
            )
        )
        let cache = isolatedCache()
        cache.save(old)
        let store = SpyCredentialStore()
        store.credentialAccount = account
        let service = LimitsService(credentials: store, session: .resetStubbed, cache: cache)

        let limits = try await service.fetchLimits()

        #expect(limits.account == account)
        #expect(limits.fiveHour?.utilization == 0.25)
        #expect(limits.extra?.usedCredits == 25)
        #expect(limits.claudeResets?.totalResets == 3)
        #expect(limits.supplementalRateLimit == nil)
        #expect(UsageRefreshController.Outcome.response(limits) == .success)
        #expect(cache.load()?.fetchedAt == limits.fetchedAt)
        #expect(cache.load()?.claudeResets?.totalResets == 3)
    }

    @Test("resets are re-requested on their own slower cadence, backing off after a 429")
    func supplementalCadenceIsIndependent() async throws {
        ResetRoutingURLProtocol.reset()
        defer { ResetRoutingURLProtocol.reset() }
        let rateLimitReset = LockedFlag(true)
        ResetRoutingURLProtocol.requestHandler = { request in
            if request.url?.absoluteString == primaryURL {
                return (200, Data(primaryUsageWithoutResets.utf8))
            }
            return rateLimitReset.value
                ? (429, Data())
                : (200, Data(#"{"cedar_ember":{"eligible":true,"grants":[{"id":"g","resets_left":2}]}}"#.utf8))
        }
        let clock = LockedClock(Date(timeIntervalSince1970: 1_800_000_000))
        let store = SpyCredentialStore()
        store.credentialAccount = UsageAccount(accountUuid: "account-a", organizationUuid: nil)
        let service = LimitsService(
            credentials: store, session: .resetStubbed, cache: isolatedCache(),
            refreshController: UsageRefreshController(
                minimumInterval: 0, firstRateLimitInterval: 0, repeatedRateLimitInterval: 0
            ),
            resetsRefreshInterval: 600,
            now: { clock.now }
        )
        func resetRequests() -> Int {
            ResetRoutingURLProtocol.requests.filter { $0.url?.absoluteString == resetURL }.count
        }

        _ = try await service.fetchLimits()
        #expect(resetRequests() == 1)

        // Inside the back-off: only the usage request goes out.
        clock.advance(by: 90)
        _ = try await service.fetchLimits()
        #expect(resetRequests() == 1)

        clock.advance(by: 600)
        rateLimitReset.value = false
        let recovered = try await service.fetchLimits()
        #expect(resetRequests() == 2)
        #expect(recovered.claudeResets?.totalResets == 2)

        // A successful read is reused until the interval passes...
        rateLimitReset.value = true
        clock.advance(by: 90)
        let reused = try await service.fetchLimits()
        #expect(resetRequests() == 2)
        #expect(reused.claudeResets?.totalResets == 2)

        // ...and an explicit refresh (account change, access recovery) always asks.
        _ = try await service.refreshLimitsFreshCredential()
        #expect(resetRequests() == 3)
    }

    @Test("a reset request that fails outright hides the old balance and is retried on the next poll")
    func supplementalFailureDoesNotResurrectResets() async throws {
        ResetRoutingURLProtocol.reset()
        defer { ResetRoutingURLProtocol.reset() }
        let resetStatus = LockedFlag(true)
        ResetRoutingURLProtocol.requestHandler = { request in
            if request.url?.absoluteString == primaryURL {
                return (200, Data(primaryUsageWithoutResets.utf8))
            }
            return resetStatus.value
                ? (200, Data(#"{"cedar_ember":{"eligible":true,"grants":[{"id":"g","resets_left":2}]}}"#.utf8))
                : (404, Data())
        }
        let clock = LockedClock(Date(timeIntervalSince1970: 1_800_000_000))
        let store = SpyCredentialStore()
        store.credentialAccount = UsageAccount(accountUuid: "account-a", organizationUuid: nil)
        let service = LimitsService(
            credentials: store, session: .resetStubbed, cache: isolatedCache(),
            refreshController: UsageRefreshController(
                minimumInterval: 0, firstRateLimitInterval: 0, repeatedRateLimitInterval: 0
            ),
            resetsRefreshInterval: 600,
            now: { clock.now }
        )

        #expect(try await service.fetchLimits().claudeResets?.totalResets == 2)
        clock.advance(by: 601)
        resetStatus.value = false
        #expect(try await service.fetchLimits().claudeResets == nil)
        clock.advance(by: 90)
        #expect(try await service.fetchLimits().claudeResets == nil)
        #expect(ResetRoutingURLProtocol.requests.filter { $0.url?.absoluteString == resetURL }.count == 3)
    }

    @Test("supplemental 429 cannot bypass current-account validation")
    func supplementalRateLimitStillRequiresCredentialValidation() async {
        ResetRoutingURLProtocol.reset()
        defer { ResetRoutingURLProtocol.reset() }
        ResetRoutingURLProtocol.requestHandler = { request in
            request.url?.absoluteString == primaryURL
                ? (200, Data(primaryUsageWithoutResets.utf8))
                : (429, Data())
        }
        let store = SpyCredentialStore()
        store.credentialAccount = UsageAccount(accountUuid: "old", organizationUuid: nil)
        store.validationFailure = .keychainDenied
        let cache = isolatedCache()
        let service = LimitsService(credentials: store, session: .resetStubbed, cache: cache)

        await #expect(throws: TokiError.keychainDenied) { try await service.fetchLimits() }
        #expect(cache.load() == nil)
    }

    @Test("supplemental cancellation is propagated")
    func supplementalCancellationPropagates() async {
        ResetRoutingURLProtocol.reset()
        defer { ResetRoutingURLProtocol.reset() }
        ResetRoutingURLProtocol.requestHandler = { request in
            if request.url?.absoluteString == primaryURL {
                return (200, Data(primaryUsageWithoutResets.utf8))
            }
            throw URLError(.cancelled)
        }

        await #expect(throws: CancellationError.self) {
            _ = try await OAuthUsageClient(session: .resetStubbed).fetchUsage(token: "tok-test")
        }
    }

    @Test("saved reset decoding isolates invalid grants and ambiguous status")
    func resetDecoderRejectsAmbiguityWithoutHidingUsage() async throws {
        let invalidSections = [
            #"{"eligible":true,"grants":[{"id":"bad id","resets_left":1}]}"#,
            #"{"eligible":true,"grants":[{"id":"ok","resets_left":-1}]}"#,
            #"{"eligible":true,"grants":[{"id":"ok"}]}"#,
            #"{"eligible":true,"grants":[{"id":"ok","resets_left":null}]}"#,
            #"{"eligible":true,"grants":[{"id":"ok","resets_left":"one"}]}"#,
            #"{"eligible":true,"grants":[{"resets_left":1}]}"#,
            #"{"eligible":true,"grants":[{"id":"ok","resets_total":null,"resets_left":1}]}"#,
            #"{"eligible":true,"grants":[{"id":"ok","resets_total":-1,"resets_left":1}]}"#,
            #"{"eligible":true,"grants":[{"id":"valid","resets_left":7},{"id":"bad id","resets_left":1}]}"#,
            #"{"eligible":true,"grants":[{"id":"same","resets_left":1},{"id":"same","resets_left":2}]}"#,
            #"{"eligible":true,"grants":[{"id":"a","resets_left":9223372036854775807},{"id":"b","resets_left":1}]}"#,
            #"{"eligible":true,"grants":[{"id":"ok","resets_left":1,"ends_at":"not-a-date"}]}"#,
        ]

        for section in invalidSections {
            ResetRoutingURLProtocol.reset()
            let body = "{\"five_hour\":{\"utilization\":25,\"resets_at\":null},\"cedar_ember\":\(section)}"
            ResetRoutingURLProtocol.requestHandler = { _ in (200, Data(body.utf8)) }
            let limits = try await OAuthUsageClient(session: .resetStubbed).fetchUsage(token: "tok-test")
            #expect(limits.fiveHour?.utilization == 0.25)
            #expect(limits.claudeResets == nil)
            #expect(ResetRoutingURLProtocol.requests.count == 2)
        }
        ResetRoutingURLProtocol.reset()
    }

    @Test("missing grants remains unknown and unmatched next grant is cleared")
    func optionalResetFieldsRemainTruthful() async throws {
        ResetRoutingURLProtocol.reset()
        defer { ResetRoutingURLProtocol.reset() }
        let body = """
        {
          "five_hour": { "utilization": 0, "resets_at": null },
          "cedar_ember": {
            "eligible": true,
            "ineligible_reason": "new_reason",
            "next_grant_id": "missing_grant",
            "exhausted": ["new_limit"]
          }
        }
        """
        ResetRoutingURLProtocol.requestHandler = { _ in (200, Data(body.utf8)) }

        let limits = try await OAuthUsageClient(session: .resetStubbed).fetchUsage(token: "tok-test")
        let resets = try #require(limits.claudeResets)
        #expect(resets.grants == nil)
        #expect(resets.totalResets == nil)
        #expect(resets.nextGrantID == nil)
        #expect(resets.ineligibleReason == "new_reason")
        #expect(resets.exhausted == ["new_limit"])
        #expect(ResetRoutingURLProtocol.requests.count == 1)
    }

    // MARK: 200 — realistic body

    @Test("200 response: utilizations normalised to [0,1]")
    func successResponseNormalisesUtilization() async throws {
        StubURLProtocol.statusCode = 200
        StubURLProtocol.responseData = Data(realisticBody.utf8)

        let client = OAuthUsageClient(session: .stubbed)
        let limits = try await client.fetchUsage(token: "tok-test")

        // fiveHour
        let fiveHour = try #require(limits.fiveHour)
        #expect(abs(fiveHour.utilization - 0.04) < 1e-9)

        // sevenDay
        let sevenDay = try #require(limits.sevenDay)
        #expect(abs(sevenDay.utilization - 0.70) < 1e-9)

        // sevenDaySonnet — no flat convenience accessor; the fallback builder maps
        // it to the weekly_scoped:Sonnet window.
        let sevenDaySonnet = try #require(limits.windows.first { $0.id == "weekly_scoped:Sonnet" })
        #expect(abs(sevenDaySonnet.utilization - 0.16) < 1e-9)

        // sevenDayOpus — absent in this body
        #expect(limits.windows.first { $0.id == "weekly_scoped:Opus" } == nil)

        // extra_usage — monthly_limit/used_credits arrive in cents, converted to dollars (÷100).
        let extra = try #require(limits.extra)
        #expect(extra.isEnabled == true)
        let used = try #require(extra.usedCredits)
        #expect(abs(used - 743.98) < 1e-6)
        let extraUtil = try #require(extra.utilization)
        #expect(abs(extraUtil - 0.74398) < 1e-6)
        #expect(extra.monthlyLimit == 1000.0)
    }

    @Test("extra_usage: currency, decimal_places and spend-limit status decode to the domain")
    func extraUsageCarriesCurrencyAndStatus() async throws {
        StubURLProtocol.statusCode = 200
        StubURLProtocol.responseData = Data(extraUsageDetailsBody.utf8)

        let client = OAuthUsageClient(session: .stubbed)
        let limits = try await client.fetchUsage(token: "tok-test")

        let extra = try #require(limits.extra)
        #expect(extra.currency == "EUR")
        #expect(extra.decimalPlaces == 2)
        #expect(extra.spendLimitReached == true)
        #expect(extra.disabledReason == "spend_limit_reached")
        // Amounts still convert minor → major units with 2 decimal places.
        #expect(extra.monthlyLimit == 1500.0)
        let used = try #require(extra.usedCredits)
        #expect(abs(used - 1286.26) < 1e-6)
    }

    @Test("extra_usage: legacy body without the new fields defaults them")
    func extraUsageDefaultsWithoutNewFields() async throws {
        StubURLProtocol.statusCode = 200
        StubURLProtocol.responseData = Data(realisticBody.utf8)

        let client = OAuthUsageClient(session: .stubbed)
        let limits = try await client.fetchUsage(token: "tok-test")

        let extra = try #require(limits.extra)
        #expect(extra.currency == nil)
        #expect(extra.decimalPlaces == nil)
        #expect(extra.spendLimitReached == false)
        #expect(extra.disabledReason == nil)
    }

    @Test("extra_usage: decimal_places 0 keeps amounts in whole units (no ÷100)")
    func extraUsageZeroDecimalNotDivided() async throws {
        StubURLProtocol.statusCode = 200
        StubURLProtocol.responseData = Data(extraUsageZeroDecimalBody.utf8)

        let client = OAuthUsageClient(session: .stubbed)
        let limits = try await client.fetchUsage(token: "tok-test")

        let extra = try #require(limits.extra)
        #expect(extra.monthlyLimit == 5000.0)
        #expect(extra.usedCredits == 1234.0)
        #expect(extra.currency == "JPY")
        #expect(extra.decimalPlaces == 0)
    }

    @Test("200 response: resets_at with fractional seconds parses to non-nil Date")
    func resetsAtWithFractionalSecondsParsed() async throws {
        StubURLProtocol.statusCode = 200
        StubURLProtocol.responseData = Data(realisticBody.utf8)

        let client = OAuthUsageClient(session: .stubbed)
        let limits = try await client.fetchUsage(token: "tok-test")

        let fiveHour = try #require(limits.fiveHour)
        // "2026-06-24T16:50:00.421248+00:00" — fractional seconds variant
        let resetsAt = try #require(fiveHour.resetsAt)
        #expect(resetsAt.timeIntervalSince1970 > 0)
    }

    @Test("200 response: resets_at without fractional seconds parses to non-nil Date")
    func resetsAtWithoutFractionalSecondsParsed() async throws {
        StubURLProtocol.statusCode = 200
        StubURLProtocol.responseData = Data(realisticBody.utf8)

        let client = OAuthUsageClient(session: .stubbed)
        let limits = try await client.fetchUsage(token: "tok-test")

        let sevenDay = try #require(limits.sevenDay)
        // "2026-06-26T21:00:00+00:00" — no fractional seconds
        let resetsAt = try #require(sevenDay.resetsAt)
        #expect(resetsAt.timeIntervalSince1970 > 0)
    }

    @Test("200 response: fetchedAt is recent")
    func fetchedAtIsRecent() async throws {
        StubURLProtocol.statusCode = 200
        StubURLProtocol.responseData = Data(realisticBody.utf8)

        let before = Date()
        let client = OAuthUsageClient(session: .stubbed)
        let limits = try await client.fetchUsage(token: "tok-test")
        let after = Date()

        #expect(limits.fetchedAt >= before)
        #expect(limits.fetchedAt <= after)
    }

    // MARK: 401 → .tokenExpired

    @Test("401 response throws tokenExpired")
    func http401ThrowsTokenExpired() async throws {
        StubURLProtocol.statusCode = 401
        StubURLProtocol.responseData = Data(#"{"error":"unauthorized"}"#.utf8)

        let client = OAuthUsageClient(session: .stubbed)
        await #expect(throws: TokiError.tokenExpired) {
            _ = try await client.fetchUsage(token: "expired-token")
        }
    }

    // MARK: 429 → .rateLimited

    @Test("429 response throws rateLimited with retryAfter >= 180")
    func http429ThrowsRateLimited() async throws {
        StubURLProtocol.statusCode = 429
        StubURLProtocol.responseData = Data(#"{"error":"rate_limited"}"#.utf8)

        let client = OAuthUsageClient(session: .stubbed)
        do {
            _ = try await client.fetchUsage(token: "tok-test")
            Issue.record("Expected rateLimited to be thrown")
        } catch TokiError.rateLimited(let retryAfter) {
            #expect(retryAfter >= 180)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    // MARK: null resets_at → window kept, resetsAt nil (regression for "error 2")

    // The live API sends `"resets_at": null` for an inactive window (e.g. the
    // 5-hour window at 0% utilization). A single null reset time must NOT make the
    // whole-response decode throw — otherwise the seven-day / extra-usage gauges
    // silently vanish and the dashboard shows the opaque "…error 2" message.
    @Test("200 response: null resets_at keeps the window (resetsAt nil), other windows intact")
    func nullResetsAtDoesNotDiscardResponse() async throws {
        StubURLProtocol.statusCode = 200
        StubURLProtocol.responseData = Data(nullResetBody.utf8)

        let client = OAuthUsageClient(session: .stubbed)
        let limits = try await client.fetchUsage(token: "tok-test")

        // five_hour: present, 0% utilization, no reset time.
        let fiveHour = try #require(limits.fiveHour)
        #expect(fiveHour.utilization == 0.0)
        #expect(fiveHour.resetsAt == nil)

        // seven_day: still decoded — 100% with a real reset time.
        let sevenDay = try #require(limits.sevenDay)
        #expect(abs(sevenDay.utilization - 1.0) < 1e-9)
        #expect(sevenDay.resetsAt != nil)

        // extra_usage: still decoded.
        let extra = try #require(limits.extra)
        #expect(extra.isEnabled == true)
    }

    // MARK: Malformed JSON → .decoding

    @Test("Malformed JSON on 200 throws decoding error")
    func malformedJSONThrowsDecoding() async throws {
        StubURLProtocol.statusCode = 200
        StubURLProtocol.responseData = Data("not valid json at all {{{".utf8)

        let client = OAuthUsageClient(session: .stubbed)
        do {
            _ = try await client.fetchUsage(token: "tok-test")
            Issue.record("Expected decoding error to be thrown")
        } catch TokiError.decoding {
            // expected
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("LimitsService: 429 throws rateLimited with retryAfter >= 180")
    func limitsService429ThrowsRateLimited() async throws {
        StubURLProtocol.statusCode = 429
        StubURLProtocol.responseData = Data(#"{"error":"rate_limited"}"#.utf8)

        let store = FixedCredentialStore(token: "tok-test")
        let service = LimitsService(credentials: store, session: .stubbed, cache: isolatedCache())

        do {
            _ = try await service.fetchLimits()
            Issue.record("Expected rateLimited to be thrown")
        } catch TokiError.rateLimited(let retryAfter) {
            #expect(retryAfter >= 180)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("LimitsService: 401 throws tokenExpired (credential store provides token)")
    func limitsService401ThrowsTokenExpired() async throws {
        StubURLProtocol.statusCode = 401
        StubURLProtocol.responseData = Data(#"{"error":"unauthorized"}"#.utf8)

        let store = FixedCredentialStore(token: "expired-token")
        let service = LimitsService(credentials: store, session: .stubbed, cache: isolatedCache())

        await #expect(throws: TokiError.tokenExpired) {
            _ = try await service.fetchLimits()
        }
    }

    // MARK: 401 handling — rejection, retry, and the same-token guard

    @Test("LimitsService: 401 marks the token rejected so the retry uses the rotated one")
    func tokenExpiredRetryUsesFreshToken() async throws {
        // Both the initial attempt and the retry get 401 from the stub, which is fine —
        // what matters is that the dead token was reported before re-resolving, so the
        // retry received the rotated token rather than the one that just failed.
        StubURLProtocol.statusCode = 401
        StubURLProtocol.responseData = Data(#"{"error":"unauthorized"}"#.utf8)

        let store = RotatingCredentialStore()
        let service = LimitsService(credentials: store, session: .stubbed, cache: isolatedCache())

        do {
            _ = try await service.fetchLimits()
            Issue.record("Expected tokenExpired to be re-thrown on second 401")
        } catch TokiError.tokenExpired {
            // expected — both calls returned 401
        }

        #expect(store.rejected == ["expired_tok"])
        #expect(store.lastTokenUsed == "fresh_tok",
            "retry must use the rotated token, not the one that just 401'd")
    }

    @Test("LimitsService: a 401 is not retried when re-resolution yields the same token")
    func sameTokenIsNotRetried() async throws {
        StubURLProtocol.statusCode = 401
        StubURLProtocol.responseData = Data(#"{"error":"unauthorized"}"#.utf8)
        StubURLProtocol.resetCount()

        // Claude Code isn't running to rotate the token, so re-resolution hands back the
        // same one. Retrying it would burn an extra request on every single poll.
        let store = FixedCredentialStore(token: "same-token")
        let service = LimitsService(credentials: store, session: .stubbed, cache: isolatedCache())

        await #expect(throws: TokiError.tokenExpired) {
            _ = try await service.fetchLimits()
        }
        #expect(StubURLProtocol.requestCount == 1, "the doomed retry must never go out")
    }

    @Test("LimitsService: a 401 on an environment token still reports the rejection to its source")
    func environmentTokenRejectionIsReported() async throws {
        StubURLProtocol.statusCode = 401
        StubURLProtocol.responseData = Data(#"{"error":"unauthorized"}"#.utf8)

        let store = EnvSourcedCredentialStore()
        let service = LimitsService(credentials: store, session: .stubbed, cache: isolatedCache())

        await #expect(throws: TokiError.tokenExpired) {
            _ = try await service.fetchLimits()
        }
        // The service reports it; the store decides what that means for its own caches
        // (CredentialStore ignores it for non-vault-backed sources).
        #expect(store.rejected == ["env-token"])
    }

    // MARK: refreshLimitsFreshCredential — noninteractive credential re-resolution

    @Test("refreshing credentials does not authorize a Keychain dialog")
    func refreshForcesFreshCredential() async throws {
        StubURLProtocol.statusCode = 200
        StubURLProtocol.responseData = Data(realisticBody.utf8)
        let store = SpyCredentialStore()
        let service = LimitsService(credentials: store, session: .stubbed, cache: isolatedCache())
        _ = try await service.refreshLimitsFreshCredential()
        #expect(store.lastUserInitiated == false)
        #expect(store.lastForceRefresh == true)
    }

    @Test("a response whose account changed is neither returned nor cached")
    func changedAccountResponseIsRejected() async {
        StubURLProtocol.statusCode = 200
        StubURLProtocol.responseData = Data(realisticBody.utf8)
        let store = SpyCredentialStore()
        store.validationFailure = .keychainDenied
        let cache = isolatedCache()
        let service = LimitsService(credentials: store, session: .stubbed, cache: cache)
        await #expect(throws: TokiError.keychainDenied) { try await service.fetchLimits() }
        #expect(cache.load() == nil)
    }

    @Test("an account generation change rejects fetched resets before publication")
    func changedAccountGenerationRejectsResets() async {
        StubURLProtocol.statusCode = 200
        StubURLProtocol.responseData = Data(realisticBody.utf8)
        let store = AccountChangingCredentialStore()
        let cache = isolatedCache()
        let service = LimitsService(credentials: store, session: .stubbed, cache: cache)
        store.onValidate = { await service.accountDidChange() }

        await #expect(throws: CancellationError.self) { try await service.fetchLimits() }
        #expect(cache.load() == nil)
    }

    @Test("the verified account accompanies usage through publication and persistence")
    func publishedUsageKeepsVerifiedOwner() async throws {
        StubURLProtocol.statusCode = 200
        StubURLProtocol.responseData = Data(realisticBody.utf8)
        let store = SpyCredentialStore()
        store.credentialAccount = UsageAccount(accountUuid: "account-b", organizationUuid: "org-2")
        let cache = isolatedCache()
        let service = LimitsService(credentials: store, session: .stubbed, cache: cache)
        let result = try await service.fetchLimits()
        #expect(result.account?.accountUuid == "account-b")
        #expect(result.account?.organizationUuid == "org-2")
        #expect(result.claudeResets?.eligible == false)
        #expect(result.claudeResets?.totalResets == 0)
        #expect(cache.load()?.account == result.account)
        #expect(cache.load()?.claudeResets == result.claudeResets)
    }

    @Test("a background poll resolves the credential without user-initiated privileges")
    func backgroundPollIsNotUserInitiated() async throws {
        StubURLProtocol.statusCode = 200
        StubURLProtocol.responseData = Data(realisticBody.utf8)
        let store = SpyCredentialStore()
        let service = LimitsService(credentials: store, session: .stubbed, cache: isolatedCache())
        _ = try await service.fetchLimits()
        #expect(store.lastUserInitiated == false)
    }

    // MARK: Fix #3 regression — malformed resets_at surfaces as .decoding

    @Test("200 body with malformed resets_at throws decoding error (not silent nil)")
    func malformedResetsAtThrowsDecoding() async throws {
        let badBody = """
        {
            "five_hour": {
                "utilization": 4.0,
                "resets_at": "NOT-A-DATE"
            }
        }
        """
        StubURLProtocol.statusCode = 200
        StubURLProtocol.responseData = Data(badBody.utf8)

        let client = OAuthUsageClient(session: .stubbed)
        do {
            _ = try await client.fetchUsage(token: "tok-test")
            Issue.record("Expected decoding error for malformed resets_at")
        } catch TokiError.decoding {
            // expected — malformed date must surface as .decoding, not silent nil
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    // MARK: New data-driven `limits[]` array

    @Test("200 response: new limits[] array decodes to ordered windows")
    func newLimitsArrayDecodesToWindows() async throws {
        StubURLProtocol.statusCode = 200
        StubURLProtocol.responseData = Data(newFormatBody.utf8)

        let client = OAuthUsageClient(session: .stubbed)
        let limits = try await client.fetchUsage(token: "tok-test")

        // Three windows, in the order received.
        #expect(limits.windows.count == 3)

        let session = limits.windows[0]
        #expect(session.id == "session")
        #expect(session.title == "5-hour")
        #expect(abs(session.utilization - 0.75) < 1e-9)
        #expect(session.isAvailable)

        let weeklyAll = limits.windows[1]
        #expect(weeklyAll.id == "weekly_all")
        #expect(weeklyAll.title == "7-day")
        #expect(abs(weeklyAll.utilization - 0.07) < 1e-9)
        #expect(weeklyAll.isAvailable)

        let fable = limits.windows[2]
        #expect(fable.id == "weekly_scoped:Fable")
        #expect(fable.title == "7-day Fable")
        #expect(fable.utilization == 0)
        #expect(fable.isAvailable == false)
        #expect(fable.resetsAt == nil)

        // Convenience accessors resolve the canonical windows.
        let fiveHour = try #require(limits.fiveHour)
        #expect(abs(fiveHour.utilization - 0.75) < 1e-9)
        let sevenDay = try #require(limits.sevenDay)
        #expect(abs(sevenDay.utilization - 0.07) < 1e-9)
    }

    @Test("200 response: weekly_scoped with is_active false but non-zero percent is available")
    func weeklyScopedAvailableByPercent() async throws {
        StubURLProtocol.statusCode = 200
        StubURLProtocol.responseData = Data(scopedActiveByPercentBody.utf8)

        let client = OAuthUsageClient(session: .stubbed)
        let limits = try await client.fetchUsage(token: "tok-test")

        let scoped = try #require(limits.windows.first { $0.id == "weekly_scoped:Opus" })
        #expect(scoped.isAvailable)
        #expect(abs(scoped.utilization - 0.12) < 1e-9)
    }

    @Test("200 response: no limits[] key falls back to flat fields in canonical order")
    func legacyFallbackBuildsWindows() async throws {
        StubURLProtocol.statusCode = 200
        StubURLProtocol.responseData = Data(legacyFallbackBody.utf8)

        let client = OAuthUsageClient(session: .stubbed)
        let limits = try await client.fetchUsage(token: "tok-test")

        #expect(limits.windows.map(\.id) == [
            "session", "weekly_all", "weekly_scoped:Opus", "weekly_scoped:Sonnet"
        ])
        // Every fallback window is marked available.
        let allAvailable = limits.windows.allSatisfy { $0.isAvailable }
        #expect(allAvailable)
        #expect(abs(try #require(limits.fiveHour).utilization - 0.10) < 1e-9)
        #expect(abs(try #require(limits.sevenDay).utilization - 0.20) < 1e-9)
    }

    @Test("200 response: malformed resets_at inside limits[] degrades to nil (no throw)")
    func malformedResetInLimitsDoesNotThrow() async throws {
        StubURLProtocol.statusCode = 200
        StubURLProtocol.responseData = Data(malformedResetInLimitsBody.utf8)

        let client = OAuthUsageClient(session: .stubbed)
        // Must NOT throw — the array path is resilient to one bad reset time.
        let limits = try await client.fetchUsage(token: "tok-test")

        #expect(limits.windows.count == 2)
        let session = try #require(limits.windows.first { $0.id == "session" })
        #expect(session.resetsAt == nil)
        // Sibling window is still present with its (valid) reset time.
        let weeklyAll = try #require(limits.windows.first { $0.id == "weekly_all" })
        #expect(weeklyAll.resetsAt != nil)
    }

    @Test("UsageLimits Codable round-trip preserves windows")
    func usageLimitsWindowsCodableRoundTrip() throws {
        let resetsAt = Date(timeIntervalSince1970: 1_750_010_000)
        let original = UsageLimits(
            windows: [
                RateLimitWindow(id: "session", title: "5-hour", utilization: 0.5, resetsAt: resetsAt, isAvailable: true),
                RateLimitWindow(id: "weekly_all", title: "7-day", utilization: 0.25, resetsAt: resetsAt, isAvailable: true),
                RateLimitWindow(id: "weekly_scoped:Fable", title: "7-day Fable", utilization: 0, resetsAt: nil, isAvailable: false),
            ],
            extra: ExtraUsage(isEnabled: true, monthlyLimit: 1000, usedCredits: 743.98, utilization: 0.74),
            fetchedAt: Date(timeIntervalSince1970: 1_750_000_000)
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(UsageLimits.self, from: data)

        #expect(decoded.windows.count == 3)
        #expect(decoded.windows.map(\.id) == original.windows.map(\.id))
        #expect(decoded.windows.map(\.isAvailable) == original.windows.map(\.isAvailable))
        #expect(decoded.windows[2].resetsAt == nil)
        #expect(decoded.extra?.isEnabled == true)
        #expect(decoded.fetchedAt == original.fetchedAt)
    }
}

// MARK: - LimitsCache tests

@Suite("LimitsCache")
struct LimitsCacheTests {

    private func tempCacheURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("limits-cache-test-\(UUID().uuidString).json")
    }

    private func makeMockLimits() -> UsageLimits {
        let resetsAt = Date(timeIntervalSince1970: 1_750_010_000)
        return UsageLimits(
            windows: [
                RateLimitWindow(id: "session", title: "5-hour", utilization: 0.5, resetsAt: resetsAt, isAvailable: true)
            ],
            extra: nil,
            fetchedAt: Date(timeIntervalSince1970: 1_750_000_000)
        )
    }

    @Test("save then load returns equal limits")
    func saveThenLoadRoundTrip() throws {
        let url = tempCacheURL()
        let cache = LimitsCache(fileURL: url)
        let mock = makeMockLimits()

        cache.save(mock)
        let loaded = try #require(cache.load())

        #expect(loaded.fetchedAt == mock.fetchedAt)
        #expect(loaded.fiveHour?.utilization == mock.fiveHour?.utilization)
        #expect(loaded.fiveHour?.resetsAt == mock.fiveHour?.resetsAt)
        #expect(loaded.sevenDay == nil)
        #expect(loaded.extra == nil)
    }

    @Test("load returns nil when no file exists")
    func loadNilWhenNoFile() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nonexistent-\(UUID().uuidString).json")
        let cache = LimitsCache(fileURL: url)
        #expect(cache.load() == nil)
    }

    @Test("load returns nil for corrupt file, does not crash")
    func loadNilForCorruptFile() throws {
        let url = tempCacheURL()
        // Write garbage bytes
        try Data("NOT VALID JSON {{{{".utf8).write(to: url)
        let cache = LimitsCache(fileURL: url)
        // Must not throw or crash — returns nil
        #expect(cache.load() == nil)
    }

    @Test("remove clears an account-scoped snapshot")
    func removeClearsSnapshot() {
        let url = tempCacheURL()
        let cache = LimitsCache(fileURL: url)
        cache.save(makeMockLimits())
        #expect(cache.load() != nil)

        cache.remove()

        #expect(cache.load() == nil)
        cache.remove() // A missing cache remains a harmless no-op.
    }

    @Test("LimitsService: successful fetch populates the cache")
    func successfulFetchPopulatesCache() async throws {
        StubURLProtocol.statusCode = 200
        StubURLProtocol.responseData = Data(realisticBody.utf8)

        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("service-cache-test-\(UUID().uuidString).json")
        let cache = LimitsCache(fileURL: cacheURL)
        let store = FixedCredentialStore(token: "tok-test")
        let service = LimitsService(credentials: store, session: .stubbed, cache: cache)

        let limits = try await service.fetchLimits()

        // Cache must now contain the returned limits.
        let cached = try #require(cache.load())
        #expect(abs(cached.fetchedAt.timeIntervalSince(limits.fetchedAt)) < 1.0)
        #expect(cached.fiveHour?.utilization == limits.fiveHour?.utilization)
        #expect(cached.claudeResets == limits.claudeResets)
    }
}
