import SwiftUI
import TokiAlerts
import TokiCore
import TokiAccounts

/// The account row in the menu-bar popover: shows the active account, expands into a
/// list with per-account headroom, and swaps on click.
struct AccountSwitcher: View {
    @Bindable var model: AccountsViewModel
    /// Who Claude Code says is signed in, read straight from `~/.claude.json`. Used
    /// whenever no stored slot is the active one — which is the normal state for anyone
    /// who has not added an account to Toki yet, and also happens right after a `/login`
    /// performed outside the app. Without it the popover would claim "No account" while
    /// the user is plainly signed in.
    var signedInLabel: String?
    @State private var expanded = false

    private let notifier = SwapNotifier()

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
            } label: {
                // No `person.crop.circle` glyph: `AppIconBadge` sits immediately to its left
                // in the popover header, and two circular marks opening one line read as a
                // stutter. The account is already unmistakable — it is the only line there.
                HStack(spacing: Spacing.xs) {
                    // `.title`/`textPrimary`, not `.detail`/`textSecondary`: this control is
                    // the popover's PRIMARY header line. It used to sit under a "Toki"
                    // wordmark as a subtitle, so subtitle styling was right; the wordmark is
                    // gone (the user just clicked the Toki icon — naming the app back at them
                    // carried nothing), and the account took its place. Left quiet, the
                    // header would read as an icon beside a caption with no headline at all.
                    Text(activeLabel)
                        .textStyle(.title)
                        .foregroundStyle(Palette.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if model.presentedAccounts.count > 1 {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .iconSize(.small)
                            .foregroundStyle(Palette.textSecondary)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(model.presentedAccounts.count <= 1)

            if expanded {
                ForEach(model.presentedAccounts) { account in
                    row(account)
                }
            }

            // A swap started from the popover fails silently otherwise: the Accounts tab is
            // the only other place `errorMessage` is rendered, and the user need never open it.
            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .textStyle(.caption)
                    .foregroundStyle(Palette.critical)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var activeLabel: String {
        if let active = model.presentedAccounts.first(where: \.isActive) { return active.label }
        if let signedInLabel, !signedInLabel.isEmpty { return signedInLabel }
        return "No account"
    }

    @ViewBuilder
    private func row(_ account: AccountPresentation) -> some View {
        Button {
            swap(to: account)
        } label: {
            HStack(spacing: Spacing.xs) {
                Image(systemName: account.isActive ? "checkmark.circle.fill" : "circle")
                    .iconSize(.small)
                    .foregroundStyle(account.isActive ? Palette.accent : Palette.textSecondary)
                Text(account.label)
                    .textStyle(.detail)
                    .foregroundStyle(Palette.textPrimary)
                Spacer()
                if model.swapInFlight == account.accountUuid {
                    ProgressView().controlSize(.small)
                } else if account.health == .needsReauth {
                    Text("sign in again")
                        .textStyle(.caption)
                        .foregroundStyle(Palette.textSecondary)
                } else {
                    Text(headroom(account))
                        .textStyle(.metricInline)
                        .foregroundStyle(Palette.textSecondary)
                }
            }
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
        // An account already active, mid-swap, or needing a re-login (dead lineage —
        // swapping to it would just hand Claude Code a token it can't refresh) is not
        // a valid swap target.
        .disabled(account.isActive || model.swapInFlight != nil || account.health == .needsReauth)
    }

    private func headroom(_ account: AccountPresentation) -> String {
        // A stale gauge holds a possibly hours-old percentage; showing it as
        // current would misrepresent headroom. The active row can't dash here in
        // steady state: `presentedAccounts` joins it to the live-limits store.
        guard !account.gaugesAreStale, let five = account.fiveHour else { return "—" }
        return "\(Int((five * 100).rounded()))%"
    }

    /// Read fresh on each swap from the one store that gates every notification Toki sends —
    /// a manual swap must honour the "account switched" preference just as the auto-swap
    /// driver does.
    private var swapNotificationsEnabled: Bool {
        NotificationSettingsStore(defaults: .standard).load().onSwap
    }

    /// Swaps, then — only when it actually succeeded (the `Bool` return, not the shared
    /// `errorMessage`, which the auto-swap tick and every gauge refresh also clear) — posts
    /// the "switched accounts" notification, so a failed/aborted swap stays silent.
    private func swap(to account: AccountPresentation) {
        let from = model.presentedAccounts.first(where: \.isActive)?.label
        Task {
            guard await model.swap(to: account.accountUuid) else { return }
            guard swapNotificationsEnabled else { return }
            // A user who never touched the Settings toggles was never asked for notification
            // permission; the first manual swap is where we ask. Re-requesting after a prior
            // decision is a no-op, so calling it every swap raises no second prompt.
            guard await notifier.requestAuthorization() else { return }
            notifier.notifySwap(from: from, to: account.label, trigger: nil)
        }
    }
}
