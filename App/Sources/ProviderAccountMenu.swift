import SwiftUI
import TokiAccounts
import TokiAlerts
import TokiCore

/// Compact provider-scoped account menus used by both the popover and dashboard toolbar.
/// Keeping two explicit views is intentional: Claude and Codex have different stores and
/// different swap transactions, so a click can never be routed to the wrong provider.
struct ClaudeAccountMenu: View {
    @Bindable var model: AccountsViewModel
    var signedInLabel: String?
    var providerLabel: String? = nil

    private let notifier = SwapNotifier()

    var body: some View {
        if model.presentedAccounts.count > 1 {
            Menu {
                ForEach(model.presentedAccounts) { account in
                    Button {
                        switchAccount(account)
                    } label: {
                        Label(
                            menuTitle(account),
                            systemImage: account.isActive ? "checkmark.circle.fill" : "circle"
                        )
                    }
                    .disabled(
                        account.isActive || model.swapInFlight != nil
                            || account.health == .needsReauth
                    )
                }
            } label: {
                AccountMenuLabel(
                    provider: providerLabel,
                    account: activeLabel,
                    busy: model.swapInFlight != nil,
                    hasChoices: true
                )
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
        } else {
            AccountMenuLabel(
                provider: providerLabel,
                account: activeLabel,
                busy: model.swapInFlight != nil,
                hasChoices: false
            )
        }
    }

    private var activeLabel: String {
        model.presentedAccounts.first(where: \.isActive)?.label
            ?? signedInLabel
            ?? "No account"
    }

    private func menuTitle(_ account: AccountPresentation) -> String {
        guard account.health != .needsReauth else { return "\(account.label) — sign in again" }
        guard !account.gaugesAreStale, let usage = account.fiveHour else { return account.label }
        return "\(account.label) — \(Int((usage * 100).rounded()))% used"
    }

    private func switchAccount(_ account: AccountPresentation) {
        let from = model.presentedAccounts.first(where: \.isActive)?.label
        Task {
            guard await model.swap(to: account.accountUuid) else { return }
            guard NotificationSettingsStore(defaults: .standard).load().onSwap else { return }
            guard await notifier.requestAuthorization() else { return }
            notifier.notifySwap(from: from, to: account.label, trigger: nil)
        }
    }
}

struct CodexAccountMenu: View {
    @Bindable var model: CodexAccountsViewModel
    var providerLabel: String? = nil

    private let notifier = SwapNotifier()

    var body: some View {
        if model.accounts.filter(\.isStored).count > 1 {
            Menu {
                ForEach(model.accounts) { account in
                    if account.isStored {
                        Button {
                            switchAccount(account)
                        } label: {
                            Label(
                                menuTitle(account),
                                systemImage: account.isActive ? "checkmark.circle.fill" : "circle"
                            )
                        }
                        .disabled(account.isActive || model.swapInFlight != nil)
                    }
                }
            } label: {
                AccountMenuLabel(
                    provider: providerLabel,
                    account: activeLabel,
                    busy: model.swapInFlight != nil,
                    hasChoices: true
                )
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
        } else {
            AccountMenuLabel(
                provider: providerLabel,
                account: activeLabel,
                busy: model.swapInFlight != nil,
                hasChoices: false
            )
        }
    }

    private var activeLabel: String {
        model.accounts.first(where: \.isActive)?.label
            ?? model.signedInLabel
            ?? "No account"
    }

    private func menuTitle(_ account: CodexAccountPresentation) -> String {
        guard let plan = account.planType, !plan.isEmpty else { return account.label }
        return "\(account.label) — \(plan.capitalized)"
    }

    private func switchAccount(_ account: CodexAccountPresentation) {
        let from = model.accounts.first(where: \.isActive)?.label
        Task {
            guard await model.swap(to: account.id) else { return }
            guard NotificationSettingsStore(defaults: .standard).load().onSwap else { return }
            guard await notifier.requestAuthorization() else { return }
            notifier.notifySwap(from: from, to: account.label, trigger: nil, provider: .codex)
        }
    }
}

private struct AccountMenuLabel: View {
    let provider: String?
    let account: String
    let busy: Bool
    let hasChoices: Bool

    var body: some View {
        HStack(spacing: 5) {
            title
                .lineLimit(1)
                .truncationMode(.middle)
            if busy {
                ProgressView().controlSize(.mini)
            } else if hasChoices {
                Image(systemName: "chevron.down")
                    .iconSize(.small)
                    .foregroundStyle(Palette.textSecondary)
            }
        }
        .contentShape(Rectangle())
        .help(account)
    }

    /// Keep the complete label in one backing string. AppKit's borderless `Menu` bridge
    /// sometimes measures a concatenated SwiftUI `Text` using only its first run, which
    /// previously left just "Claude Code" visible and hid the actual account.
    private var title: Text {
        if let provider {
            return Text("\(provider) · \(account)")
                .font(Font(role: .body))
                .foregroundColor(Palette.textPrimary)
        }
        return Text(account)
            .font(Font(role: .body))
            .foregroundColor(Palette.textPrimary)
    }
}
