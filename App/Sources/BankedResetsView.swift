import SwiftUI
import TokiCore
import TokiAlerts

/// Both usage surfaces read the same fresh Codex snapshot. No cached count is presented
/// as current after a failed poll, a long sleep, or a known credit's expiry.
struct BankedResetsView: View {
    let limits: UsageLimits
    @State private var showsDetails = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            if let resets = limits.bankedResets,
               context.date.timeIntervalSince(limits.fetchedAt) <= 210,
               limits.fetchedAt.timeIntervalSince(context.date) <= 300 {
                let details = (resets.credits ?? []).filter { $0.status == "available" }
                let expired = details.contains { $0.expiresAt.map { $0 <= context.date } ?? false }
                Button {
                    showsDetails.toggle()
                } label: {
                    Label(expired ? "Updating…" : compactTitle(resets.availableCount),
                          systemImage: "arrow.counterclockwise.circle")
                        .textStyle(.caption)
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize()
                        .padding(.horizontal, Spacing.xs)
                        .padding(.vertical, Spacing.xxs)
                        .background(Palette.textSecondary.opacity(0.10), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("codex-banked-resets")
                .accessibilityLabel(expired ? "Updating reset availability" : countTitle(resets.availableCount))
                .help("Show available Codex resets and expiry dates")
                .popover(isPresented: $showsDetails, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        HStack(spacing: Spacing.xs) {
                            Image(systemName: "arrow.counterclockwise.circle")
                                .foregroundStyle(Palette.textSecondary)
                            Text(expired ? "Updating reset availability…" : countTitle(resets.availableCount))
                                .textStyle(.label)
                                .foregroundStyle(Palette.textPrimary)
                        }
                        if !expired, resets.availableCount > 0 {
                            ForEach(details.sorted { ($0.expiresAt ?? .distantFuture) < ($1.expiresAt ?? .distantFuture) }, id: \.id) { credit in
                                Text(credit.expiresAt.map { "Expires \(ResetDateFormat.string(date: $0))" }
                                     ?? "Expiry not provided")
                                    .textStyle(.caption)
                                    .foregroundStyle(Palette.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if details.count < resets.availableCount {
                                Text("Expiry details are not available for every reset.")
                                    .textStyle(.caption)
                                    .foregroundStyle(Palette.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Link("Open Codex Usage ↗", destination: ResetLinks.codexUsage)
                                .textStyle(.caption)
                                .help("Use available resets in the official Codex Usage settings.")
                        }
                    }
                    .padding(Spacing.md)
                    .frame(width: 300, alignment: .leading)
                }
            }
        }
    }

    private func compactTitle(_ count: Int) -> String {
        count == 1 ? "1 reset" : "\(count) resets"
    }

    private func countTitle(_ count: Int) -> String {
        count == 1 ? "1 Codex reset available" : "\(count) Codex resets available"
    }
}
