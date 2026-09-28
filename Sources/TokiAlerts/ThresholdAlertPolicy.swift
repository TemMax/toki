import Foundation
import TokiModels

/// One notification's worth of tripped rules.
public struct ThresholdAlert: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public let title: String
        public let utilization: Double
        public let threshold: Double

        public init(title: String, utilization: Double, threshold: Double) {
            self.title = title
            self.utilization = utilization
            self.threshold = threshold
        }
    }

    public let entries: [Entry]

    public init(entries: [Entry]) {
        self.entries = entries
    }
}

/// Decides which rules warrant a notification, and remembers what it already said.
///
/// The rule is "at or above the threshold and not yet reported for this window instance",
/// NOT "crossed the threshold". A Mac asleep through the crossing wakes up already past it,
/// and a crossing detector would then stay silent forever — the one case the feature exists
/// for. At-or-above plus a latch fires once, late.
///
/// The latch key is (rule id, account uuid, that window's reset time to the MINUTE), which
/// re-arms itself: the window resets and that minute moves, or the user switches accounts and
/// the uuid moves. See `Fired.instanceMinute` for why it is minutes and not a `Date`.
/// Utilization only rises inside a window, so no "fell back below" re-arm is needed.
///
/// The latch is `Codable` because it has to outlive the process. A policy that starts empty on
/// every launch re-notifies for every rule that is already over its threshold — a 7-day window
/// sitting at 100% for days then greets the user on every single launch. "Once per window" is
/// only true if the set is persisted; see `ThresholdAlertLatchStore`.
public struct ThresholdAlertPolicy: Equatable, Sendable, Codable {
    private struct Fired: Hashable, Codable {
        let rule: UUID
        let account: String?
        /// The window instance, as WHOLE MINUTES — never a `Date`.
        ///
        /// This is the whole bug the latch shipped with. The API's `resets_at` carries
        /// fractional seconds that move between responses for the same window: measured on
        /// live data, one 5-hour window reported `…400.511091` and then `…400.775991`
        /// 32 seconds later. Same instant to any human, a different `Date` to `==` — so every
        /// poll minted a fresh key, the rule re-armed, and the user got a notification on
        /// every percentage change instead of one per window.
        ///
        /// Minutes, not seconds, because reset boundaries are minute-aligned and this then
        /// also absorbs a server shifting the instant by a second or two. A genuine reset
        /// moves it by hours, which no rounding can hide.
        let instanceMinute: Int?
    }

    /// Whole minutes since the reference date — the unit a window instance is keyed in, and the
    /// unit `forget(before:)` takes. Public so a caller pruning against "now" reads the clock in
    /// the same unit the latch stores rather than re-deriving the conversion.
    public static func minute(_ date: Date) -> Int {
        Int((date.timeIntervalSinceReferenceDate / 60).rounded(.down))
    }

    /// Whole minutes since the reference date, or nil for a window with no reset time.
    private static func instanceMinute(_ date: Date?) -> Int? {
        date.map(minute)
    }

    private var fired: Set<Fired> = []

    public init() {}

    public mutating func alerts(
        for limits: UsageLimits?,
        accountUuid: String?,
        settings: NotificationSettings,
        provider: UsageProvider = .claudeCode
    ) -> ThresholdAlert? {
        guard let limits else { return nil }

        var entries: [ThresholdAlert.Entry] = []
        for rule in settings.rules where rule.isEnabled && rule.provider == provider {
            guard let selected = rule.window.resolve(against: limits), selected.isAvailable else { continue }
            guard selected.utilization >= rule.threshold else { continue }

            let key = Fired(
                rule: rule.id,
                account: accountUuid,
                instanceMinute: Self.instanceMinute(selected.resetsAt)
            )
            guard !fired.contains(key) else { continue }
            fired.insert(key)

            entries.append(ThresholdAlert.Entry(
                title: selected.title,
                utilization: selected.utilization,
                threshold: rule.threshold
            ))
        }

        return entries.isEmpty ? nil : ThresholdAlert(entries: entries)
    }

    /// Drops entries whose window has already reset, so the latch cannot grow without bound.
    ///
    /// `minute` is whole minutes since the reference date, the same unit the key stores the
    /// window instance in. An entry is only dropped once its instance is strictly in the past:
    /// at the boundary minute itself the window may not have turned over yet, and dropping it
    /// early would notify twice.
    ///
    /// An entry with a nil instance — a window that reports no reset time — is KEPT. There is
    /// no moment to compare it against, and forgetting it would re-notify.
    public mutating func forget(before minute: Int) {
        fired = fired.filter { entry in
            guard let instance = entry.instanceMinute else { return true }
            return instance >= minute
        }
    }
}
