import Foundation
import TokiCore
import TokiFixtures

private final class CountingSamples: SpeedSampleProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var gate: CheckedContinuation<Void, Never>?
    var holdNext = false
    private var lastAt: ContinuousClock.Instant?
    var lastCallAt: ContinuousClock.Instant? { lock.withLock { lastAt } }
    var callCount: Int { lock.withLock { calls } }
    func release() { lock.withLock { gate }?.resume(); lock.withLock { gate = nil } }
    func speedSamples() async throws -> SpeedSamples {
        let hold = lock.withLock { calls += 1; lastAt = .now; return holdNext }
        if hold { await withCheckedContinuation { c in lock.withLock { gate = c } } }
        var s = SpeedSamples.empty
        s.groups = [SpeedSampleGroup(model: "claude-opus-5-5", effort: "high", isFast: false)]
        for i in 0..<20 {
            s.group.append(0); s.timestampMs.append(1_790_899_200_000 + Int64(i) * 1_000)
            s.outputTokens.append(500); s.generationMs.append(10_000)
        }
        return s
    }
}

/// Counts every read and write of the hidden-models key. Used on the main actor only.
private final class CountingDefaults: UserDefaults, @unchecked Sendable {
    private(set) var reads = 0
    private(set) var writes = 0
    private func isHiddenModels(_ key: String) -> Bool { key == SpeedTableVisibilityStore.key }

    override func object(forKey defaultName: String) -> Any? {
        if isHiddenModels(defaultName) { reads += 1 }
        return super.object(forKey: defaultName)
    }
    override func array(forKey defaultName: String) -> [Any]? {
        if isHiddenModels(defaultName) { reads += 1 }
        return super.array(forKey: defaultName)
    }
    override func stringArray(forKey defaultName: String) -> [String]? {
        if isHiddenModels(defaultName) { reads += 1 }
        return super.stringArray(forKey: defaultName)
    }
    override func set(_ value: Any?, forKey defaultName: String) {
        if isHiddenModels(defaultName) { writes += 1 }
        super.set(value, forKey: defaultName)
    }
    override func removeObject(forKey defaultName: String) {
        if isHiddenModels(defaultName) { writes += 1 }
        super.removeObject(forKey: defaultName)
    }
}

/// Set once `waitForIdle()` returns; read by the watchdog on another queue.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

/// `waitForIdle()` that fails the probe instead of hanging. The watchdog runs off the main
/// actor, so it fires even when a stuck wait spins there.
@MainActor
private func waitForIdle(_ vm: SpeedViewModel, orFail message: String) async {
    let done = Flag()
    DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
        guard !done.isSet else { return }
        print("FAIL: \(message)")
        exit(1)
    }
    await vm.waitForIdle()
    done.set()
}

