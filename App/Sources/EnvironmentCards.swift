/// EnvironmentCards — glass-aesthetic card components for the "Your Claude"
/// environment view (CLI info, plugins, marketplaces, skills, MCP servers).
///
/// No Swift Charts dependency. All visualisations use the design-system
/// primitives: panelCard, SectionHeader, StatusPill, cardLabel/cardValue.
import TokiCore
import SwiftUI

// MARK: - Shared compact details

@MainActor
private struct EnvironmentStatusBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .textStyle(.caption)
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.14)))
    }
}

@MainActor
private struct EnvironmentDetailRow: View {
    let label: String
    let value: String
    var secondary: String? = nil
    var statusText: String? = nil
    var statusColor: Color = Palette.textSecondary

    var body: some View {
        HStack(spacing: Spacing.xs) {
            Text(label)
                .textStyle(.detail)
                .foregroundStyle(Palette.textSecondary)

            Spacer(minLength: Spacing.xs)

            Text(value)
                .textStyle(.metricInline)
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)

            if let secondary {
                Text(secondary)
                    .textStyle(.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
            }

            if let statusText {
                EnvironmentStatusBadge(text: statusText, color: statusColor)
            }
        }
    }
}

// MARK: - CLI Info Card

@MainActor
struct CLIInfoCard: View {
    let cli: CLIInfo
    let isExpanded: Bool
    let onToggle: () -> Void

    var body: some View {
        MachineDisclosureCard(
            isExpanded: isExpanded,
            accessibilityLabel: "CLI \(cli.version ?? "unknown")",
            onToggle: onToggle
        ) {
            HStack(spacing: Spacing.xs) {
                SectionHeader("CLI · \(cli.version ?? "unknown")")

                Spacer(minLength: Spacing.xs)

                if let installLine {
                    Text(installLine)
                        .textStyle(.metricInline)
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(1)
                }

                if cli.updateAvailable {
                    EnvironmentStatusBadge(text: "Update available", color: Palette.accent)
                } else if cli.latestVersion != nil {
                    EnvironmentStatusBadge(text: "Up to date", color: Palette.ok)
                }
            }
        } details: {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                if let installLine {
                    EnvironmentDetailRow(label: "Installation", value: installLine)
                }

                if let latestVersion = cli.latestVersion {
                    EnvironmentDetailRow(label: "Latest version", value: latestVersion)
                }

                if let outcome = cli.lastUpdateOutcome {
                    let succeeded = outcome.lowercased().contains("success")
                    EnvironmentDetailRow(
                        label: "Last update",
                        value: updateHistoryValue(succeeded: succeeded),
                        secondary: cli.lastUpdateAt.map(relativeAge),
                        statusText: outcome.capitalized,
                        statusColor: succeeded ? Palette.ok : Palette.warn
                    )
                } else if let from = cli.lastUpdateFrom, let to = cli.lastUpdateTo {
                    EnvironmentDetailRow(label: "Last update", value: "\(from) \u{2192} \(to)")
                } else {
                    EnvironmentDetailRow(label: "Last update", value: "No history")
                }

                if let autoUpdates = cli.autoUpdates {
                    EnvironmentDetailRow(
                        label: "Auto-updates",
                        value: autoUpdates ? "On" : "Off",
                        statusText: autoUpdates ? "Enabled" : nil,
                        statusColor: Palette.ok
                    )
                }
            }
            .padding(Spacing.md)
        }
    }

    /// "native · latest channel" / "npm-global" — the install method plus, for
    /// native installs, the release channel the update badge is measured against
    /// (defaulting to `latest`, matching the CLI when unconfigured).
    private var installLine: String? {
        guard let method = cli.installMethod else { return nil }
        guard method == "native" else { return method }
        let channel = cli.releaseChannel ?? "latest"
        return "\(method) · \(channel) channel"
    }

    private func updateHistoryValue(succeeded: Bool) -> String {
        guard succeeded else { return "Failed" }
        return "\(cli.lastUpdateFrom ?? "?") \u{2192} \(cli.lastUpdateTo ?? "?")"
    }

    private func relativeAge(since date: Date) -> String {
        let elapsed = Date().timeIntervalSince(date)
        let minutes = Int(elapsed / 60)
        if minutes < 1 { return "just now" }
        if minutes == 1 { return "1m ago" }
        let hours = minutes / 60
        if hours < 1 { return "\(minutes)m ago" }
        let days = hours / 24
        if days < 1 { return "\(hours)h ago" }
        return "\(days)d ago"
    }
}

// MARK: - Plugins Card

@MainActor
struct PluginsCard: View {
    let plugins: [PluginInfo]
    let isExpanded: Bool
    let onToggle: () -> Void

