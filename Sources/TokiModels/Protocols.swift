/// Service protocols that each TokiCore module implements.
import Foundation

/// Reads the current OAuth credential from the Keychain or a fallback source.
public protocol CredentialProviding: Sendable {
    /// Returns the freshest available credential, reading the Keychain if needed.
    /// Throws `TokiError.credentialsNotFound` when no credential exists, or
    /// `TokiError.keychainDenied` / `.keychainLocked` on access failures.
    func currentCredential() async throws -> OAuthCredential

    /// Resolves a credential, optionally permitting user-visible interaction.
    /// Background callers must use the default (`false`): they may never cause the macOS
    /// Keychain dialog to appear out of nowhere.
    func currentCredential(userInitiated: Bool) async throws -> OAuthCredential

    /// Bypasses credential memoization independently of permission to show authentication UI.
    func currentCredential(userInitiated: Bool, forceRefresh: Bool) async throws -> OAuthCredential

    /// Re-checks that a resolved credential still belongs to the expected account before
    /// publishing a network response. Unscoped providers may use the default no-op.
    func validateCredential(_ credential: OAuthCredential) async throws

    /// Reports that `credential` was rejected by the server (HTTP 401) so the provider
    /// stops handing it back. Implementations must be source-aware: a rejected
    /// environment token says nothing about a cached Keychain token.
    func markCredentialRejected(_ credential: OAuthCredential) async

    /// Drops any in-memory credential cache so the next `currentCredential()` call
    /// re-reads from the authoritative source (Keychain / file).
    /// Conformers that hold no cache may rely on the default no-op implementation.
    func invalidateCache() async
}

public extension CredentialProviding {
    /// Default no-op: conformers without an in-memory cache need not override this.
    func invalidateCache() async {}

    /// Default: providers with no interactive path ignore the distinction.
    func currentCredential(userInitiated: Bool) async throws -> OAuthCredential {
        try await currentCredential()
    }

    func currentCredential(userInitiated: Bool, forceRefresh: Bool) async throws -> OAuthCredential {
        if forceRefresh { await invalidateCache() }
        return try await currentCredential(userInitiated: userInitiated)
    }

    func validateCredential(_ credential: OAuthCredential) async throws {}

    /// Default no-op: providers that hold no cached credential have nothing to mark.
    func markCredentialRejected(_ credential: OAuthCredential) async {}
}

/// Adds a non-interactive credential-access probe on top of `CredentialProviding`,
/// used to drive onboarding UI without ever triggering the Keychain dialog.
public protocol CredentialOnboarding: CredentialProviding {
    /// Determines credential-access state WITHOUT presenting the macOS Keychain dialog.
    func accessState() async -> CredentialAccessState
}

/// Fetches the live rate-limit snapshot from the Anthropic usage endpoint.
public protocol LimitsProviding: Sendable {
    /// Returns the current usage limits, performing a network request if necessary.
    /// Throws `TokiError.notLoggedIn` when no usable credential is available, or
    /// `TokiError.httpError` / `.rateLimited` on network failures.
    func fetchLimits() async throws -> UsageLimits
}

/// Looks up per-model pricing and computes cost breakdowns.
public protocol PricingProviding: Sendable {
    /// Returns the pricing entry for `model` (using longest-prefix matching) that was
    /// effective on `date`, or nil when the model is unrecognised on that date.
    func pricing(for model: String, on date: Date) -> ModelPricing?

    /// `model`'s pricing over all time, as a lock-free value — for pricing many records in
    /// one pass (see `PriceSchedule`). Must agree with `pricing(for:on:)` on every date.
    /// `nil` when the provider cannot state it; callers then price record by record.
    func schedule(for model: String) -> PriceSchedule?
}

public extension PricingProviding {
    /// Returns the pricing entry for `model` using longest-prefix matching, as of now,
    /// or nil when the model is unrecognised.
    func pricing(for model: String) -> ModelPricing? {
        pricing(for: model, on: Date())
    }

    /// Computes an itemised cost breakdown for `usage` priced at `model` rates effective
    /// on `date`. Returns nil (not $0) when `model` is unrecognised on that date, so
    /// callers can surface a "pricing unavailable" notice rather than silently showing
    /// a zero cost.
    func cost(for usage: TokenUsage, model: String, on date: Date) -> CostBreakdown? {
        pricing(for: model, on: date)?.cost(for: usage)
    }

    /// Default: no schedule, so bulk pricing falls back to one `pricing(for:on:)` per record.
    func schedule(for model: String) -> PriceSchedule? { nil }

    /// Computes an itemised cost breakdown for `usage` priced at `model` rates, as of now.
    /// Returns nil (not $0) when `model` is unrecognised, so callers can surface
    /// a "pricing unavailable" notice rather than silently showing a zero cost.
    func cost(for usage: TokenUsage, model: String) -> CostBreakdown? {
        cost(for: usage, model: model, on: Date())
    }
}

/// Supplies deduplicated transcript records for a date range. Implemented by the
/// transcript index (`TokiTranscripts`) and consumed by analytics (`TokiAnalytics`);
/// abstracted so analytics is unit-testable with a fake record source (no live index).
public protocol RecordProviding: Sendable {
    /// Returns deduplicated transcript records whose `timestamp` falls in [start, end]
    /// (inclusive). Implementations dedup by `requestId` (last-wins per D2).
    func records(start: Date, end: Date) async throws -> [TranscriptRecord]
}

/// Aggregates transcript records into a usage summary for a date range.
public protocol AnalyticsProviding: Sendable {
    /// Returns a usage summary covering all records whose timestamp falls in
    /// [start, end] (inclusive). Throws `TokiError.decoding` on index corruption.
    func summary(start: Date, end: Date) async throws -> UsageSummary
}
