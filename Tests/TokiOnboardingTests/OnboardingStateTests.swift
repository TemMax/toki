import Testing
import TokiModels
@testable import TokiOnboarding

@Suite("OnboardingState")
struct OnboardingStateTests {
    @Test("init(accessState:) maps .available to .success")
    func available() {
        #expect(OnboardingState(accessState: .available) == .success)
    }

    @Test("init(accessState:) maps .needsAuthorization to .intro")
    func needsAuthorization() {
        #expect(OnboardingState(accessState: .needsAuthorization) == .intro)
    }

    @Test("init(accessState:) maps .locked to .locked")
    func locked() {
        #expect(OnboardingState(accessState: .locked) == .locked)
    }

    @Test("init(accessState:) maps .notFound to .notLoggedIn")
    func notFound() {
        #expect(OnboardingState(accessState: .notFound) == .notLoggedIn)
    }

    @Test("init(accessState:) maps .unsupportedLayout to its own screen")
    func unsupportedLayout() {
        #expect(OnboardingState(accessState: .unsupportedLayout) == .unsupportedLayout)
    }
}
