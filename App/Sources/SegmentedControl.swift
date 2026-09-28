/// SegmentedControl — a polished pure-SwiftUI segmented control for the Toki dashboard.
///
/// Replaces the native `.pickerStyle(.segmented)` with a refined macOS-style indicator
/// that slides via matchedGeometryEffect. No AppKit dependencies.
/// All colors use Palette tokens; selected text Palette.textPrimary, unselected Palette.textSecondary.
import SwiftUI

// MARK: - SegmentedControl

/// A polished segmented control that matches Toki's Quarried Slate design system.
///
/// Usage:
/// ```swift
/// SegmentedControl(selection: $model.range)
/// ```
struct SegmentedControl: View {
    @Binding var selection: DashboardViewModel.Range
    @Namespace private var namespace

    private let items = DashboardViewModel.Range.allCases

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items, id: \.self) { item in
                segment(for: item)
            }
        }
        // Names the set the four buttons belong to, so a screen-reader user hears
        // "Date range, 7 Days, selected" instead of four unrelated buttons.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Date range")
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: Radius.element, style: .continuous)
                .fill(Palette.textPrimary.opacity(0.06))
        )
        // Was a fixed 280 for 3 segments (~93pt each); 4 segments at the same per-item width.
        .frame(maxWidth: 373)
        .frame(height: 30)            // fixed height — must not grow vertically
        .fixedSize(horizontal: false, vertical: true)
        .animation(.spring(response: 0.28, dampingFraction: 0.85), value: selection)
    }

    /// Compact display label (the enum rawValue is verbose for a segmented control).
    private func label(for item: DashboardViewModel.Range) -> String {
        switch item {
        case .today:      return "Today"
        case .last7Days:  return "7 Days"
        case .last30Days: return "30 Days"
        case .allTime:    return "All Time"
        }
    }

    // MARK: - Segment button

    @ViewBuilder
    private func segment(for item: DashboardViewModel.Range) -> some View {
        let isSelected = selection == item

        Button {
            selection = item
        } label: {
            ZStack {
                // Sliding selected indicator
                if isSelected {
                    selectedPill
                        .matchedGeometryEffect(id: "seg_selection", in: namespace)
                }

                // Label
                Text(label(for: item))
                    .textStyle(.body)
                    .foregroundStyle(isSelected ? Palette.textPrimary : Palette.textSecondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, minHeight: 24)
                    .padding(.horizontal, Spacing.xs)
                    .contentShape(Rectangle())
            }
        }
        .buttonStyle(SegmentButtonStyle())
        .segmentFocusRing()
        // Appearance already says which segment is current; this is the same fact said out
        // loud, so a screen-reader user can tell the active range from the other three.
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    // MARK: - Selected pill

    @ViewBuilder
    private var selectedPill: some View {
        SelectedPillBackground()
    }
}

// MARK: - Segment button plumbing

/// Draws a segment's label with no press styling of its own.
///
/// The segments are `Button`s for what a `Button` *is*, not for what it looks like: a
/// `Text` + `.onTapGesture` reports `AXStaticText` with no press action, so VoiceOver reads
/// the whole tab strip as four labels and the keyboard cannot reach it at all. Those come
/// free with a button; the visuals are the label's job and must stay byte-identical, which
/// is why this style hands `configuration.label` straight back — a pressed-state tint here
/// would be a pixel change nobody asked for.
struct SegmentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

extension View {
    /// Confines the *system's own* focus ring to the selected-pill silhouette.
    ///
    /// The ring itself is left to AppKit/SwiftUI — it then follows whatever the user's focus
    /// conventions are (Full Keyboard Access, accent colour, increased contrast) instead of a
    /// hand-drawn stroke that only imitates them. Only its shape is ours, so it hugs the pill
    /// rather than boxing it; being an overlay, it costs no layout and changes no unfocused pixel.
    func segmentFocusRing() -> some View {
        contentShape(.focusEffect, RoundedRectangle(cornerRadius: 11, style: .continuous))
    }
}

// MARK: - SelectedPillBackground

/// The raised pill that sits behind the selected segment label.
/// Light: Palette.card; Dark: lifted Palette.surface — both cool slate and on-brand.
private struct SelectedPillBackground: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        RoundedRectangle(cornerRadius: 11, style: .continuous)
            .fill(pillFill)
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(Palette.hairline, lineWidth: 0.5)
            )
            .shadow(color: Color.black.opacity(0.10), radius: 1, x: 0, y: 0.5)
    }

    private var pillFill: Color {
        // Light: Palette.card (cool slate lift). Dark: Palette.surface (elevated cool dark).
        scheme == .light ? Palette.card : Palette.surface
    }
}

// MARK: - Preview

#Preview("SegmentedControl") {
    struct PreviewWrapper: View {
        @State private var range: DashboardViewModel.Range = .last7Days

        var body: some View {
            VStack(spacing: 20) {
                SegmentedControl(selection: $range)
                Text("Selected: \(range.rawValue)")
                    .textStyle(.detail)
                    .foregroundStyle(Palette.textSecondary)
            }
            .padding(24)
            .frame(width: 400)
            .background(Palette.surface)
        }
    }

    return PreviewWrapper()
}
