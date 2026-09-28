import Foundation
import TokiAccounts
import TokiAutoSwap
import TokiCore

private struct UnusedCredentials: CredentialProviding {
    func currentCredential() async throws -> OAuthCredential {
        throw TokiError.credentialsNotFound
    }
}

private final class MemoryProfiles: CodexProfileStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: CodexAccountProfile] = [:]
    private var loadsUntilPause: Int?
    private var paused = false
    private let resumeLoad = DispatchSemaphore(value: 0)
    var isLoadPaused: Bool { lock.withLock { paused } }
    func pauseSecondLoad() { lock.withLock { loadsUntilPause = 2 } }
    func resumePausedLoad() { resumeLoad.signal() }
    func loadAll() throws -> [CodexAccountProfile] {
        let shouldPause = lock.withLock {
            guard let remaining = loadsUntilPause else { return false }
            loadsUntilPause = remaining - 1
            if remaining == 1 {
                loadsUntilPause = nil
                paused = true
                return true
            }
            return false
        }
        if shouldPause {
            resumeLoad.wait()
            lock.withLock { paused = false }
        }
        return lock.withLock { Array(values.values) }
    }
    func load(id: String) throws -> CodexAccountProfile? { lock.withLock { values[id] } }
    func save(_ profile: CodexAccountProfile) throws { lock.withLock { values[profile.id] = profile } }
    func delete(id: String) throws { _ = lock.withLock { values.removeValue(forKey: id) } }
}

