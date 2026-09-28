/// TokiControlChrome — the treatment that puts a text field, a stepper and a menu picker on
/// the same surface as everything else in the editor.
///
/// These three are the controls AppKit gives no style protocol for: there is no
/// `TextFieldStyle` you can write, no `StepperStyle` and no `PickerStyle` at all. What is
/// available is (a) the *plain* variant of each — the one that draws no bezel of its own — and
/// (b) the container it sits in. So the treatment is exactly that: strip the system bezel,
/// then put the control in a `controlWell()`, which is the same opaque `raised` plane, the
/// same hairline rim and the same `Radius.element` the buttons and the switch use.
///
/// **Nothing here rebuilds a control.** The field is still a `TextField`, the stepper is still
/// a `Stepper`, the picker is still a `Picker` — they keep `AXTextField`, `AXIncrementor` and
/// `AXPopUpButton`, their keyboard behaviour and their value semantics. The stepper's own
/// increment/decrement arrows are left as AppKit draws them: they are the one piece of chrome
/// with no plain variant, and two `Button`s in their place would trade a real `AXIncrementor`
/// for two unrelated buttons. Inside the well and paired with the value they read as part of
/// the field rather than as loose system furniture, which is the whole of what is being fixed.
import SwiftUI

/// Dropping the system bezel also drops the focus ring AppKit drew on it, and a text field
/// nobody can see the focus of is a keyboard trap of the quiet kind. The well therefore draws
/// its own: an accent rim, on the same shape, only while the field holds focus. `@FocusState`
/// lives here rather than at the call site so every field gets it for free — the editor has
/// four of them and none should have to remember.
private struct TokiFieldModifier: ViewModifier {
    @FocusState private var isFocused: Bool

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .focused($isFocused)
            .controlWell(horizontal: Spacing.xs, vertical: Spacing.xxs)
            .overlay(
                ControlShape.rounded
                    // Twice the card hairline: a rim that reads as "this one is live" next to
                    // three that are not, without becoming a second border weight in the app.
                    .strokeBorder(Palette.accent, lineWidth: BorderWidth.card * 2)
                    .opacity(isFocused ? 1 : 0)
            )
            .animation(.easeOut(duration: 0.12), value: isFocused)
    }
}

extension View {

    /// A text field on the app's own surface: no system bezel, a `raised` well instead.
    /// Replaces both `.roundedBorder` (a white/black box that fought every card it sat on) and
    /// the hand-rolled `Palette.card` + 4pt-radius background the label field carried.
    func tokiField() -> some View {
        modifier(TokiFieldModifier())
    }

    /// A value readout and its stepper, held in one well so the pair reads as a single
    /// numeric control. See this file's doc comment for why the arrows stay native.
    func tokiStepperWell() -> some View {
        controlWell(horizontal: Spacing.xs, vertical: 0)
    }

    /// A pop-up menu with the system bezel dropped (`.borderless` is what removes it) and the
    /// well put back around it, so it matches the fields beside it instead of the Finder.
    func tokiMenuPicker() -> some View {
        pickerStyle(.menu)
            .buttonStyle(.borderless)
            .controlWell(horizontal: Spacing.xs, vertical: Spacing.xxs)
    }
}
