import Foundation
import Observation
import TokiAccounts
import TokiAutoSwap
import TokiCore
import TokiFixtures

private let log = TokiLog.logger("codex-accounts")

/// Owns Codex profiles independently from Claude's `AccountsViewModel`.
///
/// A profile appears only after the user explicitly saves the currently signed-in Codex
/// account. The live file stays Codex's source of truth; stored copies live in Toki's
/// Keychain and are used only for an explicit switch.
@Observable
@MainActor
final class CodexAccountsViewModel {
    /// Two live poll intervals; .ok can remain set while the machine sleeps.
    private static let maximumActiveGaugeAge: TimeInterval = 180
    var accounts: [CodexAccountPresentation] = []
    var signedInLabel: String?
    var errorMessage: String?
    var swapInFlight: String?
    var runMode: RunMode = .live
    var activeAccountLimits: UsageLimits? { liveLimits.codexLimits }
    var activeAccountLimitsState: LiveLimits.State { liveLimits.codexState }
    var activeLimits: UsageLimits? { activeAccountLimits }
    var activeAccountID: String? { accounts.first(where: \.isActive)?.id }

    private let store: any CodexProfileStoring
    private let switcher: CodexProfileSwitcher
    private let client: CodexAppServerClient
    private let liveLimits: LiveLimits
    private let liveAuthURL: URL
    private let refreshController: UsageRefreshController
    /// Opening Accounts, the three-minute upkeep loop and a manual refresh can coincide.
    /// Every caller joins the same pass so one saved profile never launches duplicate App
    /// Servers or races two refreshed auth snapshots back into the Keychain.
    private var gaugeRefresh = SingleFlightSlot<Task<Void, Never>>()

    init(
        store: any CodexProfileStoring,
        switcher: CodexProfileSwitcher,
        client: CodexAppServerClient,
        liveLimits: LiveLimits,
        liveAuthURL: URL = CodexAuthFile.liveURL(),
        refreshController: UsageRefreshController
    ) {
        self.store = store
        self.switcher = switcher
        self.client = client
        self.liveLimits = liveLimits
        self.liveAuthURL = liveAuthURL
        self.refreshController = refreshController
    }

    func load() {
        guard runMode.isLive else { return }
        Task { await reload() }
    }

    func reload() async {
        guard runMode.isLive else { return }

        let info = await accountInfoIfAvailable()
        let profiles: [CodexAccountProfile]
        do {
            profiles = try await profilesOffMain()
        } catch {
            log.error("Codex profiles could not be loaded: \(error: error)")
            errorMessage = "Couldn't load saved Codex accounts."
            return
        }

        let liveData = await liveAuthIfAvailable()
        let liveIdentity: CodexAccountIdentity?
        if let liveData {
            do {
                liveIdentity = try CodexAuthBlob.identity(
                    from: liveData,
                    accountEmail: info?.email,
                    planType: info?.planType
                )
            } catch {
                log.error("The live Codex credential could not be identified: \(error: error)")
                liveIdentity = nil
            }
        } else {
            liveIdentity = nil
        }
        let activeID = liveIdentity?.id
        var rows = profiles.map { CodexAccountPresentation.make(profile: $0, activeID: activeID) }

        if let liveIdentity, !profiles.contains(where: { $0.id == liveIdentity.id }) {
            rows.insert(.makeLiveUnstored(identity: liveIdentity), at: 0)
        } else if liveIdentity == nil, let info {
            // Keyring-backed Codex can still identify itself through App Server even though
            // Toki cannot snapshot or switch that credential as an auth.json profile.
            let fallback = CodexAccountIdentity(
                id: "live-\(info.email ?? info.type)",
                email: info.email,
                planType: info.planType,
                isAPIKey: info.type == "apiKey"
            )
            rows.insert(.makeLiveUnstored(identity: fallback), at: 0)
        }

        accounts = rows
        signedInLabel = rows.first(where: \.isActive)?.label ?? info?.email
        errorMessage = nil
    }

