/// InstancesView — the "Instances" tab: a live, grouped-by-version list of
/// running Claude Code and Codex CLI processes.
///
/// Renders INSIDE the Dashboard content area (no toolbar, no window
/// background — the dashboard supplies those). Uses only design-system
/// primitives: panelCard, Palette, SectionHeader, Spacing, Radius.
import TokiCore
import TokiFixtures
import SwiftUI

// MARK: - InstancesView

@MainActor
struct InstancesView: View {
    @Bindable var model: InstancesViewModel
    @State private var expansion: MachineExpansionState
    var topInset: CGFloat = 0

    init(model: InstancesViewModel, topInset: CGFloat = 0) {
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
            InstancesSection(model: model, expansion: expansion)
                .padding(.horizontal, Spacing.xl)
                .padding(.bottom, Spacing.xl)
                .padding(.top, topInset)
        }
        .onAppear {
            model.startPolling()
        }
        .onDisappear {
            model.stopPolling()
        }
    }
}

// MARK: - InstancesSection

/// The loading/empty/populated switch for a Claude instances scan — no `ScrollView`, no
/// lifecycle hooks, just the content. Factored out of `InstancesView.body` so `MachineView`
/// can lay it inside the Machine tab's own single scroll region instead of nesting a second
/// `ScrollView` (which `InstancesView.body` owns for its standalone-tab-surface use, e.g. the
/// snapshot harness's bare "instances" surface).
@MainActor
struct InstancesSection: View {
    @Bindable var model: InstancesViewModel
    let expansion: MachineExpansionState

    var body: some View {
        let instances = model.snapshot?.instances ?? []

        if model.snapshot == nil && model.isLoading {
            loadingState
        } else if instances.isEmpty {
            emptyState
        } else {
            InstancesContent(
                instances: instances,
                referenceVersion: model.snapshot?.referenceVersion,
                expansion: expansion,
                onKill: { pid in model.kill(pid: pid) }
            )
        }
    }

    // MARK: - States

    @ViewBuilder
    private var loadingState: some View {
        ProgressView("Scanning processes\u{2026}")
            .frame(maxWidth: .infinity, minHeight: 320, alignment: .center)
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: Spacing.sm) {
            Image(systemName: "terminal")
                .iconSize(.hero)
                .foregroundStyle(Palette.textSecondary)
            Text("No coding-tool sessions running")
                .textStyle(.headline)
                .foregroundStyle(Palette.textSecondary)
            Text("Launch the Claude CLI or Codex in a project to see it here.")
                .textStyle(.detail)
                .foregroundStyle(Palette.textSecondary.opacity(0.7))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, minHeight: 320, alignment: .center)
    }
}

// MARK: - InstancesContent

/// Instances grouped by version and rendered as stacked disclosure cards.
///
/// Sort order:
///   - Groups: by version DESCENDING (newest first); the "unknown" (nil
///     version) group always sorts last, regardless of comparison result.
///   - Within a group: by uptime DESCENDING (longest-running instance first,
///     i.e. earliest `startedAt`; instances with no `startedAt` sort last).
@MainActor
struct InstancesContent: View {
    let instances: [ClaudeInstance]
    let referenceVersion: String?
    let expansion: MachineExpansionState
    /// Called with a pid when its row's kill hold completes.
    var onKill: (Int32) -> Void = { _ in }

    // Headless snapshots don't fire onAppear, so start visible in flat mode
    // to skip the entrance animation and render content immediately.
    @State private var isVisible = SnapshotConfig.flatSurfaces

    private struct VersionGroup: Identifiable {
        let id: String
        let provider: UsageProvider
        let version: String?      // nil for the unknown group
        let instances: [ClaudeInstance]
    }

    private var groups: [VersionGroup] {
        struct GroupKey: Hashable {
            let provider: UsageProvider
            let version: String?
        }
        let dict = Dictionary(grouping: instances) {
            GroupKey(provider: $0.provider ?? .claudeCode, version: $0.version)
        }
        let built = dict.map { key, items -> VersionGroup in
            let sortedItems = items.sorted { a, b in
                // Longest-running first; missing startedAt sorts last.
                switch (a.startedAt, b.startedAt) {
                case let (lhs?, rhs?): return lhs < rhs
                case (nil, nil): return a.pid < b.pid
                case (nil, _): return false
                case (_, nil): return true
                }
            }
            return VersionGroup(
                id: "\(key.provider.rawValue):\(key.version ?? "unknown")",
                provider: key.provider,
                version: key.version,
                instances: sortedItems
            )
        }
        return built.sorted { lhs, rhs in
            if lhs.provider != rhs.provider {
                return lhs.provider == .claudeCode
            }
            switch (lhs.version, rhs.version) {
            case let (l?, r?):
                return versionIsNewer(l, than: r)
            case (nil, nil):
                return lhs.id < rhs.id
            case (nil, _):
                return false  // unknown always last
            case (_, nil):
                return true
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                let isExpanded = expansion.isExpanded("instances.\(group.id)")

                MachineDisclosureCard(
                    isExpanded: isExpanded,
                    accessibilityLabel: "\(group.provider.displayName) \(group.version ?? "unknown"), \(runningLabel(group.instances.count))",
                    onToggle: { expansion.toggle("instances.\(group.id)") }
                ) {
                    VersionGroupHeader(
                        version: "\(group.provider.displayName) · \(group.version ?? "unknown")",
                        count: group.instances.count,
                        totalMemoryBytes: totalMemory(in: group.instances),
                        oldestStartedAt: group.instances.compactMap(\.startedAt).min(),
                        isLatest: latestBadge(for: group)
                    )
                } details: {
                    VStack(spacing: 0) {
                        ForEach(Array(group.instances.enumerated()), id: \.element.id) { rowIndex, instance in
                            InstanceCard(instance: instance, onKill: { onKill(instance.pid) })
                            if rowIndex < group.instances.count - 1 {
                                Divider().overlay(Palette.hairline)
                            }
                        }
                    }
                }
                .staggerIn(index: index, isVisible: isVisible)
            }
        }
        .onAppear {
            isVisible = true
        }
    }

