/// HoldToKillButton — a destructive pill that ignores a plain click and only
/// fires after the user *holds* it for `holdDuration`.
///
/// On hover the label rolls from "Kill process" to "Hold to kill" using the same
/// numeric-roll motion as the dashboard's numbers (`.numericRoll`). While held,
/// `Palette.critical` fills the pill left→right as a progress bar; the white
/// label is revealed exactly over the red sweep (masked to the fill) so it stays
/// legible on both the idle background and the red fill. Releasing early drains
/// the fill and fires nothing.
///
/// The pill width is fixed to the wider of the two labels up front, so the swap
/// never changes its size.
import TokiCore
import SwiftUI

@MainActor
struct HoldToKillButton: View {
    /// How long the pill must be held before `action` fires.
    var holdDuration: Double = 1.2
    /// Invoked once, only when the hold completes.
    let action: () -> Void

    private let idleTitle = "Kill process"
    private let activeTitle = "Hold to kill"

    @State private var progress: CGFloat = 0
    @State private var isHovering = false
    @State private var isPressing = false
    @State private var holdTask: Task<Void, Never>?

    var body: some View {
        // The (invisible) stack of BOTH labels fixes the pill to its widest
        // label; the visual is drawn as an overlay sized to match.
        sizer
            .overlay { visual }
            .contentShape(Capsule())
            .onHover { isHovering = $0 }
            .gesture(pressAndHold)
            .accessibilityLabel("Kill process")
            .accessibilityHint("Press and hold to send SIGTERM")
            .accessibilityAddTraits(.isButton)
    }

    // MARK: - Sizing

    /// Both titles overlaid & hidden establish the max intrinsic size, so the
    /// label swap never reflows the pill.
    private var sizer: some View {
        ZStack {
            titleText(idleTitle).foregroundStyle(.clear)
            titleText(activeTitle).foregroundStyle(.clear)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - Visual

    private var visual: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.critical.opacity(0.10))

                Capsule()
                    .fill(Palette.critical)
                    .frame(width: w * progress)

                // Base (red) label — always fully visible.
                label(Palette.critical)
                    .frame(width: w, height: geo.size.height)

                // White label revealed exactly over the red sweep. Framed to the
                // full pill first, so the mask anchors to the PILL's leading edge
                // (not the centered text's) and stays in lockstep with the fill.
                label(.white)
                    .frame(width: w, height: geo.size.height)
                    .mask(alignment: .leading) {
                        Rectangle().frame(width: w * progress)
                    }
            }
            .clipShape(Capsule())
            .overlay(
                Capsule().strokeBorder(Palette.critical.opacity(0.55), lineWidth: 1)
            )
        }
    }

    /// The live label: text follows hover, animated with the numeric-roll motion.
    private func label(_ color: Color) -> some View {
        titleText(isHovering ? activeTitle : idleTitle)
            .foregroundStyle(color)
            .numericRoll(value: isHovering ? 1 : 0)
    }

    private func titleText(_ string: String) -> some View {
        Text(string)
            // Was 11pt semibold ROUNDED — rounded-for-tone prose, not a numeral display, so
            // `label` (11pt medium, default design) is the deliberate mapping: this drops the
            // rounded face rather than adding a role that only exists to keep it. A scale with
            // both "11pt regular" and "11pt regular rounded" as distinct roles has two names
            // for one job — that's the ad-hoc variation the scale exists to remove.
            .textStyle(.label)
            .lineLimit(1)
            .fixedSize()
    }

    // MARK: - Gesture

    private var pressAndHold: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                if !isPressing { begin() }
            }
            .onEnded { _ in cancel() }
    }

    private func begin() {
        isPressing = true
        withAnimation(.linear(duration: holdDuration)) { progress = 1 }
        holdTask = Task { @MainActor in
            // no-log: `Task.sleep` only ever throws `CancellationError`, which the very
            // next line already checks for and handles by returning — not a failure.
            try? await Task.sleep(for: .seconds(holdDuration))
            guard !Task.isCancelled else { return }
            fire()
        }
    }

    private func fire() {
        holdTask = nil
        isPressing = false
        action()
        // Snap the fill back in case the card lingers (e.g. signal didn't take).
        withAnimation(.easeOut(duration: 0.2)) { progress = 0 }
    }

    private func cancel() {
        guard isPressing else { return }
        holdTask?.cancel()
        holdTask = nil
        isPressing = false
        withAnimation(.easeOut(duration: 0.25)) { progress = 0 }
    }
}

#Preview("HoldToKillButton") {
    HoldToKillButton(action: {})
        .padding(40)
        .background(Palette.bg)
}
