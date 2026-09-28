/// OAuthUsageClient — fetches live rate-limit data from GET /api/oauth/usage.
import Foundation
import TokiLogging
import TokiModels

// MARK: - Wire DTOs

private struct WireRateWindow: Decodable {
    let utilization: Double
    // Optional: the API sends `resets_at: null` for an inactive window (e.g. the
    // 5-hour window at 0% utilization). A non-optional field here would make the
    // whole-response decode throw on that null, silently dropping every gauge.
    let resetsAt: String?

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }
}

private struct WireExtraUsage: Decodable {
    let isEnabled: Bool
    let monthlyLimit: Double?
    let usedCredits: Double?
    let utilization: Double?
    let currency: String?
    let decimalPlaces: Int?
    let spendLimitReached: Bool?
    let disabledReason: String?

    enum CodingKeys: String, CodingKey {
        case isEnabled   = "is_enabled"
        case monthlyLimit = "monthly_limit"
        case usedCredits  = "used_credits"
        case utilization
        case currency
        case decimalPlaces = "decimal_places"
        case spendLimitReached = "spend_limit_reached"
        case disabledReason = "disabled_reason"
    }
}

// A single entry in the generic `limits[]` array (the new data-driven shape).
private struct WireLimit: Decodable {
    let kind: String
    let percent: Double?
    let resetsAt: String?
    let scope: WireScope?
    let isActive: Bool?

    enum CodingKeys: String, CodingKey {
        case kind
        case percent
        case resetsAt = "resets_at"
        case scope
        case isActive = "is_active"
    }
}

private struct WireScope: Decodable {
    let model: WireScopeModel?
}

private struct WireScopeModel: Decodable {
    let id: String?
    let displayName: String?

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
    }
}

private struct WireUsageResponse: Decodable {
    let fiveHour:      WireRateWindow?
    let sevenDay:      WireRateWindow?
    let sevenDayOpus:  WireRateWindow?
    let sevenDaySonnet: WireRateWindow?
    let extraUsage:    WireExtraUsage?
    // New data-driven windows array; nil when the API predates the `limits[]` shape.
    let limits:        [WireLimit]?

    enum CodingKeys: String, CodingKey {
        case fiveHour      = "five_hour"
        case sevenDay      = "seven_day"
        case sevenDayOpus  = "seven_day_opus"
        case sevenDaySonnet = "seven_day_sonnet"
        case extraUsage    = "extra_usage"
        case limits
    }
}

// MARK: - Date parsing helpers

// Use value-type Date.ISO8601FormatStyle (Sendable, no shared mutable state)
// so the Swift 6 strict-concurrency checker does not flag global state.
private func parseISO8601(_ string: String) -> Date? {
    // Try with fractional seconds first (e.g. "2026-06-24T16:50:00.421248+00:00").
    // no-log: first of two format attempts; trying the fractional-seconds variant before
    // falling back to whole seconds is normal control flow, not a fault — only a failure of
    // BOTH attempts (below) is potentially interesting, and callers already decide what that
    // means (WireRateWindow.toDomain() throws and is logged where fetchUsage surfaces the
    // decoding error; WireLimit.toRateLimitWindow() degrades to nil by design, documented above
    // it).
    if let date = try? Date(string, strategy: .iso8601.year().month().day()
        .time(includingFractionalSeconds: true).timeZone(separator: .colon)) {
        return date
    }
    // no-log: final attempt — this function does not know which caller invoked it (one
    // throws on nil and is logged there, the other treats nil as an expected, lenient
    // degrade), so logging here would either duplicate that log line or misreport a
    // by-design no-op as an error.
    return try? Date(string, strategy: .iso8601.year().month().day()
        .time(includingFractionalSeconds: false).timeZone(separator: .colon))
}

// MARK: - Domain mapping helpers

private extension WireRateWindow {
    /// Maps this wire DTO to a domain `RateWindow`.
    /// - Throws: `TokiError.decoding` when `resets_at` is present but cannot be parsed
    ///   as ISO8601, so callers surface a decoding error rather than silently dropping the
    ///   window. A `null` `resets_at` (inactive window) maps to `resetsAt: nil` — not an error.
    func toDomain() throws -> RateWindow {
        var parsedResetsAt: Date? = nil
        if let resetsAtString = self.resetsAt {
            guard let parsed = parseISO8601(resetsAtString) else {
                throw TokiError.decoding("WireRateWindow: unparseable resets_at: \(resetsAtString)")
            }
            parsedResetsAt = parsed
        }
        return RateWindow(
            utilization: utilization / 100.0,
            resetsAt: parsedResetsAt
        )
    }
}

