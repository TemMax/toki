/// One row in the account list — the pure mapping, testable without SwiftUI.
import Foundation
import TokiModels

/// Why a row's gauges are stale — drives the banner wording on the Accounts tab.
public enum GaugeStaleReason: Equatable, Sendable {
    /// The account's token was rejected and could not be renewed.
    case auth
    /// The usage endpoint rate-limited this account's poll.
    case rateLimited
    /// Anything else — network failure, server error, decode failure.
    case network
}

public struct AccountPresentation: Equatable, Sendable, Identifiable {
    public var id: String { accountUuid }

    public let accountUuid: String
    public let label: String
    public let isActive: Bool
    public let health: AccountHealth
    /// Utilization 0…1, nil when this account's usage has never been fetched. While
    /// `gaugesAreStale` it is the last-known value, not a current one.
    public let fiveHour: Double?
    public let weekly: Double?
    /// When each window clears, nil when unknown. Carried alongside the utilization so a
    /// card can say *when* 92% stops mattering — the number alone is not actionable.
    public let fiveHourResetsAt: Date?
    public let weeklyResetsAt: Date?
    /// True when fresh data shows the account has no 5-hour limit at all (verified Claude
    /// Ultra). `fiveHour` is nil then too, so this flag is what tells "no such limit" apart
    /// from "unknown". Carried from the last-known snapshot while the gauges are stale.
    public let hasNoFiveHourLimit: Bool
    /// The per-model weekly window the API scopes separately (Fable today; it has been
    /// Opus and Sonnet before). Carried by the model's own name rather than a hardcoded
    /// id, so a renamed model shows up instead of silently emptying the gauge.
    public let scopedModel: Double?
    public let scopedModelResetsAt: Date?
    public let scopedModelLabel: String?
    /// True when the latest poll failed. The gauges then still carry the last-known values
    /// (shown dimmed under a banner) — hiding them left the card empty for the whole
    /// rate-limit back-off. Policy consumers must check this flag before trusting the values;
    /// `AccountSnapshot` drops them itself.
    public let gaugesAreStale: Bool
    /// When the values on this row were fetched, nil when there are none.
    public let fetchedAt: Date?
    /// Why the gauges are stale, when known — nil if not stale or the reason is unknown.
    public let staleReason: GaugeStaleReason?
    public let lastActiveAt: Date?
    /// The subscription plan's display name ("Pro", "Max", "Ultra"), nil when unknown.
    public let plan: String?
    /// False for the account Claude Code is signed into that Toki hasn't saved yet. It is
    /// shown so the tab never looks empty while the user is plainly signed in; the UI offers
    /// to save it rather than switch to it (there is nothing to switch to — it is already
    /// live), and it cannot be removed because there is no stored slot to remove.
    public let isStored: Bool

    public init(
        accountUuid: String, label: String, isActive: Bool, health: AccountHealth,
        fiveHour: Double?, weekly: Double?, gaugesAreStale: Bool, lastActiveAt: Date?,
        isStored: Bool = true,
        fiveHourResetsAt: Date? = nil, weeklyResetsAt: Date? = nil,
        scopedModel: Double? = nil, scopedModelResetsAt: Date? = nil,
        scopedModelLabel: String? = nil,
        staleReason: GaugeStaleReason? = nil,
        hasNoFiveHourLimit: Bool = false,
        plan: String? = nil,
        fetchedAt: Date? = nil
    ) {
        self.accountUuid = accountUuid
        self.label = label
        self.isActive = isActive
        self.health = health
        self.fiveHour = fiveHour
        self.weekly = weekly
        self.fiveHourResetsAt = fiveHourResetsAt
        self.weeklyResetsAt = weeklyResetsAt
        self.hasNoFiveHourLimit = hasNoFiveHourLimit && fiveHour == nil
        self.scopedModel = scopedModel
        self.scopedModelResetsAt = scopedModelResetsAt
        self.scopedModelLabel = scopedModelLabel
        self.gaugesAreStale = gaugesAreStale
        self.fetchedAt = fetchedAt
        self.staleReason = gaugesAreStale ? staleReason : nil
        self.lastActiveAt = lastActiveAt
        self.plan = plan
        self.isStored = isStored
    }

