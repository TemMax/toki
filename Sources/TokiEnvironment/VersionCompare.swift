/// Minimal semver-ish version comparison used only to decide whether a
/// catalog version is strictly newer than an installed version. Never
/// crashes on odd version strings — unparsable input is treated
/// conservatively (see `isNewer`).
import Foundation

enum VersionCompare {
    /// Returns true only when `latest` can be confidently determined to be
    /// newer than `installed`. Any ambiguity (nil, "unknown", non-numeric
    /// components) yields `false` rather than risk a false "update available".
    static func isNewer(latest: String?, than installed: String?) -> Bool {
        guard let latest, let installed,
              latest.lowercased() != "unknown", installed.lowercased() != "unknown",
              let latestComponents = numericComponents(latest),
              let installedComponents = numericComponents(installed) else {
            return false
        }
        let count = max(latestComponents.count, installedComponents.count)
        for index in 0..<count {
            let lhs = index < latestComponents.count ? latestComponents[index] : 0
            let rhs = index < installedComponents.count ? installedComponents[index] : 0
            if lhs != rhs { return lhs > rhs }
        }
        return false
    }

    /// Splits a version string on "." and parses each component as an
    /// integer, stopping at the first non-numeric segment (e.g. a
    /// pre-release suffix like "1.2.0-beta" yields [1, 2, 0]). Returns `nil`
    /// only when no leading numeric component exists at all.
    private static func numericComponents(_ version: String) -> [Int]? {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        var components: [Int] = []
        for part in parts {
            let digits = part.prefix { $0.isNumber }
            guard !digits.isEmpty, let value = Int(digits) else { break }
            components.append(value)
        }
        return components.isEmpty ? nil : components
    }
}
