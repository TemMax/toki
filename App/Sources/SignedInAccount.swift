import Foundation
import Observation
import TokiCore
import TokiAccounts
import TokiSwap
import TokiFixtures

/// The single source of truth for *who* Claude Code is signed in as.
///
/// Before this, the same "signed-in account" datum was read four different ways — the
/// dashboard header, the popover, the Accounts tab and the new-account notification each
/// parsed `~/.claude.json` on their own schedule, in two different identity types, and drifted
/// (the symptom being a stale email or a spurious "No account"). Now one object owns it,
/// `ClaudeConfigWatcher` refreshes it the instant the file changes, and every surface observes
/// it — so the moment the account switches, they all move together.
///
/// Reads only the config file; never touches the Keychain.
@Observable
@MainActor
final class SignedInAccount {
    /// Settable so the demo/snapshot harness can inject a mock identity, mirroring
    /// `LiveLimits.limits`. Production code sets it only through `refresh()`.
    var identity: AccountIdentity?

    /// A fixture must never be replaced by a real config read that was already in flight.
    var runMode: RunMode = .live {
        didSet {
            if runMode != oldValue { generation &+= 1 }
        }
    }

    /// The display label (email → name → org → uuid), or nil when signed out / unreadable.
    var label: String? { identity?.label }

    var usageAccount: UsageAccount? {
        identity.map { UsageAccount(accountUuid: $0.accountUuid, organizationUuid: $0.organizationUuid) }
    }

    private let configURL: URL
    private var generation: UInt64 = 0

    init(
        configURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude.json")
    ) {
        self.configURL = configURL
    }

    /// Re-reads the signed-in account from the config. Cheap and keychain-free; the ~120 KB
    /// file is parsed off the main actor.
    func refresh() async {
        guard runMode.isLive else { return }
        generation &+= 1
        let started = generation
        let current = await Self.read(configURL)
        guard runMode.isLive, generation == started else { return }
        identity = current
    }

    private static func read(_ url: URL) async -> AccountIdentity? {
        await Task.detached(priority: .utility) {
            // no-log: `readOAuthAccount()` already logs at the point it throws
            // (`ClaudeConfigEditor.readOAuthAccount()`); this call site only needs the
            // degrade-to-nil, not a second log line for the same failure.
            guard let oauth = try? ClaudeConfigEditor(configURL: url).readOAuthAccount() else {
                return nil
            }
            return AccountIdentity.parse(oauthAccount: oauth)
        }.value
    }
}
