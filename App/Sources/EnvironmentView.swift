/// EnvironmentView — the "Environment" tab: a local, offline snapshot of the
/// installed Claude Code/Codex CLIs, plugins, marketplaces, skills, and MCP servers.
///
/// Renders INSIDE the Dashboard content area (no toolbar, no window
/// background — the dashboard supplies those). Uses only design-system
/// primitives (panelCard, Palette, SectionHeader, Spacing, Radius).
import TokiCore
import TokiFixtures
import SwiftUI

// MARK: - EnvironmentView

@MainActor
struct EnvironmentView: View {
    @Bindable var model: EnvironmentViewModel
    @State private var expansion: MachineExpansionState
    var topInset: CGFloat = 0

    init(model: EnvironmentViewModel, topInset: CGFloat = 0) {
        self.model = model
        self.topInset = topInset
        _expansion = State(
            initialValue: MachineExpansionState(
                expandedByDefault: SnapshotConfig.flatSurfaces
            )
        )
    }

    var body: some View {
        ScrollView {
            EnvironmentSection(model: model, expansion: expansion)
                .padding(.horizontal, Spacing.xl)
                .padding(.bottom, Spacing.xl)
                .padding(.top, topInset)
        }
        .onAppear {
            model.load()
        }
    }
}

// MARK: - EnvironmentSection

/// The loading/empty/populated switch for a `ClaudeEnvironment` read — no `ScrollView`, no
/// lifecycle hooks, just the content. Factored out of `EnvironmentView.body` so `MachineView`
/// can lay it inside the Machine tab's own single scroll region instead of nesting a second
/// `ScrollView` (which `EnvironmentView.body` owns for its standalone-tab-surface use, e.g. the
/// snapshot harness's bare "environment" surface).
@MainActor
struct EnvironmentSection: View {
    @Bindable var model: EnvironmentViewModel
    let expansion: MachineExpansionState

    var body: some View {
        if model.isLoading && model.environment == nil && model.codexEnvironment == nil {
            loadingState
        } else if hasContent {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                if let environment = model.environment, !environment.isEmpty {
                    EnvironmentContent(
                        environment: environment,
                        provider: .claudeCode,
                        expansion: expansion
                    )
                }
                if let environment = model.codexEnvironment, !environment.isEmpty {
                    EnvironmentContent(
                        environment: environment,
                        provider: .codex,
                        expansion: expansion
                    )
                }
            }
        } else {
            emptyState
        }
    }

    private var hasContent: Bool {
        model.environment.map { !$0.isEmpty } == true
            || model.codexEnvironment.map { !$0.isEmpty } == true
    }

    // MARK: - States

    @ViewBuilder
    private var loadingState: some View {
        ProgressView("Reading local tool configuration\u{2026}")
            .frame(maxWidth: .infinity, minHeight: 320, alignment: .center)
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: Spacing.sm) {
            Image(systemName: "puzzlepiece.extension")
                .iconSize(.hero)
                .foregroundStyle(Palette.textSecondary)
            Text("Nothing to show yet")
                .textStyle(.headline)
                .foregroundStyle(Palette.textSecondary)
            Text("Couldn't find local configuration for an installed coding tool.")
                .textStyle(.detail)
                .foregroundStyle(Palette.textSecondary.opacity(0.7))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, minHeight: 320, alignment: .center)
    }
}

// MARK: - ClaudeEnvironment helpers

private extension ClaudeEnvironment {
    var isEmpty: Bool {
        cli == nil && marketplaces.isEmpty && plugins.isEmpty
            && skills.isEmpty && mcpServers.isEmpty
    }
}

// MARK: - EnvironmentContent

@MainActor
struct EnvironmentContent: View {
    let environment: ClaudeEnvironment
    var provider: UsageProvider = .claudeCode
    let expansion: MachineExpansionState

    @State private var isVisible = false

    private let categories = ["cli", "plugins", "marketplaces", "skills", "mcp-servers"]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            SectionHeader(provider.displayName.uppercased())
                .staggerIn(index: 0, isVisible: isVisible)

