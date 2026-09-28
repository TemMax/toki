/// Cached polling boundary for Codex App Server rate limits.
import Foundation
import TokiLogging
import TokiModels

private let log = TokiLog.logger("codex-limits")

public actor CodexLimitsService {
    private let client: CodexAppServerClient
    private let cache: LimitsCache
    private let refreshController: UsageRefreshController
    private let accountID: @Sendable () async -> String?
    private var inFlight: Task<(UsageRefreshKey, UsageLimits), Error>?
    private var accountGeneration = 0
    private var snapshotsByAccount: [String: UsageLimits] = [:]

    public init(
        client: CodexAppServerClient = CodexAppServerClient(),
        cache: LimitsCache = LimitsCache(
            fileURL: AppSupportDirectory.url.appendingPathComponent("codex-limits-cache.json")
        ),
        refreshController: UsageRefreshController,
        accountID: @escaping @Sendable () async -> String? = { nil }
    ) {
        self.client = client
        self.cache = cache
        self.refreshController = refreshController
        self.accountID = accountID
    }

    public func cachedLimits() -> UsageLimits? {
        cache.load()
    }

    public func fetchLimits() async throws -> UsageLimits {
        if let inFlight {
            return try await inFlight.value.1
        }

        let client = self.client
        let refreshController = self.refreshController
        let accountID = self.accountID
        let generation = accountGeneration
        let task = Task {
            let key = UsageRefreshKey(
                provider: .codex, accountID: await accountID() ?? "live"
            )
            guard generation == self.accountGeneration else { throw CancellationError() }
            guard let permit = await refreshController.begin(key) else {
                throw UsageRefreshDeferred()
            }
            do {
                let limits = try await client.fetchUsage()
                await refreshController.finish(permit, outcome: .response(limits))
                return (key, limits)
            } catch {
                // The caller reports the failure to the user; this records the provider call.
                log.debug("Codex usage request failed \(error: error)")
                await refreshController.finish(permit, outcome: .error(error))
                throw error
            }
        }
        inFlight = task
        defer { inFlight = nil }

        let (key, limits) = try await task.value
        guard generation == accountGeneration else { throw CancellationError() }
        if key.accountID != "live" {
            snapshotsByAccount[key.accountID] = limits
        }
        cache.save(limits)
        return limits
    }

    /// Restores only the current account's prior response after an account switch.
    /// The caller presents it as stale until the controller permits another request.
    public func lastSnapshotForCurrentAccount() async -> UsageLimits? {
        guard let id = await accountID() else { return nil }
        return snapshotsByAccount[id]
    }

    /// Invalidates both the persistent cache and an in-flight result after auth.json changes.
    public func accountDidChange() {
        accountGeneration += 1
        inFlight?.cancel()
        inFlight = nil
        cache.remove()
        // A recognized new account gets a new key on its next fetch. If identity is
        // unknown, retain the fallback key's cooldown rather than guessing a switch.
    }
}
