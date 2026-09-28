import Foundation

/// Uncached verification of the exact item just written, using only existing access.
/// A source's modification date may have one-second resolution; neither the vault nor
/// the credential ladder's memo can prove that the current bytes are the new write.
public struct CredentialVerificationReader: Sendable {
    private let silentRead: @Sendable (KeychainItemRef) -> Data?
    private let cliReader: SecurityCLIReader
    private let refreshRef: @Sendable (KeychainItemRef) -> KeychainItemRef?

    public init() {
        self.init(silentRead: { CredentialStore.silentRead($0) },
                  cliReader: SecurityCLIReader(gate: SubprocessGate()), refreshRef: { source in
                      CredentialStore.enumerateClaudeItems().first {
                          $0.service == source.service && $0.account == source.account
                      }
                  })
    }

    init(silentRead: @escaping @Sendable (KeychainItemRef) -> Data?, cliReader: SecurityCLIReader,
         refreshRef: @escaping @Sendable (KeychainItemRef) -> KeychainItemRef? = { $0 }) {
        self.silentRead = silentRead
        self.cliReader = cliReader
        self.refreshRef = refreshRef
    }

    public func read(_ item: KeychainItemRef) async -> Data? {
        if let data = silentRead(item) { return data }
        // The write changed modifiedAt. Re-enumerate metadata for THIS item before the
        // ACL preflight, which intentionally refuses an outdated item reference.
        guard let current = refreshRef(item), current.service == item.service,
              current.account == item.account else { return nil }
        return await cliReader.read(current, context: .background)
    }
}
