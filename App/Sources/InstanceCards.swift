/// InstanceCards — glass-aesthetic card components for the "Instances" tab
/// (running Claude Code CLI processes, grouped by version).
///
/// No Swift Charts dependency. All visualisations use the design-system
/// primitives: panelCard, SectionHeader, StatusPill, cardLabel/cardValue.
import TokiCore
import SwiftUI

// MARK: - Version Group Header

/// Header row for a collapsible version group. It keeps the information needed for the
/// compact Machine overview visible without revealing any process rows.
@MainActor
struct VersionGroupHeader: View {
    let version: String
    let count: Int
    let totalMemoryBytes: UInt64?
    let oldestStartedAt: Date?
    /// nil => no badge (referenceVersion unknown); true => [latest]; false => [outdated].
    let isLatest: Bool?

    var body: some View {
        HStack(spacing: Spacing.xs) {
            Text(version)
                .textStyle(.metricInline)
                .foregroundStyle(Palette.textPrimary)

            Text("\u{00B7}")
                .foregroundStyle(Palette.textSecondary.opacity(0.6))

            Text(count == 1 ? "1 running" : "\(count) running")
                .cardLabel()

            Spacer(minLength: Spacing.xs)

            if let totalMemoryBytes {
                summaryItem(symbol: "memorychip", text: formattedMemory(totalMemoryBytes))
            }

            if let oldestStartedAt {
                summaryItem(symbol: "clock", text: "oldest \(relativeUptime(since: oldestStartedAt))")
            }

            if let isLatest {
                VersionBadge(isLatest: isLatest)
            }
        }
    }

    @ViewBuilder
    private func summaryItem(symbol: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .iconSize(.small)
            Text(text)
                .textStyle(.metricInline)
        }
        .foregroundStyle(Palette.textSecondary)
    }
}

@MainActor
private struct VersionBadge: View {
    let isLatest: Bool

    var body: some View {
        Text(isLatest ? "latest" : "outdated")
            .textStyle(.caption)
            .foregroundStyle(isLatest ? Palette.ok : Palette.warn)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(
                Capsule().fill((isLatest ? Palette.ok : Palette.warn).opacity(0.14))
            )
    }
}

// MARK: - Instance Card

@MainActor
struct InstanceCard: View {
    let instance: ClaudeInstance
    /// Fires when the user completes a hold on this row's kill pill.
    var onKill: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(alignment: .center, spacing: Spacing.xs) {
                Text(instance.projectName ?? "\u{2014}")
                    .textStyle(.headline)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)

                if instance.source == .managed {
                    ManagedChip(executablePath: instance.executablePath)
                }

                Spacer(minLength: Spacing.sm)

                HoldToKillButton(action: onKill)
            }

            if let workingDirectory = instance.workingDirectory {
                Text(workingDirectory)
                    .cardLabel()
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            statLine
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var statLine: some View {
        HStack(spacing: Spacing.md) {
            statItem(symbol: "clock", text: relativeUptime(since: instance.startedAt))
            if let memoryBytes = instance.memoryBytes {
                statItem(symbol: "memorychip", text: formattedMemory(memoryBytes))
            }
            statItem(symbol: "number", text: "pid \(instance.pid)")
            Spacer(minLength: 0)
        }
        .padding(.top, 2)
    }

    @ViewBuilder
    private func statItem(symbol: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .iconSize(.small)
                .foregroundStyle(Palette.textSecondary)
            Text(text)
                .textStyle(.metricInline)
                .foregroundStyle(Palette.textSecondary)
        }
    }
}

@MainActor
private struct ManagedChip: View {
    let executablePath: String

    private var label: String {
        executablePath.lowercased().contains("conductor") ? "Conductor" : "managed"
    }

    var body: some View {
        Text(label)
            .textStyle(.caption)
            .foregroundStyle(Palette.textSecondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(Palette.textSecondary.opacity(0.14)))
    }
}

// MARK: - Formatting helpers

/// Relative uptime from a process start time to now: "just now" (<1m),
/// "5m" (<1h), "3h" (<1d), "2d" (>=1d). Returns "\u{2014}" when `date` is nil.
func relativeUptime(since date: Date?, now: Date = Date()) -> String {
    guard let date else { return "\u{2014}" }
    let elapsed = max(0, now.timeIntervalSince(date))
    let minutes = Int(elapsed / 60)
    if minutes < 1 { return "just now" }
    if minutes < 60 { return "\(minutes)m" }
    let hours = minutes / 60
    if hours < 24 { return "\(hours)h" }
    let days = hours / 24
    return "\(days)d"
}

/// Formats resident memory bytes compactly: "148 MB" below 1 GB, "1.2 GB" at/above.
///
/// Goes through `DisplayFormat`, not `ByteCountFormatter` — the latter takes its decimal
/// separator from the machine and rendered "1,22 GB" next to English labels.
func formattedMemory(_ bytes: UInt64) -> String {
    DisplayFormat.memory(bytes: bytes)
}
