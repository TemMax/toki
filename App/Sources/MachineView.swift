/// MachineView — the "Machine" tab: what is happening on this machine, in one place.
/// Stacks the existing Instances content (running Claude Code processes) above the existing
/// Environment content (CLI version, plugins, marketplaces, skills, MCP servers) inside one
/// shared scroll region, so the two no longer split navigation for a single topic.
///
/// Composes `InstancesSection`/`EnvironmentSection` — the same loading/empty/populated content
/// `InstancesView`/`EnvironmentView` render in their own standalone `ScrollView` (still used by
/// the snapshot harness and the debug control channel as the `instances`/`environment`
/// surfaces) — rather than nesting those views' own `ScrollView`s inside this one.
import TokiCore
import TokiFixtures
import Observation
import SwiftUI

// MARK: - Expansion state

/// One session-scoped owner for every disclosure in the Machine tab.
///
/// `DashboardView` keeps this object alive while the user moves between tabs, so opening a
/// Machine group and briefly checking Usage does not throw the layout away. It is deliberately
/// not persisted to UserDefaults: a new app launch starts from the useful compact overview
/// instead of restoring a potentially very tall diagnostic view from yesterday.
@Observable
@MainActor
final class MachineExpansionState {
    private let expandedByDefault: Bool
    private var overrides: [String: Bool] = [:]

    init(expandedByDefault: Bool = false) {
        self.expandedByDefault = expandedByDefault
    }

    func isExpanded(_ id: String) -> Bool {
        overrides[id] ?? expandedByDefault
    }

    func toggle(_ id: String) {
        overrides[id] = !isExpanded(id)
    }

    /// Toggles one disclosure while closing its siblings. Environment uses this to behave as
    /// an accordion within each provider without coupling Claude Code and Codex state.
    func toggleExclusively(_ id: String, within group: [String]) {
        let shouldExpand = !isExpanded(id)
        for sibling in group {
            overrides[sibling] = false
        }
        overrides[id] = shouldExpand
    }
}

// MARK: - MachineView

@MainActor
struct MachineView: View {
    @Bindable var instances: InstancesViewModel
    @Bindable var environment: EnvironmentViewModel
    let expansion: MachineExpansionState
    /// Extra top padding for callers that render this view OUTSIDE the dashboard — the
    /// snapshot harness and the debug control channel. As a dashboard tab it is 0: clearing
    /// the floating toolbar is `DashboardView`'s job, done once for all five tabs
    /// (`Measure.dashboardContentTop`).
    var topInset: CGFloat = 0

    init(
        instances: InstancesViewModel,
        environment: EnvironmentViewModel,
        topInset: CGFloat = 0,
        expansion: MachineExpansionState? = nil
    ) {
        self.instances = instances
        self.environment = environment
        self.topInset = topInset
        // Full snapshot surfaces stay expanded so visual regression coverage still sees the
        // rows inside every disclosure. The real dashboard passes its own collapsed state.
        self.expansion = expansion
            ?? MachineExpansionState(expandedByDefault: SnapshotConfig.flatSurfaces)
    }

    // Headless snapshots don't fire onAppear, so start visible in flat mode to skip the
    // entrance animation and render content immediately.
    @State private var isVisible = SnapshotConfig.flatSurfaces