@main
struct CodexFreshnessProbe {
    @MainActor
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("toki-codex-freshness-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let authURL = directory.appendingPathComponent("auth.json")
        let auth = Data(#"{"tokens":{"access_token":"dummy-access","refresh_token":"dummy-refresh","account_id":"fixture-active"}}"#.utf8)
        try CodexAuthFile.writeAtomically(auth, to: authURL)
        let identity = try CodexAuthBlob.identity(from: auth)
        let now = Date()
        let store = MemoryProfiles()
        var active = CodexAccountProfile(identity: identity, authJSON: auth, addedAt: now,
            fiveHourUtilization: 0.25, weeklyUtilization: 0.10,
            gaugesFetchedAt: now, gaugesAreStale: false)
        try store.save(active)

        // A local protocol stub prevents discovery of the user's Codex installation.
        // It stays alive through requests, avoiding a SIGPIPE from an early-exit stub.
        let executable = directory.appendingPathComponent("codex-stub")
        try """
        #!/usr/bin/python3
        import json, sys
        for line in sys.stdin:
            request = json.loads(line)
            if "id" in request:
                reply = {"id": request["id"]}
                if request["method"] == "initialize":
                    reply["result"] = {}
                else:
                    reply["error"] = {"code": -32000, "message": "fixture unavailable"}
                print(json.dumps(reply), flush=True)
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let client = CodexAppServerClient(executableURL: executable)
        let controller = UsageRefreshController()
        let live = LiveLimits(
            limits: LimitsService(credentials: UnusedCredentials(),
                cache: LimitsCache(fileURL: directory.appendingPathComponent("claude-cache.json")),
                refreshController: controller),
            codex: CodexLimitsService(client: client,
                cache: LimitsCache(fileURL: directory.appendingPathComponent("codex-cache.json")),
                refreshController: controller),
            signedIn: SignedInAccount(configURL: directory.appendingPathComponent("claude-config.json")))
        let vm = CodexAccountsViewModel(store: store,
            switcher: CodexProfileSwitcher(store: store, liveAuthURL: authURL),
            client: client, liveLimits: live, liveAuthURL: authURL,
            refreshController: controller)
        live.codexLimits = UsageLimits(windows: [
            RateLimitWindow(id: "session", title: "5-hour", utilization: 0.99, resetsAt: nil, isAvailable: true),
            RateLimitWindow(id: "weekly_all", title: "Weekly", utilization: 0.1, resetsAt: nil, isAvailable: true),
        ], extra: nil, fetchedAt: now)
        await vm.reload()
        var failures: [String] = []
        func require(_ condition: Bool, _ message: String) {
            if !condition { failures.append(message) }
        }
        var settings = AutoSwapSettings.default
        settings.enabled = true
        let candidate = AccountSnapshot(accountUuid: "rested", label: "Rested", fiveHour: 0.05,
            weekly: 0.05, isActive: false, isHealthy: true, gaugesAreStale: false)
        for state: LiveLimits.State in [.loading, .stale(now), .notLoggedIn, .needsAccess, .error("fixture")] {
            live.codexState = state
            let snapshots = vm.snapshotsForPolicy(now: now)
            require(snapshots.first?.gaugesAreStale == true, "non-ok state must revoke active policy gauges: \(state)")
            require(AutoSwapPolicy.decide(accounts: snapshots + [candidate], settings: settings,
                now: now, lastSwapAt: nil) == .doNothing, "recent stale/error live payload must not select a swap")
        }

        live.codexState = .stale(now)
        await vm.refreshGauges()
        let persisted = try store.load(id: identity.id)
        require(persisted?.gaugesAreStale == true, "background upkeep marked stale live payload fresh")
        require(persisted?.fiveHourUtilization == 0.25, "background upkeep copied stale live utilization over stored data")

        // An old storage failure cannot veto a new successful live response.
        active.gaugesAreStale = true
        try store.save(active)
        await vm.reload()
        live.codexState = .ok
        let recovered = vm.snapshotsForPolicy(now: now)
        require(recovered.first?.gaugesAreStale == false, "ok live recovery remained blocked by stored stale flag")
        require(AutoSwapPolicy.decide(accounts: recovered + [candidate], settings: settings,
            now: now, lastSwapAt: nil) == .swap(to: "rested", trigger: SwapTrigger(window: .fiveHour, utilization: 0.99)),
            "genuine live recovery must allow the policy to select fresh headroom")
        await vm.refreshGauges()
        require(try store.load(id: identity.id)?.gaugesAreStale == false, "ok live upkeep must restore stored freshness")
        require(try store.load(id: identity.id)?.fiveHourUtilization == 0.99, "ok live upkeep must persist current gauges")

        // A sleeping machine can retain .ok while its last poll has aged out.
        live.codexLimits = UsageLimits(windows: live.codexLimits!.windows, extra: nil,
            fetchedAt: now.addingTimeInterval(-181))
        require(vm.snapshotsForPolicy(now: now).first?.gaugesAreStale == true,
            "ok state must not authorize 181-second-old active limits after sleep")
        await vm.refreshGauges()
        require(try store.load(id: identity.id)?.gaugesAreStale == true,
            "upkeep must not re-stamp aged active limits fresh")

        // Refresh reloads A, then awaits profile loading. Switch to B while that load
        // is suspended: A must not inherit B's freshly published utilization.
        store.pauseSecondLoad()
        let refreshing = Task { await vm.refreshGauges() }
        for _ in 0..<200 {
            if store.isLoadPaused { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard store.isLoadPaused else {
            print("FAIL: profile-load race fixture did not reach its suspension point")
            exit(1)
        }
        let otherIdentity = CodexAccountIdentity(id: "fixture-b", email: nil, planType: nil)
        vm.accounts = [CodexAccountPresentation.make(profile: active, activeID: otherIdentity.id),
                       .makeLiveUnstored(identity: otherIdentity)]
        live.codexLimits = UsageLimits(windows: [
            RateLimitWindow(id: "session", title: "5-hour", utilization: 0.42, resetsAt: nil, isAvailable: true),
        ], extra: nil, fetchedAt: Date())
        live.codexState = .ok
        store.resumePausedLoad()
        await refreshing.value
        require(try store.load(id: identity.id)?.fiveHourUtilization == 0.99,
            "refresh copied account B live utilization into account A after an awaited load")
        require(try store.load(id: identity.id)?.gaugesAreStale == true,
            "inactive A must retain stale status when its isolated poll fails")

        guard failures.isEmpty else {
            for failure in failures { print("FAIL: \(failure)") }
            exit(1)
        }
        print("PASS: real CodexAccountsViewModel rejects non-ok live limits, preserves stale upkeep and accepts genuine recovery")
    }
}
