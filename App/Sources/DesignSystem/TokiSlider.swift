/// TokiSlider — the app's percentage slider: ONE rounded bar, filled from the leading edge to
/// the value and empty after it. No knob, no circle, no system chrome.
///
/// A threshold is chosen roughly — "about ninety" — and a `Stepper` is the wrong instrument for
/// a rough choice. The auto-swap rows shipped `Stepper(value:in: 50...99)` with an implicit step
/// of 1: forty-nine clicks from one end of the range to the other, on an AppKit incrementor
/// whose two arrows share about 11pt of height, so each click is a ~5pt target. The alert rules
/// had the same shape at `in: 5...100, step: 5`. A bar states the whole range at once and lets
/// one gesture cross it.
///
/// **One control, two call sites.** `SettingsView` (auto-swap thresholds, 50…99 by 1) and
/// `NotificationsEditorView` (alert rules, 5…100 by 5) both instantiate THIS view. Two private
/// copies would drift — a width fix landing in one and not the other is exactly how an earlier
/// problem in this codebase started — so the drawing, the metrics and the accessibility wiring
/// live here once and the call sites pass only their range, step and name.
///
/// ## Why nothing here is a `Slider`
/// Recolouring the system control was tried first and it does not survive contact: AppKit gives
/// no `SliderStyle` to implement (the same gap `TokiControlChrome` documents for fields,
/// steppers and pickers), so the only lever is to paint over the stock control. That leaves two
/// things the paint cannot reach. The round knob is translucent enough to show the filled
/// track's rounded cap through itself, and pressing the control raises the system's own glassy
/// focus overlay ON TOP of everything drawn — a second, differently-shaped control appearing
/// over ours at the exact moment the user touches it. So the bar is drawn outright, and the
/// system slider survives only inside `.accessibilityRepresentation`, where it is never rendered.
///
/// ## Which means accessibility is built by hand — the same way `TokiSegmentedPicker` does it
/// Hand-rolling a shape normally costs `AXSlider`, its spoken value and its adjust actions. It
/// does not have to. `TokiSegmentedPicker` already draws its own segments and hands assistive
/// technology a real `Picker` over the same binding; this hands AT a real `Slider` over the same
/// binding, range and step, so the control announces as a slider, reports a percentage, and
/// responds to VoiceOver's increment/decrement. Three separate mechanisms, none optional:
///  - `.accessibilityRepresentation { Slider(…) }` — the role (`AXSlider`) and the adjust
///    actions (`AXIncrement` / `AXDecrement`), both verified on the running app.
///  - `.accessibilityValue("\(value)%")` on that slider — it resolves to `AXValueDescription`,
///    the attribute VoiceOver speaks, so the announcement carries the unit instead of a bare
///    "ninety-five".
///  - `.focusable()` + `.onKeyPress(.leftArrow/.rightArrow)` — a mouse is not a requirement for
///    setting a threshold. Arrow keys move by exactly one `step`, so 5…100 by 5 moves in fives.
///
/// `.focusEffectDisabled()` goes with the focus: the system's focus effect is the same glassy
/// overlay that made the stock slider unusable here. Focus is instead observed with
/// `@FocusState` and drawn as an accent rim just outside the bar — the same device, for the
/// same reason, as `TokiFieldModifier`, and placed outside the bar rather than on it because an
/// accent rim on top of an accent fill is invisible at the high end of the travel.
///
/// ## Surface
/// The popover's `CapsuleGauge` vocabulary, deliberately: `Palette.accent` up to the value on
/// the same muted recessed track (`Palette.textPrimary.opacity(0.08)`) the gauges use. A limit's
/// usage and the threshold that limits it are the same kind of quantity, so they are drawn in
/// the same language rather than in two.
import AppKit
import SwiftUI

struct TokiSlider: View {

    /// The value in whole percent. Kept as `Int` because both call sites store and display
    /// whole percent — any floating-point bridging is this view's business.
    @Binding var value: Int
    /// Inclusive percent bounds, e.g. `50...99`.
    let range: ClosedRange<Int>
    /// Granularity in percent. 1 for the auto-swap thresholds, 5 for the alert rules. Also the
    /// distance one arrow-key press moves.
    let step: Int
    /// Spoken name — "Watch the 5-hour window threshold". Without it a screen-reader user
    /// hears a percentage with nothing saying what it is the percentage of.
    let label: String

    @FocusState private var isFocused: Bool

    /// Height of the drawn bar. One step above the gauges' 6pt track and the nearest token to
    /// it, so the threshold reads as the same object as the usage it limits.
    /// Twice `Spacing.xs`. The first draft was one step and read as a hairline next to the
    /// switch beside it — a threshold is a primary control on that row, not a decoration.
    private static let barHeight: CGFloat = Spacing.xs * 2
    /// Gap between the bar and its focus rim, so the rim never sits on the fill. Half a step of
    /// the smallest spacing token — the same hairline gap `TokiSegmentedPicker` insets by, for
    /// the same reason: every real spacing step is visibly too big at this size.
    private static let focusGap: CGFloat = Spacing.xxs / 2
    /// Interactive height of the whole control. The bar is thin; the band that answers a press
    /// is not — more than twice the ~11pt an entire two-arrow stepper occupied, across the full
    /// width of the card rather than one arrow.
    private static let height: CGFloat = Spacing.lg