    var body: some View {
        ScrollView {
            // Spacing.xl (24) between the two groups against Spacing.sm (12) inside one is
            // what separates them — twice the internal rhythm, and wider than the Spacing.lg
            // (20) that Settings and Accounts get away with. A rule between them would be the
            // app's only section-level divider, saying a second time what the gap and the two
            // SectionHeaders already say.
            VStack(alignment: .leading, spacing: Spacing.xl) {
                // Header and section arrive together, as one group, the way every other
                // tab's sections do. `entranceOwnedByParent()` stands the composed section's
                // own entrance down — without it the two sections ran their private
                // staggers here while the headers, wrapped in nothing, just appeared.
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    SectionHeader("Instances")
                    InstancesSection(model: instances, expansion: expansion)
                        .entranceOwnedByParent()
                }
                .staggerIn(index: 0, isVisible: isVisible)

                VStack(alignment: .leading, spacing: Spacing.sm) {
                    SectionHeader("Environment")
                    EnvironmentSection(model: environment, expansion: expansion)
                        .entranceOwnedByParent()
                }
                .staggerIn(index: 1, isVisible: isVisible)
            }
            .padding(.horizontal, Spacing.xl)
            .padding(.bottom, Spacing.xl)
            .padding(.top, topInset)
        }
        // Both view models keep their own independent lifecycle (polling vs. one-shot load) —
        // this tab just has to trigger both, the way each used to trigger its own when it was
        // its own top-level tab. A section that only started polling/loading when it happened
        // to be the sole tab would silently show stale or empty data once merged.
        .onAppear {
            isVisible = true
            instances.startPolling()
            environment.load()
        }
        .onDisappear {
            instances.stopPolling()
        }
    }
}

// MARK: - Machine disclosure card

/// Shared disclosure surface for process groups and environment collections. The header never
/// moves, so opening a card reads as revealing its contents rather than replacing the card.
/// A custom control keeps Toki's glass card treatment while retaining real Button semantics.
@MainActor
struct MachineDisclosureCard<Header: View, Details: View>: View {
    let isExpanded: Bool
    let accessibilityLabel: String
    let onToggle: () -> Void
    private let header: Header
    private let details: Details

    init(
        isExpanded: Bool,
        accessibilityLabel: String,
        onToggle: @escaping () -> Void,
        @ViewBuilder header: () -> Header,
        @ViewBuilder details: () -> Details
    ) {
        self.isExpanded = isExpanded
        self.accessibilityLabel = accessibilityLabel
        self.onToggle = onToggle
        self.header = header()
        self.details = details()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(revealAnimation) {
                    onToggle()
                }
            } label: {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: "chevron.right")
                        .iconSize(.small, weight: .semibold)
                        .foregroundStyle(Palette.textSecondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .animation(revealAnimation, value: isExpanded)
                        .frame(width: 10)

                    header
                }
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.sm)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(MachineDisclosureButtonStyle())
            .accessibilityLabel(accessibilityLabel)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint(isExpanded ? "Collapse details" : "Expand details")

            if isExpanded {
                Divider()
                    .overlay(Palette.hairline)

                details
                    .transition(
                        .opacity
                            .combined(with: .move(edge: .top))
                    )
            }
        }
        .panelCard()
        .animation(revealAnimation, value: isExpanded)
    }

    private var revealAnimation: Animation? {
        SnapshotConfig.flatSurfaces
            ? nil
            : .spring(response: 0.24, dampingFraction: 0.9)
    }
}

private struct MachineDisclosureButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Palette.raised.opacity(configuration.isPressed ? 0.65 : 0))
            .opacity(configuration.isPressed ? 0.82 : 1)
    }
}

// MARK: - Preview

#Preview("MachineView") {
    MachineView(
        instances: {
            let vm = InstancesViewModel(service: PreviewMachineInstancesService())
            vm.runMode = .fixture(.singleAccount)
            vm.snapshot = .empty
            return vm
        }(),
        environment: {
            let vm = EnvironmentViewModel(service: PreviewMachineEnvironmentService())
            vm.runMode = .fixture(.singleAccount)
            vm.environment = .empty
            return vm
        }()
    )
    .frame(width: 880, height: 720)
    .background(Palette.bg)
}

private struct PreviewMachineInstancesService: ClaudeInstancesProviding {
    func loadInstances() async -> ClaudeInstancesSnapshot { .empty }
}

private struct PreviewMachineEnvironmentService: EnvironmentProviding {
    func loadEnvironment() async -> ClaudeEnvironment { .empty }
}