    func addCurrentAccount() async {
        guard runMode.isLive else { return }
        errorMessage = nil
        do {
            let info = await accountInfoIfAvailable()
            let data = try await liveAuthOffMain()
            let identity = try CodexAuthBlob.identity(
                from: data,
                accountEmail: info?.email,
                planType: info?.planType
            )
            let existing = try await profileOffMain(id: identity.id)
            let profile = CodexAccountProfile(
                identity: identity,
                alias: existing?.alias,
                authJSON: data,
                addedAt: existing?.addedAt ?? Date(),
                lastActiveAt: Date(),
                fiveHourUtilization: existing?.fiveHourUtilization,
                weeklyUtilization: existing?.weeklyUtilization,
                gaugesFetchedAt: existing?.gaugesFetchedAt,
                gaugesAreStale: existing?.gaugesAreStale
            )
            try await saveOffMain(profile)
            await reload()
        } catch {
            log.error("Saving the current Codex profile failed: \(error: error)")
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func swap(to id: String) async -> Bool {
        guard runMode.isLive else { return false }
        guard swapInFlight == nil else {
            errorMessage = "Another Codex account switch is already running."
            return false
        }
        errorMessage = nil
        swapInFlight = id
        defer { swapInFlight = nil }

        do {
            let switcher = self.switcher
            try await Task.detached(priority: .userInitiated) {
                try switcher.swap(to: id)
            }.value
            await reload()
            liveLimits.codexAccountDidChange()
            return true
        } catch {
            log.error("Codex profile switch failed: \(error: error)")
            let message = error.localizedDescription
            await reload()
            errorMessage = message
            return false
        }
    }

    func remove(id: String) async {
        guard !accounts.contains(where: { $0.id == id && $0.isActive }) else {
            errorMessage = CodexAccountError.cannotRemoveActiveProfile.localizedDescription
            return
        }
        do {
            try await deleteOffMain(id: id)
            await reload()
        } catch {
            log.error("Removing a Codex profile failed: \(error: error)")
            errorMessage = error.localizedDescription
        }
    }

    func rename(id: String, alias: String?) async {
        do {
            guard var profile = try await profileOffMain(id: id) else { return }
            profile.alias = alias
            try await saveOffMain(profile)
            await reload()
        } catch {
            log.error("Renaming a Codex profile failed: \(error: error)")
            errorMessage = error.localizedDescription
        }
    }

    /// Refreshes every saved account without replacing the user's live auth.json. Inactive
    /// profiles run App Server against a private, short-lived CODEX_HOME; an auth refresh
    /// performed there is written back to that profile's Keychain item.
    func refreshGauges() async {
        let claim = gaugeRefresh.beginOrJoin {
            Task { [weak self] in await self?.performGaugeRefresh() }
        }
        await claim.run.value
        if claim.isOwner { gaugeRefresh.end(claim.run) }
    }

    private func performGaugeRefresh() async {
        guard runMode.isLive else { return }
        await reload()

        let profiles: [CodexAccountProfile]
        do {
            profiles = try await profilesOffMain()
        } catch {
            log.error("Loading Codex profiles for gauge refresh failed: \(error: error)")
            return
        }

        for var profile in profiles {
            do {
                let limits: UsageLimits
                // Account identity and its live payload must be read in the same actor
                // turn: profile loading and earlier polls can suspend across a switch.
                if profile.id == activeAccountID {
                    // Only the shared live poll can attest to active-account freshness.
                    // Retained limits after a failure are display history, and polling an
                    // isolated copy would not establish that the live session recovered.
                    guard activeAccountLimitsState == .ok, let live = activeAccountLimits,
                          Date().timeIntervalSince(live.fetchedAt) <= Self.maximumActiveGaugeAge else {
                        profile.gaugesAreStale = true
                        try await saveOffMain(profile)
                        continue
                    }
                    limits = live
                } else {
                    guard let permit = await refreshController.begin(
                        UsageRefreshKey(provider: .codex, accountID: profile.id)
                    ) else { continue }
                    let result: IsolatedUsageResult
                    do {
                        result = try await isolatedUsage(for: profile)
                        await refreshController.finish(permit, outcome: .response(result.limits))
                    } catch {
                        // Surfaced on the account's card by the caller; logged here as the provider call.
                        log.debug("saved Codex account usage request failed \(error: error)")
                        await refreshController.finish(permit, outcome: .error(error))
                        throw error
                    }
                    limits = result.limits
                    if CodexAuthBlob.identityMatches(profile.authJSON, result.authJSON) {
                        profile.authJSON = result.authJSON
                    }
                }
                profile.fiveHourUtilization = limits.fiveHour?.utilization
                profile.weeklyUtilization = limits.sevenDay?.utilization
                profile.gaugesFetchedAt = limits.fetchedAt
                profile.gaugesAreStale = false
                try await saveOffMain(profile)
            } catch {
                log.notice("Codex profile gauge refresh failed: \(error: error)")
                profile.gaugesAreStale = true
                try? await saveOffMain(profile)
            }
        }
        await reload()
    }

    func snapshotsForPolicy(now: Date = Date()) -> [AccountSnapshot] {
        let live = activeAccountLimits
        let liveIsFresh = activeAccountLimitsState == .ok
        return accounts.filter(\.isStored).map { account in
            let isLive = account.isActive
            let fetchedAt = isLive ? live?.fetchedAt : account.gaugesFetchedAt
            let maximumAge = isLive ? Self.maximumActiveGaugeAge : 15 * 60
            let tooOld = fetchedAt.map { now.timeIntervalSince($0) > maximumAge } ?? true
            return AccountSnapshot(
                accountUuid: account.id,
                label: account.label,
                fiveHour: isLive ? live?.fiveHour?.utilization : account.fiveHour,
                weekly: isLive ? live?.sevenDay?.utilization : account.weekly,
                isActive: account.isActive,
                isHealthy: true,
                // A new live success supersedes the stored profile's old failure flag;
                // conversely, recent bytes alone cannot override a current live failure.
                gaugesAreStale: (isLive ? !liveIsFresh : account.gaugesAreStale) || tooOld
            )
        }
    }

    private struct IsolatedUsageResult: Sendable {
        let limits: UsageLimits
        let authJSON: Data
    }

    private func isolatedUsage(for profile: CodexAccountProfile) async throws -> IsolatedUsageResult {
        let client = self.client
        return try await Task.detached(priority: .utility) {
            let manager = FileManager.default
            let directory = manager.temporaryDirectory
                .appendingPathComponent("toki-codex-profile-\(UUID().uuidString)", isDirectory: true)
            try manager.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            defer {
                do {
                    try manager.removeItem(at: directory)
                } catch {
                    log.error("failed to remove isolated Codex profile directory \(error: error)")
                }
            }

            let authURL = directory.appendingPathComponent("auth.json")
            try CodexAuthFile.writeAtomically(profile.authJSON, to: authURL)
            let limits = try await client.fetchUsage(codexHome: directory)
            let refreshed: Data
            do {
                refreshed = try CodexAuthFile.read(from: authURL)
            } catch {
                // The usage response is still valid, but retain the original credential
                // snapshot when App Server did not leave a readable refreshed auth file.
                log.debug("isolated Codex auth refresh was unreadable; keeping stored auth \(error: error)")
                refreshed = profile.authJSON
            }
            return IsolatedUsageResult(limits: limits, authJSON: refreshed)
        }.value
    }

    private func profilesOffMain() async throws -> [CodexAccountProfile] {
        let store = self.store
        return try await Task.detached(priority: .userInitiated) { try store.loadAll() }.value
    }

    private func profileOffMain(id: String) async throws -> CodexAccountProfile? {
        let store = self.store
        return try await Task.detached(priority: .userInitiated) { try store.load(id: id) }.value
    }

    private func saveOffMain(_ profile: CodexAccountProfile) async throws {
        let store = self.store
        try await Task.detached(priority: .userInitiated) { try store.save(profile) }.value
    }

    private func deleteOffMain(id: String) async throws {
        let store = self.store
        try await Task.detached(priority: .userInitiated) { try store.delete(id: id) }.value
    }

    private func liveAuthOffMain() async throws -> Data {
        let url = liveAuthURL
        return try await Task.detached(priority: .userInitiated) {
            try CodexAuthFile.read(from: url)
        }.value
    }

    private func accountInfoIfAvailable() async -> CodexAccountInfo? {
        do {
            return try await client.fetchAccountInfo()
        } catch {
            // The App Server client already records the transport error. This contextual
            // line explains why the profile UI is falling back to auth.json claims.
            log.debug("Codex account metadata is unavailable: \(error: error)")
            return nil
        }
    }

    private func liveAuthIfAvailable() async -> Data? {
        do {
            return try await liveAuthOffMain()
        } catch {
            // Missing auth.json is expected for keyring-backed Codex installations.
            log.debug("Codex auth.json is unavailable: \(error: error)")
            return nil
        }
    }
}
