import Testing
import Foundation
@testable import TokiKeychain

@Suite("KeychainItemRef")
struct KeychainItemRefTests {

    @Test("select prefers the exact service name over prefixed variants")
    func selectPrefersExactService() {
        let candidates = [
            KeychainItemRef(service: "Claude Code-credentials-profile2", account: "a", modifiedAt: 200),
            KeychainItemRef(service: "Claude Code-credentials", account: "a", modifiedAt: 100),
        ]
        #expect(KeychainItemRef.select(from: candidates)?.service == "Claude Code-credentials")
    }

    @Test("select is order-independent for prefixed variants")
    func selectIsDeterministic() {
        let a = KeychainItemRef(service: "Claude Code-credentials-b", account: "u", modifiedAt: 1)
        let b = KeychainItemRef(service: "Claude Code-credentials-a", account: "u", modifiedAt: 2)
        #expect(KeychainItemRef.select(from: [a, b]) == KeychainItemRef.select(from: [b, a]))
        #expect(KeychainItemRef.select(from: [a, b])?.service == "Claude Code-credentials-a")
    }

    @Test("select breaks account ties lexicographically")
    func selectBreaksAccountTies() {
        let a = KeychainItemRef(service: "Claude Code-credentials", account: "zoe", modifiedAt: 1)
        let b = KeychainItemRef(service: "Claude Code-credentials", account: "amy", modifiedAt: 2)
        #expect(KeychainItemRef.select(from: [a, b])?.account == "amy")
    }

    @Test("select returns nil when nothing matches")
    func selectReturnsNilForEmpty() {
        #expect(KeychainItemRef.select(from: []) == nil)
    }

    @Test("from(attributes:) keeps only Claude Code items and reads their modification date")
    func fromAttributesFiltersByPrefix() {
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        let attributes: [[CFString: Any]] = [
            [kSecAttrService: "Slack", kSecAttrAccount: "u", kSecAttrModificationDate: when],
            [kSecAttrService: "Claude Code-credentials", kSecAttrAccount: "u", kSecAttrModificationDate: when],
            [kSecAttrService: "Claude Code-credentials-alt", kSecAttrAccount: "u"],  // no mdat
        ]
        let refs = KeychainItemRef.from(attributes: attributes)
        #expect(refs.count == 2)
        #expect(refs.allSatisfy { $0.service.hasPrefix(KeychainItemRef.claudeServicePrefix) })
        #expect(refs.first(where: { $0.service == "Claude Code-credentials" })?.modifiedAt == 1_700_000_000)
        // A missing modification date must not drop the item; it sorts as epoch 0.
        #expect(refs.first(where: { $0.service == "Claude Code-credentials-alt" })?.modifiedAt == 0)
    }
}
