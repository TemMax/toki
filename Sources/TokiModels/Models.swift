/// Core value types shared across all TokiCore modules.
import Foundation

// MARK: - Limits

/// A single rate-limit window with utilization and reset time.
public struct RateWindow: Sendable, Codable {
    /// Utilization fraction in [0, 1] (0 = unused, 1 = fully consumed).
    public let utilization: Double
    /// When this window resets and utilization drops back to 0. `nil` when the
    /// window is inactive and the API reports no reset time (`resets_at: null`).
    public let resetsAt: Date?

    public init(utilization: Double, resetsAt: Date?) {
        self.utilization = utilization
        self.resetsAt = resetsAt
    }

    private enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt
    }
}

/// Extra-usage (pay-as-you-go) credit information.
public struct ExtraUsage: Sendable, Codable {
    /// Whether extra usage is enabled on the account.
    public let isEnabled: Bool
    /// Monthly spend cap in major currency units, if set.
    public let monthlyLimit: Double?
    /// Credits consumed so far this month, in major currency units.
    public let usedCredits: Double?
    /// Utilization fraction in [0, 1], if available.
    public let utilization: Double?
    /// ISO currency code of the amounts (e.g. "USD"); nil on older API responses.
    public let currency: String?
    /// How many decimal places the currency's minor unit has (2 for USD cents, 0 for JPY).
    public let decimalPlaces: Int?
    /// True once the monthly spend cap has been hit — further usage is blocked, not billed.
    public let spendLimitReached: Bool
    /// API's machine-readable reason when extra usage is off (e.g. "spend_limit_reached").
    public let disabledReason: String?

    public init(
        isEnabled: Bool,
        monthlyLimit: Double?,
        usedCredits: Double?,
        utilization: Double?,
        currency: String? = nil,
        decimalPlaces: Int? = nil,
        spendLimitReached: Bool = false,
        disabledReason: String? = nil
    ) {
        self.isEnabled = isEnabled
        self.monthlyLimit = monthlyLimit
        self.usedCredits = usedCredits
        self.utilization = utilization
        self.currency = currency
        self.decimalPlaces = decimalPlaces
        self.spendLimitReached = spendLimitReached
        self.disabledReason = disabledReason
    }

    /// How much room extra usage has earned on a surface: a full gauge card, one quiet line,
    /// or nothing.
    ///
    /// This lives here, not in the view that draws it, because it is a rule with a right
    /// answer and `App/Sources` is not part of `Package.swift` — nothing there can be reached
    /// by `swift test`. The rule has already been wrong once: keyed on `usedCredits` alone, a
    /// response carrying a `utilization` but no credit amount collapsed to the quiet line,
    /// where there are no amounts to print and the row falls back to saying merely "on" —
    /// silently dropping a percentage the API did send. The two fields are INDEPENDENT
    /// optionals, so one cannot stand in for the other. Tests pin that.
    public enum Prominence: Equatable, Sendable {
        /// Credits are in play: show the gauge, its amounts and its section header.
        case card
        /// Switched on, nothing spent against it yet — the standing state for anyone who
        /// enabled pay-as-you-go and never exceeded the included limits. One row.
        case line
        /// Off and unused: say nothing.
        case hidden
    }

    /// `.card` whenever there is a number worth a gauge — the cap was reached, money was
    /// spent, or the API reported a non-zero utilization.
    ///
    /// Two deliberate asymmetries:
    ///  - The cap-reached case shows the card even though the API may flip `isEnabled` off at
    ///    that exact moment. Dropping it there would hide *why* usage stopped.
    ///  - Spend recorded while `isEnabled` is false still shows the card. Money spent this
    ///    month is worth reporting regardless of the switch's current position; the older
    ///    behaviour keyed the whole section on `isEnabled` and hid it.
    ///
    /// A utilization of exactly 0 stays on the quiet line on purpose: a gauge pinned at 0%
    /// is not information, and the line still reports that extra usage is on.
    public var prominence: Prominence {
        if spendLimitReached || (usedCredits ?? 0) > 0 || (utilization ?? 0) > 0 { return .card }
        return isEnabled ? .line : .hidden
    }