@main
struct SpeedViewModelProbe {
    @MainActor static func main() async {
        var failures: [String] = []
        // Printed as they happen, so a later watchdog exit cannot swallow an earlier failure.
        func require(_ ok: Bool, _ message: String) { if !ok { failures.append(message); print("FAIL: \(message)") } }

        let source = CountingSamples()
        let vm = SpeedViewModel(samples: source, minimumInterval: .zero)

        vm.indexDidChange()
        await vm.waitForIdle()
        require(source.callCount == 0, "a hidden tab must not query the index")

        vm.isVisible = true
        await vm.waitForIdle()
        require(source.callCount == 1, "becoming visible with a stale report must query once")
        require(vm.report?.groups.count == 1, "the report must be published")

        vm.isVisible = false; vm.isVisible = true
        await vm.waitForIdle()
        require(source.callCount == 1, "re-showing an up-to-date report must not query again")

        source.holdNext = true
        vm.indexDidChange()
        try? await Task.sleep(for: .milliseconds(50))
        require(vm.report != nil, "the previous report stays on screen while recomputing")
        vm.indexDidChange(); vm.indexDidChange()   // bursts during a pass coalesce
        source.holdNext = false
        source.release()
        await vm.waitForIdle()
        require(source.callCount == 3, "a burst during a recompute is one more query, got \(source.callCount)")

        // Hidden mid-recompute with a re-run owed: the re-run must wait for the next appearance.
        source.holdNext = true
        vm.indexDidChange()
        try? await Task.sleep(for: .milliseconds(50))
        vm.indexDidChange()                        // owes a re-run
        vm.isVisible = false
        source.holdNext = false
        source.release()
        await vm.waitForIdle()
        require(source.callCount == 4, "a re-run owed while hidden must not query, got \(source.callCount)")
        vm.isVisible = true
        await vm.waitForIdle()
        require(source.callCount == 5, "the owed re-run must run once on the next appearance, got \(source.callCount)")

        let fixture = SpeedViewModel(samples: source, minimumInterval: .zero)
        fixture.runMode = .fixture(.singleAccount)
        fixture.isVisible = true
        fixture.indexDidChange()
        await fixture.waitForIdle()
        require(source.callCount == 5, "fixture mode must never touch the index")

        // A live compute that lands after a switch to a fixture must not replace the injected report.
        let switched = SpeedViewModel(samples: source, minimumInterval: .zero)
        switched.isVisible = true
        await switched.waitForIdle()
        source.holdNext = true
        switched.indexDidChange()
        try? await Task.sleep(for: .milliseconds(50))
        switched.runMode = .fixture(.singleAccount)
        switched.inject(.empty)
        source.holdNext = false
        source.release()
        await waitForIdle(switched, orFail: "waitForIdle must return after a fixture switch mid-compute")
        require(switched.report == .empty,
                "a live compute finishing after a fixture switch must not overwrite the injected report, got \(switched.report?.groups.count ?? -1) groups")

        // An owed re-run that `start()` declines (fixture mode) must still leave the model idle.
        let owed = SpeedViewModel(samples: source, minimumInterval: .zero)
        owed.isVisible = true
        await owed.waitForIdle()
        source.holdNext = true
        owed.indexDidChange()
        try? await Task.sleep(for: .milliseconds(50))
        owed.indexDidChange()                      // owes a re-run
        owed.runMode = .fixture(.singleAccount)
        source.holdNext = false
        source.release()
        await waitForIdle(owed, orFail: "an owed re-run declined by start() must leave task nil so waitForIdle returns")
        require(!owed.isComputing, "the model must be idle after a declined re-run")

        // Throttle: index-driven recomputes start at most once per `minimumInterval`.
        let window = Duration.milliseconds(300)
        let throttled = CountingSamples()
        let tvm = SpeedViewModel(samples: throttled, minimumInterval: window)
        tvm.isVisible = true                       // first computation is never throttled
        await tvm.waitForIdle()
        require(throttled.callCount == 1, "the first computation on appearing must not be throttled, got \(throttled.callCount)")
        let windowStart = ContinuousClock.now
        tvm.indexDidChange(); tvm.indexDidChange()
        try? await Task.sleep(for: .milliseconds(100))
        await tvm.waitForIdle()
        require(throttled.callCount == 1, "index changes inside the window must not query yet, got \(throttled.callCount)")
        try? await Task.sleep(for: .milliseconds(400))
        await tvm.waitForIdle()
        require(throttled.callCount == 2, "two index changes inside the window are exactly one trailing query, got \(throttled.callCount)")
        require(throttled.lastCallAt.map { $0 - windowStart >= window } ?? false,
                "the trailing query must start after the window elapsed")
        try? await Task.sleep(for: .milliseconds(400))
        await tvm.waitForIdle()
        require(throttled.callCount == 2, "no further query without a further change, got \(throttled.callCount)")

        // refresh() is not throttled and resets the interval.
        tvm.indexDidChange()                       // outside the window: starts now
        await tvm.waitForIdle()
        require(throttled.callCount == 3, "an index change after the window starts at once, got \(throttled.callCount)")
        tvm.refresh()
        await tvm.waitForIdle()
        require(throttled.callCount == 4, "refresh() inside the window must query at once, got \(throttled.callCount)")
        tvm.indexDidChange()                       // window restarted by refresh()
        try? await Task.sleep(for: .milliseconds(100))
        await tvm.waitForIdle()
        require(throttled.callCount == 4, "refresh() must reset the interval, got \(throttled.callCount)")
        // refresh() also supersedes the pending trailing query.
        tvm.refresh()
        await tvm.waitForIdle()
        try? await Task.sleep(for: .milliseconds(500))
        await tvm.waitForIdle()
        require(throttled.callCount == 5, "refresh() replaces the pending trailing query, got \(throttled.callCount)")

        // Hiding inside the window cancels the pending query; the next appearance computes once.
        tvm.refresh()                              // opens a fresh window
        await tvm.waitForIdle()
        require(throttled.callCount == 6, "refresh() starts a query, got \(throttled.callCount)")
        tvm.indexDidChange()
        tvm.isVisible = false
        try? await Task.sleep(for: .milliseconds(500))
        await tvm.waitForIdle()
        require(throttled.callCount == 6, "hiding must cancel the pending trailing query, got \(throttled.callCount)")
        tvm.isVisible = true
        await tvm.waitForIdle()
        require(throttled.callCount == 7, "the next appearance computes once, got \(throttled.callCount)")
        try? await Task.sleep(for: .milliseconds(400))
        await tvm.waitForIdle()
        require(throttled.callCount == 7, "no stray trailing query after re-showing, got \(throttled.callCount)")

        // Model visibility: saved while live, never read or written on fixtures. A private
        // defaults domain, removed below — never `.standard`.
        let suite = "dev.komar.toki.probe.speed-visibility.\(UUID().uuidString)"
        guard let defaults = CountingDefaults(suiteName: suite) else {
            print("FAIL: could not open the private defaults domain \(suite)")
            exit(1)
        }
        let store = SpeedTableVisibilityStore(defaults: defaults)

        let first = SpeedViewModel(samples: source, minimumInterval: .zero, visibility: store)
        require(defaults.reads == 0 && defaults.writes == 0,
                "constructing a view model must not touch the defaults: a fixture may be applied right after, got \(defaults.reads) reads, \(defaults.writes) writes")
        require(first.hiddenModels.isEmpty, "nothing is hidden before the user hides a model")
        first.setModel("claude-opus-5-5", hidden: true)
        first.setModel("gpt-6-sol", hidden: true)
        first.setModel("gpt-6-sol", hidden: false)
        require(first.hiddenModels == ["claude-opus-5-5"], "hide, hide, show leaves one model hidden, got \(first.hiddenModels.sorted())")
        // The positive control for the fixture checks below: a live model does read and write.
        require(defaults.reads > 0 && defaults.writes == 3,
                "a live view model reads the set once and saves each change, got \(defaults.reads) reads, \(defaults.writes) writes")
        let writesAfterChanges = defaults.writes
        first.setModel("claude-opus-5-5", hidden: true)
        require(defaults.writes == writesAfterChanges, "hiding a hidden model again must not save, got \(defaults.writes - writesAfterChanges) writes")

        let second = SpeedViewModel(samples: source, minimumInterval: .zero, visibility: store)
        require(second.hiddenModels == ["claude-opus-5-5"],
                "a hidden model must persist through a second view model on the same store, got \(second.hiddenModels.sorted())")

        // The set is observable: a view reading it is told when it changes.
        let observed = Flag()
        withObservationTracking { _ = second.hiddenModels } onChange: { observed.set() }
        second.setModel("gpt-6-luna", hidden: true)
        require(observed.isSet, "changing the hidden set must notify its observers")
        require(SpeedViewModel(samples: source, minimumInterval: .zero, visibility: store).hiddenModels == ["claude-opus-5-5", "gpt-6-luna"],
                "every change is saved")

        // Fixture mode: starts empty whatever the store holds, stays in memory, never touches it.
        let fixtureModel = SpeedViewModel(samples: source, minimumInterval: .zero, visibility: store)
        fixtureModel.runMode = .fixture(.singleAccount)
        let (readsBefore, writesBefore) = (defaults.reads, defaults.writes)
        require(fixtureModel.hiddenModels.isEmpty,
                "fixture mode must start with nothing hidden even when the store has hidden models, got \(fixtureModel.hiddenModels.sorted())")
        fixtureModel.setModel("claude-opus-5-5", hidden: true)
        fixtureModel.setModel("claude-sonnet-5-5", hidden: true)
        require(fixtureModel.hiddenModels == ["claude-opus-5-5", "claude-sonnet-5-5"],
                "fixture mode keeps its hidden set in memory, got \(fixtureModel.hiddenModels.sorted())")
        fixtureModel.setModel("claude-opus-5-5", hidden: false)
        fixtureModel.showAllModels()
        require(fixtureModel.hiddenModels.isEmpty, "showAllModels() clears the fixture set")
        fixtureModel.setModel("claude-fable-5-1", hidden: true)
        require(defaults.reads == readsBefore, "fixture mode must never read the defaults, got \(defaults.reads - readsBefore) reads")
        require(defaults.writes == writesBefore, "fixture mode must never write the defaults, got \(defaults.writes - writesBefore) writes")
        require(store.load() == ["claude-opus-5-5", "gpt-6-luna"], "fixture mode must leave the saved set as it was, got \(store.load().sorted())")

        // Back to live: the saved set again, and nothing the fixture hid.
        fixtureModel.runMode = .live
        require(fixtureModel.hiddenModels == ["claude-opus-5-5", "gpt-6-luna"],
                "returning to live shows the saved set, got \(fixtureModel.hiddenModels.sorted())")
        fixtureModel.runMode = .fixture(.heavy)
        require(fixtureModel.hiddenModels.isEmpty, "every fixture starts with nothing hidden")

        second.showAllModels()
        require(second.hiddenModels.isEmpty, "showAllModels() shows every model")
        require(SpeedViewModel(samples: source, minimumInterval: .zero, visibility: store).hiddenModels.isEmpty,
                "showAllModels() is saved")
        defaults.removePersistentDomain(forName: suite)

        guard failures.isEmpty else { exit(1) }
        print("PASS: SpeedViewModel queries only while visible, coalesces bursts, throttles index-driven recomputes, keeps the last report, persists hidden models while live and never touches the defaults on fixtures")
    }
}
