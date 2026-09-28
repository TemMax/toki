import AppKit
import Observation
import TokiCore
import TokiAlerts

private let log = TokiLog.logger("resets")

/// Local notifications reuse account polling and a public, credential-free catalog.
/// Histories outlive the process and are updated even while delivery is muted.
@MainActor
final class ResetNotificationDriver {
    private static let announcementDeliveryWindow: TimeInterval = 24 * 60 * 60

    private struct History: Codable {
        var banked = BankedResetPolicy()
        var announcements = ResetAnnouncementPolicy()
    }

    #if DEBUG
    private static let historyKey = "toki.resetNotifications.history.debug"
    #else
    private static let historyKey = "toki.resetNotifications.history"
    #endif

    private let limits: LiveLimits
    private let providers: Set<UsageProvider>
    private let defaults: UserDefaults
    private let settings: NotificationSettingsStore
    private let client: ResetAnnouncementClient
    private let now: () -> Date
    private let notifier = SwapNotifier()
    private var history: History
    private var pollingTask: Task<Void, Never>?
    private var bankedDeliveryTask: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?
    private var started = false
    private var polling = false

    init(
        limits: LiveLimits, providers: Set<UsageProvider>, defaults: UserDefaults = .standard,
        client: ResetAnnouncementClient = ResetAnnouncementClient(),
        now: @escaping () -> Date = { Date() }
    ) {
        self.limits = limits
        self.providers = providers
        self.defaults = defaults
        self.client = client
        self.now = now
        self.settings = NotificationSettingsStore(defaults: defaults)
        if let data = defaults.data(forKey: Self.historyKey) {
            do {
                self.history = try JSONDecoder().decode(History.self, from: data)
            } catch {
                log.error("Reset notification history decode failed \(error: error)")
                self.history = History()
            }
        } else {
            self.history = History()
        }
    }

    func start() {
        guard !started, limits.runMode.isLive else { return }
        started = true
        observeBanked()
        evaluateBanked()
        pollingTask = Task { [weak self] in
            var delay: Double = 300
            while !Task.isCancelled {
                guard let self else { return }
                let succeeded = await self.pollAnnouncements()
                delay = succeeded ? 300 : min(delay * 2, 1800)
                do { try await Task.sleep(for: .seconds(delay)) }
                catch {
                    log.debug("Reset announcement polling stopped \(error: error)")
                    return
                }
            }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                _ = await self?.pollAnnouncements()
            }
        }
    }

    private func observeBanked() {
        withObservationTracking {
            _ = limits.codexLimits
            _ = limits.codexState
            _ = limits.runMode
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.observeBanked()
                self.evaluateBanked()
            }
        }
    }

    private func evaluateBanked() {
        guard limits.runMode.isLive, providers.contains(.codex), case .ok = limits.codexState,
              let snapshot = limits.codexLimits,
              (0...210).contains(Date().timeIntervalSince(snapshot.fetchedAt)) else { return }
        let notice = history.banked.observe(
            snapshot.bankedResets, accountID: snapshot.account?.accountUuid, fetchedAt: snapshot.fetchedAt
        )
        save()
        guard let notice else { return }
        guard let accountID = snapshot.account?.accountUuid else { return }
        bankedDeliveryTask?.cancel()
        bankedDeliveryTask = Task { [weak self] in
            guard let self, self.settings.load().onBankedResets,
                  await self.notifier.requestAuthorization(), !Task.isCancelled,
                  self.limits.runMode.isLive, self.settings.load().onBankedResets,
                  case .ok = self.limits.codexState,
                  let current = self.limits.codexLimits,
                  current.account?.accountUuid == accountID,
                  (0...210).contains(Date().timeIntervalSince(current.fetchedAt)),
                  let resets = current.bankedResets, resets.availableCount > 0 else { return }
            // Authorization can remain open across polls or a time-zone change. Compose
            // from the current account snapshot at delivery, never the old prompt's count.
            let available = (resets.credits ?? []).filter { $0.status == "available" }
            let now = Date()
            guard !available.contains(where: { $0.expiresAt.map { $0 <= now } ?? false }) else { return }
            self.notifier.notifyReset(
                title: ResetNotificationCopy.bankedTitle(isInitial: notice.isInitial),
                body: ResetNotificationCopy.bankedBody(
                    count: resets.availableCount,
                    expiresAt: available.compactMap(\.expiresAt).min(),
                    detailsComplete: available.count == resets.availableCount
                ),
                destination: ResetLinks.codexUsage
            )
        }
    }

    private func pollAnnouncements() async -> Bool {
        guard limits.runMode.isLive, !polling else { return true }
        polling = true
        defer { polling = false }
        var succeeded = true
        for provider in UsageProvider.allCases where providers.contains(provider) {
            do {
                let events = try await client.fetch(provider: provider)
                guard limits.runMode.isLive, !Task.isCancelled else { return true }
                let notices = history.announcements.observe(events, provider: provider, now: now())
                save()
                for event in notices {
                    deliver(
                        title: ResetNotificationCopy.announcementTitle(provider: provider),
                        body: ResetNotificationCopy.announcementBody(scope: event.scope),
                        destination: event.sourceURL,
                        announcedAt: event.announcedAt,
                        setting: provider == .codex ? \.onOpenAIResets : \.onClaudeResets
                    )
                }
            } catch {
                succeeded = false
                log.error("Reset announcement fetch failed \(error: error)")
            }
        }
        return succeeded
    }

    private func save() {
        do { defaults.set(try JSONEncoder().encode(history), forKey: Self.historyKey) }
        catch { log.error("Reset notification history save failed \(error: error)") }
    }

    private func deliver(
        title: String, body: String, destination: URL, announcedAt: Date,
        setting: KeyPath<NotificationSettings, Bool>
    ) {
        guard settings.load()[keyPath: setting] else { return }
        Task { [weak self] in
            guard let self, await self.notifier.requestAuthorization(),
                  self.limits.runMode.isLive, self.settings.load()[keyPath: setting],
                  (0...Self.announcementDeliveryWindow).contains(
                      self.now().timeIntervalSince(announcedAt)
                  ) else { return }
            self.notifier.notifyReset(title: title, body: body, destination: destination)
        }
    }
}
