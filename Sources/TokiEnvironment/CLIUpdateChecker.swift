/// Best-effort network check for the latest published Claude Code CLI version.
///
/// The source depends on how the CLI was installed, mirroring the CLI's own
/// updater logic:
///
///   • NATIVE installs (`~/.local/share/claude/...`, the recommended path) pull
///     from Anthropic's release channel:
///       `GET https://downloads.claude.ai/claude-code-releases/<channel>`
///     which returns the latest version for that channel as plain text.
///     Channels are `stable` / `latest` / `rc`; when unconfigured the CLI
///     defaults to `latest`, so we do too.
///
///   • NON-NATIVE installs (npm global/local — a now-deprecated path) resolve
///     the latest version from the npm registry's dist-tag endpoint:
///       `GET https://registry.npmjs.org/@anthropic-ai/claude-code/latest`
///
/// PRIVACY: both are anonymous `GET`s to public endpoints. Nothing about the
/// user, their config, or their installation is sent — only the fixed URL (plus
/// a channel path segment that is one of three constant strings). These are the
/// only network requests in the whole environment feature.
///
/// RESILIENCE: every failure mode (offline, timeout, non-200, malformed body,
/// unparsable version) is swallowed and reported as `nil`, so the environment
/// still loads fully from local disk when the check can't complete.
import Foundation
import TokiLogging

public enum CLIUpdateChecker {
    private static let log = TokiLog.logger("environment")

    static let nativeReleasesBase = "https://downloads.claude.ai/claude-code-releases"
    static let npmLatestURL = URL(string: "https://registry.npmjs.org/@anthropic-ai/claude-code/latest")!

    /// Valid native release channels. Anything else falls back to `latest`.
    static let knownChannels: Set<String> = ["stable", "latest", "rc"]

    /// The npm dist-tag document — only `version` is read.
    private struct DistTag: Decodable {
        var version: String?
    }

    /// Resolves the latest published version for the given install method,
    /// or `nil` on any failure. A short timeout keeps a slow/offline network
    /// from stalling the environment load.
    public static func fetchLatestVersion(
        installMethod: String?,
        releaseChannel: String?,
        session: URLSession = .shared
    ) async -> String? {
        if installMethod == "native" {
            return await fetchNativeChannelVersion(
                channel: normalizedChannel(releaseChannel), session: session
            )
        }
        return await fetchNpmLatest(session: session)
    }

    // MARK: - Native release channel

    /// Normalizes a configured channel to one the release endpoint serves,
    /// defaulting to `latest` (the CLI's own default when unconfigured).
    static func normalizedChannel(_ configured: String?) -> String {
        guard let configured = configured?.lowercased(), knownChannels.contains(configured) else {
            return "latest"
        }
        return configured
    }

    /// URL of the plain-text "latest version for this channel" pointer.
    static func nativeVersionURL(channel: String) -> URL? {
        URL(string: "\(nativeReleasesBase)/\(channel)")
    }

    private static func fetchNativeChannelVersion(channel: String, session: URLSession) async -> String? {
        guard let url = nativeVersionURL(channel: channel) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            // Offline/timeout is common and expected (see RESILIENCE above); a debug
            // trace is enough, this is not an application error.
            log.debug("native CLI version check request failed \(error: error)")
            return nil
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let body = String(data: data, encoding: .utf8) else {
            return nil
        }
        // The endpoint returns a bare version string; validate it so a stray
        // HTML/error body served with a 200 can't masquerade as a version.
        return sanitizedVersion(body)
    }

    // MARK: - npm registry (non-native installs)

    private static func fetchNpmLatest(session: URLSession) async -> String? {
        var request = URLRequest(url: npmLatestURL)
        request.timeoutInterval = 5
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            log.debug("npm CLI version check request failed \(error: error)")
            return nil
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            return nil
        }
        let tag: DistTag
        do {
            tag = try JSONDecoder().decode(DistTag.self, from: data)
        } catch {
            // `DistTag` is a fixed schema name, never a value from the response body.
            log.error("unparseable config field \(String(describing: DistTag.self), privacy: .public) \(error: error)")
            return nil
        }
        guard let version = tag.version else { return nil }
        return sanitizedVersion(version)
    }

    // MARK: - Helpers

    /// Trims whitespace, strips a leading `v`, and returns the string only if
    /// it looks like a dotted numeric version (e.g. `2.1.197`, `2.1.0-rc.1`).
    static func sanitizedVersion(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("v") { value.removeFirst() }
        guard !value.isEmpty else { return nil }
        // Must start with digit.digit.digit; a pre-release suffix is allowed.
        let head = value.split(separator: "-", maxSplits: 1).first.map(String.init) ?? value
        let components = head.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count >= 3, components.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) })
        else { return nil }
        return value
    }
}
