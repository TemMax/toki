/// TokiButtonStyle — the app's own button, in three roles.
///
/// It is a `ButtonStyle`, not a look-alike: the call site keeps writing `Button { … }`, so the
/// control keeps its `AXButton` role, its keyboard focus, its `.disabled` handling and its
/// press action. Only the drawing is ours. (The commit that removed eight `Text` +
/// `.onTapGesture` "buttons" from the dashboard navigation is the standing argument for why
/// this is the only acceptable way to restyle a control here.)
///
/// ## The roles
///  - `.prominent` — the one affirmative action on a screen (the editor's *Done*). Filled with
///    `Palette.accent`, labelled in `Palette.onAccent`.
///  - `.secondary` — everything else that is a real action (*Reset to Defaults*, Settings'
///    *Edit…*). Neutral pressable surface, `Palette.textPrimary` label.
///  - `.icon` — a bare glyph target (*add indicator*, *remove indicator*). No resting chrome,
///    because a row of six controls cannot afford two more boxes; the surface appears under
///    the pointer so the target is still discoverable.
///
/// ## Why `.prominent` is not glass
/// `Glass.tint()` is translucent by construction: the accent it draws is the accent *mixed
/// with whatever is behind the window*, so the label's contrast against it is no longer the
/// 5.99:1 / 6.17:1 that `ContrastTests` asserts for `onAccent` on `copper500` — it becomes
/// unmeasurable, and on a light backdrop it drifts the wrong way. The filled button therefore
/// stays an opaque accent fill in every appearance and on every OS. The neutral roles carry
/// `textPrimary`, whose worst pairing on any plane in this app is 11.2:1, so a translucent
/// surface cannot take it below AA — that is the difference, and it is why only they are glass.
import SwiftUI

struct TokiButtonStyle: ButtonStyle {

    enum Role {
        case prominent
        case secondary
        case icon
    }

    var role: Role = .secondary

    func makeBody(configuration: Configuration) -> some View {
        // A nested View, not a bare modifier chain: `@Environment(\.isEnabled)` and `@State`
        // for hover are only populated inside a View's body, never in `makeBody` itself.
        ButtonBody(role: role, configuration: configuration)
    }

    private struct ButtonBody: View {
        let role: Role
        let configuration: Configuration

        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovering = false

        var body: some View {
            label
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, verticalPadding)
                .modifier(Surface(role: role, isPressed: configuration.isPressed, isHovering: isHovering))
                // Disabled controls are WCAG-exempt; the codebase already expresses them by
                // lowering a token's opacity rather than reaching for a dimmer colour.
                .opacity(isEnabled ? 1 : 0.4)
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
                .contentShape(ControlShape.rounded)
                .onHover { isHovering = $0 }
        }

        /// `.icon` leaves the foreground to the call site — the trash glyph is
        /// `textSecondary`, the add glyph is `accent`, and both dim themselves further when
        /// the action is unavailable — so it must not be overridden here.
        @ViewBuilder private var label: some View {
            switch role {
            case .prominent: configuration.label.foregroundStyle(Palette.onAccent)
            case .secondary: configuration.label.foregroundStyle(Palette.textPrimary)
            case .icon: configuration.label
            }
        }

        private var horizontalPadding: CGFloat {
            role == .icon ? Spacing.xxs : Spacing.md
        }

        private var verticalPadding: CGFloat {
            role == .icon ? Spacing.xxs : Spacing.xs
        }
    }

    /// Split out so the three roles' backgrounds are one readable decision rather than three
    /// nested ternaries inside the label chain.
    private struct Surface: ViewModifier {
        let role: Role
        let isPressed: Bool
        let isHovering: Bool

        func body(content: Content) -> some View {
            switch role {
            case .prominent:
                content
                    .background(ControlShape.rounded.fill(Palette.accent))
                    // Pressed = a touch deeper, not a system-blue flash.
                    .overlay(ControlShape.rounded.fill(Palette.textPrimary.opacity(isPressed ? 0.12 : 0)))
            case .secondary:
                content.controlGlass()
            case .icon:
                // No resting chrome: the surface fades in under the pointer, so a six-control
                // row stays readable while the target stays discoverable.
                content.background(
                    ControlShape.rounded
                        .fill(Palette.raised)
                        .opacity(isPressed ? 1 : (isHovering ? 0.7 : 0))
                        .animation(.easeOut(duration: 0.12), value: isHovering)
                )
            }
        }
    }
}

extension ButtonStyle where Self == TokiButtonStyle {

    /// The single affirmative action — filled accent.
    static var tokiProminent: TokiButtonStyle { TokiButtonStyle(role: .prominent) }

    /// Every other real action — neutral pressable surface.
    static var tokiSecondary: TokiButtonStyle { TokiButtonStyle(role: .secondary) }

    /// A bare glyph target; the call site owns the glyph's colour.
    static var tokiIcon: TokiButtonStyle { TokiButtonStyle(role: .icon) }
}
