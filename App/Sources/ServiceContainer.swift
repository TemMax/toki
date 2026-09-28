import SwiftUI
import Foundation
import TokiAlerts
import TokiCore
import TokiAccounts
import TokiSwap
import TokiAutoSwap
import TokiFixtures
import TokiMenuBar

private let log = TokiLog.logger("app")

/// Builds and owns the full dependency graph for the app.
///
/// Constructed once (as `@State` in `TokiApp`) so the graph lives as long as
/// the app process.  All heavy services are created eagerly; the actor-based
/// services (`LimitsService`, `TranscriptIndexer`) are retained here so they
/// are never deallocated between polling cycles.
@MainActor
final class ServiceContainer {

    // MARK: Core services (retain references so actors are not deallocated)

    let credentials: CredentialStore
    let limits: LimitsService
    let codexLimits: CodexLimitsService
    let usageRefreshController: UsageRefreshController
    let pricing: LivePricingTable
    let indexer: TranscriptIndexer
    let analytics: AnalyticsService
    let environment: EnvironmentService
    let codexEnvironment: CodexEnvironmentService
    let instances: ClaudeInstanceScanner
    let slotStore: KeychainSlotStore
    let swapService: SwapService
    let codexProfileStore: KeychainCodexProfileStore
    /// Fixed for this process launch: provider surfaces never flash in while asynchronous
    /// data loads, and a CLI installed later appears after the next ordinary app launch.
    let providerAvailability: ProviderAvailability

    /// The one Sparkle updater in the process.
    ///
    /// It used to be a `@StateObject` on `TokiApp` while the snapshot harness and the debug
    /// control channel each built their own, so a debug run could have three
    /// `SPUStandardUpdaterController`s scheduling checks and writing the same `UserDefaults`
    /// keys. It lives here instead because the container is the graph's single owner and
    /// every consumer (`TokiApp`'s `.environmentObject`, the snapshot harness, the control
    /// channel's Settings surface) can reach it.
    ///
    /// `lazy` rather than `let` because constructing it *starts* Sparkle: the transient
    /// containers the snapshot/demo harness builds (two per `--snapshot` run) must not each
    /// spin one up just to exist. Whoever renders a surface that reads it asks for it, and
    /// that first ask is the only construction.
    private(set) lazy var updater = UpdaterController()

    /// Opens the dashboard window. Wired by `TokiApp` (which owns the SwiftUI
    /// `openWindow` action) so the onboarding overlay can be brought on-screen at
    /// first run even though it lives inside the dashboard window.
    var openDashboard: (() -> Void)?

    /// The single source of truth for which dashboard tab is shown. Every entry point
    /// (popover footer, ⌘,, app-menu Settings, a tapped new-account notification) sets
    /// `navigation.section`; `DashboardView` observes it.
    let navigation = DashboardNavigation()

    // MARK: View models

    let liveLimits: LiveLimits
    /// Feeds Claude Code's own status line usage into `liveLimits`, and is what Settings shows
    /// the state of. Keychain-free, so it runs from launch rather than behind the access gate.
    let statuslineUsage: StatuslineUsageDriver
    /// One source of truth for whether Claude Code itself is healthy, observed by the
    /// popover banner, the dashboard banner and the status-alert driver alike.
    let serviceStatus = ServiceStatusStore()
    /// OpenAI's Codex-specific public status feed, deliberately separate from Anthropic's.
    let codexServiceStatus = ServiceStatusStore(client: ServiceStatusClient(
        baseURL: URL(string: "https://status.openai.com")!,
        componentNames: StatusParser.openAICodexComponentNames,
        incidentTitleKeywords: ["Codex"],
        pollsSummaryDirectly: true
    ))
    let signedIn: SignedInAccount
    /// Persists the status item's indicator configuration. Owned here (not by `menuBarVM`,
    /// which only holds the live, observable value) so a later Settings screen can reach the
    /// same store `menuBarVM` was constructed with, rather than opening a second one on a
    /// different `UserDefaults` suite.
    let menuBarConfigurationStore: MenuBarConfigurationStore
    let menuBarConfiguration: MenuBarConfigurationState
    let usageDisplayConfigurationStore: UsageDisplayConfigurationStore
    let usageDisplayConfiguration: UsageDisplayConfigurationState
    let menuBarVM: MenuBarViewModel
    let dashboardVM: DashboardViewModel
    let environmentVM: EnvironmentViewModel
    let instancesVM: InstancesViewModel
    let accountsVM: AccountsViewModel
    let codexAccountsVM: CodexAccountsViewModel
    let statisticsVM: StatisticsViewModel

