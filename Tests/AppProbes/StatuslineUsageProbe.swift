import Foundation
import TokiAccounts
import TokiCore
import TokiMenuBar
import TokiSwap

private struct UnusedCredentials: CredentialProviding {
    func currentCredential() async throws -> OAuthCredential {
        throw TokiError.credentialsNotFound
    }
}

private actor DeniedCredentials: CredentialProviding {
    private(set) var reads = 0

    func currentCredential() async throws -> OAuthCredential {
        reads += 1
        throw TokiError.keychainDenied
    }
}

private actor AccountBoundCredentials: CredentialProviding {
    private let account: UsageAccount
    private var reads = 0

    init(account: UsageAccount) {
        self.account = account
    }

    func currentCredential() async throws -> OAuthCredential {
        reads += 1
        return OAuthCredential(
            accessToken: "probe-access",
            refreshToken: nil,
            expiresAt: nil,
            source: .vault,
            account: account
        )
    }

    func readCount() -> Int { reads }
}

private actor CodexProbeIdentity {
    private var accountID: String
    private var reads = 0
    private var pausesNextRead = false
    private var pausedRead = false
    private var releaseRequested = false
    private var readContinuation: CheckedContinuation<Void, Never>?

    init(accountID: String) {
        self.accountID = accountID
    }

    func set(_ accountID: String) {
        self.accountID = accountID
    }

    func current() async -> String {
        reads += 1
        let currentAccountID = accountID
        if pausesNextRead {
            pausesNextRead = false
            await withCheckedContinuation { continuation in
                if releaseRequested {
                    releaseRequested = false
                    continuation.resume()
                } else {
                    pausedRead = true
                    readContinuation = continuation
                }
            }
        }
        return currentAccountID
    }

    func pauseNextRead() {
        pausesNextRead = true
    }

    func isReadPaused() -> Bool { pausedRead }

    func releasePausedRead() {
        if let readContinuation {
            self.readContinuation = nil
            pausedRead = false
            readContinuation.resume()
        } else if pausesNextRead {
            releaseRequested = true
        }
    }

    func readCount() -> Int { reads }
}

private final class ProtocolCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    func increment() { lock.withLock { calls += 1 } }
    var count: Int { lock.withLock { calls } }
    func reset() { lock.withLock { calls = 0 } }
}

private final class FailingUsageURLProtocol: URLProtocol, @unchecked Sendable {
    static let calls = ProtocolCallCounter()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.calls.increment()
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }

    override func stopLoading() {}
}

private actor SuspendedDeniedCredentials: CredentialProviding {
    private(set) var reads = 0
    private var secondReadIsWaiting = false
    private var secondReadStarted: CheckedContinuation<Void, Never>?
    private var secondReadContinuation: CheckedContinuation<Void, Never>?

    func currentCredential() async throws -> OAuthCredential {
        reads += 1
        if reads == 2 {
            await withCheckedContinuation { continuation in
                secondReadContinuation = continuation
                secondReadIsWaiting = true
                secondReadStarted?.resume()
                secondReadStarted = nil
            }
        }
        throw TokiError.keychainDenied
    }

    func waitForSecondRead() async {
        if secondReadIsWaiting { return }
        await withCheckedContinuation { continuation in
            secondReadStarted = continuation
        }
    }

    func releaseSecondRead() {
        secondReadIsWaiting = false
        secondReadContinuation?.resume()
        secondReadContinuation = nil
    }
}

private actor SupersededRefreshCredentials: CredentialProviding {
    private(set) var reads = 0
    private var invalidationIsWaiting = false
    private var invalidationStarted: CheckedContinuation<Void, Never>?
    private var invalidationContinuation: CheckedContinuation<Void, Never>?
    private var ordinaryReadIsWaiting = false
    private var ordinaryReadStarted: CheckedContinuation<Void, Never>?
    private var ordinaryReadContinuation: CheckedContinuation<Void, Never>?
    private var forcedReadStarted: CheckedContinuation<Void, Never>?
    private var forcedReadIsComplete = false

    func currentCredential() async throws -> OAuthCredential {
        try await currentCredential(userInitiated: false, forceRefresh: false)
    }

    func currentCredential(userInitiated: Bool) async throws -> OAuthCredential {
        try await currentCredential(userInitiated: userInitiated, forceRefresh: false)
    }

    func currentCredential(userInitiated: Bool, forceRefresh: Bool) async throws -> OAuthCredential {
        reads += 1
        if forceRefresh {
            forcedReadIsComplete = true
            forcedReadStarted?.resume()
            forcedReadStarted = nil
            throw TokiError.keychainDenied
        }
        await withCheckedContinuation { continuation in
            ordinaryReadContinuation = continuation
            ordinaryReadIsWaiting = true
            ordinaryReadStarted?.resume()
            ordinaryReadStarted = nil
        }
        throw TokiError.keychainDenied
    }

    func invalidateCache() async {
        await withCheckedContinuation { continuation in
            invalidationContinuation = continuation
            invalidationIsWaiting = true
            invalidationStarted?.resume()
            invalidationStarted = nil
        }
        invalidationIsWaiting = false
    }

    func waitForInvalidation() async {
        if invalidationIsWaiting { return }
        await withCheckedContinuation { continuation in
            invalidationStarted = continuation
        }
    }

    func waitForOrdinaryRead() async {
        if ordinaryReadIsWaiting { return }
        await withCheckedContinuation { continuation in
            ordinaryReadStarted = continuation
        }
    }

    func waitForForcedRead() async {
        if forcedReadIsComplete { return }
        await withCheckedContinuation { continuation in
            forcedReadStarted = continuation
        }
    }

    func releaseInvalidation() {
        invalidationContinuation?.resume()
        invalidationContinuation = nil
        invalidationIsWaiting = false
    }

    func releaseOrdinaryRead() {
        ordinaryReadContinuation?.resume()
        ordinaryReadContinuation = nil
        ordinaryReadIsWaiting = false
    }

    func releaseAll() {
        releaseInvalidation()
        releaseOrdinaryRead()
    }
}