private extension WireLimit {
    /// Maps this generic `limits[]` entry to a domain `RateLimitWindow`, or `nil`
    /// to SKIP the entry (unknown `kind`, or a `weekly_scoped` entry with no model
    /// name). Unlike `WireRateWindow.toDomain()`, this never throws: a malformed
    /// `resets_at` degrades to `nil` so one bad reset time can't drop the whole
    /// response — the array path favours resilience.
    func toRateLimitWindow() -> RateLimitWindow? {
        // Clamp percent (0–100) into a [0, 1] utilization fraction.
        let utilization = min(max((percent ?? 0) / 100.0, 0), 1)

        // Parse resets_at leniently: null → nil, unparseable → nil (no throw).
        let parsedResetsAt: Date? = resetsAt.flatMap { parseISO8601($0) }

        switch kind {
        case "session":
            return RateLimitWindow(
                id: "session",
                title: "5-hour",
                utilization: utilization,
                resetsAt: parsedResetsAt,
                isAvailable: true
            )
        case "weekly_all":
            return RateLimitWindow(
                id: "weekly_all",
                title: "7-day",
                utilization: utilization,
                resetsAt: parsedResetsAt,
                isAvailable: true
            )
        case "weekly_scoped":
            let model = (scope?.model?.displayName ?? "").trimmingCharacters(in: .whitespaces)
            guard !model.isEmpty else { return nil }
            let available = (isActive == true) || ((percent ?? 0) > 0) || (parsedResetsAt != nil)
            return RateLimitWindow(
                id: "weekly_scoped:\(model)",
                title: "7-day \(model)",
                utilization: utilization,
                resetsAt: parsedResetsAt,
                isAvailable: available
            )
        default:
            return nil
        }
    }
}

private extension RateWindow {
    /// Adapts a legacy flat `RateWindow` into a data-driven `RateLimitWindow`.
    func toRateLimitWindow(id: String, title: String) -> RateLimitWindow {
        RateLimitWindow(
            id: id,
            title: title,
            utilization: utilization,
            resetsAt: resetsAt,
            isAvailable: true
        )
    }
}

private extension WireExtraUsage {
    func toDomain() -> ExtraUsage {
        // `monthly_limit` and `used_credits` arrive in the currency's MINOR units
        // (e.g. 160000 US cents = $1,600); `decimal_places` says how many digits the
        // minor unit has (absent on older responses — the historical cents assumption).
        // `utilization` arrives as a 0–100 percent.
        let minorUnitScale = pow(10.0, Double(decimalPlaces ?? 2))
        return ExtraUsage(
            isEnabled: isEnabled,
            monthlyLimit: monthlyLimit.map { $0 / minorUnitScale },
            usedCredits: usedCredits.map { $0 / minorUnitScale },
            utilization: utilization.map { $0 / 100.0 },
            currency: currency,
            decimalPlaces: decimalPlaces,
            spendLimitReached: spendLimitReached ?? false,
            disabledReason: disabledReason
        )
    }
}

// MARK: - Client

/// Performs a single GET /api/oauth/usage request and decodes the response.
public struct OAuthUsageClient: Sendable {
    public static let defaultUserAgent = "claude-cli/2.1.280 (external, cli)"

    private let session: URLSession
    private let userAgent: String
    private let log = TokiLog.logger("limits")

    private static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let resetEndpoint = URL(
        string: "https://api.anthropic.com/api/oauth/usage?cedar_ember=1&skip_spend=1"
    )!

    public init(
        userAgent: String = OAuthUsageClient.defaultUserAgent,
        session: URLSession = .shared
    ) {
        self.userAgent = userAgent
        self.session = session
    }

    /// Fetches live usage limits using the supplied bearer token.
    /// - Parameter includeSupplemental: whether to spend a second request on saved-reset
    ///   metadata when the usage response does not carry it. `LimitsService` asks for it on
    ///   its own slower cadence; both requests draw on the same rate limit.
    /// - Throws: `TokiError.tokenExpired` on 401, `TokiError.rateLimited` on 429,
    ///   `TokiError.httpError` on other non-200 status codes, `TokiError.decoding`
    ///   if the response body cannot be decoded.
    public func fetchUsage(token: String, includeSupplemental: Bool = true) async throws -> UsageLimits {
        let request = makeRequest(url: Self.endpoint, token: token)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            // `\(error: error)` already renders the bridged NSError's domain/code, which for
            // a URLError is NSURLErrorDomain plus the numeric URLError code — exactly what is
            // wanted here, and never the request itself.
            log.error("usage request transport failure \(error: error)")
            throw error
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TokiError.httpError(0)
        }