    private var sorted: [PluginInfo] {
        plugins.sorted { a, b in
            if a.isFavorite != b.isFavorite { return a.isFavorite }
            let aUsage = a.usageCount ?? 0
            let bUsage = b.usageCount ?? 0
            if aUsage != bUsage { return aUsage > bUsage }
            return a.name < b.name
        }
    }

    private var enabledCount: Int {
        plugins.filter(\.enabled).count
    }

    private var updateCount: Int {
        plugins.filter { $0.versionStatus == .outdated }.count
    }

    private var currentCount: Int {
        plugins.filter { $0.versionStatus == .upToDate }.count
    }

    private var unknownCount: Int {
        plugins.filter { $0.versionStatus == .unknown }.count
    }

    var body: some View {
        MachineDisclosureCard(
            isExpanded: isExpanded,
            accessibilityLabel: "Plugins, \(plugins.count)",
            onToggle: onToggle
        ) {
            HStack(spacing: Spacing.xs) {
                SectionHeader("Plugins · \(plugins.count)")
                Spacer(minLength: Spacing.xs)
                Text("\(enabledCount) enabled")
                    .textStyle(.metricInline)
                    .foregroundStyle(Palette.textSecondary)
                if currentCount > 0 {
                    EnvironmentStatusBadge(text: "\(currentCount) current", color: Palette.ok)
                }
                if updateCount > 0 {
                    EnvironmentStatusBadge(
                        text: "\(updateCount) outdated",
                        color: Palette.accent
                    )
                }
                if unknownCount > 0 {
                    EnvironmentStatusBadge(text: "\(unknownCount) unknown", color: Palette.textSecondary)
                }
            }
        } details: {
            VStack(spacing: Spacing.xs) {
                ForEach(sorted) { plugin in
                    PluginRow(plugin: plugin)
                    if plugin.id != sorted.last?.id {
                        Divider().overlay(Palette.hairline)
                    }
                }
            }
            .padding(Spacing.md)
        }
    }
}

@MainActor
private struct PluginRow: View {
    let plugin: PluginInfo

    var body: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: plugin.isFavorite ? "star.fill" : "star")
                .iconSize(.regular)
                .foregroundStyle(plugin.isFavorite ? Palette.accent : Palette.textSecondary.opacity(0.4))

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(plugin.name)
                        .textStyle(.body)
                        .foregroundStyle(Palette.textPrimary)
                    if let version = plugin.version {
                        Text(version)
                            .textStyle(.metricInline)
                            .foregroundStyle(Palette.textSecondary)
                    }
                }
                Text(plugin.marketplace)
                    .textStyle(.caption)
                    .foregroundStyle(Palette.textSecondary.opacity(0.8))
            }

            Spacer(minLength: Spacing.xs)

            PluginVersionBadge(plugin: plugin)

            if let usage = plugin.usageCount {
                Text("\(usage)")
                    .textStyle(.metricInline)
                    .foregroundStyle(Palette.textSecondary)
                    .frame(minWidth: 22, alignment: .trailing)
            }

            StatusPill(
                text: plugin.enabled ? "Enabled" : "Disabled",
                color: plugin.enabled ? Palette.ok : Palette.textSecondary
            )
        }
        .opacity(plugin.enabled ? 1 : 0.55)
        .padding(.vertical, 2)
    }
}

@MainActor
private struct PluginVersionBadge: View {
    let plugin: PluginInfo

    private var presentation: (text: String, symbol: String, color: Color) {
        switch plugin.versionStatus {
        case .upToDate:
            return ("Current", "checkmark.circle.fill", Palette.ok)
        case .outdated:
            let text = plugin.latestVersion.map { "Outdated · \($0)" } ?? "Outdated"
            return (text, "arrow.up.circle.fill", Palette.accent)
        case .unknown:
            return ("Unknown", "questionmark.circle", Palette.textSecondary)
        }
    }

    var body: some View {
        let content = presentation
        HStack(spacing: 3) {
            Image(systemName: content.symbol)
                .iconSize(.small)
            Text(content.text)
                .textStyle(.metricInline)
        }
        .foregroundStyle(content.color)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(content.color.opacity(0.14)))
        .accessibilityLabel("Version status: \(content.text)")
    }
}

// MARK: - Marketplaces Card

@MainActor
struct MarketplacesCard: View {
    let marketplaces: [MarketplaceInfo]
    let isExpanded: Bool
    let onToggle: () -> Void

    private var sorted: [MarketplaceInfo] {
        marketplaces.sorted { $0.name < $1.name }
    }

    private var latestUpdate: Date? {
        marketplaces.compactMap(\.lastUpdated).max()
    }

