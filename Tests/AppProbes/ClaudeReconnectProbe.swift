import Foundation
import TokiCore

private final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []

    func append(_ event: String) {
        lock.withLock { events.append(event) }
    }

    func snapshot() -> [String] {
        lock.withLock { events }
    }
}

private actor SyntheticCredentials: CredentialOnboarding {
    struct Read: Equatable {
        let userInitiated: Bool
        let forceRefresh: Bool
    }

    private let events: EventRecorder
    private var reads: [Read] = []
    private var continuations: [CheckedContinuation<OAuthCredential, Error>] = []

    init(events: EventRecorder) {
        self.events = events
    }

    func accessState() async -> CredentialAccessState { .needsAuthorization }

    func currentCredential() async throws -> OAuthCredential {
        try await currentCredential(userInitiated: false, forceRefresh: false)
    }

    func currentCredential(
        userInitiated: Bool,
        forceRefresh: Bool
    ) async throws -> OAuthCredential {
        reads.append(Read(userInitiated: userInitiated, forceRefresh: forceRefresh))
        events.append("read")
        return try await withCheckedThrowingContinuation { continuations.append($0) }
    }

    func recordedReads() -> [Read] { reads }

    func succeed() {
        let credential = OAuthCredential(
            accessToken: "fixture-token", refreshToken: nil, expiresAt: nil
        )
        continuations.forEach { $0.resume(returning: credential) }
        continuations.removeAll()
    }

    func deny() {
        continuations.forEach { $0.resume(throwing: TokiError.keychainDenied) }
        continuations.removeAll()
    }
}

@main
private struct ClaudeReconnectProbe {
    @MainActor
    static func main() async throws {
        try await verifySuccessfulReconnect()
        try await verifyDenialRemainsVisible()
        try await verifyExistingGrantIsNotReplaced()
        try await verifyCloseBeforeReadSuppressesPrompt()
        try await verifyClosingSetupSuppressesLateCompletion()
        print("PASS: production Claude reconnect presents before one interactive forced read, suppresses pending duplicates, preserves existing grants and failures, and ignores late completion after close")
    }

    @MainActor
    private static func verifySuccessfulReconnect() async throws {
        let events = EventRecorder()
        let credentials = SyntheticCredentials(events: events)
        var presented: [OnboardingViewModel] = []
        var completed = 0
        let action = ClaudeReconnectAction(
            credentials: credentials,
            currentModel: { presented.last },
            present: { model in
                events.append("present")
                presented.append(model)
            },
            onCompleted: { _ in completed += 1 }
        )

        action.perform()
        try await waitUntil { await credentials.recordedReads().count == 1 }

        precondition(events.snapshot().prefix(2) == ["present", "read"],
                     "onboarding presentation must precede the protected credential read")
        let initialReads = await credentials.recordedReads()
        precondition(initialReads == [
            .init(userInitiated: true, forceRefresh: true)
        ], "explicit reconnect must perform exactly one interactive forced read")
        precondition(presented.count == 1)
        let originalModel = presented[0]

        action.perform()
        try await Task.sleep(for: .milliseconds(25))
        let readsAfterDuplicate = await credentials.recordedReads()
        precondition(readsAfterDuplicate.count == 1,
                     "a duplicate pending reconnect must not start another read")
        precondition(presented.count == 1 && presented[0] === originalModel,
                     "a duplicate pending reconnect must not replace its onboarding model")

        await credentials.succeed()
        try await waitUntil { originalModel.state == .success }
        precondition(completed == 1, "successful reconnect must invoke the existing completion path")
    }

    @MainActor
    private static func verifyDenialRemainsVisible() async throws {
        let events = EventRecorder()
        let credentials = SyntheticCredentials(events: events)
        var presented: OnboardingViewModel?
        var completed = 0
        let action = ClaudeReconnectAction(
            credentials: credentials,
            currentModel: { presented },
            present: { presented = $0 },
            onCompleted: { _ in completed += 1 }
        )

        action.perform()
        try await waitUntil { await credentials.recordedReads().count == 1 }
        await credentials.deny()
        try await waitUntil { presented?.state == .denied }

        precondition(presented?.state == .denied,
                     "denial must remain visible in the existing onboarding state")
        precondition(completed == 0, "denial must not invoke completion")
    }

    @MainActor
    private static func verifyExistingGrantIsNotReplaced() async throws {
        let events = EventRecorder()
        let credentials = SyntheticCredentials(events: events)
        let model = OnboardingViewModel(credentials: credentials)
        var current: OnboardingViewModel? = model
        var continueCompletion = 0
        var reconnectCompletion = 0
        model.onCompleted = { continueCompletion += 1 }
        let existingGrant = Task { await model.grantAccess() }
        try await waitUntil { await credentials.recordedReads().count == 1 }

        let action = ClaudeReconnectAction(
            credentials: credentials,
            currentModel: { current },
            present: { current = $0 },
            onCompleted: { _ in reconnectCompletion += 1 }
        )
        action.perform()
        try await Task.sleep(for: .milliseconds(25))

        let reads = await credentials.recordedReads()
        precondition(reads.count == 1,
                     "reconnect must not start a second prompt while Continue is granting")
        precondition(current === model,
                     "reconnect must retain the model already granting from Continue")

        await credentials.succeed()
        await existingGrant.value
        precondition(continueCompletion == 1 && reconnectCompletion == 0,
                     "reconnect must not replace an existing grant's completion handler")
    }

    @MainActor
    private static func verifyClosingSetupSuppressesLateCompletion() async throws {
        let events = EventRecorder()
        let credentials = SyntheticCredentials(events: events)
        var current: OnboardingViewModel?
        var completed = 0
        let action = ClaudeReconnectAction(
            credentials: credentials,
            currentModel: { current },
            present: { current = $0 },
            onCompleted: { _ in completed += 1 }
        )

        action.perform()
        try await waitUntil { await credentials.recordedReads().count == 1 }
        let pendingModel = current
        current = nil
        await credentials.succeed()
        try await waitUntil { pendingModel?.state == .success }

        precondition(completed == 0,
                     "a credential read finishing after setup closes must not run completion side effects")
        precondition(current == nil,
                     "late completion must not resurrect the dismissed onboarding UI")
    }

    @MainActor
    private static func verifyCloseBeforeReadSuppressesPrompt() async throws {
        let events = EventRecorder()
        let credentials = SyntheticCredentials(events: events)
        var current: OnboardingViewModel?
        let action = ClaudeReconnectAction(
            credentials: credentials,
            currentModel: { current },
            present: { current = $0 },
            onCompleted: { _ in }
        )

        action.perform()
        current = nil
        try await Task.sleep(for: .milliseconds(25))

        let reads = await credentials.recordedReads()
        precondition(reads.isEmpty,
                     "closing setup before the queued read starts must suppress permission UI")
    }

    @MainActor
    private static func waitUntil(
        _ condition: @escaping @MainActor () async -> Bool
    ) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NSError(
            domain: "ClaudeReconnectProbe",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for reconnect state"]
        )
    }
}
