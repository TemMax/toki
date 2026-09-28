/// Whether a stored account's usage gauge is worth polling on a refresh pass.
import Foundation

public enum GaugePollDecision: Equatable, Sendable {
    /// Poll the usage endpoint with this slot's stored access token.
    case poll
    /// Poll nothing. This slot's refresh-token lineage is dead, so its stored access
    /// token is both expired and unrenewable: the request is a guaranteed 401, and the
    /// forced refresh behind that 401 a guaranteed `invalid_grant`. Repeating the pair
    /// every three minutes buys no information the store does not already hold — it only
    /// spends requests against an endpoint that rate-limits, and re-derives a
    /// `needsReauth` that was recorded the first time. Only a new `/login` revives the
    /// account, and the card already says so.
    case skipNeedsReauth

    /// Health outranks expiry: a dead lineage cannot be rescued by a token that merely
    /// looks current, and a live lineage with a stale token is exactly what the poll's
    /// own 401-and-retry path is for.
    public static func decide(slot: AccountSlot) -> GaugePollDecision {
        slot.health == .needsReauth ? .skipNeedsReauth : .poll
    }
}
