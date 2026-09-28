import Testing
import Foundation
@testable import TokiKeychain

private func credentialJSON(token: String, expiresAtMs: Double? = 1_700_003_600_000) -> Data {
    var inner: [String: Any] = ["accessToken": token]
    if let ms = expiresAtMs { inner["expiresAt"] = ms }
    return try! JSONSerialization.data(withJSONObject: ["claudeAiOauth": inner])
}

private let expiry = Date(timeIntervalSince1970: 1_700_003_600)
private let refV1 = KeychainItemRef(service: "Claude Code-credentials", account: "u", modifiedAt: 100)
private let refV2 = KeychainItemRef(service: "Claude Code-credentials", account: "u", modifiedAt: 200)

/// Counts calls so the tests can assert that memoization actually suppresses reads.
private final class LadderSpy: @unchecked Sendable {
    var refs: [KeychainItemRef] = [refV1]
    var silentData: Data?
    var cliData: Data?
    var silentReads = 0
    var cliReads = 0
}

private func makeLadder(_ spy: LadderSpy) -> SilentLadder {
    SilentLadder(
        enumerate: { spy.refs },
        silentRead: { _ in spy.silentReads += 1; return spy.silentData },
        cliRead: { _, _ in spy.cliReads += 1; return spy.cliData }
    )
}

@Suite("SilentLadder")
struct SilentLadderTests {

    @Test("step (a) alone satisfies the read; the subprocess is never spawned")
    func silentReadWins() async {
        let spy = LadderSpy()
        spy.silentData = credentialJSON(token: "tok-a")
        let result = await makeLadder(spy).run(context: .background, force: false)
        #expect(result == .harvested(token: "tok-a", expiresAt: expiry, from: refV1))
        #expect(spy.cliReads == 0)
    }

    @Test("falls through to the subprocess when the silent read is refused")
    func fallsThroughToCLI() async {
        let spy = LadderSpy()
        spy.silentData = nil
        spy.cliData = credentialJSON(token: "tok-b")
        let result = await makeLadder(spy).run(context: .userInitiated, force: false)
        #expect(result == .harvested(token: "tok-b", expiresAt: expiry, from: refV1))
        #expect(spy.silentReads == 1)
        #expect(spy.cliReads == 1)
    }

    @Test("re-running for an unchanged mdat performs no reads at all")
    func memoizesByModificationDate() async {
        let spy = LadderSpy()
        spy.silentData = credentialJSON(token: "tok-a")
        let ladder = makeLadder(spy)
        _ = await ladder.run(context: .background, force: false)
        let second = await ladder.run(context: .background, force: false)
        #expect(second == .harvested(token: "tok-a", expiresAt: expiry, from: refV1))
        #expect(spy.silentReads == 1)   // not re-read
        #expect(spy.cliReads == 0)
    }

    @Test("a changed mdat re-runs the ladder")
    func changedModificationDateReRuns() async {
        let spy = LadderSpy()
        spy.silentData = credentialJSON(token: "tok-a")
        let ladder = makeLadder(spy)
        _ = await ladder.run(context: .background, force: false)

        spy.refs = [refV2]
        spy.silentData = credentialJSON(token: "tok-c")
        let result = await ladder.run(context: .background, force: false)
        #expect(result == .harvested(token: "tok-c", expiresAt: expiry, from: refV2))
        #expect(spy.silentReads == 2)
    }

    @Test("force re-runs even when the mdat is unchanged")
    func forceBypassesMemoization() async {
        let spy = LadderSpy()
        spy.silentData = credentialJSON(token: "tok-a")
        let ladder = makeLadder(spy)
        _ = await ladder.run(context: .background, force: false)
        _ = await ladder.run(context: .userInitiated, force: true)
        #expect(spy.silentReads == 2)
    }

    @Test("a blocked result is not memoized, so a later user-initiated run still tries")
    func blockedIsNotMemoized() async {
        let spy = LadderSpy()
        spy.silentData = nil
        spy.cliData = nil                       // background: gate refuses → blocked
        let ladder = makeLadder(spy)
        #expect(await ladder.run(context: .background, force: false) == .blocked)

        spy.cliData = credentialJSON(token: "tok-d")
        let result = await ladder.run(context: .userInitiated, force: false)
        #expect(result == .harvested(token: "tok-d", expiresAt: expiry, from: refV1))
    }

    @Test("a payload without claudeAiOauth reports the unsupported layout")
    func unsupportedLayoutIsDistinctFromNotFound() async {
        let spy = LadderSpy()
        spy.silentData = try! JSONSerialization.data(withJSONObject: ["mcpOAuth": ["x": 1]])
        #expect(await makeLadder(spy).run(context: .background, force: false) == .unsupportedLayout)
    }

    @Test("no Claude Code item at all reports notFound")
    func noItemReportsNotFound() async {
        let spy = LadderSpy()
        spy.refs = []
        #expect(await makeLadder(spy).run(context: .background, force: false) == .notFound)
    }

    @Test("currentSource exposes the deterministically selected item for change detection")
    func currentSourceIsSelected() async {
        let spy = LadderSpy()
        spy.refs = [refV2, refV1]
        #expect(await makeLadder(spy).currentSource() == refV2)  // ties break on service/account
    }
}