    /// The 5-hour utilization from a limits snapshot (nil when absent). Shared so every
    /// surface reads the same window ids.
    public static func fiveHour(from limits: UsageLimits?) -> Double? {
        limits?.windows.first { $0.id == "session" }?.utilization
    }

    /// The 5-hour utilization auto-swap should use. An account with no 5-hour limit can
    /// never hit one, so it counts as 0% used. A missing 5-hour window on an account that
    /// does have the limit stays nil (unknown).
    public static func fiveHourForPolicy(from limits: UsageLimits?) -> Double? {
        if limits?.hasNoFiveHourLimit == true { return 0 }
        return fiveHour(from: limits)
    }

    /// Same rule as `fiveHourForPolicy(from:)`, for a row already built. Nil while stale:
    /// last-known values are for display, never for a swap decision.
    public var fiveHourForPolicy: Double? {
        guard !gaugesAreStale else { return nil }
        return hasNoFiveHourLimit ? 0 : fiveHour
    }

    /// The one percentage a compact account summary shows: the 5-hour window, or the weekly
    /// one when the account has no 5-hour limit.
    public var headlineUtilization: Double? {
        hasNoFiveHourLimit ? weekly : fiveHour
    }

    /// The weekly utilization from a limits snapshot (nil when absent).
    public static func weekly(from limits: UsageLimits?) -> Double? {
        limits?.windows.first { $0.id == "weekly_all" }?.utilization
    }

    /// When the 5-hour window clears (nil when absent) — same window id as `fiveHour`.
    public static func fiveHourResetsAt(from limits: UsageLimits?) -> Date? {
        limits?.windows.first { $0.id == "session" }?.resetsAt
    }

    /// When the weekly window clears (nil when absent) — same window id as `weekly`.
    public static func weeklyResetsAt(from limits: UsageLimits?) -> Date? {
        limits?.windows.first { $0.id == "weekly_all" }?.resetsAt
    }

    static let scopedModelPrefix = "weekly_scoped:"

    /// The per-model weekly window, whichever model the API currently scopes. Matched on
    /// the `weekly_scoped:` prefix rather than a fixed model name — the client builds that
    /// id from the API's own `display_name`.
    public static func scopedModelWindow(from limits: UsageLimits?) -> RateLimitWindow? {
        limits?.windows.first { $0.id.hasPrefix(scopedModelPrefix) }
    }

    /// The scoped window's model name, e.g. "Fable".
    public static func scopedModelLabel(from limits: UsageLimits?) -> String? {
        scopedModelWindow(from: limits).map { String($0.id.dropFirst(scopedModelPrefix.count)) }
    }

    /// - Parameter livePlan: the plan `~/.claude.json` names right now, for the account
    ///   Claude Code is signed into. It wins over the slot's copy, which is only as fresh as
    ///   the moment the slot was saved.
    public static func make(
        slot: AccountSlot, active: Bool, limits: UsageLimits?, stale: Bool,
        staleReason: GaugeStaleReason? = nil, livePlan: String? = nil
    ) -> AccountPresentation {
        AccountPresentation(
            accountUuid: slot.identity.accountUuid,
            label: slot.displayLabel,
            isActive: active,
            health: slot.health,
            // Unknown stays nil: a zero would read as "plenty of headroom".
            fiveHour: fiveHour(from: limits),
            weekly: weekly(from: limits),
            gaugesAreStale: stale,
            lastActiveAt: slot.lastActiveAt,
            isStored: true,
            fiveHourResetsAt: fiveHourResetsAt(from: limits),
            weeklyResetsAt: weeklyResetsAt(from: limits),
            scopedModel: scopedModelWindow(from: limits)?.utilization,
            scopedModelResetsAt: scopedModelWindow(from: limits)?.resetsAt,
            scopedModelLabel: scopedModelLabel(from: limits),
            staleReason: staleReason,
            hasNoFiveHourLimit: limits?.hasNoFiveHourLimit ?? false,
            plan: livePlan ?? slot.identity.plan ?? ClaudePlan.displayName(credentialJSON: slot.credentialJSON),
            fetchedAt: limits?.fetchedAt
        )
    }

