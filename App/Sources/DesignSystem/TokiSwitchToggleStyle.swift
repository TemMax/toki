/// TokiSwitchToggleStyle — the app's switch: a `raised` well that fills with the accent.
///
/// A `ToggleStyle`, so the call site still writes `Toggle(…, isOn:)` and the control stays a
/// control. That matters more here than anywhere else in the editor: a switch drawn as a
/// shape with a tap gesture has no role, no on/off value and no keyboard focus, and the
/// commit before this one exists solely to undo that mistake elsewhere in the app.
///
/// ## Keeping the role
/// A custom `ToggleStyle` has to *do* something with the press, and the only honest way to
/// take a press is a `Button` — which would report `AXButton` and drop the on/off value a
/// switch is for. `accessibilityRepresentation` is the fix: the visible view is ours, while
/// assistive technology is handed a plain system `Toggle` bound to the very same
/// `configuration.$isOn`, so the element stays `AXCheckBox` / `AXToggle` with a real value and
/// a working action. The representation pins `.toggleStyle(.switch)` explicitly — inheriting
/// this style there would recurse.
///
/// ## Colour
/// On: `Palette.accent` track with a `Palette.onAccent` knob — the same measured pair the
/// filled button uses (5.99:1 light, 6.17:1 dark; `ContrastTests`), which is why the knob
/// inverts with the appearance instead of always being white. White-on-accent would sit at
/// 2.89:1 in dark mode, i.e. a knob you cannot find.
/// Off: the same opaque `controlWell()` surface as the fields beside it, with a
/// `textSecondary` knob — so an off switch reads as an empty well of the same material,
/// rather than as a different control.
import SwiftUI

struct TokiSwitchToggleStyle: ToggleStyle {

    /// Sized to the editor's indicator row: the stock `.mini` switch it replaces was 26x15,
    /// and the row's 37pt pitch has no room to grow.
    private static let trackWidth: CGFloat = 28
    private static let trackHeight: CGFloat = 16
    private static let knobInset: CGFloat = 2

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: Spacing.xs) {
                configuration.label
                track(isOn: configuration.isOn)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
                .toggleStyle(.switch)
        }
    }

    private func track(isOn: Bool) -> some View {
        let knobDiameter = Self.trackHeight - Self.knobInset * 2
        return ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule(style: .continuous)
                .fill(isOn ? AnyShapeStyle(Palette.accent) : AnyShapeStyle(Palette.raised))
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(Palette.hairline, lineWidth: BorderWidth.card)
                        .opacity(isOn ? 0 : 1)
                )
            Circle()
                .fill(isOn ? Palette.onAccent : Palette.textSecondary)
                .frame(width: knobDiameter, height: knobDiameter)
                .padding(Self.knobInset)
        }
        .frame(width: Self.trackWidth, height: Self.trackHeight)
        .animation(.easeOut(duration: 0.15), value: isOn)
    }
}

extension ToggleStyle where Self == TokiSwitchToggleStyle {

    /// The app's switch — see `TokiSwitchToggleStyle` for why it is a style and not a shape.
    static var tokiSwitch: TokiSwitchToggleStyle { TokiSwitchToggleStyle() }
}
