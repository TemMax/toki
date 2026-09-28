/// Unified error type for all TokiCore modules.
import Foundation

/// All errors that TokiCore modules can throw, grouped by domain.
public enum TokiError: Error, Sendable, Equatable {
    // MARK: Credential / Keychain errors

    /// No Claude Code credential found in the Keychain or any fallback source.
    case credentialsNotFound
    /// The credential exists, but Keychain access needs authorization or was denied.
    case keychainDenied
    /// The Keychain item exists but the keychain is locked (screen locked / non-GUI session).
    case keychainLocked

    // MARK: Authentication / session errors

    /// No usable credential is available (not logged in to Claude Code).
    case notLoggedIn
    /// The access token has expired and Claude Code is not running to rotate it.
    case tokenExpired

    // MARK: Network errors

    /// The Anthropic endpoint returned HTTP 429; caller should back off by at least `retryAfter` seconds.
    case rateLimited(retryAfter: TimeInterval)
    /// An unexpected HTTP status code was received.
    case httpError(Int)

    // MARK: Data errors

    /// JSON decoding failed; the associated value contains a diagnostic description.
    case decoding(String)

    // MARK: Pricing errors

    /// The requested model has no entry in the embedded pricing table.
    case pricingUnavailable(model: String)
}

// MARK: - LocalizedError

/// Human-readable descriptions. Without this, `error.localizedDescription` falls back to
/// the Foundation bridge's opaque "The operation couldn't be completed. (TokiCore.TokiError
/// error N.)" — where N is an internal case ordinal — so a decode failure surfaced in the UI
/// as the mystifying "…error 2." with the real diagnostic (the associated value) thrown away.
extension TokiError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .credentialsNotFound:
            return "No Claude credentials were found."
        case .keychainDenied:
            return "Keychain access was denied."
        case .keychainLocked:
            return "The Keychain is locked."
        case .notLoggedIn:
            return "Not logged in to Claude."
        case .tokenExpired:
            return "The Claude session token has expired."
        case let .rateLimited(retryAfter):
            return "Rate limited by Anthropic; retry after \(Int(retryAfter))s."
        case let .httpError(status):
            return "Unexpected HTTP status \(status) from Anthropic."
        case let .decoding(detail):
            return "Couldn't read the response: \(detail)"
        case let .pricingUnavailable(model):
            return "No pricing data for model \(model)."
        }
    }
}
