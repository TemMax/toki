import AppKit
import SwiftUI
import TokiCore
import TokiAccounts
import TokiFixtures

// MARK: - SnapshotRunner

/// Headless UI snapshot mode.  Invoked by passing `--snapshot [output-dir] [--scenario name]`
/// on the command line.  Wires a `ServiceContainer` to a named `TokiFixtures.Scenario`, renders
/// every surface to a PNG through `SurfaceRenderer`, writes the files, and calls `exit(0)` — so
/// normal app launch is completely unaffected when the flag is absent.
@MainActor
enum SnapshotRunner {

    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let flagIndex = args.firstIndex(of: "--snapshot") else { return }

        // Determine output directory — next argument if present, else tmp.
        let outputDir: URL
        let nextIndex = flagIndex + 1
        if nextIndex < args.count, !args[nextIndex].hasPrefix("-") {
            outputDir = URL(fileURLWithPath: args[nextIndex], isDirectory: true)
        } else {
            outputDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("toki-snapshots", isDirectory: true)
        }

        // `--scenario <name>` selects the TokiFixtures scenario every surface is rendered
        // with; defaults to `single-account`. The caller loops scenarios from the shell —
        // this harness only ever renders one per invocation.
        let scenario: Scenario
        if let scenarioFlagIndex = args.firstIndex(of: "--scenario") {
            guard
                scenarioFlagIndex + 1 < args.count,
                let parsed = Scenario(rawValue: args[scenarioFlagIndex + 1])
            else {
                let names = Scenario.allCases.map(\.rawValue).joined(separator: ", ")
                print("SnapshotRunner: --scenario requires one of: \(names)")
                exit(1)
            }
            scenario = parsed
        } else {
            scenario = .singleAccount
        }

        do {
            try FileManager.default.createDirectory(
                at: outputDir,
                withIntermediateDirectories: true
            )
        } catch {
            print("SnapshotRunner: failed to create output dir: \(error)")
            exit(1)
        }

