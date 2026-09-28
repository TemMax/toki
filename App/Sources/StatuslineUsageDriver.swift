import Foundation
import Observation
import TokiCore
import TokiSwap

private let log = TokiLog.logger("statusline")

/// Keeps Claude Code's status line tapped and feeds what it sees into `LiveLimits`.
///
/// Claude Code reads the account's 5-hour and 7-day usage from the headers of every API
/// response and hands it to the status line command after each reply. With the tap in place
/// (`StatuslineTap`) that payload lands in a file this driver watches, so the gauges move the
/// moment Claude Code replies — no Keychain read, no rate-limited request. The OAuth poll
/// stays as the source for everything else and for when Claude Code is idle.
///
/// On by default, under `enabledKey`, which Settings writes; flipping it installs or removes
/// the tap immediately. The tap is re-applied whenever `settings.json` changes and on a
/// periodic check besides, so a status line the user replaces — by hand, from another tool,
/// through a synced dotfile — is wrapped again rather than silently left untapped.
@Observable
@MainActor
final class StatuslineUsageDriver {
    static let enabledKey = "toki.statuslineTap.enabled"
    /// How often the settings file is re-checked on top of the file watcher.
    static let checkInterval: Duration = .seconds(60)

    enum Status: Equatable {
        /// Not checked yet.
        case unknown
        case off
        /// The user's own status line runs through the tap.
        case wrappingUserCommand
        /// Toki's silent status line is installed.
        case silentStatusLine
        /// `statusLine` holds something Toki does not understand, so it is left alone.
        case unsupported
        /// `settings.json` could not be read or written.
        case failed
    }

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    private(set) var status: Status = .unknown
    /// When Claude Code last handed Toki usage through the status line.
    private(set) var lastSampleAt: Date?

    var backupsURL: URL { tap.backupsURL }

    @ObservationIgnored private let tap: StatuslineTap
    @ObservationIgnored private let limits: LiveLimits
    /// Installs and removes in the order they were asked for; each is a read-modify-write of
    /// the user's settings file.
    @ObservationIgnored private let tapQueue = DispatchQueue(label: "dev.komar.toki.statusline-tap")
    @ObservationIgnored private var sampleWatcher: FileWatcher?
    @ObservationIgnored private var settingsWatcher: FileWatcher?
    @ObservationIgnored private var defaultsObserver: NSObjectProtocol?
    @ObservationIgnored private var periodicCheck: Task<Void, Never>?
    @ObservationIgnored private var appliedEnabled: Bool?
    @ObservationIgnored private var lastSampleModified: Date?

    init(tap: StatuslineTap = .live, limits: LiveLimits) {
        self.tap = tap
        self.limits = limits
    }

    func start() {
        guard sampleWatcher == nil else { return }
        applySettingIfChanged()

        let sampleWatcher = FileWatcher(url: tap.sampleURL, debounce: 0.05) { [weak self] in
            Task { @MainActor in await self?.readSample() }
        }
        self.sampleWatcher = sampleWatcher
        sampleWatcher.start()

        let settingsWatcher = FileWatcher(url: tap.settingsURL.resolvingSymlinksInPath(), debounce: 0.5) { [weak self] in
            Task { @MainActor in self?.reconcile() }
        }
        self.settingsWatcher = settingsWatcher
        settingsWatcher.start()

        // The watcher follows one inode; a settings file swapped behind a symlink, or an edit
        // made while a watch was being re-armed, would otherwise go unnoticed until relaunch.
        periodicCheck = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: Self.checkInterval)
                } catch {
                    log.debug("status line periodic check stopped \(error: error)")
                    return
                }
                self?.reconcile()
            }
        }

        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applySettingIfChanged() }
        }

        // A sample written while Toki was not running may still be newer than the cache.
        Task { await readSample() }
    }

    func stop() {
        sampleWatcher?.stop()
        sampleWatcher = nil
        settingsWatcher?.stop()
        settingsWatcher = nil
        periodicCheck?.cancel()
        periodicCheck = nil
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
        defaultsObserver = nil
    }

    private func applySettingIfChanged() {
        let enabled = Self.isEnabled
        guard enabled != appliedEnabled else { return }
        appliedEnabled = enabled
        log.info("live usage from the status line enabled=\(enabled)")
        reconcile()
    }

    /// Brings `settings.json` in line with the setting. Both directions are idempotent, so the
    /// settings watcher firing on Toki's own write settles after one no-op pass.
    private func reconcile() {
        let enabled = appliedEnabled ?? Self.isEnabled
        let tap = self.tap
        tapQueue.async { [weak self] in
            let status = Self.apply(enabled: enabled, to: tap)
            Task { @MainActor in self?.status = status }
        }
    }

    nonisolated private static func apply(enabled: Bool, to tap: StatuslineTap) -> Status {
        do {
            if enabled {
                try tap.install()
            } else {
                try tap.uninstall()
                return .off
            }
            switch try tap.state() {
            case let .tapped(original): return original.isEmpty ? .silentStatusLine : .wrappingUserCommand
            case .unsupported: return .unsupported
            case .untapped, .noStatusLine: return .failed
            }
        } catch where enabled {
            log.error("status line tap could not be installed \(error: error)")
            return .failed
        } catch {
            log.error("status line tap could not be removed \(error: error)")
            return .failed
        }
    }

    private func readSample() async {
        let url = tap.sampleURL
        let read = await Task.detached { () -> (Data, Date)? in
            // An absent sample is the normal state until Claude Code next replies.
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                guard let modified = attributes[.modificationDate] as? Date else { return nil }
                return (try Data(contentsOf: url), modified)
            } catch {
                log.error("status line sample could not be read \(error: error)")
                return nil
            }
        }.value
        guard let (data, modified) = read, modified != lastSampleModified else { return }
        lastSampleModified = modified
        guard let sample = StatuslineRateLimits.parse(data, observedAt: modified) else { return }
        lastSampleAt = modified
        limits.ingestStatusline(sample)
    }
}
