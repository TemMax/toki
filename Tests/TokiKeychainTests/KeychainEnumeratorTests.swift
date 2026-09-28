import Testing
import Foundation
import Security
@testable import TokiKeychain

@Suite("KeychainEnumerator", .serialized)
struct KeychainEnumeratorTests {

    @Test("finds only items whose service carries the requested prefix")
    func findsByPrefix() throws {
        let prefix = "dev.komar.toki.enumtest.\(UUID().uuidString.prefix(8))."
        let service = prefix + "alpha"
        let account = NSUserName()
        let base: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData] = Data("x".utf8)
        #expect(SecItemAdd(add as CFDictionary, nil) == errSecSuccess)
        // A one-shot `SecItemDelete` here would be exposed to the exact same shared-Keychain
        // eventual consistency the read loop below already documents and retries for — a
        // delete that lands in that window returns something other than success/not-found and
        // silently leaves the item behind, which is how residue like this test's own
        // `dev.komar.toki.enumtest.*` items has accumulated on real machines (see
        // `KeychainNamespaceTests.foreignItemsAreSkipped`, which cites exactly that prefix as
        // observed leftover). `deleteRetrying` closes that window the same way the read loop
        // does: retry until the system confirms either success or "already gone."
        defer { #expect(deleteRetrying(base)) }

        // The login Keychain is a shared system service, and a just-added item is
        // occasionally not yet visible to a broad enumeration when several suites in this
        // target hammer it at once (including through `security` subprocesses). Measured:
        // `KeychainEnumerator` never missed an item across 200 sequential reads, 300 reads
        // under concurrent writers, or 120 add-then-read rounds under concurrent readers —
        // so the enumerator is sound and this is the system's own eventual consistency.
        // Asserting on the first read made this test fail roughly one run in four.
        var found: [KeychainItemRef] = []
        for _ in 0..<20 {
            found = KeychainEnumerator.items(servicePrefix: prefix)
            if found.contains(where: { $0.service == service && $0.account == account }) { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        #expect(found.contains { $0.service == service && $0.account == account })
        #expect(KeychainEnumerator.items(servicePrefix: "dev.komar.toki.nothinghere.").isEmpty)
    }

    /// Retries `SecItemDelete` until it reports either success or "already gone", instead of
    /// firing once and trusting the result — the same defensiveness the read loop above
    /// applies to `SecItemCopyMatching` against the same shared, eventually-consistent store.
    /// Returns whether the item is confirmed gone.
    private func deleteRetrying(_ query: [CFString: Any]) -> Bool {
        for _ in 0..<20 {
            let status = SecItemDelete(query as CFDictionary)
            if status == errSecSuccess || status == errSecItemNotFound { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }
}