    /// Formats an amount in this account's currency and precision. Defaults to USD with
    /// 2 fraction digits, matching what the API sent before it reported currency at all.
    ///
    /// The currency CODE comes from the API; the formatting conventions come from
    /// `DisplayFormat.locale`, not the machine. Following the machine here is what rendered
    /// `100 000,00 US$` inside an English interface.
    public func amountString(_ amount: Double, locale: Locale = DisplayFormat.locale) -> String {
        amount.formatted(
            .currency(code: currency ?? "USD")
            .precision(.fractionLength(decimalPlaces ?? 2))
            .locale(locale)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled
        case monthlyLimit
        case usedCredits
        case utilization
        case currency
        case decimalPlaces
        case spendLimitReached
        case disabledReason
    }

    public init(from decoder: Decoder) throws {
        // Tolerant of pre-0.7.0 cached payloads that lack the new keys: a missing
        // `spendLimitReached` must default to false, not fail the whole cache load.
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try c.decode(Bool.self, forKey: .isEnabled)
        monthlyLimit = try c.decodeIfPresent(Double.self, forKey: .monthlyLimit)
        usedCredits = try c.decodeIfPresent(Double.self, forKey: .usedCredits)
        utilization = try c.decodeIfPresent(Double.self, forKey: .utilization)
        currency = try c.decodeIfPresent(String.self, forKey: .currency)
        decimalPlaces = try c.decodeIfPresent(Int.self, forKey: .decimalPlaces)
        spendLimitReached = try c.decodeIfPresent(Bool.self, forKey: .spendLimitReached) ?? false
        disabledReason = try c.decodeIfPresent(String.self, forKey: .disabledReason)
    }
}

/// A single rate-limit window as delivered by the usage API's generic `limits[]`
/// array. Unlike `RateWindow` (a bare utilization + reset pair), this carries the
/// display identity of the window so the UI can render an arbitrary, data-driven
/// list of gauges rather than four hardcoded ones.
public struct RateLimitWindow: Sendable, Codable, Identifiable {
    /// Stable identity used to find canonical windows and as a SwiftUI list id.
    /// One of `"session"`, `"weekly_all"`, or `"weekly_scoped:<Model>"`.
    public let id: String
    /// Human-facing title, e.g. `"5-hour"`, `"7-day"`, or `"7-day Fable"`.
    public let title: String
    /// Utilization fraction in [0, 1] (0 = unused, 1 = fully consumed).
    public let utilization: Double
    /// When this window resets and utilization drops back to 0. `nil` when the
    /// window is inactive and the API reports no reset time.
    public let resetsAt: Date?
    /// Whether this window is currently in effect. When `false` the UI renders it
    /// disabled with an "unavailable" tag rather than a live gauge.
    public let isAvailable: Bool

    public init(id: String, title: String, utilization: Double, resetsAt: Date?, isAvailable: Bool) {
        self.id = id
        self.title = title
        self.utilization = utilization
        self.resetsAt = resetsAt
        self.isAvailable = isAvailable
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case utilization
        case resetsAt
        case isAvailable
    }
}

/// The account and organization proven to own a credential or usage response.
public struct UsageAccount: Sendable, Codable, Equatable {
    public let accountUuid: String
    public let organizationUuid: String?

    public init(accountUuid: String, organizationUuid: String?) {
        self.accountUuid = accountUuid
        self.organizationUuid = organizationUuid
    }
}

/// A successful primary usage response whose supplemental request was rate limited.
public struct SupplementalRateLimit: Sendable, Codable, Equatable {
    public let retryAfter: TimeInterval

