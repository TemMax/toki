/// Typography+Scale — maps `TypeScale.Role` onto a SwiftUI `Font`.
///
/// `TokiDesign` is pure data (no SwiftUI import, so it stays usable from anywhere), so this
/// is the one place a `Role` becomes an actual `Font`. Every call site in `App/Sources` reads
/// text size through `.textStyle(_ role:)` below rather than a raw `.system(size:)` literal —
/// `scripts/lint-type-scale.sh` enforces that in CI.
///
/// Named `textStyle`, not `font`: an unlabelled `font(_ role: TypeScale.Role)` is an exact
/// type match that wins overload resolution against SwiftUI's own `font(_ font: Font?)` for
/// every literal that happens to share a case name (`.body`, `.headline`, `.caption`,
/// `.title` are both `Role` cases and `Font` static members). That silently rerouted
/// `.font(.title)` (meant as SwiftUI's ~22pt) through our 15pt `title` role, with no compiler
/// warning. `.textStyle(.body)` cannot collide with anything `Font` defines.
import SwiftUI
import TokiDesign

extension Font {
    /// Builds the `Font` for a role at the app's current ambient scale
    /// (`TypeScale.Role.resolvedSize` — never `spec.step.rawValue` directly, so a future
    /// text-size setting reaches every role through the one multiplier).
    init(role: TypeScale.Role) {
        let spec = role.spec
        self = .system(size: role.resolvedSize, weight: spec.weight.swiftUI, design: spec.design.swiftUI)
        if spec.monospacedDigits {
            self = self.monospacedDigit()
        }
    }
}

/// Not `private`: `IconSize+Modifier.swift` reuses this mapping so icon weights and text
/// weights go through the same `TypeScale.Weight` → `Font.Weight` table rather than two.
extension TypeScale.Weight {
    var swiftUI: Font.Weight {
        switch self {
        case .light: .light
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        }
    }
}

private extension TypeScale.Design {
    var swiftUI: Font.Design {
        switch self {
        case .default: .default
        case .rounded: .rounded
        case .monospaced: .monospaced
        }
    }
}

extension View {
    /// The type-scale entry point: `.textStyle(.title)`, `.textStyle(.metricInline)`, etc. —
    /// reads at call sites the way the codebase's existing `.cardValue()` / `.cardLabel()`
    /// modifiers do, but for the full role set rather than two hand-rolled styles.
    func textStyle(_ role: TypeScale.Role) -> some View {
        font(Font(role: role))
    }
}
