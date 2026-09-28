import SwiftUI
import TokiAlerts
import TokiCore

/// A current-account Claude reset balance. The domain value decides freshness and expiry;
/// this view reevaluates that state every 30 seconds so a known grant expiry moves to
/// Updating even when rate limiting delays the next network response.
struct ClaudeResetsView: View {
    let limits: UsageLimits
    var allowsStaleDisplay = false
    @State private var showsDetails = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            if let resets = limits.claudeResets {
                switch resets.displayState(
                    fetchedAt: limits.fetchedAt,
                    now: context.date,
                    allowsStale: allowsStaleDisplay
                ) {
                case .hidden:
                    EmptyView()
                case .updating:
                    badge(resets: resets, count: nil, now: context.date)
                case .balance(let count):
                    badge(resets: resets, count: count, now: context.date)
                }
            }
        }
    }

    private func badge(resets: ClaudeResetStatus, count: Int?, now: Date) -> some View {
        Button {
            showsDetails.toggle()
        } label: {
            Label(count.map(compactTitle) ?? "Updating…", systemImage: "arrow.counterclockwise.circle")
                .textStyle(.caption)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize()
                .padding(.horizontal, Spacing.xs)
                .padding(.vertical, Spacing.xxs)
                .background(Palette.textSecondary.opacity(0.10), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("claude-banked-resets")
        .accessibilityLabel(count.map(accessibilityTitle) ?? "Updating Claude reset availability")
        .help("Show saved Claude resets and their conditions")
        .popover(isPresented: $showsDetails, arrowEdge: .bottom) {
            details(resets: resets, count: count, now: now)
        }
    }

    private func details(resets: ClaudeResetStatus, count: Int?, now: Date) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(spacing: Spacing.xs) {
                Image(systemName: "arrow.counterclockwise.circle")
                    .foregroundStyle(Palette.textSecondary)
                Text("Claude resets")
                    .textStyle(.label)
                    .foregroundStyle(Palette.textPrimary)
            }

            if count == nil {
                Text("Updating reset availability…")
                    .textStyle(.caption)
                    .foregroundStyle(Palette.textSecondary)
            } else if let grants = resets.grants, !grants.isEmpty {
                ForEach(sorted(grants), id: \.id) { grant in
                    grantDetails(
                        grant,
                        status: resets,
                        now: allowsStaleDisplay ? limits.fetchedAt : now
                    )
                }
            } else {
                Text("No resets saved.")
                    .textStyle(.caption)
                    .foregroundStyle(Palette.textSecondary)
            }

            if let count, count > 0 {
                Link(
                    "Open Claude Usage ↗",
                    destination: URL(string: "https://claude.ai/settings/usage")!
                )
                .textStyle(.caption)
                .help("Review saved resets in the official Claude Usage settings.")
            }
        }
        .padding(Spacing.md)
        .frame(width: 320, alignment: .leading)
    }

    private func grantDetails(
        _ grant: ClaudeResetGrant,
        status: ClaudeResetStatus,
        now: Date
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Text(grant.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                 ? "Reset grant" : grant.label)
                .textStyle(.label)
                .foregroundStyle(Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            Text(remainingTitle(grant.resetsLeft))
                .textStyle(.caption)
                .foregroundStyle(Palette.textSecondary)

            Text(grant.endsAt.map { "Expires \(ResetDateFormat.string(date: $0))" }
                 ?? "Expiry not provided")
                .textStyle(.caption)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if let startsAt = grant.startsAt, startsAt > now {
                Text("Starts \(ResetDateFormat.string(date: startsAt))")
                    .textStyle(.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(availabilityText(for: grant, status: status, now: now))
                .textStyle(.caption)
                .foregroundStyle(
                    !allowsStaleDisplay && status.canUse(grant, at: now)
                        ? Palette.accent
                        : Palette.textSecondary
                )
                .fixedSize(horizontal: false, vertical: true)

            if !grant.clears.isEmpty {
                Text("Clears: \(friendlyValues(grant.clears, unknown: "another usage window"))")
                    .textStyle(.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !grant.blocking.isEmpty {
                Text("Waiting on: \(friendlyValues(grant.blocking, unknown: "another condition"))")
                    .textStyle(.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func availabilityText(
        for grant: ClaudeResetGrant,
        status: ClaudeResetStatus,
        now: Date
    ) -> String {
        let currentText: String
        if status.canUse(grant, at: now) {
            currentText = "Ready to use"
        } else if grant.paused {
            currentText = "Temporarily unavailable"
        } else if let cooldownUntil = status.cooldownUntil, cooldownUntil > now {
            currentText = "Available after \(ResetDateFormat.string(date: cooldownUntil))"
        } else if grant.useRequiresLimit && !grant.usableNow {
            currentText = "Available when a usage limit is reached"
        } else {
            currentText = "Not currently available"
        }
        return allowsStaleDisplay ? "At last update: \(currentText)" : currentText
    }

    private func sorted(_ grants: [ClaudeResetGrant]) -> [ClaudeResetGrant] {
        grants.sorted {
            ($0.endsAt ?? .distantFuture, $0.label, $0.id)
                < ($1.endsAt ?? .distantFuture, $1.label, $1.id)
        }
    }

    private func friendlyValues(_ values: [String], unknown: String) -> String {
        values.map { value in
            switch value.lowercased() {
            case "five_hour", "5_hour", "session": "5-hour limit"
            case "seven_day", "weekly", "weekly_all": "7-day limit"
            case "seven_day_opus", "weekly_opus": "7-day Opus limit"
            case "seven_day_sonnet", "weekly_sonnet": "7-day Sonnet limit"
            case "limit": "a usage limit"
            default: unknown
            }
        }
        .uniqued()
        .joined(separator: ", ")
    }

    private func compactTitle(_ count: Int) -> String {
        count == 1 ? "1 reset" : "\(count) resets"
    }

    private func accessibilityTitle(_ count: Int) -> String {
        count == 1 ? "1 Claude reset saved" : "\(count) Claude resets saved"
    }

    private func remainingTitle(_ count: Int) -> String {
        count == 1 ? "1 reset remaining" : "\(count) resets remaining"
    }
}

private extension Sequence where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