    private func runningLabel(_ count: Int) -> String {
        count == 1 ? "1 running" : "\(count) running"
    }

    private func totalMemory(in instances: [ClaudeInstance]) -> UInt64? {
        let values = instances.compactMap(\.memoryBytes)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +)
    }

    /// nil => no badge (referenceVersion unknown); true => [latest]; false => [outdated].
    private func latestBadge(for group: VersionGroup) -> Bool? {
        guard group.provider == .claudeCode else { return nil }
        guard let referenceVersion, let version = group.version else { return nil }
        if version == referenceVersion { return true }
        if group.instances.contains(where: { $0.isOutdated }) { return false }
        return versionIsNewer(version, than: referenceVersion) ? true : false
    }

    /// Best-effort dotted-numeric version comparison ("2.1.197" > "2.1.20").
    /// Falls back to string comparison when either side isn't numeric-dotted.
    private func versionIsNewer(_ lhs: String, than rhs: String) -> Bool {
        let lhsParts = lhs.split(separator: ".").compactMap { Int($0) }
        let rhsParts = rhs.split(separator: ".").compactMap { Int($0) }
        guard !lhsParts.isEmpty, !rhsParts.isEmpty else { return lhs > rhs }
        for (l, r) in zip(lhsParts, rhsParts) where l != r {
            return l > r
        }
        return lhsParts.count > rhsParts.count
    }
}


// MARK: - Preview

#Preview("InstancesView — populated") {
    InstancesView(model: {
        let vm = InstancesViewModel(service: PreviewInstancesService())
        vm.runMode = .fixture(.singleAccount)
        vm.snapshot = .previewSample
        return vm
    }())
    .frame(width: 720, height: 640)
    .background(Palette.bg)
}

#Preview("InstancesView — empty") {
    InstancesView(model: {
        let vm = InstancesViewModel(service: PreviewInstancesService())
        vm.runMode = .fixture(.singleAccount)
        vm.snapshot = .empty
        return vm
    }())
    .frame(width: 720, height: 640)
    .background(Palette.bg)
}

private struct PreviewInstancesService: ClaudeInstancesProviding {
    func loadInstances() async -> ClaudeInstancesSnapshot { .empty }
}

private extension ClaudeInstancesSnapshot {
    static var previewSample: ClaudeInstancesSnapshot {
        ClaudeInstancesSnapshot(
            instances: [
                ClaudeInstance(
                    pid: 4821,
                    version: "2.1.197",
                    executablePath: "/Users/example/.local/share/claude/versions/2.1.197/claude",
                    workingDirectory: "/Users/example/Developer/personal/Toki",
                    startedAt: Date().addingTimeInterval(-3600 * 3),
                    memoryBytes: 155_189_248,
                    source: .native,
                    isOutdated: false
                ),
                ClaudeInstance(
                    pid: 5310,
                    version: "2.1.197",
                    executablePath: "/Applications/Conductor.app/Contents/Resources/agent-binaries/claude/2.1.197/claude",
                    workingDirectory: "/Users/example/Developer/work/api-gateway",
                    startedAt: Date().addingTimeInterval(-60 * 5),
                    memoryBytes: 1_310_720_000,
                    source: .managed,
                    isOutdated: false
                ),
                ClaudeInstance(
                    pid: 2290,
                    version: "2.1.150",
                    executablePath: "/Users/example/.local/share/claude/versions/2.1.150/claude",
                    workingDirectory: "/Users/example/Developer/personal/old-project",
                    startedAt: Date().addingTimeInterval(-86400 * 2),
                    memoryBytes: 98_500_000,
                    source: .native,
                    isOutdated: true
                ),
            ],
            referenceVersion: "2.1.197"
        )
    }
}