private struct ProbeFailure: Error, CustomStringConvertible {
    let description: String
}

@MainActor
private struct Fixture {
    let directory: URL
    let tap: StatuslineTap
    let live: LiveLimits
    let driver: StatuslineUsageDriver
    let original: UsageLimits
    let weekReset: Date
    let refreshController: UsageRefreshController
    let session: URLSession

    init(
        legacyEnabled: Bool? = nil,
        bound: Bool = true,
        credentials: any CredentialProviding = UnusedCredentials(),
        originalAge: TimeInterval = 600,
        originalClaudeResets: ClaudeResetStatus? = nil,
        refreshController: UsageRefreshController? = nil,
        session: URLSession? = nil,
        signedInAccount: UsageAccount? = nil
    ) throws {
        Self.setLegacyEnabled(legacyEnabled)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tap = StatuslineTap(
            settingsURL: directory.appendingPathComponent("settings.json"),
            scriptURL: directory.appendingPathComponent("statusline.sh"),
            sampleURL: directory.appendingPathComponent("latest.json"),
            backupsURL: directory.appendingPathComponent("backups"),
            homeDirectory: directory.path
        )
        try "{}".write(to: tap.settingsURL, atomically: true, encoding: .utf8)
        let signedIn = SignedInAccount(configURL: directory.appendingPathComponent("claude.json"))
        let activeAccount = signedInAccount ?? UsageAccount(accountUuid: "account-a", organizationUuid: "org-a")
        signedIn.identity = AccountIdentity(
            accountUuid: activeAccount.accountUuid, email: nil, displayName: nil,
            organizationName: nil, organizationUuid: activeAccount.organizationUuid
        )
        let selectedController = refreshController ?? UsageRefreshController(
            scheduleURL: directory.appendingPathComponent("usage-refresh-schedule.json")
        )
        let selectedSession = session ?? URLSession(configuration: .ephemeral)
        self.refreshController = selectedController
        self.session = selectedSession
        live = LiveLimits(
            limits: LimitsService(
                credentials: credentials,
                session: selectedSession,
                cache: LimitsCache(fileURL: directory.appendingPathComponent("claude-cache.json")),
                refreshController: selectedController
            ),
            codex: CodexLimitsService(
                cache: LimitsCache(fileURL: directory.appendingPathComponent("codex-cache.json")),
                refreshController: selectedController
            ),
            signedIn: signedIn
        )
        weekReset = Date().addingTimeInterval(6 * 86400)
        original = UsageLimits(windows: [
            RateLimitWindow(id: "session", title: "5-hour", utilization: 0.1,
                            resetsAt: Date().addingTimeInterval(14400), isAvailable: true),
            RateLimitWindow(id: "weekly_all", title: "7-day", utilization: 0.2,
                            resetsAt: weekReset, isAvailable: true),
        ], extra: nil, fetchedAt: Date().addingTimeInterval(-originalAge),
           account: signedIn.usageAccount, bankedResets: nil,
           claudeResets: originalClaudeResets)
        if bound {
            live.limits = original
            live.state = .stale(original.fetchedAt)
        }
        driver = StatuslineUsageDriver(tap: tap, limits: live)
    }

    static func setLegacyEnabled(_ enabled: Bool?) {
        var preferences: [String: Any] = [:]
        if let enabled { preferences["toki.statuslineTap.enabled"] = enabled }
        UserDefaults.standard.setVolatileDomain(
            preferences, forName: UserDefaults.argumentDomain
        )
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: nil)
    }

    func writeSample(at date: Date = Date(), matchingWeek: Bool = true) throws {
        let payload: [String: Any] = ["rate_limits": [
            "five_hour": ["used_percentage": 35, "resets_at": original.fiveHour!.resetsAt!.timeIntervalSince1970],
            "seven_day": ["used_percentage": 40,
                          "resets_at": weekReset.addingTimeInterval(matchingWeek ? 0 : 86400).timeIntervalSince1970],
        ]]
        try JSONSerialization.data(withJSONObject: payload).write(to: tap.sampleURL, options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: tap.sampleURL.path)
    }

    func finish() {
        driver.stop()
        session.invalidateAndCancel()
        try? FileManager.default.removeItem(at: directory)
    }
}

