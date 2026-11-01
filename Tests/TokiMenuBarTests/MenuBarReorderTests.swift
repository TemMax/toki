import CoreGraphics
import Foundation
import Testing
@testable import TokiMenuBar

@Suite("Menu bar editor reordering")
struct MenuBarReorderTests {
    private let a = MenuBarIndicator(window: .fiveHour, rendering: .number)
    private let b = MenuBarIndicator(window: .sevenDay, rendering: .number)
    private let c = MenuBarIndicator(window: .extraUsage, rendering: .number)

    @Test("a row lands in the slot of the row it was dropped on, in either direction")
    func moving() {
        let list = [a, b, c]
        #expect(MenuBarReorder.moving(a.id, toPositionOf: c.id, in: list).map(\.id) == [b.id, c.id, a.id])
        #expect(MenuBarReorder.moving(c.id, toPositionOf: a.id, in: list).map(\.id) == [c.id, a.id, b.id])
        #expect(MenuBarReorder.moving(a.id, toPositionOf: b.id, in: list).map(\.id) == [b.id, a.id, c.id])
        #expect(MenuBarReorder.moving(b.id, toPositionOf: b.id, in: list).map(\.id) == [a.id, b.id, c.id])
        #expect(MenuBarReorder.moving(UUID(), toPositionOf: b.id, in: list).map(\.id) == [a.id, b.id, c.id])
    }

    /// Three 30pt rows with 10pt gaps: 0–30, 40–70, 80–110.
    private var rows: [(id: UUID, frame: CGRect)] {
        [a, b, c].enumerated().map { (id: $1.id, frame: CGRect(x: 0, y: CGFloat($0) * 40, width: 300, height: 30)) }
    }

    @Test("the drop slot follows the dragged row's centre", arguments: [
        (CGFloat(0), 0), (CGFloat(14), 0), (CGFloat(30), 1), (CGFloat(70), 2), (CGFloat(400), 2), (CGFloat(-50), 0),
    ])
    func target(translation: CGFloat, expected: Int) {
        let ids = [a.id, b.id, c.id]
        #expect(MenuBarReorder.target(dragging: a.id, translation: translation, rows: rows) == ids[expected])
    }

    @Test("dragging the last row up past the top lands it first")
    func upwards() {
        #expect(MenuBarReorder.target(dragging: c.id, translation: -200, rows: rows) == a.id)
        #expect(MenuBarReorder.target(dragging: c.id, translation: -40, rows: rows) == b.id)
        #expect(MenuBarReorder.target(dragging: UUID(), translation: 0, rows: rows) == nil)
    }
}
