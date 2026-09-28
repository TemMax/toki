/// ControlSurface — the shape and the two fills every Toki control is cut from.
///
/// The editor used to be stock AppKit chrome with `.tint(Palette.accent)` bolted on, which is
/// why it read as a system dialog dropped into the app. The fix is one shared surface
/// vocabulary that the button, toggle, field, stepper and picker treatments all draw from, so
/// a control is recognisably the same material as the `panelCard()` it sits on.
///
/// ## Two surfaces, and why they are different
///
/// **`controlWell()` — opaque `Palette.raised`.** Everything that *holds a value* (text
/// fields, stepper wells, the menu picker, the switch track) sits INSIDE a `panelCard()`,
/// which is already a frosted material. `raised` is the palette's nearest-to-the-user plane
/// and was measured for exactly this job (>= 3.0 ΔL* from `card`, see `PlaneSeparationTests`),
/// so the well reads as a lift without a second blur on top of the card's.
///
/// A material or a `glassEffect` here would be the wrong call twice over: at ~21pt tall over
/// an already-frosted card there is nothing behind it to sample but the card's own blur — it
/// resolves to a flat tint, indistinguishable from this fill — and it would put the text a
/// value field carries onto a background whose contrast cannot be measured. Being opaque also
/// means `SnapshotConfig.flatSurfaces` needs no stand-in branch: the snapshot draws the same
/// pixels the app does, which is a stronger guarantee than a stand-in that merely looks right.
///
/// **`controlGlass()` — real Liquid Glass on macOS 26, `.ultraThinMaterial` below it.** Only
/// the *pressable* neutral surfaces (the secondary/icon button roles) use it. A button is the
/// one control the pointer actually pushes, and `Glass.interactive()` is a response — the
/// highlight tracks the press — that no static fill reproduces; that is the "genuinely
/// improves the control" bar the material fallback does not clear on its own. It is honest
/// about its limits, though: `flatSurfaces` falls back to the same opaque `raised` fill as a
/// well, because neither a material nor `glassEffect` composites offscreen (see
/// `SurfaceRenderer`'s doc comment) and an invisible button makes the editor unreviewable.
///
/// The FILLED accent button is deliberately NOT glass — see `TokiButtonStyle`.
import SwiftUI

// MARK: - Shape

enum ControlShape {

    /// One radius for every control, from `Radius` — the small-control step the segmented
    /// control and pills already use, so a field, a button and a switch track are visibly
    /// members of the same set rather than three unrelated roundings.
    static var rounded: RoundedRectangle {
        RoundedRectangle(cornerRadius: Radius.element, style: .continuous)
    }
}

// MARK: - Well

private struct ControlWellModifier: ViewModifier {
    var horizontal: CGFloat
    var vertical: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, horizontal)
            .padding(.vertical, vertical)
            .background(ControlShape.rounded.fill(Palette.raised))
            .overlay(ControlShape.rounded.strokeBorder(Palette.hairline, lineWidth: BorderWidth.card))
    }
}

// MARK: - Glass

private struct ControlGlassModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if SnapshotConfig.opaqueSurfaces(reduceTransparency: reduceTransparency) {
            fallback(content)
        } else if #available(macOS 26, *) {
            content.glassEffect(.regular.interactive(), in: ControlShape.rounded)
        } else {
            fallback(content, fill: AnyShapeStyle(.ultraThinMaterial))
        }
    }

    /// The pre-26 (and snapshot) surface: a fill plus the same hairline rim the wells carry,
    /// so a button on macOS 14 is still a Toki button and not a bare label.
    private func fallback(
        _ content: Content,
        fill: AnyShapeStyle = AnyShapeStyle(Palette.raised)
    ) -> some View {
        content
            .background(ControlShape.rounded.fill(fill))
            .overlay(ControlShape.rounded.strokeBorder(Palette.hairline, lineWidth: BorderWidth.card))
    }
}

// MARK: - View extensions

extension View {

    /// A value-holding control's well: opaque `raised` plane, hairline rim, control radius.
    /// Defaults are the editor's dense metrics — a ~21pt-tall control that fits the indicator
    /// row's 37pt pitch.
    func controlWell(
        horizontal: CGFloat = Spacing.xs,
        vertical: CGFloat = Spacing.xxs
    ) -> some View {
        modifier(ControlWellModifier(horizontal: horizontal, vertical: vertical))
    }

    /// A pressable neutral surface: real Liquid Glass on macOS 26, material below, opaque in
    /// snapshots. Used by `TokiButtonStyle`; not for anything that holds a value.
    func controlGlass() -> some View {
        modifier(ControlGlassModifier())
    }
}
