import Foundation
import ServiceManagement
import Observation
import TokiCore

private let log = TokiLog.logger("app")

/// Wraps SMAppService registration so SettingsSections stays clean.
/// Registration can fail in unsigned / non-/Applications builds — errors are
/// surfaced to callers rather than crashing.
///
/// Every SMAppService call (`status`, `register`, `unregister`) is a synchronous
/// XPC round trip to launchd — run on the main actor it stalls whatever is in
/// flight (the Settings tab's entrance, the toggle click), so the XPC work hops
/// off through detached tasks and only the published state lands back here.
@Observable
@MainActor
final class LaunchAtLogin {

    // MARK: - Published state

    /// Whether "Launch at Login" is currently enabled.
    private(set) var isEnabled: Bool = false

    /// Non-nil when the last toggle attempt threw an error.
    private(set) var lastError: String? = nil

    // MARK: - Lifecycle

    init() {}

    /// Reads the current registration status from SMAppService.
    func refresh() {
        Task { [weak self] in
            let enabled = await Task.detached { SMAppService.mainApp.status == .enabled }.value
            self?.isEnabled = enabled
        }
    }

    /// Toggles the registration state.
    /// On failure, `lastError` is updated with a human-readable hint.
    func toggle() {
        lastError = nil
        let enabling = !isEnabled
        log.info("toggle: requesting launch-at-login change (enabling=\(enabling))")
        // Optimistic flip so the toggle answers the click immediately; the detached
        // result (or the re-read on failure) settles it to the truth.
        isEnabled = enabling
        Task { [weak self] in
            let outcome: Result<Void, Error> = await Task.detached {
                do {
                    if enabling {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                    return .success(())
                } catch {
                    // no-log: the `.failure(error)` case is logged by the caller below,
                    // once it also knows whether this was a register or unregister attempt.
                    return .failure(error)
                }
            }.value

            guard let self else { return }
            if case let .failure(error) = outcome {
                // Registration frequently fails in dev builds or when the app is
                // not in /Applications — this is expected and non-fatal.
                log.notice("toggle: launch-at-login change (enabling=\(enabling)) failed (expected outside /Applications): \(error: error)")
                self.lastError = Self.errorHint(for: error)
                // Re-read actual status so the toggle reflects truth.
                self.refresh()
            } else {
                log.info("toggle: launch-at-login change (enabling=\(enabling)) succeeded")
            }
        }
    }

    // MARK: - Private helpers

    private static func errorHint(for error: Error) -> String {
        let msg = error.localizedDescription
        // Provide a friendlier hint for the most common case.
        if msg.contains("unsupported") || msg.contains("not supported") {
            return "Launch at login requires the app to be in /Applications."
        }
        return "Could not update launch at login: \(msg)"
    }
}
