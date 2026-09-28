import SwiftUI
import Combine
import Sparkle
import TokiCore

private let log = TokiLog.logger("updater")

/// Owns the Sparkle updater for the app's whole lifetime and exposes a
/// SwiftUI-friendly "check for updates" entry point.
///
/// The updater starts automatically and periodically checks the appcast
/// published to the public GitHub release (the feed URL and the EdDSA
/// public key live in Info.plist as `SUFeedURL` / `SUPublicEDKey`). Automatic
/// checks use Sparkle's default cadence (~24h); the user can also trigger one
/// from Settings ▸ About.
///
/// Sparkle asks once (on first update check) whether to enable automatic checks.
/// Whatever the user picks in that prompt — including declining it — is just the
/// initial value of `automaticallyChecksForUpdates`; the Settings ▸ Updates
/// toggles below let the user change their mind at any time afterwards.
@MainActor
final class UpdaterController: ObservableObject {
    private let controller: SPUStandardUpdaterController

    /// Mirrors `SPUUpdater.canCheckForUpdates` so the menu item disables itself
    /// while a check is already in flight.
    @Published var canCheckForUpdates = false

    /// Two-way mirror of `SPUUpdater.automaticallyChecksForUpdates`. Sparkle
    /// persists the backing value in `UserDefaults`, so it survives relaunches.
    @Published var automaticallyChecksForUpdates = false {
        didSet {
            guard controller.updater.automaticallyChecksForUpdates != automaticallyChecksForUpdates else { return }
            controller.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        }
    }

    /// Two-way mirror of `SPUUpdater.automaticallyDownloadsUpdates` (download +
    /// install in the background). Only meaningful while automatic checks are on.
    @Published var automaticallyDownloadsUpdates = false {
        didSet {
            guard controller.updater.automaticallyDownloadsUpdates != automaticallyDownloadsUpdates else { return }
            controller.updater.automaticallyDownloadsUpdates = automaticallyDownloadsUpdates
        }
    }

    init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        // KVO → @Published mirrors. Because the `didSet` observers above no-op
        // when the value already matches, writes originating from Sparkle itself
        // flow in here without bouncing back out (no feedback loop).
        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
        controller.updater.publisher(for: \.automaticallyChecksForUpdates)
            .assign(to: &$automaticallyChecksForUpdates)
        controller.updater.publisher(for: \.automaticallyDownloadsUpdates)
            .assign(to: &$automaticallyDownloadsUpdates)
    }

    func checkForUpdates() {
        // The outcome (found/not found/error) is not observable here without adopting
        // `SPUUpdaterDelegate` — `controller` is constructed with `updaterDelegate: nil` and
        // adding one is a behavior change outside this task's scope (see the app-instrumentation
        // report's dead-end note). This logs only that a check was requested.
        log.info("checkForUpdates: user-initiated update check requested")
        controller.updater.checkForUpdates()
    }
}