    /// Whether every surface shows real data or a fixture scenario. Assigning through
    /// `apply(_:)` propagates to each view model and, for a fixture, injects that
    /// scenario's data.
    private(set) var runMode: RunMode = .live

    /// Polls the auto-swap policy in the background. Started at launch rather than behind
    /// the Keychain gate: it reads the app's own slot items and no-ops until the user opts
    /// in via Settings, and gating it left the toggle inert with no feedback on any machine
    /// where access was never granted.
    private var autoSwapDriver: AutoSwapDriver?
    private var codexAutoSwapDriver: CodexAutoSwapDriver?
    /// Watches the active account's limits for the thresholds the user configured. Kept
    /// separate from `autoSwapDriver` because the two features are independent — notifications
    /// on with auto-swap off is a normal configuration.
    private var alertDriver: AlertDriver?
    private var codexAlertDriver: AlertDriver?
    /// Watches Anthropic's status page for incidents affecting Claude Code. Separate from
    /// `alertDriver` for the same reason: "the service is down" and "you are near your
    /// limit" are independent facts with independent switches.
    private var statusAlertDriver: StatusAlertDriver?
    private var codexStatusAlertDriver: StatusAlertDriver?
    private var resetNotificationDriver: ResetNotificationDriver?

    /// The window whose closing cancels a pending setup flow. The same literal `TokiApp`
    /// titles the dashboard window with; there is one window in this app that can host
    /// onboarding.
    static let dashboardWindowTitle = "Toki Dashboard"

    /// Held so the observer is registered once and torn down with the flow it guards.
    private var setupWindowCloseObserver: NSObjectProtocol?
    private var claudeReconnectAction: ClaudeReconnectAction?
    private var configWatcher: ClaudeConfigWatcher?
    private var codexAuthWatcher: CodexAuthWatcher?
    private let notifier = SwapNotifier()

