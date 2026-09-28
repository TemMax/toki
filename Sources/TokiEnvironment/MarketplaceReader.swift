/// Reads configured plugin marketplaces from
/// `~/.claude/plugins/known_marketplaces.json`, optionally merging in
/// `extraKnownMarketplaces` from `~/.claude/settings.json`.
import TokiModels
import Foundation

enum MarketplaceReader {
    private struct MarketplaceSource: Decodable {
        var repo: String?
    }

    private struct MarketplaceEntry: Decodable {
        var source: MarketplaceSource?
        var lastUpdated: String?
    }

    static func read(claudeHome: URL) -> [MarketplaceInfo] {
        var marketplaces: [String: MarketplaceInfo] = [:]

        let known = readJSON(
            [String: MarketplaceEntry].self,
            at: claudeHome.appendingPathComponent("plugins/known_marketplaces.json")
        ) ?? [:]
        for (name, entry) in known {
            marketplaces[name] = MarketplaceInfo(
                name: name,
                repo: entry.source?.repo,
                lastUpdated: parseISO8601(entry.lastUpdated)
            )
        }

        // Optional merge: settings.json's extraKnownMarketplaces carries the
        // same {source: {repo}} shape but no lastUpdated.
        let settings = readJSONValue(at: claudeHome.appendingPathComponent("settings.json"))
        if let extra = settings?["extraKnownMarketplaces"]?.objectValue {
            for (name, entry) in extra where marketplaces[name] == nil {
                let repo = entry["source"]?["repo"]?.stringValue
                marketplaces[name] = MarketplaceInfo(name: name, repo: repo, lastUpdated: nil)
            }
        }

        return marketplaces.values.sorted { $0.name < $1.name }
    }
}