    /// The account Claude Code is currently signed into but Toki has not stored. Always
    /// active by definition, always healthy (it is the credential in use), and never
    /// removable.
    public static func makeLiveUnstored(
        identity: AccountIdentity, limits: UsageLimits?, stale: Bool,
        staleReason: GaugeStaleReason? = nil
    ) -> AccountPresentation {
        AccountPresentation(
            accountUuid: identity.accountUuid,
            label: identity.label,
            isActive: true,
            health: .ok,
            fiveHour: fiveHour(from: limits),
            weekly: weekly(from: limits),
            gaugesAreStale: stale,
            lastActiveAt: nil,
            isStored: false,
            fiveHourResetsAt: fiveHourResetsAt(from: limits),
            weeklyResetsAt: weeklyResetsAt(from: limits),
            scopedModel: scopedModelWindow(from: limits)?.utilization,
            scopedModelResetsAt: scopedModelWindow(from: limits)?.resetsAt,
            scopedModelLabel: scopedModelLabel(from: limits),
            staleReason: staleReason,
            hasNoFiveHourLimit: limits?.hasNoFiveHourLimit ?? false,
            plan: identity.plan,
            fetchedAt: limits?.fetchedAt
        )
    }

    /// Rows with the active account's gauges replaced by the shared live-limits
    /// snapshot — the one owner of the signed-in account's usage. Callers must explicitly
    /// attest that the snapshot is fresh; the safe default marks it stale (values stay as
    /// last-known, flagged). Sleeping rows pass through untouched. Surfaces
    /// render THESE rows, never the raw ones, so no
    /// consumer can forget the active-account join again (the popover's headroom
    /// column did exactly that, and the active row dashed out forever).
    public static func overlayingLiveActiveLimits(
        _ rows: [AccountPresentation], live: UsageLimits?, liveIsFresh: Bool = false,
        liveStaleReason: GaugeStaleReason? = nil
    ) -> [AccountPresentation] {
        rows.map { row in
            guard row.isActive else { return row }
            let scoped = scopedModelWindow(from: live)
            let liveHasPrimaryGauge = fiveHour(from: live) != nil || weekly(from: live) != nil
            let matchesAccount = live?.account.map { $0.accountUuid == row.accountUuid } ?? true
            let gaugesAreStale = !liveIsFresh || !liveHasPrimaryGauge || !matchesAccount
            // Another account's numbers must never appear on this card, stale or not. A
            // stale snapshot that IS this account's stays visible as last-known data.
            let live = matchesAccount ? live : nil
            return AccountPresentation(
                accountUuid: row.accountUuid,
                label: row.label,
                isActive: true,
                health: row.health,
                fiveHour: fiveHour(from: live),
                weekly: weekly(from: live),
                // Live limits that have not arrived yet read as stale, not as
                // unknown-but-fresh — same rule AccountSnapshot.withLiveActiveLimits
                // applies on the policy side.
                gaugesAreStale: gaugesAreStale,
                lastActiveAt: row.lastActiveAt,
                isStored: row.isStored,
                fiveHourResetsAt: fiveHourResetsAt(from: live),
                weeklyResetsAt: weeklyResetsAt(from: live),
                scopedModel: scoped?.utilization,
                scopedModelResetsAt: scoped?.resetsAt,
                scopedModelLabel: scopedModelLabel(from: live),
                // The live feed carries its own health state; a sleeping-poll stale
                // reason must not survive onto the active row.
                staleReason: gaugesAreStale ? liveStaleReason : nil,
                hasNoFiveHourLimit: live?.hasNoFiveHourLimit ?? false,
                plan: row.plan,
                fetchedAt: live?.fetchedAt
            )
        }
    }
}
