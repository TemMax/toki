import AppKit
import Foundation
import SwiftUI
import TokiCore
import TokiAccounts
import TokiSwap
import TokiFixtures

@main
struct TokiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    /// Runs `TokiLog.bootstrap()` exactly once, the first time it is read.
    ///
    /// Referenced from the `container` default expression below, because Swift evaluates a
    /// stored property's default BEFORE the `init` body — a `bootstrap()` call in `init()`
    /// would land after `ServiceContainer` had already been built, and any log line that
    /// container emitted while constructing would be dropped by a logger that did not yet
    /// have sinks. Reading this static from the default expression is what makes the
    /// ordering real rather than merely intended.
    ///
    /// A `static let` is lazy and Swift guarantees its initialiser runs at most once per
    /// process, however many places read it — so both read sites below are safe, and
    /// `bootstrap` still has exactly one call site. (Were it somehow reached twice it would
    /// be a no-op that records a fault, never a crash.)
    private static let loggingReady: Void = {
        TokiLog.bootstrap()
        TokiLog.logger("app").info(
            "Toki launched  version=\(appVersion, privacy: .public) build=\(buildNumber, privacy: .public)")
    }()

    @State private var container: ServiceContainer = {
        _ = TokiApp.loggingReady
        #if DEBUG
        if let name = ProcessInfo.processInfo.environment["TOKI_DEBUG_FIXTURE_SCENARIO"],
           let scenario = Scenario(rawValue: name) {
            let container = ServiceContainer(prewarm: false)
            container.apply(.fixture(scenario))
            return container
        }
        #endif
        return ServiceContainer()
    }()

    init() {
        // Also covers a harness that constructs the App without ever reading `container`.
        _ = Self.loggingReady

        SnapshotRunner.runIfRequested()
    }

    /// Read from the generated Info.plist. A missing key is only reachable in a harness
    /// build, and "unknown" is more useful in a log line than an empty string.
    private static let appVersion =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"

    private static let buildNumber =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"

    var body: some Scene {
        // MenuBarExtra provides the status-bar item + panel.
        MenuBarExtra {
            MenuBarPanelView(
                menuBar: container.menuBarVM,
                dashboard: container.dashboardVM,
                accounts: container.accountsVM,
                codexAccounts: container.codexAccountsVM,
                navigation: container.navigation,
                serviceStatus: container.serviceStatus,
                codexServiceStatus: container.codexServiceStatus,
                providerAvailability: container.providerAvailability
            )
            .frame(width: 320)
        } label: {
            MenuBarLabelHost(container: container)
        }
        .menuBarExtraStyle(.window)

        // Full dashboard window — Usage / Speed / Machine / Accounts / Settings tabs.
        // Settings is a tab here now; there is no standalone Settings window.
        Window("Toki Dashboard", id: "dashboard") {
            DashboardView(
                model: container.dashboardVM,
                instances: container.instancesVM,
                environment: container.environmentVM,
                menuBar: container.menuBarVM,
                serviceStatus: container.serviceStatus,
                codexServiceStatus: container.codexServiceStatus,
                providerAvailability: container.providerAvailability,
                accounts: container.accountsVM,
                codexAccounts: container.codexAccountsVM,
                statistics: container.statisticsVM,
                speed: container.speedVM,
                addQuarantineEntry: { await addQuarantineEntry($0, container: container) },
                deleteQuarantineEntry: { await deleteQuarantineEntry($0, container: container) },
                navigation: container.navigation
            )
            // Supplies the Settings tab's controls (Check for Updates, auto-update toggles).
            // The container owns the single updater (see `ServiceContainer.updater`); this
            // scene only publishes it into the environment.
            .environmentObject(container.updater)
            // Settings shows whether Claude Code's status line is feeding live usage.
        }
        .defaultSize(width: 860, height: 540)
        // Hide the title bar so the window is one continuous glass surface; the
        // traffic-light buttons float over the glass and our own top bar is the header.
        .windowStyle(.hiddenTitleBar)
        .commands {
            TokiCommands(updater: container.updater, navigation: container.navigation)
        }
    }
}

// MARK: - Main-menu commands

/// Populates the standard app menu (shown at the top of the screen whenever a
/// Toki window is open) with the two items macOS apps are expected to carry:
///
///  - **Check for Updates…** right below "About Toki", mirroring the Settings ▸
///    About button so users find it in the familiar place too.
///  - **Settings… ⌘,** — Settings is a tab in the dashboard window, not a stock
///    `Settings` scene, so SwiftUI never installs the default Settings item or its
///    ⌘, shortcut. We restore both here: open the dashboard window on the Settings
///    tab and activate (switch to `.regular` so an `.accessory` app comes forward).
private struct TokiCommands: Commands {
    @ObservedObject var updater: UpdaterController
    /// Shared tab selection — the ⌘, item routes to the dashboard's Settings tab.
    let navigation: DashboardNavigation
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates\u{2026}") {
                updater.checkForUpdates()
            }
            .disabled(!updater.canCheckForUpdates)
        }

        CommandGroup(replacing: .appSettings) {
            Button("Settings\u{2026}") {
                navigation.section = .settings
                openWindow(id: "dashboard")
                activateAsRegularApp(orderingFrontWindowTitled: "Toki Dashboard")
            }
            .keyboardShortcut(",", modifiers: .command)
        }
    }
}

