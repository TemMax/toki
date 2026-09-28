/// Typography — text style modifiers for the Toki design system.
///
/// .cardValue(): metricSmall role (title step, rounded semibold, tabular digits) — metric
///              numbers inside cards. Color: Palette.textPrimary (caller may override with
///              .foregroundStyle).
/// .cardLabel(): body role — labels/footnotes beneath metric numbers;
///              color: Palette.textSecondary.
///
/// Built on `TypeScale.Role` (see `Typography+Scale.swift`) rather than raw sizes, so these
/// two long-standing modifiers move with the rest of the app's text when the scale changes.
///
/// Always uses .foregroundStyle (never .foregroundColor).
import SwiftUI
import TokiDesign

// MARK: - CardValue

private struct CardValueModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .textStyle(.metricSmall)
            .foregroundStyle(Palette.textPrimary)
    }
}

// MARK: - CardLabel

private struct CardLabelModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .textStyle(.body)
            .foregroundStyle(Palette.textSecondary)
    }
}

// MARK: - View extensions

extension View {
    /// Card metric value: 16pt rounded semibold monospacedDigit, Palette.textPrimary.
    func cardValue() -> some View {
        modifier(CardValueModifier())
    }

    /// Card label: 12pt, Palette.textSecondary.
    func cardLabel() -> some View {
        modifier(CardLabelModifier())
    }
}

// MARK: - Preview

#Preview("Typography") {
    VStack(alignment: .leading, spacing: 8) {
        Text("1.2M")
            .cardValue()
        Text("Tokens (In+Out)")
            .cardLabel()

        Divider()

        Text("$14.92")
            .cardValue()
        Text("Total Cost")
            .cardLabel()
    }
    .padding(20)
    .background(Palette.surface)
}
