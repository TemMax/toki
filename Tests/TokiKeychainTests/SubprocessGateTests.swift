import Testing
import Foundation
@testable import TokiKeychain

/// Fresh, isolated defaults per test so the verified flag can't leak between cases.
func makeTestDefaults(_ name: String) -> UserDefaults {
    let suite = "toki.tests.\(name)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return defaults
}

@Suite("SubprocessGate")
struct SubprocessGateTests {

    @Test("a late background success cannot clear suspension caused by another read")
    func backgroundSuccessCannotRearm() {
        let gate = SubprocessGate(defaults: makeTestDefaults(#function))
        #expect(gate.allows(.background, currentACLPermitsRead: true))
        gate.recordTimeout()
        gate.recordSuccess(duration: 0.1, context: .background)
        #expect(!gate.allows(.background, currentACLPermitsRead: true))
        gate.recordSuccess(duration: 0.1, context: .userInitiated)
        #expect(gate.allows(.background, currentACLPermitsRead: true))
    }

    @Test("an unverified subprocess is barred from background but allowed in a user context")
    func unverifiedIsUserInitiatedOnly() {
        let gate = SubprocessGate(defaults: makeTestDefaults(#function), keychainUnlocked: { true })
        #expect(!gate.allows(.background))
        #expect(gate.allows(.userInitiated))
    }

    @Test("saved subprocess trust never permits a background read")
    func savedTrustDoesNotPermitBackground() {
        let gate = SubprocessGate(defaults: makeTestDefaults(#function), keychainUnlocked: { true })
        gate.recordSuccess(duration: 0.2)
        #expect(gate.isVerified)
        #expect(!gate.allows(.background))
    }

    @Test("a slow success does not verify — slowness is the signature of a dialog")
    func slowSuccessDoesNotVerify() {
        let gate = SubprocessGate(defaults: makeTestDefaults(#function), keychainUnlocked: { true })
        gate.recordSuccess(duration: 5)
        #expect(!gate.isVerified)
        #expect(!gate.allows(.background))
    }

    @Test("a timeout revokes verification, and a later user-context success restores it")
    func timeoutRevokesVerification() {
        let gate = SubprocessGate(defaults: makeTestDefaults(#function), keychainUnlocked: { true })
        gate.recordSuccess(duration: 0.2)
        gate.recordTimeout()
        #expect(!gate.isVerified)
        #expect(!gate.allows(.background))

        gate.recordSuccess(duration: 0.2)
        #expect(!gate.allows(.background))
    }

    @Test("a locked keychain bars the subprocess in every context")
    func lockedKeychainBarsEverything() {
        let gate = SubprocessGate(defaults: makeTestDefaults(#function), keychainUnlocked: { false })
        gate.recordSuccess(duration: 0.1)
        #expect(!gate.allows(.background))
        #expect(!gate.allows(.userInitiated))
    }

    @Test("verification survives a new gate instance (persisted)")
    func verificationPersists() {
        let defaults = makeTestDefaults(#function)
        SubprocessGate(defaults: defaults, keychainUnlocked: { true }).recordSuccess(duration: 0.1)
        #expect(!SubprocessGate(defaults: defaults, keychainUnlocked: { true }).allows(.background))
    }

    // Diagnostic flags remain separate in both supported test configurations.
    @Test("recordSuccess writes under this build's own key, leaving the other build's key untouched")
    func recordSuccessWritesOwnBuildKey() {
        let defaults = makeTestDefaults(#function)
        SubprocessGate(defaults: defaults, keychainUnlocked: { true }).recordSuccess(duration: 0.1)

        #if DEBUG
        let otherKey = "toki.subprocessVerifiedSilent"
        #else
        let otherKey = "toki.subprocessVerifiedSilent.debug"
        #endif
        #expect(defaults.object(forKey: otherKey) == nil)
        #expect(defaults.bool(forKey: SubprocessGate.defaultsKey) == true)
    }
}
