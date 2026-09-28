/// StaggerIn — the entrance treatment every section's cards share: a fade and lift,
/// delayed by one step per card.
import SwiftUI

/// Whether the content is drawn at rest is deliberately NOT just `isVisible`.
///
/// Callers raise `isVisible` from `onAppear`, so the content is visible only *because* an
/// animation callback fired. Anything that suppresses or never runs that callback would
/// otherwise leave the whole section at opacity 0 — present in the hierarchy, invisible on
/// screen. Two cases where that is exactly what happens:
///
///   - **Reduce Motion**, where an entrance animation should not play at all. Tying presence
///     to the animation flag turns "don't animate this" into "don't show this".
///   - **Offscreen snapshot rendering**, where `onAppear` never fires.
///
/// In both, the content must appear settled, not disappear.
private struct StaggerIn: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.staggerInSuppressed) private var suppressed

    let index: Int
    let isVisible: Bool

    /// Skip the entrance entirely — the user asked for less motion, nothing is going to
    /// drive the transition, or a surrounding view has taken the entrance over.
    private var skipsEntrance: Bool { reduceMotion || SnapshotConfig.staticEntrance || suppressed }

    private var settled: Bool { isVisible || skipsEntrance }

    func body(content: Content) -> some View {
        content
            .opacity(settled ? 1 : 0)
            .offset(y: settled ? 0 : 8)
            .animation(
                skipsEntrance
                    ? nil
                    : .spring(response: 0.38, dampingFraction: 0.82)
                        .delay(Double(index) * 0.05),
                value: isVisible
            )
    }
}

// MARK: - Suppression

/// Whether a surrounding view has taken over the entrance for this subtree.
///
/// A section that is COMPOSED into a larger surface has to arrive as part of that surface,
/// not on a clock of its own. `MachineView` stacks `InstancesSection` and
/// `EnvironmentSection` under headers it writes itself, and both of those carry the
/// entrance they need when they stand alone (`InstancesView` / `EnvironmentView`). Left
/// running inside Machine they slid their own cards, from their own offset, on their own
/// two independent timelines, while the headers above them — which nothing wrapped — simply
/// appeared. That is one screen animating as three things.
///
/// A composing view raises this over the parts it has adopted and staggers the whole group
/// once, so the group moves as one piece.
private struct StaggerInSuppressedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var staggerInSuppressed: Bool {
        get { self[StaggerInSuppressedKey.self] }
        set { self[StaggerInSuppressedKey.self] = newValue }
    }
}

extension View {
    /// Fades + lifts in with a spring, delayed by `index` steps.
    func staggerIn(index: Int, isVisible: Bool) -> some View {
        modifier(StaggerIn(index: index, isVisible: isVisible))
    }

    /// Draws this subtree settled and lets an enclosing `staggerIn` animate it instead —
    /// see `staggerInSuppressed` above.
    func entranceOwnedByParent() -> some View {
        environment(\.staggerInSuppressed, true)
    }
}
