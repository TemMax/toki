import TokiCore

/// Routes an explicit Claude reconnect through the existing onboarding model.
/// Presentation is synchronous; the protected read starts on the next actor turn so the
/// dashboard can render the permission state before macOS presents its authorization UI.
@MainActor
final class ClaudeReconnectAction {
    private let credentials: any CredentialOnboarding
    private let currentModel: () -> OnboardingViewModel?
    private let present: (OnboardingViewModel) -> Void
    private let onCompleted: (OnboardingViewModel) -> Void
    private var grantTask: Task<Void, Never>?

    init(
        credentials: any CredentialOnboarding,
        currentModel: @escaping () -> OnboardingViewModel?,
        present: @escaping (OnboardingViewModel) -> Void,
        onCompleted: @escaping (OnboardingViewModel) -> Void
    ) {
        self.credentials = credentials
        self.currentModel = currentModel
        self.present = present
        self.onCompleted = onCompleted
    }

    func perform() {
        guard grantTask == nil else { return }

        if let model = currentModel(), model.state == .granting {
            // Continue already owns this prompt and its completion callback. Foreground the
            // same model without starting another read or taking ownership of its result.
            present(model)
            return
        }

        let model = currentModel() ?? OnboardingViewModel(
            credentials: credentials,
            initialState: .intro
        )
        model.onCompleted = { [weak self, weak model] in
            guard let self, let model, self.currentModel() === model else { return }
            self.onCompleted(model)
        }
        present(model)

        grantTask = Task { [weak self] in
            await Task.yield()
            guard let self else { return }
            defer { self.grantTask = nil }
            guard self.currentModel() === model, model.state != .granting else { return }
            await model.grantAccess()
        }
    }
}
