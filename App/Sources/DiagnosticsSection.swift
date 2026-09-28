/// DIAGNOSTICS — the Settings section that turns "it broke" into a file a maintainer can read.
///
/// It sits directly above ABOUT rather than among the feature settings, because it belongs
/// with the version number and the update controls: everything a user reaches for when they
/// are about to file a report, in one place.
///
/// This is an extension on `SettingsSections` rather than a standalone view so it uses that
/// type's own `sourceRow`/`toggleRow` helpers verbatim — a diagnostics card that drew its own
/// rows would drift away from the six sections around it at the first restyle. Its state
/// (`isExportingLogs`, `isVerboseLogging`, `logExport`) is declared beside the other section
/// state in `SettingsView.swift`, since Swift extensions cannot add stored properties.
import AppKit
import SwiftUI
import TokiCore

extension SettingsSections {

    var diagnosticsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            SectionHeader("DIAGNOSTICS")

            VStack(alignment: .leading, spacing: Spacing.md) {
                // The sentence that decides whether a user is willing to attach the zip to a
                // public issue, so it says what is in it rather than reassuring in general.
                sourceRow(
                    icon: "ladybug.fill",
                    title: "Local diagnostic logs",
                    detail: "Toki keeps the last 3 days of logs on this Mac and deletes older ones automatically. Nothing is uploaded anywhere. The logs never contain tokens, e-mail addresses or file paths \u{2014} names and locations are replaced by short hashes \u{2014} so the exported archive is safe to attach to a public bug report."
                )

                Rectangle()
                    .fill(Palette.hairline)
                    .frame(height: 1)
                    .opacity(0.6)

                HStack(spacing: Spacing.sm) {
                    Button {
                        isExportingLogs = true
                        Task {
                            await logExport.exportLogs()
                            isExportingLogs = false
                        }
                    } label: {
                        Text("Export Logs\u{2026}")
                            .textStyle(.body)
                    }
                    .buttonStyle(.bordered)
                    .tint(Palette.accent)
                    .disabled(isExportingLogs)

                    Button {
                        logExport.revealLogs()
                    } label: {
                        Text("Reveal in Finder")
                            .textStyle(.body)
                    }
                    .buttonStyle(.bordered)

                    Spacer(minLength: 0)
                }

                Rectangle()
                    .fill(Palette.hairline)
                    .frame(height: 1)
                    .opacity(0.6)

                toggleRow(
                    title: "Verbose Logging",
                    detail: "Records extra diagnostic detail. Best turned off again once you\u{2019}ve captured the problem.",
                    isOn: $isVerboseLogging
                )
            }
            .padding(Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .panelCard()
        }
    }
}
