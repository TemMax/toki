import Foundation
import Testing

/// Guards the Machine tab's progressive-disclosure contract. App/Sources is not a SwiftPM
/// target, so these tests assert the structural properties that screenshots cannot: real
/// controls, an announced expanded state, and ownership above the tab switch.
@Suite("Machine progressive disclosure")
struct MachineDisclosureSemanticsTests {
    @Test("every Machine disclosure is a button that announces its state")
    func disclosureUsesAccessibleButtonSemantics() throws {
        let source = try Self.read("App/Sources/MachineView.swift")
        let disclosure = try #require(
            source.range(of: "struct MachineDisclosureCard"),
            "MachineDisclosureCard is missing"
        )
        let body = source[disclosure.lowerBound...]

        #expect(body.contains("Button {"))
        #expect(body.contains(".accessibilityValue(isExpanded ? \"Expanded\" : \"Collapsed\")"))
        #expect(body.contains(".accessibilityHint(isExpanded ? \"Collapse details\" : \"Expand details\")"))
        #expect(!body.contains(".onTapGesture"))
    }

    @Test("the dashboard owns expansion state across tab switches without persisting it")
    func dashboardOwnsSessionState() throws {
        let dashboard = try Self.read("App/Sources/DashboardView.swift")
        let machine = try Self.read("App/Sources/MachineView.swift")

        #expect(dashboard.contains("@State private var machineExpansion = MachineExpansionState()"))
        #expect(dashboard.contains("expansion: machineExpansion"))
        #expect(machine.contains("init(expandedByDefault: Bool = false)"))
        #expect(!machine.contains("@AppStorage"))
        #expect(!machine.contains("UserDefaults."))
    }

    @Test("environment disclosures stay in one stable full-width column")
    func environmentUsesStableAccordionLayout() throws {
        let source = try Self.read("App/Sources/EnvironmentView.swift")
        let content = try #require(
            source.range(of: "struct EnvironmentContent"),
            "EnvironmentContent is missing"
        )
        let body = source[content.lowerBound...]

        #expect(body.contains("VStack(alignment: .leading, spacing: Spacing.sm)"))
        #expect(body.contains("toggleExclusively("))
        #expect(!body.contains("LazyVGrid"))
        #expect(!body.contains("GridItem("))
    }

    @Test("headless snapshots expand disclosures to keep detail rows covered")
    func snapshotsKeepDetailCoverage() throws {
        let machine = try Self.read("App/Sources/MachineView.swift")
        let instances = try Self.read("App/Sources/InstancesView.swift")
        let environment = try Self.read("App/Sources/EnvironmentView.swift")

        #expect(machine.contains("expandedByDefault: SnapshotConfig.flatSurfaces"))
        #expect(instances.contains("expandedByDefault: SnapshotConfig.flatSurfaces"))
        #expect(environment.contains("expandedByDefault: SnapshotConfig.flatSurfaces"))
    }

    @Test("plugin rows expose current, outdated, and unknown version states")
    func pluginRowsExposeVersionState() throws {
        let source = try Self.read("App/Sources/EnvironmentCards.swift")

        #expect(source.contains("struct PluginVersionBadge"))
        #expect(source.contains("case .upToDate:"))
        #expect(source.contains("case .outdated:"))
        #expect(source.contains("case .unknown:"))
        #expect(source.contains("Version status:"))
    }

    private static func read(_ relativePath: String, sourceFile: String = #filePath) throws -> String {
        let root = URL(fileURLWithPath: sourceFile)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appending(path: relativePath), encoding: .utf8)
    }
}
