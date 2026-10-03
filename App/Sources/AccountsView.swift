/// AccountsView — the dashboard "Accounts" tab: a card per stored account (gauges,
/// health, last active, rename/remove) plus the quarantined-credential shelf.
///
/// Renders INSIDE the Dashboard content area (no toolbar, no window background — the
/// dashboard supplies those). Uses only design-system primitives: panelCard,
/// SectionHeader, StatusPill, CapsuleGauge, cardLabel.
import TokiCore
import TokiAccounts
import SwiftUI

@MainActor
struct AccountsView: View {
    @Bindable var model: AccountsViewModel
    @Bindable var codex: CodexAccountsViewModel
    let providerAvailability: ProviderAvailability
    /// Extra top padding for callers that render this view OUTSIDE the dashboard — the
    /// snapshot harness and the debug control channel. As a dashboard tab it is 0: clearing
    /// the floating toolbar is `DashboardView`'s job, done once for all five tabs
    /// (`Measure.dashboardContentTop`).
    var topInset: CGFloat = 0

    /// Adopts a quarantined credential as a new stored account (confirming ownership
    /// against the profile endpoint first) and deletes a quarantined credential outright.
    /// Closures rather than `AccountsViewModel` methods: the view model (Task 13) ships
    /// without quarantine mutation, and extending its `init` would force a matching
    /// change in `ServiceContainer` outside this task's file list — see the task report.
    var addQuarantineEntry: (QuarantineEntry) async -> Void = { _ in }
    var deleteQuarantineEntry: (QuarantineEntry) async -> Void = { _ in }

    @State private var renamingUuid: String?
    @State private var draftAlias: String = ""
    @State private var pendingRemoval: AccountPresentation?
    @State private var addingCurrentAccount = false
    @State private var adoptingQuarantineId: String?