            // A single column keeps every header anchored to the same width and order while
            // details reveal below it. Grid reflow made neighbouring cards jump horizontally
            // whenever a long section opened.
            VStack(alignment: .leading, spacing: Spacing.sm) {
                if let cli = environment.cli {
                    CLIInfoCard(
                        cli: cli,
                        isExpanded: isExpanded("cli"),
                        onToggle: { toggle("cli") }
                    )
                    .staggerIn(index: 1, isVisible: isVisible)
                }

                if !environment.plugins.isEmpty {
                    PluginsCard(
                        plugins: environment.plugins,
                        isExpanded: isExpanded("plugins"),
                        onToggle: { toggle("plugins") }
                    )
                    .staggerIn(index: 2, isVisible: isVisible)
                }

                if !environment.marketplaces.isEmpty {
                    MarketplacesCard(
                        marketplaces: environment.marketplaces,
                        isExpanded: isExpanded("marketplaces"),
                        onToggle: { toggle("marketplaces") }
                    )
                    .staggerIn(index: 3, isVisible: isVisible)
                }

                if !environment.skills.isEmpty {
                    SkillsCard(
                        skills: environment.skills,
                        isExpanded: isExpanded("skills"),
                        onToggle: { toggle("skills") }
                    )
                    .staggerIn(index: 4, isVisible: isVisible)
                }

                if !environment.mcpServers.isEmpty {
                    MCPServersCard(
                        servers: environment.mcpServers,
                        isExpanded: isExpanded("mcp-servers"),
                        onToggle: { toggle("mcp-servers") }
                    )
                    .staggerIn(index: 5, isVisible: isVisible)
                }
            }
        }
        .onAppear {
            isVisible = true
        }
    }

    private func isExpanded(_ category: String) -> Bool {
        expansion.isExpanded(disclosureID(category))
    }

    private func toggle(_ category: String) {
        expansion.toggleExclusively(
            disclosureID(category),
            within: categories.map(disclosureID)
        )
    }

    private func disclosureID(_ category: String) -> String {
        "environment.\(provider.rawValue).\(category)"
    }
}


// MARK: - Preview

#Preview("EnvironmentView — populated") {
    EnvironmentView(model: {
        let vm = EnvironmentViewModel(service: PreviewEnvironmentService())
        vm.runMode = .fixture(.singleAccount)
        vm.environment = .previewSample
        return vm
    }())
}

#Preview("EnvironmentView — empty") {
    EnvironmentView(model: {
        let vm = EnvironmentViewModel(service: PreviewEnvironmentService())
        vm.runMode = .fixture(.singleAccount)
        vm.environment = .empty
        return vm
    }())
}

private struct PreviewEnvironmentService: EnvironmentProviding {
    func loadEnvironment() async -> ClaudeEnvironment { .empty }
}

private extension ClaudeEnvironment {
    static var previewSample: ClaudeEnvironment {
        ClaudeEnvironment(
            cli: CLIInfo(
                version: "2.1.197",
                installMethod: "native",
                autoUpdates: true,
                lastUpdateFrom: "2.1.196",
                lastUpdateTo: "2.1.197",
                lastUpdateAt: Date().addingTimeInterval(-3600 * 5),
                lastUpdateOutcome: "success",
                releaseChannel: nil,
                latestVersion: "2.2.0",
                updateAvailable: true
            ),
            marketplaces: [
                MarketplaceInfo(name: "anthropics", repo: "anthropics/claude-plugins", lastUpdated: Date().addingTimeInterval(-86400)),
                MarketplaceInfo(name: "community", repo: "claude-plugins/community", lastUpdated: Date().addingTimeInterval(-86400 * 6)),
            ],
            plugins: [
                PluginInfo(name: "figma", marketplace: "anthropics", version: "1.4.0", latestVersion: "1.5.0", updateAvailable: true, enabled: true, installedAt: nil, lastUpdated: nil, description: "Figma design integration", usageCount: 142, isFavorite: true),
                PluginInfo(name: "android-runtime-testing", marketplace: "anthropics", version: "0.9.2", latestVersion: "0.9.2", updateAvailable: false, enabled: true, installedAt: nil, lastUpdated: nil, description: "Runtime testing for Android apps", usageCount: 58, isFavorite: false),
                PluginInfo(name: "testtag-coverage", marketplace: "community", version: "1.0.0", latestVersion: nil, updateAvailable: false, enabled: false, installedAt: nil, lastUpdated: nil, description: "Test tag coverage audit", usageCount: 3, isFavorite: false),
            ],
            skills: [
                SkillInfo(name: "figma-use", plugin: "figma", description: "MANDATORY prerequisite for use_figma calls", usageCount: 89),
                SkillInfo(name: "systematic-debugging", plugin: nil, description: "Use when encountering any bug", usageCount: 41),
                SkillInfo(name: "code-review", plugin: nil, description: "Review the current diff", usageCount: 12),
            ],
            mcpServers: [
                MCPServerInfo(name: "amplitude", transport: "http", detail: "mcp.amplitude.com", source: "user", providingPluginVersion: nil, needsAuth: true),
                MCPServerInfo(name: "figma", transport: "stdio", detail: "npx", source: "figma", providingPluginVersion: "1.4.0", needsAuth: false),
            ]
        )
    }
}
