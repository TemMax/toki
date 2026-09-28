import Testing
import Foundation
@testable import TokiProcesses

@Suite("SignalTerminator")
struct SignalTerminatorTests {

    /// Spawns a real `/bin/sleep`, SIGTERMs it, and asserts it actually exits.
    @Test("terminate kills a live child process")
    func terminatesLiveProcess() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()

        let terminator = SignalTerminator()
        #expect(terminator.terminate(pid: process.processIdentifier) == true)

        // /bin/sleep doesn't trap SIGTERM, so the default action terminates it.
        process.waitUntilExit()
        #expect(process.isRunning == false)
    }

    /// A pid that has already exited yields ESRCH → false.
    @Test("terminate returns false for a dead pid")
    func returnsFalseForDeadProcess() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        let pid = process.processIdentifier

        let terminator = SignalTerminator()
        #expect(terminator.terminate(pid: pid) == true)
        process.waitUntilExit()

        // Second signal to the now-reaped pid must fail.
        #expect(terminator.terminate(pid: pid) == false)
    }
}
