/// OnboardingView — first-run Keychain-access explainer window.
///
/// Renders one of the six `OnboardingState` screens (see the design spec),
/// on the app's existing design tokens (Palette, Spacing, panelCard, BrandBadge)
/// so it reads as the same app as the dashboard window rather than a
/// stock system alert. Respects `SnapshotConfig.flatSurfaces` like the dashboard.
import AppKit
import SwiftUI
import TokiCore

// MARK: - OnboardingView

struct OnboardingView: View {
    let model: OnboardingViewModel
    var onDismiss: (() -> Void)? = nil

    var body: some View {
        ZStack {
            // Fills the whole surface (standalone window OR the dashboard-window overlay).
            OnboardingWindowBackground()
                .ignoresSafeArea()

            // Onboarding content is a centered, fixed-width column so it reads as an
            // intentional card regardless of how wide the host window is.
            VStack(spacing: 0) {
                header
                if let onDismiss {
                    Button("Continue without Claude", action: onDismiss)
                        .buttonStyle(.plain)
                        .foregroundStyle(Palette.accent)
                        .padding(.bottom, Spacing.md)
                }
                content
                    .padding(.top, Spacing.lg)
                    .padding(.bottom, Spacing.xl)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .frame(maxWidth: 460)
            .padding(.horizontal, Spacing.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: Spacing.sm) {
            BrandBadge(size: 44, symbolName: "key.fill")
            Text("Toki Setup")
                .textStyle(.title)
                .foregroundStyle(Palette.textPrimary)
        }
        .padding(.top, Spacing.xl)
        .padding(.bottom, Spacing.md)
        .frame(maxWidth: .infinity)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .intro:
            IntroScreen(model: model)
        case .granting:
            GrantingScreen()
        case .success:
            SuccessScreen()
        case .denied:
            DeniedScreen(model: model)
        case .locked:
            LockedScreen(model: model)
        case .notLoggedIn:
            NotLoggedInScreen(model: model)
        case .unsupportedLayout:
            UnsupportedLayoutScreen()
        }
    }
}

// MARK: - Intro

private struct IntroScreen: View {
    let model: OnboardingViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("See your Claude usage")
                    .textStyle(.title)
                    .foregroundStyle(Palette.textPrimary)
                Text("Let Toki read your Claude session to show live usage. If macOS asks for access, choose \u{201C}Always Allow\u{201D}. You may need to reconnect if the Claude CLI replaces its session after signing in again.")
                    .cardLabel()
                    .fixedSize(horizontal: false, vertical: true)
            }

            KeychainDialogMock()

            Spacer(minLength: 0)

            Button {
                Task { await model.grantAccess() }
            } label: {
                Text("Continue")
                    .textStyle(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Palette.accent)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A simple drawn mock of the macOS Keychain authorization dialog, with
/// "Always Allow" visually emphasized. Illustrative only — not a real dialog.
private struct KeychainDialogMock: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(alignment: .top, spacing: Spacing.sm) {
                Image(systemName: "lock.shield.fill")
                    .iconSize(.large, weight: .semibold)
                    .foregroundStyle(Palette.textSecondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\u{201C}Toki\u{201D} wants to use your confidential information stored in \u{201C}Claude Code-credentials\u{201D} in your keychain.")
                        .textStyle(.detail)
                        .foregroundStyle(Palette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: Spacing.xs) {
                Spacer()
                mockButton(title: "Deny", emphasized: false)
                mockButton(title: "Allow", emphasized: false)
                mockButton(title: "Always Allow", emphasized: true)
            }
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelCard()
    }

    private func mockButton(title: String, emphasized: Bool) -> some View {
        Text(title)
            .textStyle(emphasized ? .label : .detail)
            .foregroundStyle(emphasized ? Palette.bg : Palette.textPrimary)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: Radius.element, style: .continuous)
                    .fill(emphasized ? Palette.accent : Palette.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Radius.element, style: .continuous)
                    .strokeBorder(emphasized ? Palette.accent : Palette.hairline, lineWidth: emphasized ? 2 : BorderWidth.card)
            )
    }
}

// MARK: - Granting

