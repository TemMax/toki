/// Minimal internal semver utilities used by the Claude-instance scanner.
///
/// This is deliberately tiny and conservative: it exists only to compare CLI
/// version strings parsed out of executable paths (e.g. "2.1.197") and to pull
/// a version-looking component out of a path. It is NOT a general semver
/// implementation — pre-release / build metadata are ignored for ordering.
import Foundation

enum Semver {
    /// Parse a leading `^v?\d+(\.\d+)*` into its numeric components.
    ///
    /// Parsing stops at the first non-numeric, non-dot character, so a
    /// pre-release suffix like "2.1.0-beta.3" parses to `[2, 1, 0]`. Returns an
    /// empty array when the string doesn't start with a version.
    static func components(_ raw: String) -> [Int] {
        var s = Substring(raw)
        if s.first == "v" || s.first == "V" { s = s.dropFirst() }

        var result: [Int] = []
        var current = ""

        func flush() -> Bool {
            // Called at a dot or end. A component must be a non-empty run of
            // digits; anything else terminates parsing.
            guard !current.isEmpty, let value = Int(current) else { return false }
            result.append(value)
            current = ""
            return true
        }

        for ch in s {
            if ch.isNumber {
                current.append(ch)
            } else if ch == "." {
                if !flush() { return result }
            } else {
                // First non-numeric, non-dot char (e.g. "-beta"): stop, keeping
                // whatever numeric run we've accumulated so far.
                _ = flush()
                return result
            }
        }
        _ = flush()
        return result
    }

    /// True when `a` is confidently an older version than `b`.
    ///
    /// Conservative: returns `false` when either side is unparseable, when they
    /// compare equal, or when `a >= b`. Shorter version numbers are treated as
    /// zero-padded ("2.1" == "2.1.0").
    static func less(_ a: String, _ b: String) -> Bool {
        let lhs = components(a)
        let rhs = components(b)
        guard !lhs.isEmpty, !rhs.isEmpty else { return false }

        let count = max(lhs.count, rhs.count)
        for i in 0..<count {
            let l = i < lhs.count ? lhs[i] : 0
            let r = i < rhs.count ? rhs[i] : 0
            if l != r { return l < r }
        }
        return false // equal
    }

    /// Extract the first path component that looks like a version
    /// (`^v?\d+\.\d+\.\d+` optionally with a `-suffix`), with any leading "v"
    /// stripped. Returns the raw matched component (e.g. "2.1.197" or
    /// "2.1.0-rc1"), or nil if no component qualifies.
    static func versionComponent(in path: String) -> String? {
        for component in path.split(separator: "/") {
            if let version = normalizedVersion(String(component)) {
                return version
            }
        }
        return nil
    }

    /// If `component` starts with `v?\d+\.\d+\.\d+`, return it with a leading
    /// "v" stripped; otherwise nil. Requires at least major.minor.patch so bare
    /// numbers or "2.1" don't count as a version directory.
    static func normalizedVersion(_ component: String) -> String? {
        var s = Substring(component)
        if s.first == "v" || s.first == "V" { s = s.dropFirst() }

        // Require three numeric segments separated by dots at the start.
        var segments = 0
        var index = s.startIndex
        while segments < 3 {
            let digitsStart = index
            while index < s.endIndex, s[index].isNumber { index = s.index(after: index) }
            if index == digitsStart { return nil } // no digits where required
            segments += 1
            if segments < 3 {
                guard index < s.endIndex, s[index] == "." else { return nil }
                index = s.index(after: index) // consume dot
            }
        }
        // Matched major.minor.patch. Whatever follows (empty or "-suffix")
        // is allowed; return the whole (v-stripped) component.
        return String(s)
    }
}
