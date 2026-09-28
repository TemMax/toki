import Observation
import TokiModels
import TokiLogging

private let log = TokiLog.logger("onboarding")

/// Drives the Keychain-access onboarding UI state machine.
///
/// Wraps a `CredentialOnboarding` conformer: `probe()` performs the silent,
/// non-prompting access check to decide which screen to show, while
/// `grantAccess()` performs the real (prompting) credential read triggered by
/// the user's explicit "Grant Access" button press. See the design spec for
/// the full state table.
@MainActor
@Observable
public final class OnboardingViewModel {

    // MARK: Published state

    /// The screen currently shown by `OnboardingView`.
    public private(set) var state: OnboardingState

    /// Fired when access is confirmed available (`.success`), so the caller can
    /// close the onboarding window and kick a data refresh.
    public var onCompleted: (() -> Void)?

    // MARK: Private

    private let credentials: any CredentialOnboarding

    // MARK: Init

    /// - Parameters:
    ///   - credentials: the credential source to probe/authorize against.
    ///   - initialState: the screen to show before the first `probe()` completes.
    public init(credentials: any CredentialOnboarding, initialState: OnboardingState = .intro) {
        self.credentials = credentials
        self.state = initialState
    }

    // MARK: Public API

    /// Silently probes credential-access state (no Keychain dialog) and updates
    /// `state` to match. When access is already `.available`, also fires
    /// `onCompleted()` since there is nothing left for onboarding to do.
    public func probe() async {
        let accessState = await credentials.accessState()
        let newState = OnboardingState(accessState: accessState)
        log.info("probe: \(String(describing: state), privacy: .public) -> \(String(describing: newState), privacy: .public)")
        state = newState
        if accessState == .available {
            onCompleted?()
        }
    }

    /// Performs the real, prompting credential read (triggered by the user
    /// pressing "Grant Access"). Sets `state` to `.granting` while the read is
    /// in flight, then maps the outcome to a terminal state.
    public func grantAccess() async {
        log.info("grantAccess: \(String(describing: state), privacy: .public) -> granting")
        state = .granting
        do {
            // Explicitly user-initiated: this is the one path allowed to present the macOS
            // Keychain dialog, which is exactly what the user just asked for by pressing
            // the button. A background-context read would silently fail instead.
            _ = try await credentials.currentCredential(userInitiated: true, forceRefresh: true)
            log.info("grantAccess: granting -> success")
            state = .success
            onCompleted?()
        } catch TokiError.keychainDenied {
            log.error("grantAccess: user denied the Keychain authorization dialog; granting -> denied")
            state = .denied
        } catch TokiError.keychainLocked {
            log.error("grantAccess: login Keychain is locked; granting -> locked")
            state = .locked
        } catch TokiError.credentialsNotFound {
            log.error("grantAccess: no Claude Code credentials found; granting -> notLoggedIn")
            state = .notLoggedIn
        } catch {
            log.error("grantAccess: unexpected failure, treating as denied; granting -> denied: \(error: error)")
            state = .denied
        }
    }

    /// Re-runs the silent probe. Alias of `probe()`, exposed for the
    /// `.notLoggedIn` screen's "Re-check" action.
    public func recheck() async {
        await probe()
    }
}
