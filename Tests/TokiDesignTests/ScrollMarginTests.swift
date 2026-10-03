import Foundation
import Testing

/// Guards the Speed tab's "Models in table" popover against the dashboard's scroll margin.
///
/// `DashboardView` applies `.contentMargins(.top, …, for: .scrollContent)` so tab content
/// clears the floating toolbar. That is an environment value, so it also reaches the
/// `ScrollView` inside the popover and pushes its list ~138 pt below the title, leaving an
/// empty band. The popover's scroll view must opt out with a zero top margin.
///
/// Reads the source as text because `App/Sources` is not a SwiftPM target.
@Suite("Model picker popover opts out of the dashboard scroll margin")
struct ScrollMarginTests {
    @Test("the picker's ScrollView zeroes the inherited top content margin")
    func pickerScrollViewZeroesTopMargin() throws {
        let source = try NavigationSemanticsTests.read("App/Sources/SpeedView.swift")
        let lines = source.components(separatedBy: "\n")

        let title = try #require(lines.firstIndex { $0.contains("Text(\"Models in table\")") })
        let scroll = try #require(lines[title...].firstIndex { $0.contains("ScrollView") })
        let end = try #require(lines[scroll...].firstIndex { $0.contains(".frame(width:") })
        let block = lines[scroll...end].joined(separator: "\n")

        #expect(
            block.contains(".contentMargins(.top, 0, for: .scrollContent)"),
            "the picker's ScrollView inherits the dashboard's toolbar margin through the environment"
        )
    }
}
