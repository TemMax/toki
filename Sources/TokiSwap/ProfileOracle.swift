/// Asks Anthropic who a token belongs to.
import Foundation
import TokiAccounts
import TokiLogging
import TokiModels

private let log = TokiLog.logger("swap")

public protocol ProfileLookup: Sendable {
    func owner(ofToken token: String) async throws -> AccountIdentity
}

/// `GET https://api.anthropic.com/api/oauth/profile` — the same OAuth surface the usage
/// endpoint lives on. Strictly advisory: every caller must treat a failure as "do not
/// overwrite" rather than retrying into a destructive default.
///
/// Never called while a Claude Code lock is held.
public struct ProfileOracle: ProfileLookup {
    private static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/profile")!

    private let session: URLSession
    private let userAgent: String

    public init(session: URLSession = .shared, userAgent: String = "claude-code/2.1.223") {
        self.session = session
        self.userAgent = userAgent
    }

    public func owner(ofToken token: String) async throws -> AccountIdentity {
        var request = URLRequest(url: Self.endpoint)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        log.info("asking the profile endpoint who a token belongs to")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            log.notice("the profile endpoint answered with no HTTP response")
            throw TokiError.httpError(-1)
        }
        switch http.statusCode {
        case 200: break
        case 401:
            log.notice("the profile endpoint rejected the token as expired")
            throw TokiError.tokenExpired
        case 429:
            log.notice("the profile endpoint is rate-limiting us")
            throw TokiError.rateLimited(retryAfter: 180)
        default:
            log.notice("the profile endpoint answered http=\(http.statusCode)")
            throw TokiError.httpError(http.statusCode)
        }

        guard
            // no-log: the value being decoded is the profile body, which carries the
            // account's e-mail and organisation; the refusal below is the diagnosis.
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let account = root["account"] as? [String: Any],
            let identity = AccountIdentity.parse(oauthAccount: Self.normalize(account, root: root))
        else {
            log.notice("the profile endpoint answered in a shape this build does not understand")
            throw TokiError.decoding("ProfileOracle: unexpected profile shape")
        }

        log.info("the profile endpoint named the token's owner \(account: identity.accountUuid)")
        return identity
    }

    /// The profile endpoint names its fields differently from `oauthAccount`; map them onto
    /// the shape `AccountIdentity.parse` expects.
    ///
    /// Key names come from a live query of the endpoint (2026-08-07): `account.uuid`,
    /// `account.email`, `account.full_name`, `account.display_name`, and a sibling
    /// `organization` object with `uuid`/`name`. The `email_address`/`emailAddress` spellings
    /// are accepted as well because Claude Code's own binary carries that spelling for a
    /// profile shape, and a rename here would silently blank the account label rather than
    /// fail loudly.
    static func normalize(_ account: [String: Any], root: [String: Any]) -> [String: Any] {
        var mapped: [String: Any] = [:]
        mapped["accountUuid"] = account["uuid"] ?? account["accountUuid"]
        mapped["emailAddress"] = account["email"] ?? account["email_address"] ?? account["emailAddress"]
        mapped["displayName"] = account["full_name"] ?? account["display_name"] ?? account["displayName"]
        if let organization = root["organization"] as? [String: Any] {
            mapped["organizationName"] = organization["name"]
            mapped["organizationUuid"] = organization["uuid"]
        }
        return mapped.compactMapValues { $0 }
    }
}