@main
struct StatuslineUsageProbe {
    @MainActor static func main() async throws {
        let previous = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.setVolatileDomain(previous, forName: UserDefaults.argumentDomain) }
        let checks: [(String, @MainActor () async throws -> Void)] = [
            ("updates start automatically without a preference", automaticStartup),
            ("a legacy disabled preference cannot prevent updates", legacyDisabledPreference),
            ("legacy preference changes cannot stop updates", legacyPreferenceChanges),
            ("installation without samples leaves usage stale", noSamples),
            ("unbound samples do not count as updates", unboundSample),
            ("different-week samples do not count as updates", differentWeek),
            ("fresh samples update the shared store", freshSample),
            ("old samples stay stale", oldSample),
            ("future samples do not count as updates", futureSample),
            ("stopped drivers ignore pending samples", stoppedSource),
            ("restarted drivers consume existing samples", restartedSource),
            ("returning from fixtures restores real Claude usage", restoresLiveUsage),
            ("changing fixtures retains the original live snapshot", changingFixtures),
            ("returning from fixtures preserves authorization failure with cached usage", restoresCredentialFailure),
            ("a pre-fixture refresh cannot hide restored Claude resets", lateRefreshPreservesRestoredResets),
            ("an accepted forced refresh clears restored Claude reset availability", forcedRefreshClearsRestoredResets),
            ("a delayed credential gate survives cached usage expiry", delayedCredentialGate),
            ("a deferred Claude refresh preserves the restored reset projection", deferredClaudeRefreshPreservesResetProjection),
            ("returning from fixtures preserves a credential gate without cached usage", restoresCredentialGate),
            ("cached usage does not hide the credential gate", cachedUsagePreservesCredentialGate),
            ("returning from fixtures restores real Codex usage", restoresCodexUsage),
            ("a fixture account change restores only that Codex account snapshot", codexAccountChangeDuringFixtureRestoresMatchingSnapshot),
            ("reapplying live mode retains the current snapshot", repeatedLiveMode),
        ]
        var failures: [String] = []
        for (name, check) in checks {
            do {
                try await check()
                print("PASS: \(name)")
            } catch {
                failures.append(name)
                let line = "FAIL: \(name): \(error)\n"
                print(line, terminator: "")
                FileHandle.standardError.write(Data(line.utf8))
            }
        }
        if !failures.isEmpty { throw ProbeFailure(description: "Failed: \(failures.joined(separator: ", "))") }
    }

    @MainActor private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw ProbeFailure(description: message) }
    }

    @MainActor private static func restoresLiveUsage() async throws {
        let fixture = try Fixture()
        defer { fixture.finish() }
        fixture.live.runMode = .fixture(.singleAccount)
        fixture.live.limits = nil
        fixture.live.state = .ok
        fixture.live.runMode = .live
        try require(fixture.live.limits?.sevenDay?.utilization == 0.2, "The real Claude snapshot was erased")
        try require(fixture.live.state == .stale(fixture.original.fetchedAt), "Returning to live left usage loading")
        try fixture.writeSample()
        fixture.driver.start()
        try await waitFor { fixture.driver.lastSampleAt != nil }
        try require(fixture.live.limits?.sevenDay?.utilization == 0.4, "Passive updates cannot use the restored baseline")
    }

    @MainActor private static func changingFixtures() async throws {
        let fixture = try Fixture()
        defer { fixture.finish() }
        fixture.live.runMode = .fixture(.singleAccount)
        fixture.live.limits = UsageLimits(windows: [], extra: nil, fetchedAt: Date())
        fixture.live.runMode = .fixture(.empty)
        fixture.live.runMode = .live
        try require(fixture.live.limits?.sevenDay?.utilization == 0.2, "A later fixture replaced the saved live snapshot")
    }

    @MainActor private static func restoresCredentialFailure() async throws {
        let credentials = DeniedCredentials()
        let fixture = try Fixture(credentials: credentials)
        defer { fixture.finish() }
        fixture.live.refreshNow()
        try await waitFor { fixture.live.failure == .authorization }
        let retained = fixture.live.limits
        try require(retained?.account == fixture.original.account, "The retained snapshot lost its account binding")
        try require(fixture.live.state == .stale(fixture.original.fetchedAt), "Denied credentials erased the retained snapshot")
        fixture.live.runMode = .fixture(.singleAccount)
        fixture.live.limits = fixture.original
        fixture.live.state = .ok
        fixture.live.runMode = .live
        try require(fixture.live.limits?.account == retained?.account, "The retained account snapshot was not restored")
        try require(fixture.live.state == .stale(fixture.original.fetchedAt), "Returning to live did not retain stale usage")
        try require(fixture.live.failure == .authorization, "Returning from fixtures cleared the authorization failure")
        try require(await credentials.reads == 1, "Fixture restoration made another credential request")
    }

    @MainActor private static func delayedCredentialGate() async throws {
        let credentials = DeniedCredentials()
        let fixture = try Fixture(credentials: credentials, originalAge: 208.5)
        defer { fixture.finish() }
        fixture.live.refreshNow()
        try await waitFor { fixture.live.failure == .authorization }
        fixture.live.state = .needsAccess
        fixture.live.limitsFetchEnabled = false
        fixture.live.runMode = .fixture(.singleAccount)
        fixture.live.state = .ok
        try await Task.sleep(for: .milliseconds(150))
        fixture.live.runMode = .live
        try require(fixture.live.limits?.account == fixture.original.account, "The nearly expired account snapshot was not restored")
        try require(fixture.live.state == .needsAccess, "The credential gate was not restored")
        try require(fixture.live.failure == .authorization, "The credential failure was not restored")
        try await Task.sleep(for: .milliseconds(1_400))
        try require(fixture.live.state == .needsAccess, "Snapshot expiry replaced the credential gate")
        try require(fixture.live.failure == .authorization, "Snapshot expiry replaced the authorization failure")
        try require(await credentials.reads == 1, "A live credential request bypassed the disabled fetch gate")
    }

    @MainActor private static func lateRefreshPreservesRestoredResets() async throws {
        let credentials = SuspendedDeniedCredentials()
        let fixture = try Fixture(credentials: credentials)
        defer {
            Task { await credentials.releaseSecondRead() }
            fixture.finish()
        }

        let resetStatus = ClaudeResetStatus(
            eligible: true,
            grants: [ClaudeResetGrant(
                id: "probe-reset",
                resetsTotal: 4,
                resetsLeft: 3,
                usableNow: true,
                useRequiresLimit: false
            )]
        )
        let retained = UsageLimits(
            windows: fixture.original.windows,
            extra: fixture.original.extra,
            fetchedAt: fixture.original.fetchedAt,
            account: fixture.original.account,
            bankedResets: fixture.original.bankedResets,
            claudeResets: resetStatus
        )
        fixture.live.limits = retained
        fixture.live.state = .stale(retained.fetchedAt)

        fixture.live.refreshNow()
        try await waitFor { fixture.live.failure == .authorization }
        try require(fixture.live.limits?.claudeResets?.totalResets == 3, "The denied refresh erased the retained reset count")

        fixture.live.refreshNow()
        await credentials.waitForSecondRead()
        do {
            fixture.live.runMode = .fixture(.singleAccount)
            fixture.live.limits = nil
            fixture.live.state = .ok
            fixture.live.runMode = .live

            try require(fixture.live.limits?.account == retained.account, "Fixture return lost the retained account snapshot")
            try require(fixture.live.limits?.claudeResets?.totalResets == 3, "Fixture return lost retained Claude reset counters")
            try require(fixture.live.state == .stale(retained.fetchedAt), "Fixture return changed retained usage freshness")
            try require(fixture.live.failure == .authorization, "Fixture return lost the authorization failure")
            try require(fixture.live.allowsRestoredClaudeResets, "Fixture return did not allow restored Claude resets")

            await credentials.releaseSecondRead()
            try await Task.sleep(for: .milliseconds(100))

            try require(fixture.live.allowsRestoredClaudeResets, "The old refresh wrapper hid restored Claude resets")
            try require(fixture.live.limits?.claudeResets?.totalResets == 3, "The old refresh changed restored reset counters")
            try require(fixture.live.state == .stale(retained.fetchedAt), "The old refresh changed restored usage state")
            try require(fixture.live.failure == .authorization, "The old refresh changed the restored authorization failure")
            try require(await credentials.reads == 2, "Fixture return scheduled another live credential request")
        } catch {
            await credentials.releaseSecondRead()
            throw error
        }
    }

    @MainActor private static func forcedRefreshClearsRestoredResets() async throws {
        let credentials = SupersededRefreshCredentials()
        let fixture = try Fixture(credentials: credentials)
        defer {
            Task { await credentials.releaseAll() }
            fixture.finish()
        }

        let resetStatus = ClaudeResetStatus(
            eligible: true,
            grants: [ClaudeResetGrant(
                id: "forced-refresh-reset",
                resetsTotal: 5,
                resetsLeft: 4,
                usableNow: true,
                useRequiresLimit: false
            )]
        )
        let retained = UsageLimits(
            windows: fixture.original.windows,
            extra: fixture.original.extra,
            fetchedAt: fixture.original.fetchedAt,
            account: fixture.original.account,
            bankedResets: fixture.original.bankedResets,
            claudeResets: resetStatus
        )
        fixture.live.limits = retained
        fixture.live.state = .ok
        fixture.live.runMode = .fixture(.singleAccount)
        fixture.live.limits = nil
        fixture.live.state = .ok
        fixture.live.runMode = .live
        try require(fixture.live.allowsRestoredClaudeResets, "Fixture return did not enable retained reset display")

        fixture.live.accountDidChange(expectedAccountID: "account-a")
        await credentials.waitForInvalidation()
        fixture.live.refreshNow()
        await credentials.waitForOrdinaryRead()
        await credentials.releaseInvalidation()
        await credentials.waitForForcedRead()

        try await waitFor { fixture.live.failure == .authorization }
        try require(fixture.live.state == .needsAccess, "The forced credential error was not accepted")
        try await waitFor { !fixture.live.allowsRestoredClaudeResets }
        try require(await credentials.reads == 2, "The fixture roundtrip scheduled an unexpected credential request")
        await credentials.releaseOrdinaryRead()
    }

    @MainActor private static func restoresCredentialGate() async throws {
        let fixture = try Fixture(bound: false)
        defer { fixture.finish() }
        fixture.live.limitsFetchEnabled = false
        fixture.live.state = .needsAccess
        fixture.live.runMode = .fixture(.singleAccount)
        fixture.live.limits = fixture.original
        fixture.live.state = .ok
        fixture.live.runMode = .live
        try require(fixture.live.limits == nil, "Fixture usage leaked into live mode")
        try require(fixture.live.state == .needsAccess, "The credential gate became a perpetual loading state")
        try require(!fixture.live.limitsFetchEnabled, "Returning to live bypassed the credential gate")
    }

    @MainActor private static func restoresCodexUsage() async throws {
        let fixture = try Fixture()
        defer { fixture.finish() }
        fixture.live.codexLimits = fixture.original
        fixture.live.codexState = .stale(fixture.original.fetchedAt)
        fixture.live.runMode = .fixture(.singleAccount)
        fixture.live.codexLimits = UsageLimits(windows: [], extra: nil, fetchedAt: Date())
        fixture.live.codexState = .ok
        fixture.live.runMode = .live
        try require(fixture.live.codexLimits?.sevenDay?.utilization == 0.2, "Fixture Codex usage remained on screen")
        try require(fixture.live.codexState == .stale(fixture.original.fetchedAt), "Codex usage freshness was not restored")
    }

    @MainActor private static func codexAccountChangeDuringFixtureRestoresMatchingSnapshot() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("toki-codex-fixture-switch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let accountURL = directory.appendingPathComponent("active-account")
        let countURL = directory.appendingPathComponent("usage-count")
        try "B".write(to: accountURL, atomically: true, encoding: .utf8)
        try "0".write(to: countURL, atomically: true, encoding: .utf8)
        let executable = directory.appendingPathComponent("codex-stub")
        try """
        #!/usr/bin/python3
        import json, pathlib, sys
        account_path = pathlib.Path("\(accountURL.path)")
        count_path = pathlib.Path("\(countURL.path)")
        for line in sys.stdin:
            request = json.loads(line)
            if "id" not in request:
                continue
            result = {}
            if request.get("method") == "account/rateLimits/read":
                account_id = account_path.read_text().strip()
                count = int(count_path.read_text()) + 1
                count_path.write_text(str(count))
                result = {
                    "accountId": account_id,
                    "rateLimits": {"limitId": "codex", "primary": {
                        "usedPercent": 22 if account_id == "B" else 11,
                        "windowDurationMins": 300, "resetsAt": None}, "secondary": None},
                    "rateLimitResetCredits": {"availableCount": 7 if account_id == "B" else 3}
                }
            print(json.dumps({"id": request["id"], "result": result}), flush=True)
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

        let identity = CodexProbeIdentity(accountID: "B")
        defer { Task { await identity.releasePausedRead() } }
        let scheduleURL = directory.appendingPathComponent("usage-refresh-schedule.json")
        let controller = UsageRefreshController(
            scheduleURL: scheduleURL
        )
        let codexService = CodexLimitsService(
            client: CodexAppServerClient(executableURL: executable),
            cache: LimitsCache(fileURL: directory.appendingPathComponent("codex-cache.json")),
            refreshController: controller,
            accountID: { await identity.current() }
        )
        let signedIn = SignedInAccount(configURL: directory.appendingPathComponent("claude.json"))
        let live = LiveLimits(
            limits: LimitsService(
                credentials: UnusedCredentials(),
                cache: LimitsCache(fileURL: directory.appendingPathComponent("claude-cache.json")),
                refreshController: controller
            ),
            codex: codexService,
            signedIn: signedIn
        )

        live.refreshCodexNow()
        try await waitForAsync("initial B fetch") {
            live.codexState == .ok && live.codexLimits?.account?.accountUuid == "B"
        }
        try require(live.codexLimits?.fiveHour?.utilization == 0.22, "The fake App Server did not publish B's initial usage")

        try "A".write(to: accountURL, atomically: true, encoding: .utf8)
        await identity.set("A")
        live.codexAccountDidChange()
        try await waitForAsync("A fetch") {
            live.codexState == .ok && live.codexLimits?.account?.accountUuid == "A"
        }
        try require(live.codexLimits?.fiveHour?.utilization == 0.11, "The fake App Server did not publish A's usage")
        try require(try String(contentsOf: countURL, encoding: .utf8) == "2", "Initial B/A seeding made an unexpected App Server request")

        live.runMode = .fixture(.singleAccount)
        live.codexLimits = UsageLimits(
            windows: [RateLimitWindow(id: "session", title: "5-hour", utilization: 0.99,
                                      resetsAt: nil, isAvailable: true)],
            extra: nil,
            fetchedAt: Date(),
            account: UsageAccount(accountUuid: "fixture", organizationUuid: nil),
            bankedResets: BankedResets(availableCount: 99, credits: nil)
        )
        live.codexState = .ok
        try "B".write(to: accountURL, atomically: true, encoding: .utf8)
        await identity.set("B")
        live.codexAccountDidChange()
        try await waitForAsync("cached B restoration during fixtures") {
            live.codexState == .stale(live.codexLimits?.fetchedAt ?? .distantPast)
                && live.codexLimits?.account?.accountUuid == "B"
        }
        try require(live.codexLimits?.fiveHour?.utilization == 0.22, "The actual Codex service did not restore B's cached usage")
        try require(live.codexLimits?.bankedResets?.availableCount == 7, "The actual Codex service did not restore B's reset count")

        let accountReadsBeforeLiveRefresh = await identity.readCount()
        live.runMode = .live
        live.refreshCodexNow()
        try await waitForAsync("the live Codex refresh to enter the shared controller") {
            await identity.readCount() > accountReadsBeforeLiveRefresh
        }
        let deferred: Bool
        do {
            _ = try await codexService.fetchLimits()
            deferred = false
        } catch is UsageRefreshDeferred {
            deferred = true
        }
        try require(deferred, "B's shared cadence did not defer the post-fixture collection")
        for _ in 0..<12 { await Task.yield() }

        try require(live.codexLimits?.account?.accountUuid == "B", "Returning live showed a different Codex account")
        try require(live.codexLimits?.fiveHour?.utilization == 0.22, "Returning live replaced B's deferred usage")
        try require(live.codexLimits?.bankedResets?.availableCount == 7, "Returning live lost B's deferred reset count")
        if let fetchedAt = live.codexLimits?.fetchedAt {
            try require(live.codexState == .stale(fetchedAt), "B's deferred snapshot was not marked stale")
        } else {
            throw ProbeFailure(description: "B's deferred snapshot has no timestamp")
        }
        try require(try String(contentsOf: countURL, encoding: .utf8) == "2", "A deferred refresh made an extra App Server usage request")

        live.runMode = .fixture(.singleAccount)
        live.codexLimits = UsageLimits(
            windows: [RateLimitWindow(id: "session", title: "5-hour", utilization: 0.88,
                                      resetsAt: nil, isAvailable: true)],
            extra: nil,
            fetchedAt: Date(),
            account: UsageAccount(accountUuid: "fixture", organizationUuid: nil),
            bankedResets: BankedResets(availableCount: 88, credits: nil)
        )
        live.codexState = .ok
        try "A".write(to: accountURL, atomically: true, encoding: .utf8)
        await identity.set("A")
        await identity.pauseNextRead()
        live.codexAccountDidChange()
        do {
            try await waitForAsync("the paused A cache lookup") {
                await identity.isReadPaused()
            }

            live.runMode = .live
            try require(live.codexLimits == nil, "The prior Codex account reappeared before A's cache lookup completed")
            await identity.releasePausedRead()
            try await waitForAsync("A's cached snapshot after returning live") {
                live.codexLimits?.account?.accountUuid == "A"
                    && live.codexState == .stale(live.codexLimits?.fetchedAt ?? .distantPast)
            }
            try require(live.codexLimits?.fiveHour?.utilization == 0.11, "The pending cache lookup did not restore A's usage")
            try require(live.codexLimits?.bankedResets?.availableCount == 3, "The pending cache lookup did not restore A's resets")
        } catch {
            await identity.releasePausedRead()
            throw error
        }
    }

    @MainActor private static func deferredClaudeRefreshPreservesResetProjection() async throws {
        FailingUsageURLProtocol.calls.reset()
        let account = UsageAccount(accountUuid: "claude-probe", organizationUuid: "org-probe")
        let credentials = AccountBoundCredentials(account: account)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FailingUsageURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let defaultsName = "toki-statusline-reset-probe-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: defaultsName) else {
            session.invalidateAndCancel()
            throw ProbeFailure(description: "Unable to create isolated view-model preferences")
        }
        defer { defaults.removePersistentDomain(forName: defaultsName) }

        let resetStatus = ClaudeResetStatus(
            eligible: true,
            grants: [ClaudeResetGrant(
                id: "probe-reset",
                resetsTotal: 4,
                resetsLeft: 3,
                usableNow: true,
                useRequiresLimit: false
            )]
        )
        let controller = UsageRefreshController()
        let fixture = try Fixture(
            credentials: credentials,
            originalClaudeResets: resetStatus,
            refreshController: controller,
            session: session,
            signedInAccount: account
        )
        defer { fixture.finish() }

        let menu = MenuBarViewModel(
            live: fixture.live,
            configurationState: MenuBarConfigurationState(
                store: MenuBarConfigurationStore(defaults: defaults)
            ),
            usageDisplayState: UsageDisplayConfigurationState(
                store: UsageDisplayConfigurationStore(defaults: defaults)
            ),
            availableProviders: [.claudeCode]
        )
        fixture.live.refreshNow()
        try await waitFor { fixture.live.failure == .network }
        try require(FailingUsageURLProtocol.calls.count == 1, "The initial Claude failure did not reach the isolated URL protocol")
        try require(fixture.live.limits?.claudeResets?.totalResets == 3, "The network failure erased retained reset metadata")

        fixture.live.runMode = .fixture(.singleAccount)
        fixture.live.limits = fixture.original
        fixture.live.state = .ok
        fixture.live.runMode = .live
        try require(fixture.live.failure == .network, "Fixture restoration lost the network failure")
        try require(fixture.live.allowsRestoredClaudeResets, "Fixture restoration did not permit stale reset display")

        fixture.live.refreshNow()
        try await waitForAsync("the deferred Claude credential read") {
            await credentials.readCount() >= 2
        }
        let serviceDeferred: Bool
        do {
            _ = try await fixture.live.cachedFetcher.fetchLimits()
            serviceDeferred = false
        } catch is UsageRefreshDeferred {
            serviceDeferred = true
        }
        try require(serviceDeferred, "The failed account's shared controller cooldown was not retained")
        try require(FailingUsageURLProtocol.calls.count == 1, "The deferred Claude refresh sent another network request")
        for _ in 0..<12 { await Task.yield() }

        try require(fixture.live.limits?.account == fixture.original.account, "The deferred refresh changed the restored Claude account")
        try require(fixture.live.limits?.claudeResets?.totalResets == 3, "The deferred refresh changed restored reset metadata")
        try require(fixture.live.state == .stale(fixture.original.fetchedAt), "The deferred refresh changed restored freshness")
        try require(fixture.live.failure == .network, "The deferred refresh changed the retained failure")
        try require(menu.allowsStaleClaudeResetDisplay, "The menu-bar projection revoked retained stale reset display")
        try require(menu.currentClaudeResetLimits?.claudeResets?.totalResets == 3, "The shared reset projection hid retained Claude resets")
        try require(await credentials.readCount() == 3, "The deferred refresh path made an unexpected credential read")
    }

    @MainActor private static func cachedUsagePreservesCredentialGate() async throws {
        let fixture = try Fixture()
        defer { fixture.finish() }
        fixture.live.limitsFetchEnabled = false
        fixture.live.state = .needsAccess
        fixture.live.runMode = .fixture(.singleAccount)
        fixture.live.state = .ok
        fixture.live.runMode = .live
        try require(fixture.live.limits?.sevenDay?.utilization == 0.2, "The credential gate erased the cached usage")
        try require(fixture.live.state == .needsAccess, "Cached usage hid the required credential access")
    }

    @MainActor private static func repeatedLiveMode() async throws {
        let fixture = try Fixture()
        defer { fixture.finish() }
        fixture.live.runMode = .live
        try require(fixture.live.limits?.sevenDay?.utilization == 0.2, "Reapplying live mode erased the current snapshot")
    }

    @MainActor private static func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw ProbeFailure(description: "Timed out waiting for the driver")
    }

    @MainActor private static func waitForAsync(
        _ description: String,
        condition: @MainActor () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while !(await condition()) {
            guard clock.now < deadline else {
                throw ProbeFailure(description: "Timed out waiting for \(description)")
            }
            await Task.yield()
        }
    }

    @MainActor private static func settle(_ fixture: Fixture, status: StatuslineUsageDriver.Status) async throws {
        try await waitFor { fixture.driver.status == status }
        try await Task.sleep(for: .milliseconds(150))
    }

    @MainActor private static func automaticStartup() async throws {
        let fixture = try Fixture()
        defer { fixture.finish() }
        try fixture.writeSample()
        fixture.driver.start()
        try await waitFor { fixture.live.limits?.sevenDay?.utilization == 0.4 }
        try require(fixture.live.state == .ok, "Default startup did not publish current usage")
        try await waitFor { fixture.driver.status == .silentStatusLine }
        try require(try fixture.tap.state() == .tapped(original: ""), "Default startup did not install the integration")
    }

    @MainActor private static func legacyDisabledPreference() async throws {
        let fixture = try Fixture(legacyEnabled: false)
        defer { fixture.finish() }
        try fixture.writeSample()
        fixture.driver.start()
        try await waitFor { fixture.live.limits?.sevenDay?.utilization == 0.4 }
        try require(fixture.live.state == .ok, "Legacy preference prevented current usage")
        try await waitFor { fixture.driver.status == .silentStatusLine }
        try require(try fixture.tap.state() == .tapped(original: ""), "Legacy preference prevented installation")
    }

    @MainActor private static func legacyPreferenceChanges() async throws {
        let fixture = try Fixture(legacyEnabled: true)
        defer { fixture.finish() }
        try fixture.writeSample()
        fixture.driver.start()
        try await waitFor { fixture.driver.lastSampleAt != nil }
        let acceptedAt = fixture.driver.lastSampleAt
        Fixture.setLegacyEnabled(false)
        try await settle(fixture, status: .silentStatusLine)
        try require(fixture.driver.lastSampleAt == acceptedAt, "Legacy preference cleared source activity")
        try fixture.writeSample()
        try await waitFor { fixture.driver.lastSampleAt != nil && fixture.driver.lastSampleAt != acceptedAt }
        try require(fixture.live.limits?.fetchedAt == fixture.driver.lastSampleAt, "Legacy preference stopped new updates")
        try require(try fixture.tap.state() == .tapped(original: ""), "Legacy preference uninstalled the integration")
    }

    @MainActor private static func noSamples() async throws {
        let fixture = try Fixture()
        defer { fixture.finish() }
        fixture.driver.start()
        try await settle(fixture, status: .silentStatusLine)
        try require(fixture.driver.lastSampleAt == nil, "Installation counts as an update")
        try require(fixture.live.state == .stale(fixture.original.fetchedAt), "Installation changed freshness")
    }

    @MainActor private static func unboundSample() async throws {
        let fixture = try Fixture(bound: false)
        defer { fixture.finish() }
        try fixture.writeSample()
        fixture.driver.start()
        try await settle(fixture, status: .silentStatusLine)
        try require(fixture.live.limits == nil, "Sample created an unbound snapshot")
        try require(fixture.driver.lastSampleAt == nil, "Rejected sample reports an update")
    }

    @MainActor private static func differentWeek() async throws {
        let fixture = try Fixture()
        defer { fixture.finish() }
        try fixture.writeSample(matchingWeek: false)
        fixture.driver.start()
        try await settle(fixture, status: .silentStatusLine)
        try require(fixture.live.limits?.fetchedAt == fixture.original.fetchedAt, "Rejected sample changed the snapshot")
        try require(fixture.driver.lastSampleAt == nil, "Rejected sample reports an update")
    }

    @MainActor private static func freshSample() async throws {
        let fixture = try Fixture()
        defer { fixture.finish() }
        try fixture.writeSample()
        fixture.driver.start()
        try await waitFor { fixture.live.limits?.sevenDay?.utilization == 0.4 }
        try require(fixture.live.state == .ok, "Fresh sample stayed stale")
        try require(fixture.driver.lastSampleAt == fixture.live.limits?.fetchedAt, "Accepted sample time was lost")
    }

    @MainActor private static func oldSample() async throws {
        let fixture = try Fixture()
        defer { fixture.finish() }
        try fixture.writeSample(at: Date().addingTimeInterval(-300))
        fixture.driver.start()
        try await waitFor { fixture.live.limits?.sevenDay?.utilization == 0.4 }
        guard let updated = fixture.live.limits else { throw ProbeFailure(description: "No snapshot") }
        try require(fixture.live.state == .stale(updated.fetchedAt), "Old sample became current")
    }

    @MainActor private static func futureSample() async throws {
        let fixture = try Fixture()
        defer { fixture.finish() }
        try fixture.writeSample(at: Date().addingTimeInterval(600))
        fixture.driver.start()
        try await settle(fixture, status: .silentStatusLine)
        try require(fixture.live.limits?.fetchedAt == fixture.original.fetchedAt, "Future sample changed the snapshot")
        try require(fixture.driver.lastSampleAt == nil, "Future sample reports an update")
    }

    @MainActor private static func stoppedSource() async throws {
        let fixture = try Fixture()
        defer { fixture.finish() }
        try fixture.writeSample()
        fixture.driver.start()
        fixture.driver.stop()
        try await Task.sleep(for: .milliseconds(150))
        try require(fixture.live.limits?.fetchedAt == fixture.original.fetchedAt, "Stopped driver applied a sample")
        try require(fixture.driver.lastSampleAt == nil, "Stopped driver reports an update")
    }

    @MainActor private static func restartedSource() async throws {
        let fixture = try Fixture()
        defer { fixture.finish() }
        try fixture.writeSample()
        fixture.driver.start()
        try await waitFor { fixture.driver.lastSampleAt != nil }
        let previousSampleAt = fixture.driver.lastSampleAt
        fixture.driver.stop()
        try fixture.writeSample()
        fixture.driver.start()
        try await waitFor { fixture.driver.lastSampleAt != nil && fixture.driver.lastSampleAt != previousSampleAt }
        try require(fixture.live.state == .ok, "Restarted driver did not publish current usage")
        try require(fixture.driver.lastSampleAt == fixture.live.limits?.fetchedAt, "Restarted driver lost its sample")
    }

}