        log.debug("usage request completed with status \(httpResponse.statusCode)")

        switch httpResponse.statusCode {
        case 200:
            break
        case 401:
            // Expected, not a fault: Claude Code rotates the token and Toki just has to wait.
            log.notice("usage request returned 401 (token expired)")
            throw TokiError.tokenExpired
        case 429:
            log.notice("usage request returned 429 (rate limited) retryAfter=\(180)")
            throw TokiError.rateLimited(retryAfter: 180)
        default:
            throw TokiError.httpError(httpResponse.statusCode)
        }

        let wire: WireUsageResponse
        do {
            wire = try JSONDecoder().decode(WireUsageResponse.self, from: data)
        } catch {
            log.error("usage response decode failed \(decodingDiagnostic(error), privacy: .public)")
            throw TokiError.decoding(error.localizedDescription)
        }

        // Prefer the generic `limits[]` array when present and it yields at least
        // one usable window; otherwise fall back to the legacy flat fields.
        let windows: [RateLimitWindow]
        if let wireLimits = wire.limits {
            let mapped = wireLimits.compactMap { $0.toRateLimitWindow() }
            if !mapped.isEmpty {
                windows = mapped
            } else {
                // Present but empty after mapping → fall back to the flat fields.
                windows = try Self.legacyWindows(from: wire)
            }
        } else {
            windows = try Self.legacyWindows(from: wire)
        }

        let claudeResets: ClaudeResetStatus?
        let supplementalRateLimit: SupplementalRateLimit?
        if let primaryResets = ClaudeResetWire.decode(from: data) {
            claudeResets = primaryResets
            supplementalRateLimit = nil
        } else if !includeSupplemental {
            claudeResets = nil
            supplementalRateLimit = nil
        } else {
            let supplemental = try await fetchSupplementalResets(token: token)
            claudeResets = supplemental.resets
            supplementalRateLimit = supplemental.rateLimit
        }

        return UsageLimits(
            windows:   windows,
            extra:     wire.extraUsage?.toDomain(),
            fetchedAt: Date(),
            bankedResets: nil,
            claudeResets: claudeResets,
            supplementalRateLimit: supplementalRateLimit
        )
    }

    private func makeRequest(url: URL, token: String) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        // No Content-Type header — these are bodyless GETs.
        return request
    }

    /// Reads only `cedar_ember`; a supplemental failure must never erase already-decoded
    /// windows or extra spend. Cancellation remains observable to the caller.
    private func fetchSupplementalResets(token: String) async throws -> (
        resets: ClaudeResetStatus?,
        rateLimit: SupplementalRateLimit?
    ) {
        let request = makeRequest(url: Self.resetEndpoint, token: token)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            log.debug("saved reset supplemental request unavailable")
            return (nil, nil)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            return (nil, nil)
        }
        log.debug("saved reset supplemental request completed with status \(httpResponse.statusCode)")
        switch httpResponse.statusCode {
        case 200:
            return (ClaudeResetWire.decode(from: data), nil)
        case 429:
            return (nil, SupplementalRateLimit(retryAfter: 180))
        default:
            return (nil, nil)
        }
    }

    /// Builds the window list from the legacy flat fields (`five_hour`, `seven_day`,
    /// `seven_day_opus`, `seven_day_sonnet`), each included only when non-nil, all
    /// `isAvailable: true`, in canonical order. Reuses `WireRateWindow.toDomain()`,
    /// which THROWS `TokiError.decoding` on an unparseable non-null `resets_at`.
    private static func legacyWindows(from wire: WireUsageResponse) throws -> [RateLimitWindow] {
        var result: [RateLimitWindow] = []
        if let w = wire.fiveHour {
            result.append(try w.toDomain().toRateLimitWindow(id: "session", title: "5-hour"))
        }
        if let w = wire.sevenDay {
            result.append(try w.toDomain().toRateLimitWindow(id: "weekly_all", title: "7-day"))
        }
        if let w = wire.sevenDayOpus {
            result.append(try w.toDomain().toRateLimitWindow(id: "weekly_scoped:Opus", title: "7-day Opus"))
        }
        if let w = wire.sevenDaySonnet {
            result.append(try w.toDomain().toRateLimitWindow(id: "weekly_scoped:Sonnet", title: "7-day Sonnet"))
        }
        return result
    }
}
