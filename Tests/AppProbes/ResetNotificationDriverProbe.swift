import AppKit
import Foundation
import TokiCore
import TokiAccounts
import TokiAlerts
import TokiFixtures

// The real driver and LiveLimits are compiled below. Only notification delivery,
// credentials and public HTTP are substituted, so this probe cannot prompt or notify.
@MainActor struct SwapNotifier {
    static var authorizations = 0
    static var deliveries: [String] = []
    static var holdAuthorization = false
    static var pending: CheckedContinuation<Bool, Never>?
    func requestAuthorization() async -> Bool {
        Self.authorizations += 1
        if Self.holdAuthorization {
            return await withCheckedContinuation { Self.pending = $0 }
        }
        return true
    }
    func notifyReset(title: String, body: String, destination: URL) {
        Self.deliveries.append(title + ": " + body)
    }
}
actor UnusedCredentials: CredentialProviding {
    func currentCredential() async throws -> OAuthCredential { throw TokiError.keychainDenied }
}
final class ResetCatalog: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var responseData = Data(#"{"events":[]}"#.utf8)

    static func use(_ data: Data) {
        lock.lock()
        responseData = data
        lock.unlock()
    }

    private static func data() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return responseData
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
        )!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.data())
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
@MainActor final class ProbeClock {
    var now: Date
    init(now: Date) { self.now = now }
}
@main struct ResetDriverProbe {
    @MainActor static func main() async throws {
        let domain = "toki.reset-probe." + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ResetCatalog.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(domain)
        let live = LiveLimits(
            limits: LimitsService(credentials: UnusedCredentials(), session: session,
                                  cache: LimitsCache(fileURL: dir.appendingPathComponent("claude.json")),
                                  refreshController: UsageRefreshController()),
            codex: CodexLimitsService(cache: LimitsCache(fileURL: dir.appendingPathComponent("codex.json")),
                                      refreshController: UsageRefreshController()),
            signedIn: SignedInAccount(configURL: dir.appendingPathComponent("unused.json"))
        )
        let settings = NotificationSettingsStore(defaults: defaults)
        var prefs = NotificationSettings.standard
        prefs.onBankedResets = false
        settings.save(prefs)
        let clock = ProbeClock(now: Date(timeIntervalSince1970: 1_800_000_000))
        let driver = ResetNotificationDriver(
            limits: live, providers: [.codex], defaults: defaults,
            client: ResetAnnouncementClient(session: session),
            now: { clock.now }
        )
        live.codexState = .ok
        live.codexLimits = snapshot(1)
        live.runMode = .fixture(.singleAccount)
        driver.start()
        try await settle()
        precondition(defaults.data(forKey: "toki.resetNotifications.history.debug") == nil,
                     "fixture mode must not write notification history")
        precondition(SwapNotifier.authorizations == 0)

        live.runMode = .live
        driver.start()
        try await settle()
        precondition(defaults.data(forKey: "toki.resetNotifications.history.debug") != nil)
        live.codexLimits = snapshot(2)
        try await settle()
        precondition(SwapNotifier.authorizations == 0, "muted events must never prompt")
        prefs.onBankedResets = true
        settings.save(prefs)
        live.codexLimits = snapshot(2)
        try await settle()
        precondition(SwapNotifier.deliveries.isEmpty, "unmuting must not replay tracked availability")

        live.codexLimits = snapshot(3)
        try await settle()
        precondition(SwapNotifier.deliveries.count == 1)
        precondition(SwapNotifier.deliveries[0].contains("3 resets available."))
        live.codexState = .stale(Date())
        live.codexLimits = snapshot(4)
        try await settle()
        precondition(SwapNotifier.deliveries.count == 1, "failed polls cannot deliver cached metadata")

        SwapNotifier.holdAuthorization = true
        live.codexState = .ok
        try await settle()
        precondition(SwapNotifier.pending != nil)
        live.codexLimits = snapshot(0, account: "other-account")
        try await settle()
        SwapNotifier.pending?.resume(returning: true)
        SwapNotifier.pending = nil
        try await settle()
        precondition(SwapNotifier.deliveries.count == 1, "authorization resumed after account switch must not deliver old availability")

        SwapNotifier.holdAuthorization = true
        ResetCatalog.use(announcement(at: clock.now.addingTimeInterval(-(24 * 60 * 60 - 60))))
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        try await settle()
        precondition(SwapNotifier.pending != nil, "recent announcement must request authorization")
        let announcementAuthorizations = SwapNotifier.authorizations
        clock.now.addTimeInterval(2 * 60)
        SwapNotifier.pending?.resume(returning: true)
        SwapNotifier.pending = nil
        try await settle()
        precondition(SwapNotifier.deliveries.count == 1,
                     "announcement older than 24 hours after authorization must not deliver")

        SwapNotifier.holdAuthorization = false
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        try await settle()
        precondition(SwapNotifier.authorizations == announcementAuthorizations,
                     "expired announcement must remain consumed after delivery suppression")
        precondition(SwapNotifier.deliveries.count == 1, "consumed announcement must not replay")
        print("PASS: real reset driver respects fixtures, muted history, state changes and announcement age after authorization")
    }
    static func snapshot(_ count: Int, account: String = "account") -> UsageLimits {
        UsageLimits(windows: [], extra: nil, fetchedAt: Date(),
                    account: UsageAccount(accountUuid: account, organizationUuid: nil),
                    bankedResets: BankedResets(availableCount: count, credits: nil))
    }
    static func announcement(at date: Date) -> Data {
        let timestamp = ISO8601DateFormatter().string(from: date)
        return Data(#"{"events":[{"tweet_id":"401","tweet_url":"https://x.com/thsottiaux/status/401","announced_at":"\#(timestamp)","reset_type":"regular","source":"webhook"}]}"#.utf8)
    }
    static func settle() async throws { try await Task.sleep(for: .milliseconds(100)) }
}
