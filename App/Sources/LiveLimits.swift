import Foundation
import Observation
import TokiCore
import TokiFixtures

/// The single source of truth for Claude Code and Codex rate-limit usage.
///
/// Before this existed the menu-bar popover, the dashboard's Usage tab and the Accounts tab
/// each fetched and stored their own copy of the active account's limits, so they refreshed
/// on different schedules and drifted out of sync — the popover would update on an account
/// switch while the Accounts card still showed the previous account. Now one object owns the
/// data and the poll loop; every surface observes it, so they all move together and update
/// reactively.
@Observable
@MainActor
final class LiveLimits {

    typealias State = LiveUsageFeed.State

    private let claudeFeed: LiveUsageFeed
    private let signedIn: SignedInAccount

    /// Retains the last snapshot for display; automation must also check freshness.
    var limits: UsageLimits? {
        get {
            guard let limits = claudeFeed.limits else { return nil }
            guard !runMode.isLive || (limits.account != nil && limits.account == signedIn.usageAccount) else {
                return nil
            }
            return limits
        }
        set { claudeFeed.limits = newValue }
    }
    var state: State {
        get { claudeFeed.state }
        set { claudeFeed.state = newValue }
    }
    var failure: LiveUsageFeed.Failure? { claudeFeed.failure }
    private(set) var allowsRestoredClaudeResets = false

    /// Codex is intentionally independent: a missing CLI or expired ChatGPT session must not
    /// hide Claude data, and a Keychain denial for Claude must not stop Codex polling.
    var codexLimits: UsageLimits?
    var codexState: State = .loading
    private(set) var allowsRestoredCodexResets = false

    /// No-ops the lifecycle for the demo/snapshot harness.
    var runMode: RunMode = .live {
        didSet {
            claudeFeed.invalidate()
            allowsRestoredClaudeResets = false
            allowsRestoredCodexResets = false
        }
    }

    /// Gates the live fetch (the one path that reads the Keychain and can prompt).
    /// `ServiceContainer` holds it false until access is confirmed.
    var limitsFetchEnabled = true

    private let limitsService: LimitsService
    private let codexLimitsService: CodexLimitsService
    /// A cooldown must not erase the last known snapshot when switching A → B → A.
    /// The feed itself only publishes the currently signed-in Claude account.
    private var claudeSnapshots: [UsageRefreshKey: UsageLimits] = [:]
    private var pollingTask: Task<Void, Never>?
    private var codexPollingTask: Task<Void, Never>?
    private var codexAccountGeneration: UInt64 = 0
    private let log = TokiLog.logger("limits")
    private let logger = TokiLog.logger("codex-limits")

    init(limits limitsService: LimitsService, codex codexLimitsService: CodexLimitsService, signedIn: SignedInAccount) {
        self.signedIn = signedIn
        self.claudeFeed = LiveUsageFeed { force in
            try await (force ? limitsService.refreshLimitsFreshCredential() : limitsService.fetchLimits())
        }
        self.limitsService = limitsService
        self.codexLimitsService = codexLimitsService
    }

    var cachedFetcher: LimitsService { limitsService }

    /// Starts the Claude background poll. Codex has its own lifecycle because either CLI may
    /// be absent while the other is installed.
    func start() {
        guard runMode.isLive else { return }
        if pollingTask == nil {
            pollingTask = Task { [weak self] in
                guard let self else { return }
                await self.pollLoop()
            }
        }
    }

    /// Starts only the credential-free Codex loop. ServiceContainer calls this at launch,
    /// before Claude's Keychain onboarding has completed.
    func startCodex() {
        guard runMode.isLive, codexPollingTask == nil else { return }
        codexPollingTask = Task { [weak self] in
            guard let self else { return }
            if self.codexLimits == nil, let cached = await self.codexLimitsService.cachedLimits() {
                self.codexLimits = cached
                self.codexState = .stale(cached.fetchedAt)
            }
            await self.codexPollLoop()
        }
    }

    /// Shows the last saved snapshots until a live response replaces them — so a launch that
    /// meets a 429 or the shared cooldown still shows the account's usage. Claude's is marked
    /// stale only once it is past the feed's freshness ceiling (`LiveUsageFeed.restore`).
    ///
    /// Claude's cached snapshot records the account it belongs to, and `limits` only ever
    /// returns a snapshot for the signed-in account, so a cache written for another account
    /// is never presented as this one's. A live result or a failure that arrived first wins.
    func primeFromCache(includeClaude: Bool = true, includeCodex: Bool = true) {
        guard runMode.isLive else { return }
        Task { [weak self] in
            guard let self else { return }
            if includeClaude,
               let cached = await self.limitsService.cachedLimits(),
               cached.account != nil,
               self.claudeFeed.limits == nil,
               self.claudeFeed.state == .loading {
                self.claudeFeed.restore(cached)
                self.allowsRestoredClaudeResets = true
            }
            if includeCodex,
               self.codexLimits == nil,
               let cached = await self.codexLimitsService.cachedLimits() {
                self.codexLimits = cached
                self.codexState = .stale(cached.fetchedAt)
            }
        }
    }

    func stop() {
        claudeFeed.invalidate()
        allowsRestoredClaudeResets = false
        allowsRestoredCodexResets = false
        pollingTask?.cancel()
        pollingTask = nil
        codexPollingTask?.cancel()
        codexPollingTask = nil
    }

    /// Fetch fresh usage with a valid credential. Opening the popover must not bypass the
    /// vault: the source item may require access even after an explicit repair succeeded.
    func refreshNow() {
        Task { [weak self] in await self?.fetchOnce() }
    }