    var body: some View {
        GeometryReader { proxy in
            bar
                .frame(width: proxy.size.width, height: proxy.size.height)
                // The whole band is the target, bar included: a press anywhere in it sets the
                // value at that x, and the drag that may follow keeps setting it.
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            // Clicking must not leave the keyboard rim behind. `.focusable()`
                            // focuses on mouse-down, so the ring outlived every press and read
                            // as a stuck selection. Tab still focuses and still shows it.
                            isFocused = false
                            let next = self.value(atX: drag.location.x, width: proxy.size.width)
                            if next != value { Self.tick() }
                            value = next
                        }
                )
        }
        .frame(height: Self.height)
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onKeyPress(.leftArrow) { adjust(by: -step); return .handled }
        .onKeyPress(.rightArrow) { adjust(by: step); return .handled }
        .accessibilityRepresentation {
            Slider(value: percentValue, in: bounds, step: Double(step))
                .accessibilityLabel(label)
                // Lands on `AXValueDescription`, NOT on `AXValue` — measured with an
                // out-of-process `AXUIElementCopyAttributeValue` walk, because the debug
                // channel's `tree` reads `AXValue` only and so reports the bare "95" for a
                // slider whichever way this is spelled. `AXValueDescription` is the attribute
                // VoiceOver actually speaks for a slider, which is the one that had to carry
                // the unit: "ninety-five" alone is a number the listener still has to guess
                // the meaning of.
                .accessibilityValue("\(clamped)%")
        }
    }

    // MARK: - Bar

    /// Track and fill in one `ZStack` that is clipped ONCE, by the bar's shape.
    ///
    /// The fill is a plain `Rectangle`, never a rounded one: a rounded fill caps itself at the
    /// value, which puts a second curve in the middle of the bar and makes the filled part read
    /// as a separate pill lying on the track. Clipping the whole stack means the only rounded
    /// corners in the control are the bar's own four, and the boundary between filled and empty
    /// is the rectangle's straight vertical edge.
    private var bar: some View {
        ZStack(alignment: .leading) {
            Rectangle()
                .fill(Palette.textPrimary.opacity(0.08))
            GeometryReader { proxy in
                Rectangle()
                    .fill(Palette.accent)
                    .frame(width: proxy.size.width * fraction)
            }
        }
        .frame(height: Self.barHeight)
        .clipShape(ControlShape.rounded)
        .padding(Self.focusGap)
        .overlay(
            ControlShape.rounded
                // Twice the card hairline, exactly as the focused text field's rim — "this one
                // is live" without inventing a second border weight.
                .strokeBorder(Palette.accent, lineWidth: BorderWidth.card * 2)
                .opacity(isFocused ? 1 : 0)
        )
        .animation(.easeOut(duration: 0.12), value: isFocused)
    }

    // MARK: - Value

    private var bounds: ClosedRange<Double> {
        Double(range.lowerBound)...Double(range.upperBound)
    }

    private var clamped: Int {
        min(max(value, range.lowerBound), range.upperBound)
    }

    /// 0…1 position of the current value in the range.
    private var fraction: CGFloat {
        let span = Double(range.upperBound - range.lowerBound)
        guard span > 0 else { return 0 }
        return CGFloat(Double(clamped - range.lowerBound) / span)
    }

    /// `Slider` is `BinaryFloatingPoint`-only, so the `Int` the call sites own is bridged here
    /// for the representation rather than in each of them. Rounding on the way back keeps the
    /// stored value whole even when the step does not divide the range evenly.
    private var percentValue: Binding<Double> {
        Binding(
            get: { Double(clamped) },
            set: { value = min(max(Int($0.rounded()), range.lowerBound), range.upperBound) }
        )
    }

    /// The value a press at `x` means, snapped to `step`.
    private func value(atX x: CGFloat, width: CGFloat) -> Int {
        guard width > 0 else { return clamped }
        let position = min(max(Double(x / width), 0), 1)
        let span = Double(range.upperBound - range.lowerBound)
        return snapped(Double(range.lowerBound) + position * span)
    }

    /// Rounds to the nearest multiple of `step` measured FROM the lower bound, then clamps —
    /// so 5…100 by 5 can reach 100 and 50…99 by 1 can reach 99, whether or not the span is a
    /// whole number of steps.
    private func snapped(_ raw: Double) -> Int {
        let steps = ((raw - Double(range.lowerBound)) / Double(step)).rounded()
        let candidate = range.lowerBound + Int(steps) * step
        return min(max(candidate, range.lowerBound), range.upperBound)
    }

    /// One arrow-key press: exactly one `step`, clamped at both ends.
    /// One alignment tick per step actually crossed — the feedback a trackpad gives when a
    /// value snaps, not a buzz per pixel of travel. Silent on hardware without a haptic engine.
    private static func tick() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    private func adjust(by delta: Int) {
        let next = min(max(clamped + delta, range.lowerBound), range.upperBound)
        if next != value { Self.tick() }
        value = next
    }
}