    public init(retryAfter: TimeInterval) {
        self.retryAfter = retryAfter
    }
}

/// The full usage-limits snapshot from `/api/oauth/usage`.
public struct UsageLimits: Sendable, Codable {
    /// Rate-limit windows in the order received from the API.
    public let windows: [RateLimitWindow]
    /// Extra-usage credit state.
    public let extra: ExtraUsage?
    /// Wall-clock time when this snapshot was fetched.
    public let fetchedAt: Date
    public let account: UsageAccount?
    /// Codex banked reset availability from this same account-bound response.
    public let bankedResets: BankedResets?
    /// Claude saved reset availability from this same account-bound response.
    public let claudeResets: ClaudeResetStatus?
    /// Present only when ordinary usage succeeded but the reset-only request returned 429.
    public let supplementalRateLimit: SupplementalRateLimit?

    public init(
        windows: [RateLimitWindow],
        extra: ExtraUsage?,
        fetchedAt: Date,
        account: UsageAccount? = nil
    ) {
        self.init(
            windows: windows,
            extra: extra,
            fetchedAt: fetchedAt,
            account: account,
            bankedResets: nil,
            claudeResets: nil,
            supplementalRateLimit: nil
        )
    }

    public init(
        windows: [RateLimitWindow],
        extra: ExtraUsage?,
        fetchedAt: Date,
        account: UsageAccount? = nil,
        bankedResets: BankedResets?
    ) {
        self.init(
            windows: windows,
            extra: extra,
            fetchedAt: fetchedAt,
            account: account,
            bankedResets: bankedResets,
            claudeResets: nil,
            supplementalRateLimit: nil
        )
    }

    public init(
        windows: [RateLimitWindow],
        extra: ExtraUsage?,
        fetchedAt: Date,
        account: UsageAccount? = nil,
        bankedResets: BankedResets?,
        claudeResets: ClaudeResetStatus? = nil,
        supplementalRateLimit: SupplementalRateLimit? = nil
    ) {
        self.windows = windows
        self.extra = extra
        self.fetchedAt = fetchedAt
        self.account = account
        self.bankedResets = bankedResets
        self.claudeResets = claudeResets
        self.supplementalRateLimit = supplementalRateLimit
    }

    // Convenience accessors used by the menu-bar label (find canonical windows by id).
    /// The canonical 5-hour session window, if present.
    public var fiveHour: RateLimitWindow? {
        windows.first { $0.id == "session" }
            ?? windows
                .filter { $0.id.hasPrefix("session_scoped:") }
                .max(by: { $0.utilization < $1.utilization })
    }
    /// The canonical 7-day all-models window, if present.
    public var sevenDay: RateLimitWindow? {
        windows.first { $0.id == "weekly_all" }
            ?? windows
                .filter { $0.id.hasPrefix("weekly_scoped:") }
                .max(by: { $0.utilization < $1.utilization })
    }

    private enum CodingKeys: String, CodingKey {
        case windows
        case extra
        case fetchedAt
        case account
        case bankedResets
        case claudeResets
        case supplementalRateLimit
    }
}

// MARK: - Credentials

/// An OAuth bearer credential read from the Keychain or a fallback source.
public struct OAuthCredential: Sendable {
    /// Raw bearer token sent in `Authorization: Bearer` headers.
    public let accessToken: String
    /// Refresh token (present for CC-issued credentials; may be absent for env-var override).
    /// Toki NEVER uses this to refresh: Anthropic's refresh tokens are single-use, so
    /// rotating one would desync the Claude Code CLI and force the user to log in again.
    public let refreshToken: String?
    /// Absolute expiry time, or nil if the token has no known expiry.
    public let expiresAt: Date?
    /// Which source produced this credential; drives source-aware error handling.
    public let source: CredentialSource
    public let account: UsageAccount?

    /// True when `expiresAt` is known and the token will expire within 60 seconds.
    public var isExpired: Bool {
        guard let expiresAt else { return false }
        return expiresAt < Date().addingTimeInterval(60)
    }

    public init(
        accessToken: String,
        refreshToken: String?,
        expiresAt: Date?,
        source: CredentialSource = .claudeKeychain,
        account: UsageAccount? = nil
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.source = source
        self.account = account
    }
}