    // Headless snapshots don't fire onAppear, so start visible in flat mode to skip the
    // entrance animation and render content immediately.
    @State private var isVisible = SnapshotConfig.flatSurfaces

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                if providerAvailability.claudeCode {
                    if let errorMessage = model.errorMessage {
                        errorBanner(errorMessage)
                            .staggerIn(index: 0, isVisible: isVisible)
                    }
                    accountsSection
                        .staggerIn(index: 0, isVisible: isVisible)
                    if !model.quarantined.isEmpty {
                        quarantineSection
                            .staggerIn(index: 1, isVisible: isVisible)
                    }
                }
                if providerAvailability.codex {
                    CodexAccountsSection(model: codex)
                        .staggerIn(
                            index: providerAvailability.claudeCode ? 2 : 0,
                            isVisible: isVisible
                        )
                }
            }
            .padding(.horizontal, Spacing.xl)
            .padding(.bottom, Spacing.xl)
            .padding(.top, topInset)
        }
        .onAppear {
            isVisible = true
            if providerAvailability.claudeCode {
                model.load()
                Task { await model.refreshGauges() }
            }
            if providerAvailability.codex {
                codex.load()
                Task { await codex.refreshGauges() }
            }
        }
    }

    // MARK: - Accounts

    private var accountsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            // The button is an OVERLAY, not a row item. In an `HStack` it is the tallest
            // thing on the line, so baseline-aligning it lifted the row's top above the
            // header's and pushed "ACCOUNTS" 5.5 pt below where every other tab starts its
            // first header. As an overlay it keeps the same baseline relationship to the
            // header and contributes nothing to the section's height.
            SectionHeader("Claude accounts")
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .trailingFirstTextBaseline) {
                    addCurrentAccountButton
                }

            if model.accounts.isEmpty {
                emptyState
            } else {
                VStack(spacing: Spacing.sm) {
                    ForEach(model.presentedAccounts) { account in
                        accountCard(account)
                    }
                }
            }
        }
    }

    private var addCurrentAccountButton: some View {
        Button {
            addingCurrentAccount = true
            Task {
                await model.addCurrentAccount()
                addingCurrentAccount = false
            }
        } label: {
            HStack(spacing: 4) {
                if addingCurrentAccount {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "plus.circle.fill")
                }
                Text("Add current account")
            }
            .textStyle(.body)
        }
        .buttonStyle(.bordered)
        .tint(Palette.accent)
        .disabled(addingCurrentAccount)
    }

    private var emptyState: some View {
        VStack(spacing: Spacing.sm) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .iconSize(.hero)
                .foregroundStyle(Palette.textSecondary)
            Text("No accounts stored yet")
                .textStyle(.headline)
                .foregroundStyle(Palette.textSecondary)
            Text("Sign into the Claude CLI, then Add current account.")
                .textStyle(.detail)
                .foregroundStyle(Palette.textSecondary.opacity(0.7))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 160, alignment: .center)
    }

    private func accountCard(_ account: AccountPresentation) -> some View {
        // The active row's gauge fields are already joined to the shared `LiveLimits`
        // store by `AccountsViewModel.presentedAccounts` — every surface renders those
        // rows, so the card re-renders the moment that single source updates, in
        // lockstep with the popover and the Usage tab. Sleeping accounts carry their
        // own per-account snapshot untouched.
        let five = account.fiveHour
        let weekly = account.weekly
        let fiveReset = account.fiveHourResetsAt
        let weeklyReset = account.weeklyResetsAt
        let scoped = account.scopedModel
        let scopedReset = account.scopedModelResetsAt
        let scopedLabel = account.scopedModelLabel

        return VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(alignment: .center, spacing: Spacing.xs) {
                accountTitle(account)

                if account.isActive {
                    StatusPill(text: "Active", color: Palette.accent, active: true)
                }
                if account.health == .needsReauth {
                    StatusPill(text: "Sign in again", color: Palette.critical)
                }

                Spacer(minLength: Spacing.sm)

                accountActions(account)
            }

            if account.isStored {
                Text("Last active \(lastActiveText(account.lastActiveAt))")
                    .cardLabel()
            } else {
                Text("Signed in — not saved to Toki yet")
                    .cardLabel()
            }

            if account.gaugesAreStale {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .imageScale(.small)
                        .foregroundStyle(Palette.warn)
                    Text(staleBannerText(account.staleReason))
                        .textStyle(.caption)
                }
                .foregroundStyle(Palette.warn)
            }

            HStack(spacing: Spacing.md) {
                CapsuleGauge(
                    title: "5-hour", fraction: five ?? 0,
                    detail: five == nil ? nil : ResetCountdown.text(for: fiveReset),
                    isUnavailable: five == nil
                )
                CapsuleGauge(
                    title: "Weekly", fraction: weekly ?? 0,
                    detail: weekly == nil ? nil : ResetCountdown.text(for: weeklyReset),
                    isUnavailable: weekly == nil
                )
                if let scoped, let scopedLabel {
                    CapsuleGauge(
                        title: scopedLabel, fraction: scoped,
                        detail: ResetCountdown.text(for: scopedReset)
                    )
                }
            }
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelCard()
        .confirmationDialog(
            "Remove \(account.label)?",
            isPresented: Binding(
                get: { pendingRemoval?.accountUuid == account.accountUuid },
                set: { isPresented in if !isPresented { pendingRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                let uuid = account.accountUuid
                pendingRemoval = nil
                Task { await model.remove(accountUuid: uuid) }
            }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        } message: {
            Text("You'll need to sign in again to use this account.")
        }
    }

    @ViewBuilder
    private func accountTitle(_ account: AccountPresentation) -> some View {
        if renamingUuid == account.accountUuid {
            TextField("Label", text: $draftAlias)
                .textFieldStyle(.roundedBorder)
                .textStyle(.headline)
                .frame(maxWidth: 180)
                .onSubmit { commitRename(account) }
        } else {
            Text(account.label)
                .font(.system(.title3, design: .rounded).weight(.bold))
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private func accountActions(_ account: AccountPresentation) -> some View {
        if !account.isStored {
            // The signed-in account Toki hasn't saved yet: the only action is to save it.
            // There is nothing to rename (no slot) and nothing to remove.
            Button {
                addingCurrentAccount = true
                Task {
                    await model.addCurrentAccount()
                    addingCurrentAccount = false
                }
            } label: {
                HStack(spacing: 4) {
                    if addingCurrentAccount { ProgressView().controlSize(.small) }
                    else { Image(systemName: "square.and.arrow.down") }
                    Text("Save")
                }
                .textStyle(.label)
            }
            .buttonStyle(.bordered)
            .tint(Palette.accent)
            .disabled(addingCurrentAccount)
            .help("Save this account so you can switch back to it later")
        } else if renamingUuid == account.accountUuid {
            Button("Save") { commitRename(account) }
                .buttonStyle(.borderless)
                .textStyle(.label)
            Button("Cancel") { renamingUuid = nil }
                .buttonStyle(.borderless)
                .textStyle(.detail)
        } else {
            Button {
                draftAlias = account.label
                renamingUuid = account.accountUuid
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
        }
    }

    private func staleBannerText(_ reason: GaugeStaleReason?) -> String {
        switch reason {
        case .auth: "Usage unavailable — token couldn't be renewed"
        case .rateLimited: "Usage rate-limited — will retry"
        case .network, nil: "Usage temporarily unavailable"
        }
    }

    private func commitRename(_ account: AccountPresentation) {
        let trimmed = draftAlias.trimmingCharacters(in: .whitespacesAndNewlines)
        renamingUuid = nil
        Task {
            await model.rename(accountUuid: account.accountUuid, alias: trimmed.isEmpty ? nil : trimmed)
        }
    }

    // MARK: - Quarantine

    private var quarantineSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            SectionHeader("Unclaimed credentials")
            Text("Claude was signed into these accounts at some point, but Toki " +
                 "couldn't attribute them to a swap. Adopt the ones that are yours.")
                .textStyle(.detail)
                .foregroundStyle(Palette.textSecondary.opacity(0.8))

            VStack(spacing: Spacing.sm) {
                ForEach(model.quarantined, id: \.id) { entry in
                    quarantineRow(entry)
                }
            }
        }
    }

    @ViewBuilder
    private func quarantineRow(_ entry: QuarantineEntry) -> some View {
        HStack(spacing: Spacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.ownerLabel ?? "Unknown account")
                    .textStyle(.headline)
                    .foregroundStyle(Palette.textPrimary)
                Text("Found \(lastActiveText(entry.foundAt))")
                    .cardLabel()
            }

            Spacer()

            if adoptingQuarantineId == entry.id {
                ProgressView().controlSize(.small)
            } else {
                Button("Add as account") {
                    adoptingQuarantineId = entry.id
                    Task {
                        await addQuarantineEntry(entry)
                        adoptingQuarantineId = nil
                    }
                }
                .buttonStyle(.bordered)
                .textStyle(.label)

                Button("Delete") {
                    Task { await deleteQuarantineEntry(entry) }
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Palette.critical)
                .textStyle(.detail)
            }
        }
        .padding(Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelCard()
    }

    // MARK: - Error banner

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Palette.warn)
            Text(message)
                .textStyle(.detail)
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(2)
            Spacer()
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.xs)
        .panelCard()
    }

    // MARK: - Formatting

    private func lastActiveText(_ date: Date?) -> String {
        guard let date else { return "\u{2014}" }
        let elapsed = Date().timeIntervalSince(date)
        let minutes = Int(elapsed / 60)
        if minutes < 1 { return "just now" }
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        let days = hours / 24
        return "\(days)d ago"
    }
}
