import Foundation
import Observation
import TokiAlerts
import TokiAutoSwap
import TokiCore
import TokiFixtures

extension Notification.Name {
    static let tokiAutoSwapEnabled = Notification.Name("tokiAutoSwapEnabled")
}

struct ProbeAccount {
    var accountUuid: String
    var label: String
    var isActive: Bool
    var healthy = true
    var fiveHour = 0.05
}

@MainActor
@Observable
final class AccountsViewModel {
    var accounts = [
        ProbeAccount(accountUuid: "active", label: "Active", isActive: true),
        ProbeAccount(accountUuid: "rested", label: "Rested", isActive: false),
    ]
    var activeAccountLimits = 0.10
    var runMode: RunMode = .live
    var refreshes = 0
    var reloads = 0
    var clearOnReload = false
    var evaluations = 0
    var swaps = 0
    var concurrentWork = 0
    var maximumConcurrentWork = 0
    var swapSucceeds = true
    var rotateFailures = false
    var attemptedTargets: [String] = []

    func reload() async {
        reloads += 1
        if clearOnReload { accounts = [] }
    }

    func refreshGauges() async {
        refreshes += 1
        concurrentWork += 1
        maximumConcurrentWork = max(maximumConcurrentWork, concurrentWork)
        try? await Task.sleep(for: .milliseconds(80))
        concurrentWork -= 1
    }

    func snapshotsForPolicy() -> [AccountSnapshot] {
        evaluations += 1
        return accounts.map { row in
            AccountSnapshot(
                accountUuid: row.accountUuid,
                label: row.label,
                fiveHour: row.isActive ? activeAccountLimits : row.fiveHour,
                weekly: 0.10,
                isActive: row.isActive,
                isHealthy: row.healthy,
                gaugesAreStale: false,
                activeBindingMatches: row.isActive ? true : nil
            )
        }
    }

    func swap(to target: String) async -> Bool {
        swaps += 1
        attemptedTargets.append(target)
        concurrentWork += 1
        maximumConcurrentWork = max(maximumConcurrentWork, concurrentWork)
        try? await Task.sleep(for: .milliseconds(80))
        if swapSucceeds {
            for index in accounts.indices { accounts[index].isActive = accounts[index].accountUuid == target }
        } else {
            // Match the real failed-swap path: reload rows and force a live poll, both of
            // which mutate values observed by the driver.
            accounts[1].label = "Refused \(swaps)"
            activeAccountLimits += 0.000_001
            if rotateFailures, target == "rested" {
                accounts[1].healthy = false
            } else if rotateFailures, target == "third" {
                accounts[1].healthy = true
                accounts[2].healthy = false
            }
        }
        concurrentWork -= 1
        return swapSucceeds
    }
}

struct SwapNotifier: Sendable {
    func notifyAllExhausted(provider: UsageProvider = .claudeCode) {}
    func notifyNeedsReauth(label: String, provider: UsageProvider = .claudeCode) {}
    func notifySwap(from: String?, to: String, trigger: SwapTrigger?, provider: UsageProvider = .claudeCode) {}
}

@MainActor
private func eventually(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<100 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return false
}

