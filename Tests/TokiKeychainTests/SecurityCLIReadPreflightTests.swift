import Foundation
import Testing
@testable import TokiKeychain

@Suite("Security CLI ACL preflight")
struct SecurityCLIReadPreflightTests {
    private typealias ACL = SecurityCLIReadPreflight.ACL

    private func partitions(_ names: [String]) throws -> ACL {
        let data = try PropertyListSerialization.data(fromPropertyList: ["Partitions": names], format: .xml, options: 0)
        return ACL(authorizations: ["ACLAuthorizationPartitionID"], promptFlags: 0,
                   trustsSecurity: false, description: data.map { String(format: "%02x", $0) }.joined())
    }

    @Test("the Claude-created apple-tool partition plus a valid decrypt grant permits recovery")
    func claudeACL() throws {
        let decrypt = ACL(authorizations: ["ACLAuthorizationDecrypt", "ACLAuthorizationSign"],
                          promptFlags: 0, trustsSecurity: true, description: "Claude Code")
        #expect(SecurityCLIReadPreflight.permitsBackgroundRead([decrypt, try partitions(["apple-tool:"])]))
    }

    @Test("a partition alone cannot authorize decrypt, and an app grant cannot override the partition")
    func bothGatesRequired() throws {
        let decrypt = ACL(authorizations: ["ACLAuthorizationDecrypt"], promptFlags: 0,
                          trustsSecurity: true, description: nil)
        #expect(!SecurityCLIReadPreflight.permitsBackgroundRead([try partitions(["apple-tool:"])]))
        #expect(!SecurityCLIReadPreflight.permitsBackgroundRead([decrypt]))
        #expect(!SecurityCLIReadPreflight.permitsBackgroundRead([decrypt, try partitions(["teamid:EXAMPLE"])]))
        #expect(!SecurityCLIReadPreflight.permitsBackgroundRead([decrypt, try partitions(["apple:"])]))
    }

    @Test("passphrase requirements, invalid app signatures and other operations never grant decrypt")
    func restrictedACLs() throws {
        let partition = try partitions(["apple-tool:"])
        for decrypt in [
            ACL(authorizations: ["ACLAuthorizationDecrypt"], promptFlags: 1, trustsSecurity: true, description: nil),
            ACL(authorizations: ["ACLAuthorizationDecrypt"], promptFlags: 2, trustsSecurity: true, description: nil),
            ACL(authorizations: ["ACLAuthorizationDecrypt"], promptFlags: 0, trustsSecurity: false, description: nil),
            ACL(authorizations: ["ACLAuthorizationEncrypt"], promptFlags: 0, trustsSecurity: true, description: nil)
        ] {
            #expect(!SecurityCLIReadPreflight.permitsBackgroundRead([decrypt, partition]))
        }
    }

    @Test("malformed or ambiguous partition metadata fails closed")
    func malformedMetadata() throws {
        for hex in ["", "abc", "zz", "00", String(repeating: "00", count: 32769)] {
            #expect(SecurityCLIReadPreflight.partitionIdentifiers(hex) == nil)
        }
        let decrypt = ACL(authorizations: ["ACLAuthorizationDecrypt"], promptFlags: 0,
                          trustsSecurity: true, description: nil)
        let partition = try partitions(["apple-tool:"])
        #expect(!SecurityCLIReadPreflight.permitsBackgroundRead([decrypt, partition, partition]))
    }
}
