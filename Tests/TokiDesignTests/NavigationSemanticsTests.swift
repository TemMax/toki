import Foundation
import Testing

/// One of the app's two primary navigation strips, and the `matchedGeometryEffect` id that
/// only that strip uses — which is what lets an assertion be scoped to its per-item builder
/// instead of to any `Button` that happens to share the file.
struct NavigationStrip: Sendable, CustomStringConvertible {
    let file: String
    let namespaceID: String
    var description: String { file }
}

/// Guards the one property of the app's primary navigation that cannot be seen by looking at
/// it: that the tab strip and the range strip are *controls*, not styled text.
///
/// Both strips were `Text` + `.onTapGesture`, which renders identically to a button and is
/// nothing like one — measured through the debug channel, all eight reported `AXStaticText`
/// with no press action, so VoiceOver read the entire navigation as labels and a keyboard
/// could not reach it at all. None of that is visible in a screenshot or a preview, and a
/// pixel-diff of the fix is (deliberately) empty, so a future edit could quietly reintroduce
/// it with every visual check still passing.
///
/// It reads the sources as text because `App/Sources` is not a SwiftPM target and `swift test`
/// cannot instantiate a view from it. That makes this a coarse guard: it proves the button
/// role and the selected trait are still *asked for*, and leaves proving they arrive to the
/// accessibility-tree dump. Coarse and present beats exact and impossible.
@Suite("Primary navigation is built from controls, not tappable text")
struct NavigationSemanticsTests {
    static let strips = [
        NavigationStrip(file: "App/Sources/DashboardView.swift", namespaceID: "section_switch_selection"),
        NavigationStrip(file: "App/Sources/SegmentedControl.swift", namespaceID: "seg_selection"),
    ]

    @Test("every navigation segment is a Button, not a tapped Text", arguments: strips)
    func segmentsAreButtons(strip: NavigationStrip) throws {
        let segment = try Self.segmentBuilder(of: strip)

        #expect(
            segment.contains("Button {"),
            "\(strip.file)'s segments must be Buttons: role, press action and focus come from that"
        )
        #expect(
            !segment.contains(".onTapGesture"),
            "\(strip.file) is back on .onTapGesture, which reports AXStaticText"
        )
    }

    @Test("the active segment says so, it does not merely look so", arguments: strips)
    func activeSegmentExposesSelection(strip: NavigationStrip) throws {
        let segment = try Self.segmentBuilder(of: strip)

        #expect(
            segment.contains(".isSelected"),
            "\(strip.file)'s selected segment must carry the isSelected trait, or a screen-reader user cannot tell which one is active"
        )
    }

    @Test("each strip is announced as one set, not four loose buttons", arguments: strips)
    func stripIsAnAccessibilityContainer(strip: NavigationStrip) throws {
        let source = try Self.read(strip.file)

        #expect(source.contains(".accessibilityElement(children: .contain)"))
        #expect(source.contains(".accessibilityLabel("))
    }

    /// The Machine tab's two sections are separated by space and their own headers. A rule
    /// between them would be the app's only section-level divider — Settings, Accounts and
    /// Usage all manage without one — saying a second time what the 24pt gap already says.
    @Test("the Machine tab separates its sections with space, not a rule")
    func machineTabHasNoSectionDivider() throws {
        let source = try Self.read("App/Sources/MachineView.swift")
        let disclosureMarker = try #require(
            source.range(of: "// MARK: - Machine disclosure card"),
            "MachineView's disclosure component marker is missing"
        )
        // Disclosure cards legitimately divide their fixed header from the revealed rows.
        // This assertion is about the page-level layout above that reusable component.
        let machineLayout = source[..<disclosureMarker.lowerBound]

        #expect(!machineLayout.contains("Divider()"))
        #expect(
            machineLayout.contains("VStack(alignment: .leading, spacing: Spacing.xl)"),
            "the gap is what separates the groups: Spacing.xl (24) against the Spacing.sm (12) inside each"
        )
    }

    // MARK: - Reading App/Sources

    /// Repo root, derived from this file's own path — the suite has to work from whatever
    /// directory `swift test` happens to be invoked in.
    static func read(_ relativePath: String, sourceFile: String = #filePath) throws -> String {
        let root = URL(fileURLWithPath: sourceFile)
            .deletingLastPathComponent()   // TokiDesignTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
        return try String(contentsOf: root.appending(path: relativePath), encoding: .utf8)
    }

    /// The text of a strip's `segment(for:)` builder, from the declaration to the end of the
    /// type that owns it. Fails the test rather than passing vacuously if either the builder
    /// or the strip's own namespace id has gone missing.
    static func segmentBuilder(of strip: NavigationStrip) throws -> String {
        let source = try read(strip.file)
        let marker = try #require(
            source.range(of: "private func segment(for item:"),
            "no segment(for:) builder in \(strip.file)"
        )
        let body = source[marker.lowerBound...]
        #expect(body.contains(strip.namespaceID), "\(strip.file) no longer builds \(strip.namespaceID)")

        // Up to the end of the enclosing type — its closing brace is the first at column zero.
        guard let end = body.range(of: "\n}\n") else { return String(body) }
        return String(body[..<end.upperBound])
    }
}