private struct GrantingScreen: View {
    var body: some View {
        VStack(spacing: Spacing.md) {
            Spacer()
            ProgressView()
                .controlSize(.large)
            Text("Waiting for macOS\u{2026}")
                .textStyle(.body)
                .foregroundStyle(Palette.textSecondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Success

private struct SuccessScreen: View {
    var body: some View {
        VStack(spacing: Spacing.md) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .iconSize(.hero)
                .foregroundStyle(Palette.ok)
            Text("You\u{2019}re all set!")
                .textStyle(.title)
                .foregroundStyle(Palette.textPrimary)
            Text("Your usage and limits are loading now.")
                .cardLabel()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Denied

private struct DeniedScreen: View {
    let model: OnboardingViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                HStack(spacing: Spacing.xs) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Palette.warn)
                    Text("Almost there")
                        .textStyle(.title)
                        .foregroundStyle(Palette.textPrimary)
                }
                Text("Toki needs your permission to show your usage. When macOS asks, choose \u{201C}Always Allow\u{201D} so you won\u{2019}t be asked again.")
                    .cardLabel()
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            Button {
                Task { await model.grantAccess() }
            } label: {
                Text("Try Again")
                    .textStyle(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Palette.accent)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Locked

private struct LockedScreen: View {
    let model: OnboardingViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                HStack(spacing: Spacing.xs) {
                    Image(systemName: "lock.fill")
                        .foregroundStyle(Palette.warn)
                    Text("Locked right now")
                        .textStyle(.title)
                        .foregroundStyle(Palette.textPrimary)
                }
                Text("Access is locked. Unlock your Mac\u{2019}s login keychain, then try again.")
                    .cardLabel()
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            Button {
                Task { await model.grantAccess() }
            } label: {
                Text("Try Again")
                    .textStyle(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Palette.accent)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Not logged in

private struct NotLoggedInScreen: View {
    let model: OnboardingViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                HStack(spacing: Spacing.xs) {
                    Image(systemName: "person.crop.circle.badge.questionmark")
                        .foregroundStyle(Palette.textSecondary)
                    Text("Sign in to Claude")
                        .textStyle(.title)
                        .foregroundStyle(Palette.textPrimary)
                }
                Text("We couldn\u{2019}t find your Claude account. Open the Claude CLI and sign in, then re-check.")
                    .cardLabel()
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            Button {
                Task { await model.recheck() }
            } label: {
                Text("Re-check")
                    .textStyle(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Palette.accent)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Unsupported credential layout

/// Shown when Claude Code's Keychain item exists but holds no readable OAuth block —
/// some Claude Code versions keep their session elsewhere. Deliberately offers no
/// "Re-check": nothing the user can do here would change the outcome.
private struct UnsupportedLayoutScreen: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                HStack(spacing: Spacing.xs) {
                    Image(systemName: "questionmark.folder")
                        .foregroundStyle(Palette.textSecondary)
                    Text("Claude stores its session differently")
                        .textStyle(.title)
                        .foregroundStyle(Palette.textPrimary)
                }
                Text("This version of the Claude CLI keeps its sign-in in a format Toki can\u{2019}t read yet, so live rate-limit gauges stay unavailable. Your usage and cost analytics keep working \u{2014} they\u{2019}re read from your local Claude history.")
                    .cardLabel()
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Window background

/// Same translucent Liquid Glass window background used by Settings/Dashboard, drawn opaque
/// under the headless snapshot harness AND whenever the user has Reduce Transparency on.
private struct OnboardingWindowBackground: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        if SnapshotConfig.opaqueSurfaces(reduceTransparency: reduceTransparency) {
            Palette.bg
        } else if #available(macOS 15.0, *) {
            ZStack {
                Rectangle().fill(.regularMaterial)
                LinearGradient(
                    colors: [Palette.bg.opacity(0.60), Palette.surface.opacity(0.66)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        } else {
            Palette.bg
        }
    }
}

// MARK: - Preview

#Preview("OnboardingView \u{2014} intro") {
    OnboardingView(model: OnboardingViewModel(credentials: PreviewCredentials(), initialState: .intro))
        .frame(width: 460, height: 520)
}

#Preview("OnboardingView \u{2014} denied") {
    OnboardingView(model: OnboardingViewModel(credentials: PreviewCredentials(), initialState: .denied))
        .frame(width: 460, height: 520)
}

/// Inert `CredentialOnboarding` conformer used only to satisfy the preview's
/// initializer; previews seed `initialState` directly and never invoke it.
private struct PreviewCredentials: CredentialOnboarding {
    func currentCredential() async throws -> OAuthCredential {
        throw TokiError.credentialsNotFound
    }
    func accessState() async -> CredentialAccessState { .available }
}