// MARK: - Menu-bar label host

/// Wraps the status-bar label so it can reach the SwiftUI `openWindow` action:
/// it wires `container.openDashboard` and opens the dashboard window when the
/// onboarding overlay needs to be shown (first run), since onboarding now lives
/// inside the dashboard window rather than a standalone one.
private struct MenuBarLabelHost: View {
    @Environment(\.openWindow) private var openWindow
    let container: ServiceContainer

    var body: some View {
        Group {
            if container.providerAvailability.hasAnyProvider {
                MenuBarLabel(
                    indicators: container.providerAvailability.claudeCode
                        && container.menuBarVM.isExtraUsageActive
                        ? [container.menuBarVM.extraUsageIndicator]
                        : container.menuBarVM.resolvedIndicators,
                    isExtraUsage: container.providerAvailability.claudeCode
                        && container.menuBarVM.isExtraUsageActive,
                    style: container.menuBarVM.configuration.style
                )
            } else {
                Image(systemName: "hourglass")
                    .accessibilityLabel("Toki")
            }
        }
        .onAppear {
            container.openDashboard = { openWindow(id: "dashboard") }
            // Catch the case where the access probe resolved before this appeared.
            if container.dashboardVM.onboarding != nil {
                openWindow(id: "dashboard")
            }
        }
        .onChange(of: container.dashboardVM.onboarding != nil) { _, needsOnboarding in
            if needsOnboarding {
                openWindow(id: "dashboard")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .tokiOpenDashboard)) { note in
            // A cross-process bridge (e.g. a tapped new-account notification handled in
            // AppDelegate, which has no container) names the tab to open in `userInfo`.
            // We own `openWindow` and the container, so we set the tab and bring the window
            // forward here.
            if let raw = note.userInfo?["section"] as? String,
               let section = DashboardSection(identifier: raw) {
                container.navigation.section = section
            }
            openWindow(id: "dashboard")
            activateAsRegularApp(orderingFrontWindowTitled: "Toki Dashboard")
        }
    }
}

// MARK: - Quarantine actions

/// Adopts a quarantined credential as a stored account. `AccountsViewModel` (Task 13)
/// shipped without quarantine mutation, and extending its `init` would force a matching
/// change in `ServiceContainer` outside this task's file list, so these live here instead,
/// using only `ServiceContainer`'s already-public `slotStore` and `accountsVM`.
///
/// The profile endpoint is asked but never required. A quarantined credential's ACCESS
/// token has almost always expired by the time the user sees the entry — quarantine's
/// dominant trigger is that same endpoint being unreachable — so gating adoption on it
/// closed the one recovery path this credential has, and closed it silently.
@MainActor
private func addQuarantineEntry(_ entry: QuarantineEntry, container: ServiceContainer) async {
    var confirmed: AccountIdentity?
    if let token = quarantineAccessToken(of: entry.credentialJSON) {
        // no-log: as the comment above this function explains, the profile endpoint is
        // asked but never required, and quarantine's dominant trigger is that same
        // endpoint being unreachable — so a failure here is the common case, not an
        // exceptional one, and `AdoptionPlan.adoptedQuarantineSlot` below already decides
        // (and the caller already reports) whether adoption can proceed without it.
        confirmed = try? await ProfileOracle().owner(ofToken: token)
    }
    guard let slot = AdoptionPlan.adoptedQuarantineSlot(
        entry: entry, confirmed: confirmed, now: Date()
    ) else {
        container.accountsVM.errorMessage =
            "That credential has no refresh token left, so it can't be restored."
        return
    }

    do {
        try container.slotStore.save(slot)
    } catch {
        // These bytes may be the only surviving copy of this account's refresh token, so
        // the quarantine entry outlives any save that did not confirm.
        TokiLog.logger("app").error("adopting a quarantined credential failed: \(error: error)")
        container.accountsVM.errorMessage =
            "Couldn't add this account: \(error.localizedDescription)"
        return
    }
    do {
        try container.slotStore.deleteQuarantine(id: entry.id)
    } catch {
        TokiLog.logger("app").error(
            "the adopted quarantine entry could not be deleted: \(error: error)")
        container.accountsVM.errorMessage =
            "Added the account, but the quarantined copy couldn't be removed."
    }
    await container.accountsVM.reload()
}

@MainActor
private func deleteQuarantineEntry(_ entry: QuarantineEntry, container: ServiceContainer) async {
    do {
        try container.slotStore.deleteQuarantine(id: entry.id)
    } catch {
        TokiLog.logger("app").error("deleting a quarantine entry failed: \(error: error)")
    }
    await container.accountsVM.reload()
}

private func quarantineAccessToken(of json: Data) -> String? {
    guard
        // no-log: probing the shape of a credential JSON we already hold in memory —
        // every failure mode (not an object, no oauth block, no token) is a normal "this
        // quarantined credential doesn't carry a usable token" outcome, handled by the
        // `nil` return, not a fault.
        let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
        let oauth = root["claudeAiOauth"] as? [String: Any],
        let token = oauth["accessToken"] as? String, !token.isEmpty
    else { return nil }
    return token
}
