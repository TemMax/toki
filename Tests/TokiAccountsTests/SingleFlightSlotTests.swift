import Testing
import Foundation
@testable import TokiAccounts

@Suite("SingleFlightSlot")
struct SingleFlightSlotTests {

    @Test("a free slot is claimed, a held one refuses the second caller")
    func refusesWhileHeld() {
        var slot = SingleFlightSlot<String>()
        let claimed = slot.begin("a")
        #expect(claimed)
        #expect(slot.current == "a")

        // The swap case: a second request must be refused outright, not queued behind a
        // decision made from gauges that are already out of date.
        let refused = slot.begin("b")
        #expect(refused == false)
        #expect(slot.current == "a")
        // Same target, same answer — one transaction at a time.
        let refusedSameTarget = slot.begin("a")
        #expect(refusedSameTarget == false)
        #expect(slot.current == "a")
    }

    @Test("only the holder can release the slot")
    func releaseIsOwnershipChecked() {
        var slot = SingleFlightSlot<String>()
        let claimed = slot.begin("a")
        #expect(claimed)

        // The loser of the race clearing the winner's marker is what re-enabled the UI
        // mid-swap: the row's spinner stopped and a second swap became clickable while the
        // first transaction still held every Claude Code lock.
        slot.end("b")
        #expect(slot.current == "a")

        slot.end("a")
        #expect(slot.current == nil)
    }

    @Test("a released slot can be claimed again")
    func reclaimAfterRelease() {
        var slot = SingleFlightSlot<String>()
        let claimed = slot.begin("a")
        #expect(claimed)
        slot.end("a")
        let reclaimed = slot.begin("b")
        #expect(reclaimed)
        #expect(slot.current == "b")
    }

    @Test("joining never starts a second run")
    func joinDoesNotStartASecondRun() {
        var slot = SingleFlightSlot<Int>()
        var started = 0
        func make() -> Int {
            started += 1
            return started
        }

        let first = slot.beginOrJoin(make)
        #expect(first.run == 1)
        #expect(first.isOwner)

        // The gauge-refresh case: three callers (the Accounts tab appearing, the dashboard
        // Refresh button, the auto-swap tick) can arrive together. The joiners must await
        // the run in flight; a second run would hand the refresher slots read before this
        // one rewrote them.
        let second = slot.beginOrJoin(make)
        let third = slot.beginOrJoin(make)
        #expect(second.run == 1)
        #expect(second.isOwner == false)
        #expect(third.run == 1)
        #expect(third.isOwner == false)
        #expect(started == 1)

        // Only the owner ends the run; the next caller then starts a genuinely new one.
        slot.end(first.run)
        let fourth = slot.beginOrJoin(make)
        #expect(fourth.run == 2)
        #expect(fourth.isOwner)
        #expect(started == 2)
    }
}