    var body: some View {
        MachineDisclosureCard(
            isExpanded: isExpanded,
            accessibilityLabel: "Marketplaces, \(marketplaces.count)",
            onToggle: onToggle
        ) {
            HStack(spacing: Spacing.xs) {
                SectionHeader("Marketplaces · \(marketplaces.count)")
                Spacer(minLength: Spacing.xs)
                if let latestUpdate {
                    Text("updated \(relativeAge(since: latestUpdate))")
                        .textStyle(.metricInline)
                        .foregroundStyle(Palette.textSecondary)
                }
            }
        } details: {
            VStack(spacing: Spacing.xs) {
                ForEach(sorted) { marketplace in
                    MarketplaceRow(marketplace: marketplace)
                    if marketplace.id != sorted.last?.id {
                        Divider().overlay(Palette.hairline)
                    }
                }
            }
            .padding(Spacing.md)
        }
    }

    private func relativeAge(since date: Date) -> String {
        let elapsed = Date().timeIntervalSince(date)
        let minutes = Int(elapsed / 60)
        if minutes < 1 { return "just now" }
        if minutes == 1 { return "1m ago" }
        let hours = minutes / 60
        if hours < 1 { return "\(minutes)m ago" }
        let days = hours / 24
        if days < 1 { return "\(hours)h ago" }
        return "\(days)d ago"
    }
}

@MainActor
private struct MarketplaceRow: View {
    let marketplace: MarketplaceInfo

    var body: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "shippingbox.fill")
                .iconSize(.regular)
                .foregroundStyle(Palette.textSecondary)

            VStack(alignment: .leading, spacing: 1) {
                Text(marketplace.name)
                    .textStyle(.body)
                    .foregroundStyle(Palette.textPrimary)
                if let repo = marketplace.repo {
                    Text(repo)
                        .textStyle(.caption)
                        .foregroundStyle(Palette.textSecondary.opacity(0.8))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: Spacing.xs)

            if let lastUpdated = marketplace.lastUpdated {
                Text(relativeAge(since: lastUpdated))
                    .textStyle(.caption)
                    .foregroundStyle(Palette.textSecondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func relativeAge(since date: Date) -> String {
        let elapsed = Date().timeIntervalSince(date)
        let minutes = Int(elapsed / 60)
        if minutes < 1 { return "just now" }
        if minutes == 1 { return "1m ago" }
        let hours = minutes / 60
        if hours < 1 { return "\(minutes)m ago" }
        let days = hours / 24
        if days < 1 { return "\(hours)h ago" }
        return "\(days)d ago"
    }
}

// MARK: - Skills Card

@MainActor
struct SkillsCard: View {
    let skills: [SkillInfo]
    let isExpanded: Bool
    let onToggle: () -> Void

    /// A plugin sub-category within a marketplace.
    private struct PluginGroup: Identifiable {
        let id: String          // plugin name
        var plugin: String { id }
        let skills: [SkillInfo]
        var totalUsage: Int { skills.reduce(0) { $0 + ($1.usageCount ?? 0) } }
        var skillCount: Int { skills.count }
    }

    /// A top-level marketplace category, containing plugin sub-groups.
    private struct MarketGroup: Identifiable {
        let id: String          // marketplace name
        var marketplace: String { id }
        let plugins: [PluginGroup]
        var totalUsage: Int { plugins.reduce(0) { $0 + $1.totalUsage } }
        var skillCount: Int { plugins.reduce(0) { $0 + $1.skillCount } }
    }

    private var groups: [MarketGroup] {
        Dictionary(grouping: skills) { $0.marketplace ?? "Other" }
            .map { market, marketSkills -> MarketGroup in
                let plugins = Dictionary(grouping: marketSkills) { $0.plugin ?? "Built-in" }
                    .map { plugin, ps in
                        PluginGroup(id: plugin, skills: ps.sorted {
                            ($0.usageCount ?? 0, $1.name) > ($1.usageCount ?? 0, $0.name)
                        })
                    }
                    .sorted { rank($0.id, $0.totalUsage) < rank($1.id, $1.totalUsage) }
                return MarketGroup(id: market, plugins: plugins)
            }
            .sorted { rank($0.id, $0.totalUsage) < rank($1.id, $1.totalUsage) }
    }

    /// Sort key: named categories by descending usage, catch-all buckets last.
    private func rank(_ id: String, _ usage: Int) -> (Int, Int, String) {
        let catchAll = (id == "Other" || id == "Built-in") ? 1 : 0
        return (catchAll, -usage, id)
    }

    private var totalUsage: Int? {
        let values = skills.compactMap(\.usageCount)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +)
    }

    var body: some View {
        MachineDisclosureCard(
            isExpanded: isExpanded,
            accessibilityLabel: "Skills, \(skills.count)",
            onToggle: onToggle
        ) {
            HStack(spacing: Spacing.xs) {
                SectionHeader("Skills · \(skills.count)")
                Spacer(minLength: Spacing.xs)
                if let totalUsage {
                    Text("\(totalUsage) uses")
                        .textStyle(.metricInline)
                        .foregroundStyle(Palette.textSecondary)
                }
            }
        } details: {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                ForEach(groups) { market in
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        // Marketplace header (top-level category).
                        HStack {
                            Text(market.marketplace)
                                .textStyle(.label)
                                .foregroundStyle(Palette.textSecondary)
                            Spacer()
                            Text("\(market.skillCount)")
                                .textStyle(.metricInline)
                                .foregroundStyle(Palette.textSecondary.opacity(0.55))
                        }

                        // Plugin sub-categories, indented under the marketplace.
                        ForEach(market.plugins) { pg in
                            VStack(alignment: .leading, spacing: Spacing.xxs) {
                                Text(pg.plugin)
                                    .textStyle(.label)
                                    .foregroundStyle(Palette.textSecondary.opacity(0.85))
                                ForEach(pg.skills) { skill in
                                    SkillRow(skill: skill)
                                }
                            }
                            .padding(.leading, Spacing.sm)
                        }
                    }
                    if market.id != groups.last?.id {
                        Divider().overlay(Palette.hairline)
                    }
                }
            }
            .padding(Spacing.md)
        }
    }
}

