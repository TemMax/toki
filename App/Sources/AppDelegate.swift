import AppKit
import SwiftUI
import UserNotifications
import TokiAlerts
import TokiCore

private let log = TokiLog.logger("app")

/// Manages `NSApplication` activation policy so Toki lives in the menu bar
/// without a permanent Dock icon, but briefly becomes `.regular` when the
/// dashboard window is open. Also the notification-center delegate, so a tapped
/// notification can bring the app forward on the right tab.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate, ObservableObject {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--demo") {
            SnapshotRunner.presentDemoWindows()
            return
        }
        // Start as an accessory (no Dock icon, no app menu) to avoid a flash.
        NSApp.setActivationPolicy(.accessory)
        UNUserNotificationCenter.current().delegate = self
        #if DEBUG
        // The agent control channel — an owner-only Unix socket that renders surfaces and
        // presses this app's own buttons, so automation needs no TCC grant. The whole type
        // is behind `#if DEBUG`, so it does not exist in a Release binary.
        DebugControlChannel.start()
        #endif
    }

    /// Show Toki' notifications even while it is frontmost, so a swap or new-account alert
    /// isn't swallowed when the dashboard is open.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    /// A tapped notification carrying the open-accounts flag brings the dashboard forward on
    /// the Accounts tab. Routed through `NotificationCenter` (naming the tab in `userInfo`)
    /// so the SwiftUI layer, which owns `openWindow`, the container, and the tab selection,
    /// does the actual work.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        if let raw = response.notification.request.content.userInfo[SwapNotifier.resetURLKey] as? String,
           let url = URL(string: raw), ResetLinks.allowed(url) {
            await MainActor.run { _ = NSWorkspace.shared.open(url) }
            return
        }
        if response.notification.request.content.userInfo[SwapNotifier.openAccountsKey] as? Bool == true {
            log.info("didReceive: a tapped notification opened the Accounts tab")
            await MainActor.run {
                NotificationCenter.default.post(
                    name: .tokiOpenDashboard,
                    object: nil,
                    userInfo: ["section": "accounts"]
                )
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Revert to accessory when the dashboard window closes; keep the process alive.
        NSApp.setActivationPolicy(.accessory)
        return false
    }

    /// Get the tail of the session onto disk before the process goes away.
    ///
    /// `FileLogSink.write` hands each line to a serial queue and returns, so the caller never
    /// waits on disk — but that means whatever is still queued when the process exits is
    /// lost, and the lines closest to the exit are exactly the ones a user quits *because
    /// of*. Someone hitting a bug, quitting, relaunching and then exporting would otherwise
    /// get an archive missing the part they wanted to report.
    ///
    /// This covers a clean quit only. A crash runs no delegate method, and the answer there
    /// is that `FileHandle.write` is unbuffered: every line whose queue block has already run
    /// is in the page cache and survives, so the loss window is just what is still enqueued.
    func applicationWillTerminate(_ notification: Notification) {
        log.info("applicationWillTerminate: flushing the log before exit")
        TokiLog.flush()
    }
}

/// Brings Toki forward as a `.regular` app so its main menu appears in the
/// system menu bar.
///
/// Toki normally runs as `.accessory` (no Dock icon, no main menu). When a real
/// window opens we switch to `.regular`, but AppKit only installs the app's main
/// menu when the app actually *becomes active* — and if we're already frontmost
/// (e.g. the menu-bar popover was just showing), activating in the same runloop
/// tick is a no-op, so the window comes forward while the previous app keeps
/// owning the menu bar. Deferring the activation to the next tick forces the
/// re-activation that installs our menu.
@MainActor
func activateAsRegularApp(orderingFrontWindowTitled title: String? = nil) {
    NSApp.setActivationPolicy(.regular)
    DispatchQueue.main.async {
        NSApp.activate(ignoringOtherApps: true)
        if let title {
            NSApp.windows.first { $0.title == title }?.makeKeyAndOrderFront(nil)
        }
    }
}
