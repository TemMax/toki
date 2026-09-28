/// TokiSegmentedPicker — the dense segmented control the editor's rendering and compact-mode
/// choices are made with.
///
/// The dashboard already had one of these (`SegmentedControl`) but bound to exactly one enum,
/// `DashboardViewModel.Range`, so the editor could only reach for `.pickerStyle(.segmented)` —
/// which is why two stock AppKit slabs sat in the middle of a screen made of `panelCard()`
/// surfaces. This is the same control generalised over its options and sized for a 37pt row,
/// and it deliberately REUSES the dashboard's plumbing rather than growing a second copy of
/// it: `SegmentButtonStyle` (hands the label straight back) and `segmentFocusRing()` (confines
/// the system's own focus ring to the pill) both come from `SegmentedControl.swift`.
///
/// ## Every segment is a real `Button`, and the whole thing still reports a radio group
/// Two separate promises, and they need two separate mechanisms:
///  - The segments are `Button`s, so they are focusable, pressable and keyboard-reachable —
///    never `Text` + `.onTapGesture`, which is what the commit before this one had to undo
///    across the dashboard navigation.
///  - `accessibilityRepresentation` then hands assistive technology a real segmented `Picker`
///    over the same binding, so the control is announced as one grouped choice rather than
///    three unrelated buttons, and activating a segment through AT actually moves the
///    selection (verified, not assumed).
///
/// ## One measured difference from the stock control, left in place
/// The rendered stock `.pickerStyle(.segmented)` reported `AXRadioGroup` containing
/// `AXRadioButton`s with subrole `AXSegment`. Routed through `accessibilityRepresentation`
/// the same picker reports `AXTabGroup` containing `AXTabButton`s instead — measured before
/// and after, and NOT caused by the label (emptying it to match the stock call site changed
/// nothing). It is how the representation mechanism resolves, not something this call site
/// controls.
///
/// Left as is deliberately. "Tab" is a shade less precise than "segment" for what is a value
/// choice rather than a view switch, but the load-bearing facts survive: the control is one
/// named group, a screen reader hears "1 of 3" and which one is selected, and activation
/// works. Trading that for hand-rolled traits would give a vaguer `AXButton` and lose the
/// grouping — worse on the axis that matters.
///
/// ## Surface
/// A recessed track (`textPrimary` at 6%, the same self-adapting recess the dashboard control
/// uses, so it works on `card` and on `bg` alike) with the selected segment lifted onto
/// `Palette.raised` — the same plane as every field and stepper well beside it. The selection
/// is a lift, not a colour: the accent is spent on the switches and the one affirmative
/// button, and a fourth copper blob per row would make the row shout.
import SwiftUI
import TokiDesign

struct TokiSegmentedPicker<Value: Hashable>: View {

    struct Option: Identifiable {
        let value: Value
        let title: String
        var id: Value { value }

        init(_ value: Value, _ title: String) {
            self.value = value
            self.title = title
        }
    }

    @Binding var selection: Value
    let options: [Option]
    /// Spoken name for the set — "Rendering", "Compact mode". Without it a screen-reader user
    /// hears three titles with nothing saying what they choose between.
    let name: String
    var role: TypeScale.Role = .caption

    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options) { option in
                segment(option)
            }
        }
        // Half a step of the smallest spacing token — the track's inset is a hairline gap,
        // not a layout gap, and every real spacing step is visibly too big at this size.
        .padding(Spacing.xxs / 2)
        .background(
            ControlShape.rounded.fill(Palette.textPrimary.opacity(0.06))
        )
        .animation(.spring(response: 0.26, dampingFraction: 0.86), value: selection)
        .accessibilityRepresentation {
            Picker(name, selection: $selection) {
                ForEach(options) { option in
                    Text(option.title).tag(option.value)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private func segment(_ option: Option) -> some View {
        let isSelected = selection == option.value
        return Button {
            selection = option.value
        } label: {
            Text(option.title)
                .textStyle(role)
                .foregroundStyle(isSelected ? Palette.textPrimary : Palette.textSecondary)
                .lineLimit(1)
                .padding(.horizontal, Spacing.xxs)
                .padding(.vertical, Spacing.xxs / 2)
                .frame(maxWidth: .infinity)
                // The pill is a BACKGROUND, not a ZStack sibling: a bare `Shape` answers any
                // proposal with the whole of it, so as a sibling it dragged the control to the
                // full height of whatever row it was in (measured: a 22pt segmented control
                // rendered 100pt tall inside the indicator row).
                .background {
                    if isSelected {
                        ControlShape.rounded
                            .fill(Palette.raised)
                            .overlay(
                                ControlShape.rounded
                                    .strokeBorder(Palette.hairline, lineWidth: BorderWidth.card)
                            )
                            .matchedGeometryEffect(id: "toki_segment_selection", in: namespace)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(SegmentButtonStyle())
        .segmentFocusRing()
    }
}
