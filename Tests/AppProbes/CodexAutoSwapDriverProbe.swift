import Foundation
import Observation
import TokiAlerts
import TokiAutoSwap
import TokiCore
import TokiFixtures

extension Notification.Name {
    static let tokiAutoSwapEnabled = Notification.Name("tokiAutoSwapEnabled")
}

struct ProbeRow {
    var accountUuid: String
    var label: String
    var isActive: Bool
    var healthy = true
    var usage = 0.05
}

@MainActor
@Observable
final class CodexAccountsViewModel {
    var accounts = [
        ProbeRow(accountUuid: "active", label: "Active", isActive: true),
        ProbeRow(accountUuid: "rested", label: "Rested", isActive: false),
    ]
    var activeAccountLimits = 0.10
    var activeAccountLimitsState = 0
    var runMode: RunMode = .live
    var refreshes = 0
    var evaluations = 0
    var swaps = 0
    var concurrent = 0
    var maximumConcurrent = 0
    var emptyOnRefresh = false
    var swapSucceeds = true
    var rotateFailures = false
    var attempted: [String] = []

    func refreshGauges() async {
        refreshes += 1
        concurrent += 1
        maximumConcurrent = max(maximumConcurrent, concurrent)
        try? await Task.sleep(for: .milliseconds(50))
        if emptyOnRefresh { accounts = [] }
        concurrent -= 1
    }
    func snapshotsForPolicy(now: Date = Date()) -> [AccountSnapshot] {
        evaluations += 1
        return accounts.map { row in
            AccountSnapshot(
                accountUuid: row.accountUuid, label: row.label,
                fiveHour: row.isActive ? activeAccountLimits : row.usage, weekly: 0.1,
                isActive: row.isActive, isHealthy: row.healthy, gaugesAreStale: false,
                activeBindingMatches: row.isActive ? true : nil)
        }
    }
    func swap(to target: String) async -> Bool {
        swaps += 1
        attempted.append(target)
        concurrent += 1
        maximumConcurrent = max(maximumConcurrent, concurrent)
        try? await Task.sleep(for: .milliseconds(50))
        if swapSucceeds {
            for i in accounts.indices { accounts[i].isActive = accounts[i].accountUuid == target }
        } else {
            activeAccountLimits += 0.000_001
            activeAccountLimitsState += 1
            if rotateFailures, target == "rested" {
                accounts[1].healthy = false
            } else if rotateFailures, target == "third" {
                accounts[1].healthy = true
                accounts[2].healthy = false
            }
        }
        concurrent -= 1
        return swapSucceeds
    }
}

struct SwapNotifier: Sendable {
    func notifyAllExhausted(provider: UsageProvider = .claudeCode) {}
    func notifyNeedsReauth(label: String, provider: UsageProvider = .claudeCode) {}
    func notifySwap(
        from: String?, to: String, trigger: SwapTrigger?, provider: UsageProvider = .claudeCode
    ) {}
}

@MainActor private func eventually(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<100 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return false
}

@main
struct CodexAutoSwapDriverProbe {
    @MainActor static func main() async {
        var settings = AutoSwapSettings.default
        settings.enabled = true
        settings.cooldown = 300
        var clock = Date(timeIntervalSince1970: 1_700_000_000)
        let accounts = CodexAccountsViewModel()
        let driver = CodexAutoSwapDriver(
            accounts: accounts, notifier: SwapNotifier(), settings: { settings }, now: { clock })
        driver.start()
        guard await eventually({ accounts.refreshes == 1 && accounts.evaluations > 0 }) else {
            fatalError("initial refresh missing")
        }
        let baseline = accounts.evaluations
        accounts.activeAccountLimits = 0.99
        accounts.activeAccountLimitsState += 1
        accounts.activeAccountLimits = 0.995
        guard await eventually({ accounts.swaps == 1 }) else {
            fatalError("fresh limits did not promptly swap")
        }
        guard accounts.evaluations > baseline && accounts.maximumConcurrent == 1 else {
            fatalError("events overlapped or were lost")
        }
        try? await Task.sleep(for: .milliseconds(120))
        guard accounts.swaps == 1 && accounts.refreshes == 1 else {
            fatalError("event burst duplicated work")
        }
        clock = clock.addingTimeInterval(181)
        let oldRefreshes = accounts.refreshes
        accounts.activeAccountLimits += 0.001
        guard await eventually({ accounts.refreshes > oldRefreshes }) else {
            fatalError("aged candidates were not refreshed")
        }
        driver.stop()
        let stopped = accounts.evaluations
        accounts.activeAccountLimits += 0.001
        try? await Task.sleep(for: .milliseconds(80))
        guard accounts.evaluations == stopped else { fatalError("stop leaked observation") }

        let empty = CodexAccountsViewModel()
        empty.emptyOnRefresh = true
        let emptyDriver = CodexAutoSwapDriver(
            accounts: empty, notifier: SwapNotifier(), settings: { settings }, now: { clock })
        emptyDriver.start()
        try? await Task.sleep(for: .milliseconds(180))
        emptyDriver.stop()
        guard empty.refreshes == 1 else {
            fatalError("empty refresh looped \(empty.refreshes) times")
        }

        let refusing = CodexAccountsViewModel()
        refusing.activeAccountLimits = 0.99
        refusing.swapSucceeds = false
        let refusingDriver = CodexAutoSwapDriver(
            accounts: refusing, notifier: SwapNotifier(), settings: { settings }, now: { clock })
        refusingDriver.start()
        guard await eventually({ refusing.swaps == 1 }) else { fatalError("refusal setup missing") }
        try? await Task.sleep(for: .milliseconds(180))
        guard refusing.swaps == 1 else { fatalError("refusal feedback looped") }
        clock = clock.addingTimeInterval(181)
        refusing.activeAccountLimitsState += 1
        guard await eventually({ refusing.swaps == 2 }) else {
            fatalError("refusal backoff did not rearm")
        }
        refusingDriver.stop()

        let rotating = CodexAccountsViewModel()
        rotating.accounts.append(
            ProbeRow(accountUuid: "third", label: "Third", isActive: false, usage: 0.06))
        rotating.activeAccountLimits = 0.99
        rotating.swapSucceeds = false
        rotating.rotateFailures = true
        let rotatingDriver = CodexAutoSwapDriver(
            accounts: rotating, notifier: SwapNotifier(), settings: { settings }, now: { clock })
        rotatingDriver.start()
        guard await eventually({ rotating.swaps >= 2 }) else { fatalError("fallback missing") }
        try? await Task.sleep(for: .milliseconds(160))
        rotatingDriver.stop()
        guard rotating.attempted == ["rested", "third"] else {
            fatalError("backed-off target retried \(rotating.attempted)")
        }

        let fixture = CodexAccountsViewModel()
        fixture.runMode = .fixture(.fresh)
        let fixtureDriver = CodexAutoSwapDriver(
            accounts: fixture, notifier: SwapNotifier(), settings: { settings }, now: { clock })
        fixtureDriver.start()
        try? await Task.sleep(for: .milliseconds(80))
        fixtureDriver.stop()
        guard fixture.refreshes == 0 && fixture.swaps == 0 else {
            fatalError("fixture touched live work")
        }
        print(
            "codex-autoswap-driver probe passed: prompt=1 coalesced=1 agedRefresh=1 emptyNoLoop=1 failureBackoff=1 fixtureStop=1"
        )
    }
}
