/// Reads CLI version/update metadata from `~/.claude/.last-update-result.json`
/// and the (allowlisted) `installMethod` / `autoUpdates` keys of `~/.claude.json`.
import TokiModels
import Foundation

enum CLIReader {
    /// `~/.claude/.last-update-result.json` shape, as written by the CLI's
    /// self-update mechanism.
    private struct LastUpdateResult: Decodable {
        var timestamp: String?
        var outcome: String?
        var version_from: String?
        var version_to: String?
    }

    static func read(claudeHome: URL, claudeJSON: URL) -> CLIInfo? {
        let lastUpdate = readJSON(
            LastUpdateResult.self,
            at: claudeHome.appendingPathComponent(".last-update-result.json")
        )

        // SECURITY: read ONLY these allowlisted, non-sensitive keys from
        // ~/.claude.json. Never decode the whole document into a generic model.
        let topLevel = readJSONValue(at: claudeJSON)
        let installMethod = topLevel?["installMethod"]?.stringValue
        let autoUpdates = topLevel?["autoUpdates"]?.boolValue
        let releaseChannel = topLevel?["releaseChannel"]?.stringValue

        guard lastUpdate != nil || installMethod != nil || autoUpdates != nil else {
            return nil
        }

        // Current version: the last SUCCESSFUL update's target (version_to). When the
        // last update FAILED, version_to is null and the CLI is still on version_from —
        // so fall back to it (otherwise the version would appear blank after a failed update).
        return CLIInfo(
            version: lastUpdate?.version_to ?? lastUpdate?.version_from,
            installMethod: installMethod,
            autoUpdates: autoUpdates,
            lastUpdateFrom: lastUpdate?.version_from,
            lastUpdateTo: lastUpdate?.version_to,
            lastUpdateAt: parseISO8601(lastUpdate?.timestamp),
            lastUpdateOutcome: lastUpdate?.outcome,
            releaseChannel: releaseChannel
        )
    }
}