    /// Reject pre-repair replies and immediately use the credential just authorized.
    /// Do not invalidate LimitsService's credential cache here: that would erase the repair.
    func credentialAccessDidRecover() {
        claudeFeed.invalidate(preservingSnapshot: true)
        allowsRestoredClaudeResets = claudeFeed.limits?.account == signedIn.usageAccount
        refreshNow()
    }

    /// Refreshes only Codex after a Codex profile switch. Claude credentials and gauges are
    /// deliberately untouched because the two account domains are independent.
    func refreshCodexNow() {
        Task { [weak self] in await self?.fetchCodexOnce() }
    }

    func codexAccountDidChange() {
        codexAccountGeneration &+= 1
        let generation = codexAccountGeneration
        codexLimits = nil
        codexState = .loading
        allowsRestoredCodexResets = false
        Task { [weak self] in
            guard let self else { return }
            await self.codexLimitsService.accountDidChange()
            guard self.codexAccountGeneration == generation else { return }
            if let previous = await self.codexLimitsService.lastSnapshotForCurrentAccount() {
                guard self.codexAccountGeneration == generation else { return }
                self.codexLimits = previous
                self.codexState = .stale(previous.fetchedAt)
                self.allowsRestoredCodexResets = true
            }
            await self.fetchCodexOnce()
        }
    }

    private func pollLoop() async {
        while !Task.isCancelled {
            await fetchOnce()
            // The controller applies the shared 90-second floor and 429 backoff to
            // actual provider calls, including popover-initiated refreshes.
            // no-log: a cancelled sleep is the loop's normal teardown (`stop()`).
            try? await Task.sleep(for: .seconds(UsageRefreshController.minimumInterval))
        }
    }

    private func codexPollLoop() async {
        while !Task.isCancelled {
            await fetchCodexOnce()
            do {
                try await Task.sleep(for: .seconds(UsageRefreshController.minimumInterval))
            } catch {
                logger.debug("Codex polling sleep cancelled \(error: error)")
            }
        }
    }

    private func fetchOnce(forceFreshCredential: Bool = false) async {
        guard runMode.isLive, limitsFetchEnabled else { return }
        await claudeFeed.refresh(forceCredentialRefresh: forceFreshCredential)
        if claudeFeed.state == .ok || (claudeFeed.failure != nil && claudeFeed.failure != .rateLimited) {
            allowsRestoredClaudeResets = false
        }
    }

    /// Folds in the usage Claude Code just handed its status line. The feed decides whether
    /// the sample belongs to the snapshot on screen; a sample it refuses changes nothing.
    func ingestStatusline(_ sample: StatuslineRateLimits) {
        guard runMode.isLive else { return }
        claudeFeed.ingest(sample)
    }

    /// Called synchronously when identity changes, before any asynchronous reload.
    func accountWillChange() {
        if let previous = claudeFeed.limits, let account = previous.account {
            claudeSnapshots[Self.refreshKey(for: account)] = previous
        }
        claudeFeed.invalidate()
        allowsRestoredClaudeResets = false
    }

    func accountDidChange(expectedAccountID: String? = nil) {
        accountWillChange()
        if let account = signedIn.usageAccount,
           (expectedAccountID == nil || account.accountUuid == expectedAccountID),
           let previous = claudeSnapshots[Self.refreshKey(for: account)] {
            claudeFeed.limits = previous
            claudeFeed.state = .stale(previous.fetchedAt)
            allowsRestoredClaudeResets = true
        }
        Task { [weak self] in
            guard let self else { return }
            await self.limitsService.accountDidChange()
            await self.fetchOnce(forceFreshCredential: true)
        }
    }

    private static func refreshKey(for account: UsageAccount) -> UsageRefreshKey {
        UsageRefreshKey(provider: .claude, accountID: account.accountUuid,
                        organizationID: account.organizationUuid)
    }

    private func fetchCodexOnce() async {
        guard runMode.isLive else { return }
        let generation = codexAccountGeneration
        logger.debug("fetchCodexOnce: starting")
        do {
            let fetched = try await codexLimitsService.fetchLimits()
            guard runMode.isLive, codexAccountGeneration == generation else { return }
            codexLimits = fetched
            codexState = .ok
            allowsRestoredCodexResets = false
            logger.debug("fetchCodexOnce: succeeded")
        } catch is CancellationError {
            logger.debug("fetchCodexOnce: cancelled")
        } catch is UsageRefreshDeferred {
            logger.debug("fetchCodexOnce: refresh already covered by shared cadence")
        } catch CodexLimitsError.notLoggedIn {
            guard runMode.isLive, codexAccountGeneration == generation else { return }
            logger.notice("fetchCodexOnce: Codex is not signed in")
            allowsRestoredCodexResets = false
            codexState = codexLimits.map { .stale($0.fetchedAt) } ?? .notLoggedIn
        } catch CodexLimitsError.executableNotFound {
            guard runMode.isLive, codexAccountGeneration == generation else { return }
            logger.notice("fetchCodexOnce: Codex executable was not found")
            allowsRestoredCodexResets = false
            codexState = codexLimits.map { .stale($0.fetchedAt) }
                ?? .error(CodexLimitsError.executableNotFound.localizedDescription)
        } catch {
            guard runMode.isLive, codexAccountGeneration == generation else { return }
            logger.error("fetchCodexOnce: failed \(error: error)")
            allowsRestoredCodexResets = false
            codexState = codexLimits.map { .stale($0.fetchedAt) }
                ?? .error("Couldn't read Codex limits")
        }
    }
}
