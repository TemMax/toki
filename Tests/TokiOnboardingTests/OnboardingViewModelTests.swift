import Testing
import TokiModels
@testable import TokiOnboarding

/// A configurable fake `CredentialOnboarding` conformer: `accessState()` and
/// `currentCredential()` return/throw whatever the test preloads.
private final class FakeCredentials: CredentialOnboarding, @unchecked Sendable {
    var accessStateResult: CredentialAccessState = .available
    var currentCredentialError: TokiError?
    /// Records the context of the most recent resolution, so tests can assert that
    /// "Grant Access" resolves as user-initiated — the only context permitted to present
    /// the macOS Keychain dialog the button promises.
    var lastUserInitiated: Bool?
    var requiresFreshRead = false

    func accessState() async -> CredentialAccessState {
        accessStateResult
    }

    func currentCredential() async throws -> OAuthCredential {
        try await currentCredential(userInitiated: false)
    }

    func currentCredential(userInitiated: Bool) async throws -> OAuthCredential {
        try await currentCredential(userInitiated: userInitiated, forceRefresh: false)
    }

    func currentCredential(userInitiated: Bool, forceRefresh: Bool) async throws -> OAuthCredential {
        lastUserInitiated = userInitiated
        if requiresFreshRead && !forceRefresh { throw TokiError.tokenExpired }
        if let currentCredentialError {
            throw currentCredentialError
        }
        return OAuthCredential(accessToken: "token", refreshToken: nil, expiresAt: nil)
    }
}

@MainActor
@Suite("OnboardingViewModel")
struct OnboardingViewModelTests {

    @Test("reconnecting bypasses a rejected credential memo and completes")
    func reconnectRereadsCredential() async {
        let fake = FakeCredentials()
        fake.requiresFreshRead = true
        let vm = OnboardingViewModel(credentials: fake)
        var completed = false
        vm.onCompleted = { completed = true }
        await vm.grantAccess()
        #expect(vm.state == .success)
        #expect(completed)
        #expect(fake.lastUserInitiated == true)
    }

    // MARK: probe()

    @Test("probe() maps .available to .success and fires onCompleted")
    func probeAvailable() async {
        let fake = FakeCredentials()
        fake.accessStateResult = .available
        let vm = OnboardingViewModel(credentials: fake)
        var completed = false
        vm.onCompleted = { completed = true }

        await vm.probe()

        #expect(vm.state == .success)
        #expect(completed)
    }

    @Test("probe() maps .needsAuthorization to .intro without firing onCompleted")
    func probeNeedsAuthorization() async {
        let fake = FakeCredentials()
        fake.accessStateResult = .needsAuthorization
        let vm = OnboardingViewModel(credentials: fake)
        var completed = false
        vm.onCompleted = { completed = true }

        await vm.probe()

        #expect(vm.state == .intro)
        #expect(!completed)
    }

    @Test("probe() maps .locked to .locked")
    func probeLocked() async {
        let fake = FakeCredentials()
        fake.accessStateResult = .locked
        let vm = OnboardingViewModel(credentials: fake)

        await vm.probe()

        #expect(vm.state == .locked)
    }

    @Test("probe() maps .unsupportedLayout to the dedicated screen without completing")
    func probeUnsupportedLayout() async {
        let fake = FakeCredentials()
        fake.accessStateResult = .unsupportedLayout
        let vm = OnboardingViewModel(credentials: fake)
        var completed = false
        vm.onCompleted = { completed = true }

        await vm.probe()

        #expect(vm.state == .unsupportedLayout)
        #expect(!completed)
    }

    @Test("probe() maps .notFound to .notLoggedIn")
    func probeNotFound() async {
        let fake = FakeCredentials()
        fake.accessStateResult = .notFound
        let vm = OnboardingViewModel(credentials: fake)

        await vm.probe()

        #expect(vm.state == .notLoggedIn)
    }

    // MARK: grantAccess()

    @Test("grantAccess() success sets .success and fires onCompleted")
    func grantAccessSuccess() async {
        let fake = FakeCredentials()
        let vm = OnboardingViewModel(credentials: fake)
        var completed = false
        vm.onCompleted = { completed = true }

        await vm.grantAccess()

        #expect(vm.state == .success)
        #expect(completed)
    }

    @Test("grantAccess() resolves as user-initiated so the Keychain dialog may appear")
    func grantAccessIsUserInitiated() async {
        let fake = FakeCredentials()
        let vm = OnboardingViewModel(credentials: fake)

        await vm.grantAccess()

        #expect(fake.lastUserInitiated == true,
            "the Grant Access button is the one path allowed to prompt; a background-context read would silently fail")
    }

    @Test("grantAccess() maps keychainDenied to .denied without firing onCompleted")
    func grantAccessDenied() async {
        let fake = FakeCredentials()
        fake.currentCredentialError = .keychainDenied
        let vm = OnboardingViewModel(credentials: fake)
        var completed = false
        vm.onCompleted = { completed = true }

        await vm.grantAccess()

        #expect(vm.state == .denied)
        #expect(!completed)
    }

    @Test("grantAccess() maps keychainLocked to .locked")
    func grantAccessLocked() async {
        let fake = FakeCredentials()
        fake.currentCredentialError = .keychainLocked
        let vm = OnboardingViewModel(credentials: fake)

        await vm.grantAccess()

        #expect(vm.state == .locked)
    }

    @Test("grantAccess() maps credentialsNotFound to .notLoggedIn")
    func grantAccessNotLoggedIn() async {
        let fake = FakeCredentials()
        fake.currentCredentialError = .credentialsNotFound
        let vm = OnboardingViewModel(credentials: fake)

        await vm.grantAccess()

        #expect(vm.state == .notLoggedIn)
    }

    @Test("grantAccess() maps an unrelated error to .denied as the safe default")
    func grantAccessOtherErrorDefaultsToDenied() async {
        let fake = FakeCredentials()
        fake.currentCredentialError = .httpError(500)
        let vm = OnboardingViewModel(credentials: fake)
        var completed = false
        vm.onCompleted = { completed = true }

        await vm.grantAccess()

        #expect(vm.state == .denied)
        #expect(!completed)
    }

    @Test("grantAccess() sets .granting before the credential read completes")
    func grantAccessSetsGrantingFirst() async {
        // A fake whose currentCredential() hops back to the main actor to
        // capture the ViewModel's state at call time, before it throws —
        // proves .granting was set synchronously ahead of the await, not skipped.
        final class ObservingCredentials: CredentialOnboarding, @unchecked Sendable {
            var observedState: OnboardingState?
            weak var vm: OnboardingViewModel?

            func accessState() async -> CredentialAccessState { .available }

            func currentCredential() async throws -> OAuthCredential {
                observedState = await vm?.state
                throw TokiError.keychainDenied
            }
        }

        let observing = ObservingCredentials()
        let vm = OnboardingViewModel(credentials: observing, initialState: .intro)
        observing.vm = vm

        await vm.grantAccess()

        #expect(observing.observedState == .granting)
        #expect(vm.state == .denied)
    }

    // MARK: recheck()

    @Test("recheck() behaves like probe()")
    func recheckBehavesLikeProbe() async {
        let fake = FakeCredentials()
        fake.accessStateResult = .locked
        let vm = OnboardingViewModel(credentials: fake, initialState: .intro)

        await vm.recheck()

        #expect(vm.state == .locked)

        fake.accessStateResult = .available
        var completed = false
        vm.onCompleted = { completed = true }

        await vm.recheck()

        #expect(vm.state == .success)
        #expect(completed)
    }
}
