/// The non-identifying context a bug report needs.
///
/// Every field here is either a constant of the build (version, build number) or a property
/// of the machine model (OS version, architecture, locale, time zone) — never anything that
/// identifies the person running it. In particular: no user name, no host name, no home
/// directory, no file path, no e-mail. That is what makes this safe to attach to a bug
/// report without a second thought about what just got shipped alongside it.
import Foundation

public struct DiagnosticManifest: Sendable {
    public let appVersion: String
    public let buildNumber: String
    public let osVersion: String
    public let architecture: String
    public let locale: String
    public let timeZone: String
    public let exportedAt: Date

    public init(appVersion: String,
                buildNumber: String,
                osVersion: String,
                architecture: String,
                locale: String,
                timeZone: String,
                exportedAt: Date) {
        self.appVersion = appVersion
        self.buildNumber = buildNumber
        self.osVersion = osVersion
        self.architecture = architecture
        self.locale = locale
        self.timeZone = timeZone
        self.exportedAt = exportedAt
    }

    /// `nonisolated(unsafe)`: `ISO8601DateFormatter` is not marked `Sendable`, but this
    /// instance is never mutated after creation, and formatting is documented as safe for
    /// concurrent read-only use.
    private nonisolated(unsafe) static let exportedAtFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    public func render() -> String {
        """
        Toki Diagnostic Manifest
        App version:   \(appVersion)
        Build number:  \(buildNumber)
        OS version:    \(osVersion)
        Architecture:  \(architecture)
        Locale:        \(locale)
        Time zone:     \(timeZone)
        Exported at:   \(Self.exportedAtFormatter.string(from: exportedAt))
        """
    }
}