    /// - Parameter prewarm: when true (the default, real app launch), all data
    ///   sources are loaded in the background at construction. The snapshot/demo
    ///   harness passes `false` so its injected mock data isn't overwritten.
    init(prewarm: Bool = true, providerAvailability: ProviderAvailability? = nil) {
        // Fixture containers should be independent of the developer machine running them.
        // Real app containers detect actual executable files before the first SwiftUI frame.
        let detectedProviders = providerAvailability ?? (prewarm ? .detected() : .all)
        self.providerAvailability = detectedProviders

        let credentials = CredentialStore()
        let claudeConfigURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude.json")
        let boundCredentials = AccountBoundCredentials(
            credentials: credentials,
            oracle: ProfileOracle(),
            signedInIdentity: {
                // no-log: ClaudeConfigEditor logs read failures; unknown identity blocks usage.
                guard let oauth = try? ClaudeConfigEditor(configURL: claudeConfigURL).readOAuthAccount() else {
                    return nil
                }
                return AccountIdentity.parse(oauthAccount: oauth)
            }
        )
        let usageRefreshController = UsageRefreshController(
            scheduleURL: UsageRefreshController.defaultScheduleURL()
        )
        let limits = LimitsService(
            credentials: boundCredentials, refreshController: usageRefreshController
        )
        let codexClient = CodexAppServerClient()
        let codexLimits = CodexLimitsService(
            client: codexClient, refreshController: usageRefreshController,
            accountID: {
                await Task.detached(priority: .utility) {
                    // no-log: no readable auth file means no signed-in Codex account, which the
                    // limits service already reports as its own state.
                    guard let data = try? CodexAuthFile.read(from: CodexAuthFile.liveURL()) else {
                        return nil
                    }
                    // no-log: an auth file without an identity is keyed like a signed-out one.
                    return try? CodexAuthBlob.identity(from: data).id
                }.value
            }
        )
        let pricing = LivePricingTable()
        let codexSessionsDirectory = detectedProviders.codex
            ? CodexAuthFile.liveURL().deletingLastPathComponent().appendingPathComponent("sessions")
            : nil
        let claudeProjectsDirectory = detectedProviders.claudeCode
            ? TranscriptIndexer.defaultProjectsDirectory()
            : nil
        let indexer = TranscriptIndexer(
            claudeProjectsDirectory: claudeProjectsDirectory,
            codexSessionsDirectory: codexSessionsDirectory
        )
        let analytics = AnalyticsService(records: indexer, pricing: pricing)
        let environment = EnvironmentService()
        let codexEnvironment = CodexEnvironmentService()
        let instances = ClaudeInstanceScanner(
            includeClaude: detectedProviders.claudeCode,
            includeCodex: detectedProviders.codex
        )

        self.credentials = credentials
        self.limits = limits
        self.codexLimits = codexLimits
        self.usageRefreshController = usageRefreshController
        self.pricing = pricing
        self.indexer = indexer
        self.analytics = analytics
        self.environment = environment
        self.codexEnvironment = codexEnvironment
        self.instances = instances

        let slotStore = KeychainSlotStore()
        let configDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude")
        let liveAccess = CredentialStoreLiveAccess(store: credentials)
        // The ownership proof for every write that pairs the live Keychain credential with
        // an identity from `~/.claude.json`. It re-reads both itself — deliberately not from
        // `signedIn`, whose cached copy lags the config watcher's debounce.
        let credentialAdoption = CredentialAdoption(
            configURL: claudeConfigURL,
            readLive: { await liveAccess.readLive()?.json },
            oracle: ProfileOracle()
        )
        // One refresher for both paths that may renew a sleeping account's token: the
        // gauge poll, which renews only inside the expiry window, and the swap's
        // freshen-before-activate step, which renews unconditionally. Sharing it keeps a
        // single persistence path for a spent grant's successor.
        let tokenRefresher = TokenRefresher(endpoint: AnthropicTokenEndpoint(), store: slotStore)
        let swapService = SwapService(dependencies: SwapDependencies(
            store: slotStore,
            live: liveAccess,
            writer: CredentialWriter(readBack: { await CredentialVerificationReader().read($0) }),
            config: ClaudeConfigEditor(configURL: claudeConfigURL),
            oracle: ProfileOracle(),
            locks: LockBroker(),
            configDir: configDir,
            fallbackFileURL: configDir.appendingPathComponent(".credentials.json"),
            onVaultInvalidated: { await credentials.invalidateVault() },
            freshen: { slot, activeLineage in
                await tokenRefresher.freshenForActivation(slot: slot, activeLineage: activeLineage)
            }
        ))
        self.slotStore = slotStore
        self.swapService = swapService

        let codexProfileStore = KeychainCodexProfileStore()
        self.codexProfileStore = codexProfileStore

        // One source of truth for the signed-in account's limits, observed by the popover,
        // the Usage tab and the Accounts tab alike, so they refresh together.
        // One source of truth for *who* is signed in, observed by the same three surfaces.
        let signedIn = SignedInAccount()
        self.signedIn = signedIn
        let liveLimits = LiveLimits(limits: limits, codex: codexLimits, signedIn: signedIn)
        self.liveLimits = liveLimits
        self.statuslineUsage = StatuslineUsageDriver(limits: liveLimits)
        let menuBarConfigurationStore = MenuBarConfigurationStore(defaults: .standard)
        self.menuBarConfigurationStore = menuBarConfigurationStore
        let menuBarConfiguration = MenuBarConfigurationState(store: menuBarConfigurationStore)
        self.menuBarConfiguration = menuBarConfiguration
        let usageDisplayConfigurationStore = UsageDisplayConfigurationStore(defaults: .standard)
        self.usageDisplayConfigurationStore = usageDisplayConfigurationStore
        let usageDisplayConfiguration = UsageDisplayConfigurationState(
            store: usageDisplayConfigurationStore
        )
        self.usageDisplayConfiguration = usageDisplayConfiguration
        var availableUsageProviders: Set<UsageProvider> = []
        if detectedProviders.claudeCode { availableUsageProviders.insert(.claudeCode) }
        if detectedProviders.codex { availableUsageProviders.insert(.codex) }
        self.menuBarVM = MenuBarViewModel(
            live: liveLimits,
            configurationState: menuBarConfiguration,
            usageDisplayState: usageDisplayConfiguration,
            availableProviders: availableUsageProviders
        )
        self.dashboardVM = DashboardViewModel(analytics: analytics, live: liveLimits, indexer: indexer, signedIn: signedIn)
        self.environmentVM = EnvironmentViewModel(
            service: detectedProviders.claudeCode ? environment : nil,
            codexService: detectedProviders.codex ? codexEnvironment : nil
        )
        self.instancesVM = InstancesViewModel(service: instances)
        self.accountsVM = AccountsViewModel(
            store: slotStore,
            swapper: swapService,
            refresher: tokenRefresher,
            usage: { token in try await OAuthUsageClient().fetchUsage(token: token) },
            live: { await liveAccess.readLive()?.json },
            adoption: credentialAdoption,
            liveLimits: liveLimits,
            signedIn: signedIn,
            refreshController: usageRefreshController
        )
        let codexAuthURL = CodexAuthFile.liveURL()
        self.codexAccountsVM = CodexAccountsViewModel(
            store: codexProfileStore,
            switcher: CodexProfileSwitcher(
                store: codexProfileStore,
                liveAuthURL: codexAuthURL
            ),
            client: codexClient,
            liveLimits: liveLimits,
            liveAuthURL: codexAuthURL,
            refreshController: usageRefreshController
        )
        // Durable daily-activity rollup behind the Usage tab's all-time statistics — survives transcript
        // cleanup, so it's its own store rather than re-deriving from the index each time.
        self.statisticsVM = StatisticsViewModel(records: indexer, store: StatsRollupStore())
        self.dashboardVM.onInitialIndexFinished = { [weak statisticsVM = self.statisticsVM] in
            statisticsVM?.indexDidCatchUp()
        }

        // Codex may seed its independent cache. Claude waits for a live, account-bound
        // response after credential access has been checked.
        self.menuBarVM.limitsFetchEnabled = false
        self.menuBarVM.primeFromCache(
            includeClaude: detectedProviders.claudeCode,
            includeCodex: detectedProviders.codex
        )

        // Pull fresh rates from the official pricing page in the background so
        // point-in-time pricing stays current without blocking launch.
        if detectedProviders.claudeCode {
            Task { await pricing.refresh() }
        }

        // Prewarm every dashboard tab in the BACKGROUND at launch so opening the
        // window (or switching to any tab) shows data immediately instead of a
        // Loading / Indexing state. Each call kicks off async work and returns
        // right away; all are idempotent, so the views' own onAppear refreshes
        // stay harmless. This is why the heavy transcript index runs now, not
        // on first popover open. Skipped by the snapshot/demo harness so it can
        // inject mock data.
        if prewarm {
            if detectedProviders.hasAnyProvider {
                let resetDriver = ResetNotificationDriver(
                    limits: self.liveLimits,
                    providers: Set(UsageProvider.allCases.filter {
                        $0 == .codex ? detectedProviders.codex : detectedProviders.claudeCode
                    })
                )
                self.resetNotificationDriver = resetDriver
                resetDriver.start()
                self.dashboardVM.triggerInitialIndex()
                self.statisticsVM.load()
                self.environmentVM.load()
                self.instancesVM.load()
            }
            if detectedProviders.codex {
                // Codex owns its own ChatGPT authentication and never touches Claude's
                // Keychain, so it can start immediately while Claude's gate is closed.
                self.menuBarVM.startCodex()
                self.codexAccountsVM.load()
                self.startCodexAutoSwapDriver()
                self.startCodexAlertDriver()
                self.codexServiceStatus.start()
                self.startCodexStatusAlertDriver()
                self.startCodexAuthWatcher()
            }

            // Defer live limits until Keychain access is confirmed so the analytics
            // (local, keychain-free) still load while the prompt stays gated.
            self.dashboardVM.limitsFetchEnabled = false

            if detectedProviders.claudeCode {
                self.startAutoSwapDriver()

                self.statuslineUsage.start()

                // Anthropic's status page is public and never touches the Keychain.
                self.serviceStatus.start()
                self.startStatusAlertDriver()

                NotificationCenter.default.addObserver(
                    forName: .tokiPresentKeychainSetup,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.presentOnboarding(initialState: .intro) }
                }

                self.claudeReconnectAction = ClaudeReconnectAction(
                    credentials: credentials,
                    currentModel: { [weak self] in self?.dashboardVM.onboarding },
                    present: { [weak self] model in self?.presentOnboarding(model: model) },
                    onCompleted: { [weak self] model in
                        self?.completeOnboarding(model: model)
                    }
                )
                NotificationCenter.default.addObserver(
                    forName: .tokiReconnectClaude,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.claudeReconnectAction?.perform() }
                }

                // No Claude executable means no Claude onboarding: a Codex-only install must
                // open directly into its available surfaces.
                Task { [weak self] in
                    guard let self else { return }
                    let forced = ProcessInfo.processInfo.environment["TOKI_FORCE_ONBOARDING"] == "1"
                    let state = forced ? .needsAuthorization : await self.credentials.accessState()
                    let authenticated = state == .available
                    log.info("launch: keychain access state resolved (authenticated=\(authenticated))")
                    if authenticated {
                        self.beginAuthenticatedWork()
                    } else {
                        self.liveLimits.state = state == .notFound ? .notLoggedIn : .needsAccess
                        if forced {
                            self.presentOnboarding(initialState: OnboardingState(accessState: state))
                        }
                    }
                }
            }
        }

        #if DEBUG
        // Hands the graph to the DEBUG-only control channel (weak reference). This is the
        // smallest hand-over available: `TokiApp` owns the container as `@State` and
        // `AppDelegate`, which starts the channel, cannot reach it.
        DebugControlChannel.register(self)
        #endif
    }

    /// Switches every surface to `mode` in one call — the one owner of the demo/fixture flag
    /// (see `RunMode`), replacing what used to be six independent per-view-model booleans set
    /// one-by-one by callers.
    ///
    /// Sets `runMode` on every view model FIRST, so their I/O guards (`guard runMode.isLive`)
    /// engage before any fixture data is injected below — otherwise a load already in flight,
    /// or one triggered by a view's `onAppear` right after, could overwrite the mock data with
    /// a real one.
    @MainActor
    func apply(_ mode: RunMode) {
        liveLimits.runMode = mode
        serviceStatus.runMode = mode
        codexServiceStatus.runMode = mode
        menuBarVM.runMode = mode
        dashboardVM.runMode = mode
        statisticsVM.runMode = mode
        environmentVM.runMode = mode
        instancesVM.runMode = mode
        accountsVM.runMode = mode
        codexAccountsVM.runMode = mode
        signedIn.runMode = mode
        runMode = mode

        guard case let .fixture(scenario) = mode else {
            reloadFromLiveSources()
            return
        }

        let now = Date()
        let bundle = Fixtures.bundle(for: scenario, now: now)

        liveLimits.limits = bundle.limits
        liveLimits.state = Self.liveLimitsState(from: bundle.limitsState, now: now)
        switch scenario {
        case .fresh:
            liveLimits.codexLimits = nil
            liveLimits.codexState = .loading
        default:
            liveLimits.codexLimits = Self.fixtureCodexLimits(now: now, scenario: scenario)
            liveLimits.codexState = .ok
        }
        serviceStatus.status = bundle.serviceStatus
        codexServiceStatus.status = bundle.serviceStatus
        dashboardVM.summary = bundle.summary
        statisticsVM.history = bundle.stats
        signedIn.identity = bundle.identity
        accountsVM.accounts = bundle.accounts
        accountsVM.quarantined = bundle.quarantine
        codexAccountsVM.accounts = Self.fixtureCodexAccounts(scenario: scenario, now: now)
        codexAccountsVM.signedInLabel = codexAccountsVM.accounts
            .first(where: \.isActive)?.label
        instancesVM.snapshot = bundle.instances
        environmentVM.environment = bundle.environment
        environmentVM.codexEnvironment = bundle.environment
    }

    /// Re-reads every surface's real source after a switch back to `.live`.
    ///
    /// Fixture data is *injected* into the view models below and nothing ever removes it, so
    /// flipping `runMode` back to `.live` only re-enables I/O — it does not undo the
    /// injection. Without this, a `scenario multi-account` → `scenario live` sequence leaves
    /// the invented accounts, identity, instances and environment on screen while every
    /// surface claims to be showing real data, and only the Accounts tab would ever correct
    /// itself (on its next `onAppear`).
    ///
    /// These are exactly the entry points the app already uses at launch — `init`'s prewarm
    /// block and `beginAuthenticatedWork()` — not new loading paths. `liveLimits` is the one
    /// owner of the rate-limit gauges (popover, Usage tab, Accounts card all observe it) and
    /// `dashboardVM.load()` refreshes the shared `signedIn` store on the way through, so
    /// neither needs a second caller here.
    private func reloadFromLiveSources() {
        if providerAvailability.hasAnyProvider {
            dashboardVM.load()
            statisticsVM.load()
            environmentVM.load()
            instancesVM.load()
        }
        if providerAvailability.claudeCode {
            liveLimits.refreshNow()
            // Not `refreshNow()`: the injected fixture value has to go, and with it the
            // client's conditional-GET state.
            serviceStatus.resetToLive()
            accountsVM.load()
        }
        if providerAvailability.codex {
            liveLimits.refreshCodexNow()
            codexAccountsVM.load()
            codexServiceStatus.resetToLive()
        }
    }

    /// `FixtureLimitsState` and `LiveLimits.State` are deliberately different types —
    /// `TokiFixtures` cannot import the app target, so it can't reference `LiveLimits.State`
    /// directly. This is the one place that bridges them.
    private static func liveLimitsState(from state: FixtureLimitsState, now: Date) -> LiveLimits.State {
        switch state {
        case .loading: return .loading
        case .ok: return .ok
        case let .stale(secondsAgo): return .stale(now.addingTimeInterval(-secondsAgo))
        case .notLoggedIn: return .notLoggedIn
        case .needsAccess: return .needsAccess
        case let .error(message): return .error(message)
        }
    }

    private static func fixtureCodexLimits(now: Date, scenario: Scenario) -> UsageLimits {
        var windows = [
            RateLimitWindow(
                id: "codex:codex:primary",
                title: "7-day",
                utilization: 0.24,
                resetsAt: now.addingTimeInterval(4 * 86_400),
                isAvailable: true
            ),
        ]
        if scenario != .publicReadme {
            windows.append(RateLimitWindow(
                id: "codex:codex_bengalfox:primary",
                title: "5-hour · GPT-5.3 Codex Spark",
                utilization: 0.08,
                resetsAt: now.addingTimeInterval(4 * 3_600),
                isAvailable: true
            ))
        }
        return UsageLimits(
            windows: windows,
            extra: nil,
            fetchedAt: now,
            account: UsageAccount(accountUuid: "fixture-codex", organizationUuid: nil),
            bankedResets: BankedResets(availableCount: 2, credits: [
                BankedResetCredit(id: "fixture-reset-1", grantedAt: now.addingTimeInterval(-3600),
                                  expiresAt: now.addingTimeInterval(3 * 86400), status: "available", resetType: "codexRateLimits"),
                BankedResetCredit(id: "fixture-reset-2", grantedAt: now.addingTimeInterval(-1800),
                                  expiresAt: now.addingTimeInterval(30 * 86400), status: "available", resetType: "codexRateLimits")
            ])
        )
    }

    private static func fixtureCodexAccounts(
        scenario: Scenario,
        now: Date
    ) -> [CodexAccountPresentation] {
        guard scenario != .fresh else { return [] }
        var accounts = [
            CodexAccountPresentation(
                id: "fixture-codex-personal",
                label: "codex@example.com",
                email: "codex@example.com",
                planType: "pro",
                isActive: true,
                isStored: true,
                lastActiveAt: now
            ),
        ]
        if scenario == .multiAccount {
            accounts.append(CodexAccountPresentation(
                id: "fixture-codex-work",
                label: "Work Codex",
                email: "codex@work.example",
                planType: "business",
                isActive: false,
                isStored: true,
                lastActiveAt: now.addingTimeInterval(-86_400)
            ))
        }
        return accounts
    }

    /// Shows the Keychain-onboarding overlay inside the dashboard window (opening the
    /// window if needed). On completion it cross-fades the overlay out and begins the
    /// Keychain-dependent work.
    private func presentOnboarding(initialState: OnboardingState) {
        guard providerAvailability.claudeCode else { return }
        let vm = OnboardingViewModel(credentials: credentials, initialState: initialState)
        vm.onCompleted = { [weak self, weak vm] in
            guard let vm else { return }
            self?.completeOnboarding(model: vm)
        }
        presentOnboarding(model: vm)
    }

    /// Installs an already-created onboarding model. Explicit reconnect uses this overload
    /// so duplicate clicks can retain the exact model whose authorization is pending.
    private func presentOnboarding(model: OnboardingViewModel) {
        guard providerAvailability.claudeCode else { return }
        dashboardVM.onboarding = model
        openDashboard?()
        observeSetupWindowClose()
    }

    /// Shared completion path for Continue-driven setup and immediate popover reconnect.
    private func completeOnboarding(model: OnboardingViewModel) {
        // Closing the dashboard abandons optional setup. A protected read already inside
        // Security.framework may still finish, but its late result must not restart work.
        guard dashboardVM.onboarding === model else { return }
        withAnimation(.easeInOut(duration: 0.45)) {
            dashboardVM.onboarding = nil
        }
        beginAuthenticatedWork()
        liveLimits.credentialAccessDidRecover()
    }

    /// Closing optional setup abandons it without affecting provider access.
    private func observeSetupWindowClose() {
        guard setupWindowCloseObserver == nil else { return }
        setupWindowCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard (note.object as? NSWindow)?.title == Self.dashboardWindowTitle else { return }
            MainActor.assumeIsolated { self?.cancelPendingOnboarding() }
        }
    }

    /// Drops a setup flow the user walked away from, so every other surface works again.
    /// Does nothing once access has been granted, because the flow clears itself then.
    private func cancelPendingOnboarding() {
        guard dashboardVM.onboarding != nil else { return }
        dashboardVM.onboarding = nil
        if let observer = setupWindowCloseObserver {
            NotificationCenter.default.removeObserver(observer)
            setupWindowCloseObserver = nil
        }
    }

    /// Enables and kicks the Keychain-dependent data paths. Called once access is
    /// available at launch, or after the user grants it via onboarding/Settings.
    private func beginAuthenticatedWork() {
        guard providerAvailability.claudeCode else { return }
        dashboardVM.limitsFetchEnabled = true
        menuBarVM.limitsFetchEnabled = true
        menuBarVM.start()   // background limits polling
        dashboardVM.load()  // refresh usage + live limits now that we may read them
        // Accumulates rollup history on every launch, whether or not the Statistics
        // tab is ever opened — it's the only place this data survives transcript cleanup.
        statisticsVM.load()
        startConfigWatcher()
        startAlertDriver()
    }

    /// Arms the threshold-alert driver once limits are actually being fetched. Deliberately
    /// NOT in the prewarm block: before this point the only limits in hand come from
    /// `primeFromCache()`, which can be hours old, and notifying on those would announce a
    /// threshold the account may have long since reset past.
    private func startAlertDriver() {
        guard providerAvailability.claudeCode, alertDriver == nil else { return }
        let driver = AlertDriver(
            limits: liveLimits,
            signedIn: signedIn,
            store: NotificationSettingsStore(defaults: .standard)
        )
        alertDriver = driver
        driver.start()
    }

    /// Codex limits arrive independently of Claude's Keychain-gated feed, so its threshold
    /// observer is armed as soon as the installed Codex provider starts polling.
    private func startCodexAlertDriver() {
        guard providerAvailability.codex, codexAlertDriver == nil else { return }
        let accounts = codexAccountsVM
        let driver = AlertDriver(
            limits: liveLimits,
            signedIn: signedIn,
            provider: .codex,
            codexAccountID: { accounts.activeAccountID },
            store: NotificationSettingsStore(defaults: .standard),
            latch: ThresholdAlertLatchStore(
                defaults: UserDefaults(suiteName: "toki.codex.alertLatch") ?? .standard
            )
        )
        codexAlertDriver = driver
        driver.start()
    }

    /// Arms the status-alert driver. Unlike `startAlertDriver()` this belongs in the prewarm
    /// block: the status page is public, so there is no gate to wait for, and the driver's
    /// own latch (persisted across launches) is what keeps a relaunch mid-incident quiet.
    private func startStatusAlertDriver() {
        guard providerAvailability.claudeCode, statusAlertDriver == nil else { return }
        let driver = StatusAlertDriver(
            store: serviceStatus,
            settings: NotificationSettingsStore(defaults: .standard)
        )
        statusAlertDriver = driver
        driver.start()
    }

    private func startCodexStatusAlertDriver() {
        guard providerAvailability.codex, codexStatusAlertDriver == nil else { return }
        let driver = StatusAlertDriver(
            store: codexServiceStatus,
            settings: NotificationSettingsStore(defaults: .standard),
            provider: .codex,
            latch: StatusAlertLatchStore(
                defaults: UserDefaults(suiteName: "toki.codex.statusAlertLatch") ?? .standard
            )
        )
        codexStatusAlertDriver = driver
        driver.start()
    }

    /// Watches `~/.claude.json` so an account change made in Claude Code shows up in Toki
    /// instantly — the gauges follow the switch without waiting for a poll, and a brand-new
    /// account offers to be saved. Reads only the config file; never touches the Keychain.
    private func startConfigWatcher() {
        configWatcher?.stop()
        let slotStore = self.slotStore
        let watcher = ClaudeConfigWatcher(
            storedUuids: {
                do {
                    return Set(try slotStore.loadAll().map(\.identity.accountUuid))
                } catch {
                    log.error("startConfigWatcher: failed to load stored slots for dedupe: \(error: error)")
                    return []
                }
            },
            onChange: { [weak self] change in
                self?.handleAccountChange(change)
            }
        )
        configWatcher = watcher
        watcher.start()
        // Seed the shared signed-in-account store now, before any surface reads it, so the
        // first render already knows who is signed in rather than briefly showing nobody.
        Task { await signedIn.refresh() }
    }

    private func handleAccountChange(_ change: AccountChange) {
        switch change {
        case .ignore:
            return
        case .reloadOnly:
            // The account changed: refresh the two shared stores — who is signed in and their
            // limits — which updates the popover, Usage tab and Accounts tab together, then
            // re-poll the sleeping accounts' gauges.
            liveLimits.accountWillChange()
            Task {
                await signedIn.refresh()
                liveLimits.accountDidChange()
                await accountsVM.refreshGauges()
            }
        case let .offerSave(uuid):
            log.info("handleAccountChange: config now names \(account: uuid), not yet stored; offering to save")
            liveLimits.accountWillChange()
            Task { await accountsVM.refreshGauges() }
            Task { [signedIn, notifier, liveLimits] in
                await signedIn.refresh()
                liveLimits.accountDidChange()
                guard NotificationSettingsStore(defaults: .standard).load().onNewAccount else {
                    log.notice("handleAccountChange: new-account notification suppressed by settings")
                    return
                }
                guard await notifier.requestAuthorization() else {
                    log.notice("handleAccountChange: new-account notification suppressed; authorization was not granted")
                    return
                }
                log.info("handleAccountChange: posting a new-account notification")
                notifier.notifyNewAccount(label: signedIn.label ?? uuid)
            }
        }
    }

    private func startCodexAuthWatcher() {
        codexAuthWatcher?.stop()
        let store = codexProfileStore
        let watcher = CodexAuthWatcher(
            storedIDs: {
                do { return Set(try store.loadAll().map(\.id)) }
                catch {
                    log.error("Codex auth watcher could not load stored profile ids: \(error: error)")
                    return []
                }
            },
            onChange: { [weak self] change in self?.handleCodexAccountChange(change) }
        )
        codexAuthWatcher = watcher
        watcher.start()
    }

    private func handleCodexAccountChange(_ change: AccountChange) {
        guard change != .ignore else { return }
        codexAccountsVM.load()
        liveLimits.codexAccountDidChange()
        guard case .offerSave = change else { return }
        Task { [codexAccountsVM, notifier] in
            await codexAccountsVM.reload()
            guard NotificationSettingsStore(defaults: .standard).load().onNewAccount else { return }
            guard await notifier.requestAuthorization() else { return }
            notifier.notifyNewAccount(
                label: codexAccountsVM.signedInLabel ?? "Codex account",
                provider: .codex
            )
        }
    }

    /// Auto-swap is off by default; the driver reads the user's choice from the same
    /// `@AppStorage` key Settings writes on every poll, so toggling it in Settings takes
    /// effect without any extra wiring (and immediately, via `.tokiAutoSwapEnabled`).
    ///
    /// Any previous driver is stopped before being dropped — a cancelled task is the only
    /// thing that ends its 3-minute poll loop, and an orphaned loop keeps a strong reference
    /// to the whole view-model graph.
    private func startAutoSwapDriver() {
        guard providerAvailability.claudeCode else { return }
        autoSwapDriver?.stop()
        let driver = AutoSwapDriver(
            accounts: accountsVM,
            notifier: SwapNotifier(),
            settings: { Self.loadAutoSwapSettings() }
        )
        autoSwapDriver = driver
        driver.start()
    }

    private func startCodexAutoSwapDriver() {
        guard providerAvailability.codex else { return }
        codexAutoSwapDriver?.stop()
        let driver = CodexAutoSwapDriver(
            accounts: codexAccountsVM,
            notifier: SwapNotifier(),
            settings: { Self.loadAutoSwapSettings(key: "toki.codexAutoSwapSettings") }
        )
        codexAutoSwapDriver = driver
        driver.start()
    }

    /// Decodes the JSON-encoded `AutoSwapSettings` Settings stores under
    /// `toki.autoSwapSettings`, defaulting to `AutoSwapSettings.default` when absent
    /// or corrupt.
    private static func loadAutoSwapSettings() -> AutoSwapSettings {
        loadAutoSwapSettings(key: "toki.autoSwapSettings")
    }

    private static func loadAutoSwapSettings(key: String) -> AutoSwapSettings {
        guard
            let json = UserDefaults.standard.string(forKey: key), !json.isEmpty,
            let data = json.data(using: .utf8)
        else { return .default }
        do {
            return try JSONDecoder().decode(AutoSwapSettings.self, from: data)
        } catch {
            log.error("loadAutoSwapSettings: stored settings failed to decode; using defaults: \(error: error)")
            return .default
        }
    }
}

extension Notification.Name {
    /// Posted by Settings' "Set up Keychain access…" button to reopen onboarding.
    static let tokiPresentKeychainSetup = Notification.Name("tokiPresentKeychainSetup")

    /// Posted only by the popover's explicit reconnect buttons. Unlike passive setup entry
    /// points, this route may immediately perform the user-initiated protected read.
    static let tokiReconnectClaude = Notification.Name("tokiReconnectClaude")

    /// Posted by Settings when auto-swap is switched on, so the driver evaluates now
    /// instead of at the end of its current 3-minute sleep.
    static let tokiAutoSwapEnabled = Notification.Name("tokiAutoSwapEnabled")

    /// Posted to open the dashboard window on a specific tab, named by a String in
    /// `userInfo["section"]` (see `DashboardSection(identifier:)`). A cross-process bridge
    /// for callers without a container — e.g. `AppDelegate` on a tapped new-account
    /// notification. `MenuBarLabelHost` reads the section, opens the window, and activates.
    static let tokiOpenDashboard = Notification.Name("tokiOpenDashboard")
}
