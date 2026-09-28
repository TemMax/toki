/// SectionHeader — section label and hero number text styles.
///
/// SectionHeader: uppercased, 11pt semibold tracked caps in Palette.textSecondary.
///
/// .heroNumber(): thin hero numerals — 32pt rounded LIGHT monospacedDigit.
/// The deliberate weight contrast (light huge number vs semibold tiny caps label)
/// creates clear hierarchy: one element dominates each surface.
import SwiftUI

// MARK: - SectionHeader

struct SectionHeader: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title.uppercased())
            .textStyle(.label)
            .kerning(0.5)
            .foregroundStyle(Palette.textSecondary)
    }
}

// MARK: - HeroNumber modifier

private struct HeroNumberModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            // `hero` is now LIGHT (see `TypeScale.Role.hero`'s doc comment) precisely so this
            // site — its one real text consumer — can read the role instead of a raw literal.
            .textStyle(.hero)
    }
}

extension View {
    /// Applies the hero KPI text style: 32pt rounded LIGHT monospacedDigit.
    /// The thin weight creates strong contrast against the semibold caps labels.
    func heroNumber() -> some View {
        modifier(HeroNumberModifier())
    }
}

// MARK: - Preview

#Preview("SectionHeader + heroNumber") {
    VStack(alignment: .leading, spacing: 12) {
        SectionHeader("Current Usage")
        Text("$42.80")
            .heroNumber()
            .foregroundStyle(Palette.textPrimary)
        SectionHeader("Rate Limits")
        Text("87%")
            .heroNumber()
            .foregroundStyle(Palette.critical)
    }
    .padding(20)
    .background(Palette.surface)
}