@main
struct AutoSwapDriverProbe {
    @MainActor
    static func main() async {
        var configured = AutoSwapSettings.default
        configured.enabled = true
        configured.cooldown = 300
        var clock = Date(timeIntervalSince1970: 1_700_000_000)

        let accounts = AccountsViewModel()
        let driver = AutoSwapDriver(
            accounts: accounts, notifier: SwapNotifier(), settings: { configured }, now: { clock }
        )
        driver.start()
        guard await eventually({ accounts.refreshes == 1 && accounts.evaluations >= 1 }) else {
            fatalError("initial periodic candidate refresh did not complete")
        }

        let baseline = accounts.evaluations
        accounts.activeAccountLimits = 0.99
        accounts.activeAccountLimits = 0.995
        accounts.activeAccountLimits = 0.99
        guard await eventually({ accounts.swaps == 1 }) else {
            fatalError("fresh active limits did not promptly trigger a swap")
        }
        guard accounts.evaluations > baseline else { fatalError("live change did not evaluate policy") }
        guard accounts.maximumConcurrentWork == 1 else { fatalError("driver evaluations overlapped") }
        try? await Task.sleep(for: .milliseconds(200))
        guard accounts.swaps == 1 else { fatalError("coalesced wakeups caused duplicate swaps") }
        guard accounts.refreshes == 1 else { fatalError("live-only wakeup refreshed inactive candidates") }
        accounts.activeAccountLimits = 0.991
        try? await Task.sleep(for: .milliseconds(150))
        guard accounts.swaps == 1 else { fatalError("cooldown allowed an immediate reverse swap") }

        let beforeCandidateChange = accounts.evaluations
        accounts.accounts[1].label = "Rested renamed"
        guard await eventually({ accounts.evaluations > beforeCandidateChange }) else {
            fatalError("independently refreshed candidate rows did not trigger evaluation")
        }

        clock = clock.addingTimeInterval(181)
        let refreshesBeforeAgedWake = accounts.refreshes
        accounts.activeAccountLimits = 0.992
        guard await eventually({ accounts.refreshes > refreshesBeforeAgedWake }) else {
            fatalError("aged candidate data was used without refresh")
        }
        guard await eventually({ accounts.concurrentWork == 0 }) else {
            fatalError("aged-candidate refresh did not settle")
        }
        let settledEvaluations = accounts.evaluations
        try? await Task.sleep(for: .milliseconds(150))
        guard accounts.evaluations == settledEvaluations else {
            fatalError("observing candidate rows created a self-trigger loop")
        }

        let beforeStop = accounts.evaluations
        driver.stop()
        accounts.activeAccountLimits = 0.98
        try? await Task.sleep(for: .milliseconds(100))
        guard accounts.evaluations == beforeStop else { fatalError("stopped driver still observed live limits") }

        let fixtureAccounts = AccountsViewModel()
        fixtureAccounts.runMode = .fixture(.fresh)
        let fixtureDriver = AutoSwapDriver(
            accounts: fixtureAccounts, notifier: SwapNotifier(), settings: { configured }, now: { clock }
        )
        fixtureDriver.start()
        try? await Task.sleep(for: .milliseconds(100))
        fixtureDriver.stop()
        guard fixtureAccounts.refreshes == 0 && fixtureAccounts.swaps == 0 else {
            fatalError("fixture mode reached live autoswap work")
        }

        let emptyAccounts = AccountsViewModel()
        emptyAccounts.clearOnReload = true
        let emptyDriver = AutoSwapDriver(
            accounts: emptyAccounts, notifier: SwapNotifier(), settings: { configured }, now: { clock }
        )
        emptyDriver.start()
        try? await Task.sleep(for: .milliseconds(250))
        emptyDriver.stop()
        guard emptyAccounts.reloads == 1 else {
            fatalError("empty reload observation looped \(emptyAccounts.reloads) times")
        }

        let refusingAccounts = AccountsViewModel()
        refusingAccounts.activeAccountLimits = 0.99
        refusingAccounts.swapSucceeds = false
        let refusingDriver = AutoSwapDriver(
            accounts: refusingAccounts, notifier: SwapNotifier(), settings: { configured }, now: { clock }
        )
        refusingDriver.start()
        guard await eventually({ refusingAccounts.swaps == 1 }) else {
            fatalError("persistent-failure setup did not attempt a swap")
        }
        try? await Task.sleep(for: .milliseconds(250))
        guard refusingAccounts.swaps == 1 else {
            fatalError("failed-swap feedback retried \(refusingAccounts.swaps) times")
        }
        clock = clock.addingTimeInterval(181)
        refusingAccounts.activeAccountLimits += 0.000_001
        guard await eventually({ refusingAccounts.swaps == 2 }) else {
            fatalError("failed-swap backoff did not re-arm after 180 seconds")
        }
        refusingDriver.stop()

        let rotatingAccounts = AccountsViewModel()
        rotatingAccounts.accounts.append(
            ProbeAccount(
                accountUuid: "third", label: "Third", isActive: false, fiveHour: 0.06
            )
        )
        rotatingAccounts.activeAccountLimits = 0.99
        rotatingAccounts.swapSucceeds = false
        rotatingAccounts.rotateFailures = true
        let rotatingDriver = AutoSwapDriver(
            accounts: rotatingAccounts, notifier: SwapNotifier(), settings: { configured }, now: { clock }
        )
        rotatingDriver.start()
        guard await eventually({ rotatingAccounts.swaps >= 2 }) else {
            fatalError("multi-target fallback did not reach the second candidate")
        }
        try? await Task.sleep(for: .milliseconds(200))
        rotatingDriver.stop()
        guard rotatingAccounts.attemptedTargets == ["rested", "third"] else {
            fatalError("same pass retried a backed-off target: \(rotatingAccounts.attemptedTargets)")
        }

        print("autoswap-driver probe passed: prompt=1 swaps=1 maxConcurrent=1 agedRefresh=1 noLoop=1 emptyNoLoop=1 failureBackoff=1 fixtureGuard=1")
    }
}