@MainActor
private struct SkillRow: View {
    let skill: SkillInfo

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            Image(systemName: "sparkles")
                .iconSize(.regular)
                .foregroundStyle(Palette.textSecondary)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 1) {
                Text(skill.name)
                    .textStyle(.body)
                    .foregroundStyle(Palette.textPrimary)
                if let description = skill.description {
                    Text(description)
                        .textStyle(.caption)
                        .foregroundStyle(Palette.textSecondary.opacity(0.7))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: Spacing.xs)

            if let usage = skill.usageCount {
                Text("\(usage)")
                    .textStyle(.metricInline)
                    .foregroundStyle(Palette.textSecondary)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - MCP Servers Card

@MainActor
struct MCPServersCard: View {
    let servers: [MCPServerInfo]
    let isExpanded: Bool
    let onToggle: () -> Void

    private var sorted: [MCPServerInfo] {
        servers.sorted { $0.name < $1.name }
    }

    private var needsAuthCount: Int {
        servers.filter(\.needsAuth).count
    }

    var body: some View {
        MachineDisclosureCard(
            isExpanded: isExpanded,
            accessibilityLabel: "MCP servers, \(servers.count)",
            onToggle: onToggle
        ) {
            HStack(spacing: Spacing.xs) {
                SectionHeader("MCP servers · \(servers.count)")
                Spacer(minLength: Spacing.xs)
                if needsAuthCount > 0 {
                    EnvironmentStatusBadge(
                        text: "\(needsAuthCount) needs auth",
                        color: Palette.warn
                    )
                } else {
                    Text("all ready")
                        .textStyle(.metricInline)
                        .foregroundStyle(Palette.textSecondary)
                }
            }
        } details: {
            VStack(spacing: Spacing.xs) {
                ForEach(sorted) { server in
                    MCPServerRow(server: server)
                    if server.id != sorted.last?.id {
                        Divider().overlay(Palette.hairline)
                    }
                }
            }
            .padding(Spacing.md)
        }
    }
}

@MainActor
private struct MCPServerRow: View {
    let server: MCPServerInfo

    private var transportColor: Color {
        switch server.transport {
        case "stdio": return Palette.textSecondary
        case "http", "sse": return Palette.accent
        default: return Palette.textSecondary
        }
    }

    var body: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "server.rack")
                .iconSize(.regular)
                .foregroundStyle(Palette.textSecondary)

            VStack(alignment: .leading, spacing: 1) {
                Text(server.name)
                    .textStyle(.body)
                    .foregroundStyle(Palette.textPrimary)
                HStack(spacing: 5) {
                    Text(server.source == "user" ? "user" : server.source)
                        .textStyle(.caption)
                        .foregroundStyle(Palette.textSecondary.opacity(0.8))
                    if let version = server.providingPluginVersion {
                        Text(version)
                            .textStyle(.metricInline)
                            .foregroundStyle(Palette.textSecondary.opacity(0.6))
                    }
                }
            }

            if let detail = server.detail {
                Text(detail)
                    .textStyle(.mono)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: Spacing.xs)

            if server.needsAuth {
                HStack(spacing: 3) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .iconSize(.small)
                    Text("Needs auth")
                        .textStyle(.caption)
                }
                .foregroundStyle(Palette.warn)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Palette.warn.opacity(0.14)))
            }

            Text(server.transport)
                .textStyle(.caption)
                .foregroundStyle(transportColor)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Capsule().fill(transportColor.opacity(0.14)))
        }
        .padding(.vertical, 2)
    }
}
