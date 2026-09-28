import Testing
@testable import TokiKeychain

@Suite("Keychain interaction guard")
struct KeychainInteractionGuardTests {
    @Test("disables interaction for the operation and restores the previous state")
    func disablesAndRestores() {
        var allowed = true
        var observedDuringOperation: Bool?

        let value = KeychainInteractionGuard.performNoninteractive(
            getAllowed: { allowed },
            setAllowed: { allowed = $0; return true },
            operation: { observedDuringOperation = allowed; return 42 }
        )

        #expect(value == 42)
        #expect(observedDuringOperation == false)
        #expect(allowed == true)
    }

    @Test("fails closed when interaction cannot be disabled")
    func setFailureFailsClosed() {
        var operationRan = false
        let value: Int? = KeychainInteractionGuard.performNoninteractive(
            getAllowed: { true }, setAllowed: { _ in false },
            operation: { operationRan = true; return 42 }
        )
        #expect(value == nil)
        #expect(!operationRan)
    }
}
