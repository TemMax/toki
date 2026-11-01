/// Drag-to-reorder for the menu-bar editor's indicator list, as pure functions so the rules
/// are testable without a mouse.
import CoreGraphics
import Foundation

public enum MenuBarReorder {
    /// `indicators` with `id` moved into the slot `targetID` holds now: moving down lands it
    /// just after the target, moving up just before. Unknown ids leave the list unchanged.
    public static func moving(
        _ id: UUID, toPositionOf targetID: UUID, in indicators: [MenuBarIndicator]
    ) -> [MenuBarIndicator] {
        guard id != targetID,
              let from = indicators.firstIndex(where: { $0.id == id }),
              let to = indicators.firstIndex(where: { $0.id == targetID }) else { return indicators }
        var result = indicators
        let item = result.remove(at: from)
        result.insert(item, at: to)
        return result
    }

    /// The row a dragged row would take if dropped now: the one whose vertical span holds the
    /// dragged row's moved centre, clamped to the first or last row past either end.
    /// `rows` are the visible rows top to bottom with their frames in one coordinate space.
    public static func target(
        dragging id: UUID, translation: CGFloat, rows: [(id: UUID, frame: CGRect)]
    ) -> UUID? {
        guard let dragged = rows.first(where: { $0.id == id }), let first = rows.first,
              let last = rows.last else { return nil }
        let y = dragged.frame.midY + translation
        if y < first.frame.minY { return first.id }
        if y > last.frame.maxY { return last.id }
        // Gaps between rows (spacing, dividers) go to the nearer row.
        return rows.min { abs($0.frame.midY - y) < abs($1.frame.midY - y) }?.id
    }
}
