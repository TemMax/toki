import Foundation

public enum ResetLinks {
    public static let codexUsage = URL(string: "https://chatgpt.com/codex/settings/usage")!

    /// Notification metadata is untrusted input too. Only open the fixed Usage page or
    /// original announcement posts; never a redirect, local file or arbitrary feed URL.
    public static func allowed(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil, url.query == nil, url.fragment == nil else { return false }
        if url == codexUsage { return true }
        guard ["x.com", "twitter.com"].contains(url.host ?? "") else { return false }
        let parts = url.path.split(separator: "/")
        guard parts.count == 3, parts[1] == "status", !parts[2].isEmpty,
              parts[2].utf8.allSatisfy({ (48...57).contains($0) }) else { return false }
        return parts[0].utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 95 }
    }
}
