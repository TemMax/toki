import SwiftUI
import TokiAccounts
import TokiCore

/// The Codex half of the Accounts tab. Claude remains in `AccountsView`; this view owns
/// only Codex actions so save, rename, remove, and switch cannot cross provider boundaries.
@MainActor
struct CodexAccountsSection: View {
    @Bindable var model: CodexAccountsViewModel

    @State private var adding = false
    @State private var renamingID: String?
    @State private var draftAlias = ""
    @State private var pendingRemoval: CodexAccountPresentation?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            if let error = model.errorMessage {
                errorBanner(error)
            }

            SectionHeader("Codex accounts")
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .trailingFirstTextBaseline) {
                    addCurrentButton
                }

            if model.accounts.isEmpty {
                emptyState
            } else {
                VStack(spacing: Spacing.sm) {
                    ForEach(model.accounts) { account in
                        accountCard(account)
                    }
                }
            }
        }
    }

    private var addCurrentButton: some View {
        Button {
            adding = true
            Task {
                await model.addCurrentAccount()
                adding = false
            }
        } label: {
            HStack(spacing: 4) {
                if adding { ProgressView().controlSize(.small) }
                else { Image(systemName: "plus.circle.fill") }
                Text("Save current account")
            }
            .textStyle(.body)
        }
        .buttonStyle(.bordered)
        .tint(Palette.accent)
        .disabled(adding)
    }

    private var emptyState: some View {
        VStack(spacing: Spacing.sm) {
            Image(systemName: "terminal")
                .iconSize(.hero)
                .foregroundStyle(Palette.textSecondary)
            Text("No Codex accounts stored yet")
                .textStyle(.headline)
                .foregroundStyle(Palette.textSecondary)
            Text("Sign in with Codex, then save the current account. Repeat after signing into another account to enable switching.")
                .textStyle(.detail)
                .foregroundStyle(Palette.textSecondary.opacity(0.7))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
        }
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .center)
    }

    private func accountCard(_ account: CodexAccountPresentation) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(alignment: .center, spacing: Spacing.xs) {
                accountTitle(account)
                if account.isActive {
                    StatusPill(text: "Active", color: Palette.accent, active: true)
                }
                if let plan = account.planType, !plan.isEmpty {
                    StatusPill(text: plan.capitalized, color: Palette.textSecondary)
                }

                Spacer(minLength: Spacing.sm)
                actions(account)
            }

            if account.isStored {
                Text("Last active \(lastActiveText(account.lastActiveAt))")
                    .cardLabel()
            } else {
                Text("Signed in — not saved to Toki yet")
                    .cardLabel()
            }

            if account.isActive, let limits = model.activeLimits {
                LimitsStrip(limits: limits, uppercaseTitles: false)
                    .padding(.top, Spacing.xs)
            } else if account.isStored,
                      account.fiveHour != nil || account.weekly != nil {
                VStack(spacing: Spacing.sm) {
                    if let fiveHour = account.fiveHour {
                        CapsuleGauge(title: "5-hour", fraction: fiveHour)
                    }
                    if let weekly = account.weekly {
                        CapsuleGauge(title: "Weekly", fraction: weekly)
                    }
                }
                .padding(.top, Spacing.xs)
                .opacity(account.gaugesAreStale ? 0.55 : 1)
            } else if account.isStored {
                Text("Usage has not been refreshed for this account yet.")
                    .textStyle(.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .padding(.top, Spacing.xxs)
            }
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelCard()
        .confirmationDialog(
            "Remove \(account.label)?",
            isPresented: Binding(
                get: { pendingRemoval?.id == account.id },
                set: { shown in if !shown { pendingRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                pendingRemoval = nil
                Task { await model.remove(id: account.id) }
            }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        } message: {
            Text("The saved credential will be removed from Toki's Keychain.")
        }
    }

    @ViewBuilder
    private func accountTitle(_ account: CodexAccountPresentation) -> some View {
        if renamingID == account.id {
            TextField("Label", text: $draftAlias)
                .textFieldStyle(.roundedBorder)
                .textStyle(.headline)
                .frame(maxWidth: 220)
                .onSubmit { commitRename(account) }
        } else {
            Text(account.label)
                .font(.system(.title3, design: .rounded).weight(.bold))
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private func actions(_ account: CodexAccountPresentation) -> some View {
        if !account.isStored {
            Button {
                adding = true
                Task {
                    await model.addCurrentAccount()
                    adding = false
                }
            } label: {
                HStack(spacing: 4) {
                    if adding { ProgressView().controlSize(.small) }
                    else { Image(systemName: "square.and.arrow.down") }
                    Text("Save")
                }
                .textStyle(.body)
            }
            .buttonStyle(.bordered)
            .tint(Palette.accent)
            .disabled(adding)
        } else if renamingID == account.id {
            Button("Save") { commitRename(account) }
                .buttonStyle(.borderless)
                .textStyle(.label)
            Button("Cancel") { renamingID = nil }
                .buttonStyle(.borderless)
                .textStyle(.detail)
        } else {
            if !account.isActive {
                Button("Switch") {
                    Task { await model.swap(to: account.id) }
                }
                .buttonStyle(.bordered)
                .tint(Palette.accent)
                .disabled(model.swapInFlight != nil)
            }

            Button {
                draftAlias = account.label
                renamingID = account.id
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Palette.textSecondary)
            .help("Rename")

            Button {
                pendingRemoval = account
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(account.isActive ? Palette.textSecondary.opacity(0.4) : Palette.critical)
            .disabled(account.isActive)
            .help(account.isActive ? "The active account can't be removed" : "Remove")

            if model.swapInFlight == account.id {
                ProgressView().controlSize(.small)
            }
        }
    }

    private func commitRename(_ account: CodexAccountPresentation) {
        let alias = draftAlias.trimmingCharacters(in: .whitespacesAndNewlines)
        renamingID = nil
        Task { await model.rename(id: account.id, alias: alias.isEmpty ? nil : alias) }
    }

    private func lastActiveText(_ date: Date?) -> String {
        guard let date else { return "—" }
        let minutes = Int(Date().timeIntervalSince(date) / 60)
        if minutes < 1 { return "just now" }
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        return "\(hours / 24)d ago"
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Palette.warn)
            Text(message)
                .textStyle(.detail)
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(3)
            Spacer()
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.xs)
        .panelCard()
    }
}
