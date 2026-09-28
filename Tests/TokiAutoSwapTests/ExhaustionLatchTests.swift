import Testing
import Foundation
@testable import TokiAutoSwap

private let trigger = SwapTrigger(window: .fiveHour, utilization: 0.95)

@Suite("ExhaustionLatch")
struct ExhaustionLatchTests {

    @Test("the all-exhausted notification fires once, not on every poll")
    func notifiesOnce() {
        var latch = ExhaustionLatch()
        // `latch.shouldNotify` is mutating, so its result is bound to a local `let`
        // before being handed to `#expect` — the macro's argument-capture expansion
        // cannot call a mutating member through its immutable closure parameter.
        let first = latch.shouldNotify(decision: .allExhausted(trigger))
        let second = latch.shouldNotify(decision: .allExhausted(trigger))
        let third = latch.shouldNotify(decision: .allExhausted(trigger))
        #expect(first)
        #expect(!second)
        #expect(!third)
    }

    @Test("it re-arms once the situation improves")
    func reArmsAfterRecovery() {
        var latch = ExhaustionLatch()
        let first = latch.shouldNotify(decision: .allExhausted(trigger))
        #expect(first)
        _ = latch.shouldNotify(decision: .doNothing)
        let third = latch.shouldNotify(decision: .allExhausted(trigger))
        #expect(third)
    }

    @Test("a successful swap also re-arms it")
    func swapReArms() {
        var latch = ExhaustionLatch()
        let first = latch.shouldNotify(decision: .allExhausted(trigger))
        #expect(first)
        _ = latch.shouldNotify(decision: .swap(to: "b", trigger: trigger))
        let third = latch.shouldNotify(decision: .allExhausted(trigger))
        #expect(third)
    }
}
