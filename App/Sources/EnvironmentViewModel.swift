import Foundation
import Observation
import TokiCore
import TokiFixtures

// MARK: - EnvironmentViewModel

/// View model for the installed coding tools' environment cards.
///
/// Loads a `ClaudeEnvironment` snapshot (CLI version, plugins, marketplaces,
/// skills, MCP servers) from an `EnvironmentProviding` service. Data is local;
/// the service also performs an optional best-effort CLI-version check.
@Observable
@MainActor
final class EnvironmentViewModel {

    // MARK: Published state

    /// Claude Code's local environment. Kept as the original property name so existing
    /// fixture/debug callers remain source-compatible.
    var environment: ClaudeEnvironment?
    var codexEnvironment: ClaudeEnvironment?
    var isLoading: Bool = false

    /// When not `.live`, load() is a no-op — used by the demo/snapshot harness to
    /// render injected mock data without touching disk.
    var runMode: RunMode = .live

    // MARK: Private

    private let service: (any EnvironmentProviding)?
    private let codexService: (any EnvironmentProviding)?

    // MARK: Init

    init(
        service: (any EnvironmentProviding)?,
        codexService: (any EnvironmentProviding)? = nil
    ) {
        self.service = service
        self.codexService = codexService
    }

    // MARK: Public API

    /// Loads (or reloads) the environment snapshot.
    func load() {
        guard runMode.isLive else { return }
        guard !isLoading else { return }
        isLoading = true

        Task { [weak self] in
            guard let self else { return }
            if let service = self.service {
                self.environment = await service.loadEnvironment()
            } else {
                self.environment = nil
            }
            if let codexService = self.codexService {
                self.codexEnvironment = await codexService.loadEnvironment()
            } else {
                self.codexEnvironment = nil
            }
            self.isLoading = false
        }
    }
}
