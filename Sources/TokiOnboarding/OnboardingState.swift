import TokiModels

/// UI state for the Keychain-access onboarding flow, driven by
/// `OnboardingViewModel`.
public enum OnboardingState: Sendable, Equatable {
    /// Explains the upcoming Keychain dialog and offers "Grant Access".
    case intro
    /// "Grant Access" was pressed; the real (prompting) credential read is in flight.
    case granting
    /// Access was granted; the window will auto-close.
    case success
    /// The user denied the Keychain authorization dialog.
    case denied
    /// The login Keychain is locked.
    case locked
    /// No Claude Code credentials exist anywhere (not logged in).
    case notLoggedIn
    /// Claude Code stores credentials in a layout Toki cannot read (no `claudeAiOauth`).
    case unsupportedLayout
}

public extension OnboardingState {
    /// Maps a silent probe result (`CredentialAccessState`) to the onboarding
    /// state that should be shown for it. Note `.available` maps to `.success`
    /// here, but `OnboardingViewModel.probe()` additionally fires `onCompleted()`
    /// in that case.
    init(accessState: CredentialAccessState) {
        switch accessState {
        case .available:
            self = .success
        case .needsAuthorization:
            self = .intro
        case .locked:
            self = .locked
        case .notFound:
            self = .notLoggedIn
        case .unsupportedLayout:
            self = .unsupportedLayout
        }
    }
}
