import AppKit
import SwiftUI
import TokiCore

/// The two forms of the "Claude Code itself is having trouble" banner: a compact one for the
/// menu-bar popover and a fuller one for the dashboard.
///
/// Both take a plain `ServiceStatus` VALUE rather than the store. The snapshot harness and
/// the debug control channel render surfaces offscreen from fixture bundles, and offscreen
/// rendering never fires `onAppear` — so everything drawn here must be derivable from the
/// value that was passed in, with no state raised by a lifecycle callback.
///
/// Neither form has an "everything is fine" state. An operational service renders *nothing*:
/// a permanent green pill would occupy the top of both surfaces every day of the year to say
/// what the user already assumes, and the banner's presence is the whole signal.

// MARK: - Severity presentation

/// The one place severity becomes a colour, a glyph and a headline, shared by both forms so
/// the popover and the dashboard can never disagree about how bad something is. No new
/// colour tokens: `warn` and `critical` are the palette's existing pair.
private struct StatusSeverityStyle {
    let tint: Color
    let icon: String
    let title: String

    init?(_ severity: StatusSeverity, provider: UsageProvider) {
        switch severity {
        case .operational:
            return nil
        case .degraded:
            tint = Palette.warn
            icon = "exclamationmark.triangle.fill"
            title = "\(provider.displayName) — degraded performance"
        case .outage:
            tint = Palette.critical
            icon = "xmark.octagon.fill"
            title = "\(provider.displayName) — service outage"
        }
    }
}

/// Anthropic's own status page — the place with the full history and the subscribe button.
private func statusPageURL(for provider: UsageProvider) -> URL {
    URL(string: provider == .claudeCode
        ? "https://status.claude.com"
        : "https://status.openai.com")!
}

// MARK: - Compact (popover)

/// The popover form: one tappable card that names the severity, quotes Anthropic's incident
/// title, and opens the status page.
struct ServiceStatusBannerCompact: View {
    let status: ServiceStatus
    var provider: UsageProvider = .claudeCode

    /// Shown when there is no incident record yet — Statuspage can report a degraded
    /// component minutes before anyone publishes a sentence about it, and "degraded" with a
    /// blank second line reads as a rendering bug rather than as the truth.
    private var noDetailsYet: String {
        provider == .claudeCode
            ? "Anthropic hasn't posted details yet."
            : "OpenAI hasn't posted details yet."
    }

    var body: some View {
        if let style = StatusSeverityStyle(status.severity, provider: provider) {
            Button {
                NSWorkspace.shared.open(statusPageURL(for: provider))
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                    Image(systemName: style.icon)
                        .foregroundStyle(style.tint)
                        .imageScale(.small)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(style.title)
                            .textStyle(.label)
                            .foregroundStyle(Palette.textPrimary)
                        Text(detail)
                            .textStyle(.detail)
                            .foregroundStyle(Palette.textSecondary)
                            .lineLimit(2)
                    }

                    Spacer(minLength: 0)
                }
                // Rasterize the primitives together so individual Text backing layers
                // cannot retain vertically inverted pixels after a layer-geometry change.
                // Keep the native Button and material outside the drawing group.
                .drawingGroup()
                .padding(Spacing.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
                .panelCard(rimBright: true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(style.title). \(detail). Opens the provider status page")
        }
    }

    private var detail: String {
        status.incident?.title ?? noDetailsYet
    }
}

// MARK: - Full (dashboard)

/// The dashboard form: the same headline, plus what Anthropic last said, when they said it,
/// and which components they named.
struct ServiceStatusBannerFull: View {
    let status: ServiceStatus
    var provider: UsageProvider = .claudeCode

    var body: some View {
        if let style = StatusSeverityStyle(status.severity, provider: provider) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                // Keep the informational primitives in one rasterized image. On macOS,
                // separate Text layers can retain a stale Y orientation when attached.
                // The native Link and translucent card must render outside this group.
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                        Image(systemName: style.icon)
                            .foregroundStyle(style.tint)
                            .imageScale(.small)

                        Text(style.title)
                            .textStyle(.label)
                            .foregroundStyle(Palette.textPrimary)

                        Spacer()

                        // Omitted entirely when the page sent a date we could not parse: an
                        // age label is only worth the row when it is a real age.
                        if let age {
                            Text(age)
                                .textStyle(.caption)
                                .foregroundStyle(Palette.textSecondary)
                        }
                    }

                    if let update = status.incident?.latestUpdate {
                        Text(update)
                            .textStyle(.detail)
                            .foregroundStyle(Palette.textSecondary)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    let components = status.incident?.affectedComponentNames ?? []
                    if !components.isEmpty {
                        HStack(spacing: Spacing.xxs) {
                            ForEach(components, id: \.self) { name in
                                StatusPill(text: name, color: style.tint)
                            }
                        }
                    }
                }
                .drawingGroup()

                Link("View status page", destination: statusPageURL(for: provider))
                    .textStyle(.detail)
                    .foregroundStyle(Palette.accent)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Spacing.md)
            .panelCard()
        }
    }

    /// "Updated 12m ago". Same shape as the popover header's freshness label — minutes, then
    /// hours, then days — kept local because that one is a private helper of a different view
    /// measuring a different thing (Toki's own data, not Anthropic's post).
    private var age: String? {
        guard let updatedAt = status.incident?.updatedAt else { return nil }
        let elapsed = Date().timeIntervalSince(updatedAt)
        let minutes = Int(elapsed / 60)
        if minutes < 1 { return "Updated just now" }
        if minutes == 1 { return "Updated 1m ago" }
        let hours = minutes / 60
        if hours < 1 { return "Updated \(minutes)m ago" }
        let days = hours / 24
        if days < 1 { return "Updated \(hours)h ago" }
        return "Updated \(days)d ago"
    }
}