        renderAll(scenario: scenario, to: outputDir)
        exit(0)
    }

    // MARK: - Demo windows (REAL rendering, for screencapture)

    private static var demoWindows: [NSWindow] = []

    /// Opens real NSWindows hosting the popover + dashboard with injected fixture data.
    /// Used via `--demo` so the orchestrator can screencapture true Liquid Glass rendering.
    static func presentDemoWindows() {
        let container = ServiceContainer(prewarm: false)
        container.apply(.fixture(.claudeResets))

        let popover = AnyView(
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
            .frame(width: 320, height: 560)
        )
        let dashboard = AnyView(
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
                navigation: container.navigation
            )
            .environmentObject(container.updater)
            .frame(width: 880, height: 560)
        )

        demoWindows = [
            makeDemoWindow(title: "Toki Popover (demo)", content: popover, origin: NSPoint(x: 60, y: 240)),
            makeDemoWindow(title: "Toki Dashboard (demo)", content: dashboard, origin: NSPoint(x: 420, y: 160)),
        ]

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    private static func makeDemoWindow(title: String, content: AnyView, origin: NSPoint) -> NSWindow {
        let hosting = NSHostingController(rootView: content)
        let win = NSWindow(contentViewController: hosting)
        win.title = title
        win.styleMask = [.titled, .closable]
        win.setContentSize(hosting.view.fittingSize)
        win.setFrameOrigin(origin)
        win.isReleasedWhenClosed = false
        win.makeKeyAndOrderFront(nil)
        return win
    }

    // MARK: - Rendering

    /// One surface to capture: a name (used for the file stem), the view itself, and the
    /// fixed width it is measured at. Height is always the view's natural content height —
    /// `SurfaceRenderer` resolves it, including full `ScrollView` content — so no surface here
    /// pins a height the way the old `ImageRenderer`-era code had to.
    private struct Surface {
        let name: String
        let view: AnyView
        let width: CGFloat
    }

    /// Lets automated visual checks cover conditional provider layouts without depending on
    /// which CLIs happen to be installed on the machine rendering the fixtures.
    private static var snapshotProviderAvailability: ProviderAvailability {
        switch ProcessInfo.processInfo.environment["TOKI_SNAPSHOT_PROVIDERS"] {
        case "claude": return ProviderAvailability(claudeCode: true, codex: false)
        case "codex": return ProviderAvailability(claudeCode: false, codex: true)
        case "none": return ProviderAvailability(claudeCode: false, codex: false)
        default: return .all
        }
    }

    private static func renderAll(scenario: Scenario, to outputDir: URL) {
        // Flatten glass/material so offscreen capture shows real layout — see
        // SurfaceRenderer's doc comment for why materials can't composite off-screen.
        SnapshotConfig.flatSurfaces = true

        let container = ServiceContainer(
            prewarm: false,
            providerAvailability: snapshotProviderAvailability
        )
        container.apply(.fixture(scenario))

        // One updater instance, shared by every DashboardView/SettingsSections render — it's
        // an ObservableObject with no per-scenario state, and constructing one genuinely
        // starts Sparkle (scheduled ~24h checks), so the process must only ever have the
        // container's. `SettingsSections` needs it to be renderable at all: it reads
        // `@EnvironmentObject UpdaterController` unconditionally, not just when the Settings
        // tab is showing. The onboarding container below deliberately reuses this one rather
        // than waking its own.
        let updater = container.updater

        var surfaces: [Surface] = []

        // MARK: Popover

        surfaces.append(Surface(
            name: "popover",
            view: AnyView(
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
            ),
            width: 320
        ))

        // MARK: Dashboard (full window chrome, Usage tab)

        container.navigation.section = .usage
        surfaces.append(Surface(
            name: "dashboard",
            view: AnyView(
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
                    navigation: container.navigation
                )
                .environmentObject(updater)
            ),
            width: 880
        ))

        // MARK: Usage (bare scrollable content, no toolbar chrome)

        if let summary = container.dashboardVM.summary {
            surfaces.append(Surface(
                name: "usage",
                view: AnyView(
                    DashboardContent(
                        summary: summary,
                        limits: container.menuBarVM.displayedLimits(for: .claudeCode),
                        claudeResetLimits: container.menuBarVM.currentClaudeResetLimits,
                        codexLimits: container.menuBarVM.displayedLimits(for: .codex),
                        codexResetLimits: container.menuBarVM.currentCodexResetLimits,
                        accountCount: max(container.accountsVM.accounts.count, 1),
                        statisticsHistory: container.statisticsVM.history,
                        statisticsErrorMessage: container.statisticsVM.errorMessage,
                        serviceStatus: container.serviceStatus.status,
                        codexServiceStatus: container.codexServiceStatus.status,
                        showsClaudeCode: container.providerAvailability.claudeCode,
                        showsCodex: container.providerAvailability.codex
                    )
                    .padding(Spacing.xl)
                    .frame(maxWidth: .infinity, alignment: .top)
                    .background(Palette.bg)
                ),
                width: 860
            ))
        } else {
            print("SnapshotRunner: skipping usage — scenario '\(scenario.rawValue)' has no summary")
        }

        // MARK: Statistics (not a dashboard tab anymore — this content now lives on the
        // Usage tab, on every range, see `usage` above — kept as its own comparison
        // surface; full view — handles the empty/error states itself, which the bare
        // `StatisticsContent` struct does not; needed for the `empty` scenario to show
        // its real "no activity" message instead of a blank canvas)

        surfaces.append(Surface(
            name: "statistics",
            view: AnyView(StatisticsView(model: container.statisticsVM, topInset: Spacing.xl)),
            width: 880
        ))

        // MARK: Instances (full view — same reasoning as Statistics above)

        surfaces.append(Surface(
            name: "instances",
            view: AnyView(InstancesView(model: container.instancesVM, topInset: Spacing.xl)),
            width: 720
        ))

        // MARK: Environment (full view — no separate bare-content type is meaningfully
        // simpler than the view itself, which is just its own ScrollView + view model)

        surfaces.append(Surface(
            name: "environment",
            view: AnyView(EnvironmentView(model: container.environmentVM, topInset: Spacing.xl)),
            width: 880
        ))

        // MARK: Machine (full view — Instances content followed by Environment content, the
        // tab that replaced the two above; those two are kept as their own surfaces because
        // they are still distinct things worth capturing separately)

        surfaces.append(Surface(
            name: "machine",
            view: AnyView(
                MachineView(instances: container.instancesVM, environment: container.environmentVM, topInset: Spacing.xl)
            ),
            width: 880
        ))

        // MARK: Accounts (full view)

        surfaces.append(Surface(
            name: "accounts",
            view: AnyView(AccountsView(
                model: container.accountsVM,
                codex: container.codexAccountsVM,
                providerAvailability: container.providerAvailability,
                topInset: Spacing.xl
            )),
            width: 880
        ))

        // MARK: Gallery (design-system component gallery — no view model, no scenario data)

        surfaces.append(Surface(
            name: "gallery",
            view: AnyView(GalleryView()),
            width: 900
        ))

        // MARK: Settings (full view — no view model, just @AppStorage + the shared updater)

        surfaces.append(Surface(
            name: "settings",
            view: AnyView(
                SettingsSections(
                    topInset: Spacing.xl,
                    menuBar: container.menuBarVM,
                    providerAvailability: container.providerAvailability
                )
                    .environmentObject(updater)
            ),
            width: 880
        ))

        // MARK: Notifications editor (the sheet Settings' "Notifications" row opens, rendered
        // standalone — an actual `.sheet` presentation needs a host window and a click, which
        // this headless path has neither of. No height override: the view fixes only its
        // width, so the render reports its true natural content height against the 560pt
        // sheet. Worth capturing per scenario because the pinned preview is resolved against
        // that scenario's limits — `near-limit` draws the alert-bearing state, since every one
        // of its windows sits above the default 90% rules.)

        surfaces.append(Surface(
            name: "notifications-editor",
            view: AnyView(NotificationsEditorView(menuBar: container.menuBarVM)),
            width: NotificationsEditorView.sheetWidth
        ))

        // MARK: Onboarding

        // Dashboard with the onboarding overlay active — the first-run look now that
        // onboarding lives inside the dashboard window (not a standalone one). Reuses the
        // same scenario's data underneath so the overlay's backdrop isn't hardcoded.
        let onboardingContainer = ServiceContainer(
            prewarm: false,
            providerAvailability: snapshotProviderAvailability
        )
        onboardingContainer.apply(.fixture(scenario))
        onboardingContainer.dashboardVM.onboarding = OnboardingViewModel(
            credentials: SnapshotCredentials(), initialState: .intro
        )
        surfaces.append(Surface(
            name: "dashboard-onboarding",
            view: AnyView(
                DashboardView(
                    model: onboardingContainer.dashboardVM,
                    instances: onboardingContainer.instancesVM,
                    environment: onboardingContainer.environmentVM,
                    menuBar: onboardingContainer.menuBarVM,
                    serviceStatus: onboardingContainer.serviceStatus,
                    codexServiceStatus: onboardingContainer.codexServiceStatus,
                    providerAvailability: onboardingContainer.providerAvailability,
                    accounts: onboardingContainer.accountsVM,
                    codexAccounts: onboardingContainer.codexAccountsVM,
                    statistics: onboardingContainer.statisticsVM,
                    navigation: onboardingContainer.navigation
                )
                .environmentObject(updater)
            ),
            width: 880
        ))

        // Onboarding screens carry no scenario data (state is seeded directly via
        // `initialState`), so they render identically regardless of `scenario`.
        surfaces.append(Surface(
            name: "onboarding-intro",
            view: AnyView(
                OnboardingView(
                    model: OnboardingViewModel(credentials: SnapshotCredentials(), initialState: .intro)
                )
            ),
            width: 460
        ))
        surfaces.append(Surface(
            name: "onboarding-denied",
            view: AnyView(
                OnboardingView(
                    model: OnboardingViewModel(credentials: SnapshotCredentials(), initialState: .denied)
                )
            ),
            width: 460
        ))

        // MARK: Capture

        let lightBG = Color(white: 0.96)
        let darkBG  = Color(white: 0.13)

        for surface in surfaces {
            for (scheme, bg, suffix) in [
                (ColorScheme.light, lightBG, "light"),
                (ColorScheme.dark,  darkBG,  "dark")
            ] as [(ColorScheme, Color, String)] {
                let backdrop = ZStack {
                    bg.ignoresSafeArea()
                    surface.view
                }

                let fileName = "\(surface.name)-\(suffix).png"
                let dest = outputDir.appendingPathComponent(fileName)
                do {
                    try SurfaceRenderer.writePNG(
                        backdrop,
                        to: dest,
                        width: surface.width,
                        colorScheme: scheme
                    )
                    print(dest.path)
                } catch {
                    print("SnapshotRunner: could not render \(surface.name)-\(suffix): \(error)")
                }
            }
        }
    }
}

// MARK: - Snapshot credential stub

/// Inert `CredentialOnboarding` conformer for onboarding snapshots: state is
/// seeded via `initialState`, so these methods are never invoked during render.
private struct SnapshotCredentials: CredentialOnboarding {
    func currentCredential() async throws -> OAuthCredential {
        throw TokiError.credentialsNotFound
    }
    func accessState() async -> CredentialAccessState { .needsAuthorization }
}
