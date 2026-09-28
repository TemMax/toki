/// ModelDisplayName — turns a raw model id into the name a person would say out loud.
import Foundation

public extension DisplayFormat {

    /// Turns an OpenAI model/limit identifier into a compact product name.
    ///
    /// App Server currently reports names such as `GPT-5.3-Codex-Spark`. Keeping every
    /// hyphen and then uppercasing the whole gauge label makes that wire identifier much
    /// harder to scan than the product name people use. The formatter is structural: it
    /// preserves an initial GPT version as `GPT-5.3`, then title-cases any remaining
    /// variant words, so future names do not need to be added to a hardcoded allow-list.
    static func openAIModelName(_ id: String) -> String {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return id }

        let tokens = trimmed
            .split(whereSeparator: { $0 == "-" || $0 == "_" || $0.isWhitespace })
            .map(String.init)
        guard !tokens.isEmpty else { return id }

        var rendered: [String] = []
        var index = 0
        if tokens[0].caseInsensitiveCompare("gpt") == .orderedSame {
            if tokens.count > 1, isOpenAIVersion(tokens[1]) {
                rendered.append("GPT-\(tokens[1])")
                index = 2
            } else {
                rendered.append("GPT")
                index = 1
            }
        }

        for token in tokens[index...] {
            let lower = token.lowercased()
            switch lower {
            case "gpt": rendered.append("GPT")
            case "api": rendered.append("API")
            default:
                rendered.append(lower.prefix(1).uppercased() + lower.dropFirst())
            }
        }

        return rendered.isEmpty ? trimmed : rendered.joined(separator: " ")
    }

    /// `"claude-fable-5-1"` -> `"Fable 5.1"`, `"claude-haiku-4-5-20251001"` ->
    /// `"Haiku 4.5 (2025-10-01)"`, `"claude-opus-5[1m]"` -> `"Opus 5 (1M)"`.
    ///
    /// The By Model card used to render the raw id with only `claude-` shaved off, which
    /// left rows reading `fable-5-1` and `haiku-4-5-20251001` — a wire format on a surface
    /// whose whole job is to be read at a glance.
    ///
    /// This lives in `TokiModels`, not in the view that draws it, for the same reason
    /// `ExtraUsage.prominence` does: it is a rule with a right answer, and `App/Sources` is
    /// not part of `Package.swift`, so nothing there can be reached by `swift test`.
    ///
    /// Deliberately STRUCTURAL — it recognises version numbers, release dates and variant
    /// tags, and never a list of family names. A hardcoded family list is exactly what left
    /// Fable unpriced until it was noticed by hand; a formatter carrying one would render
    /// every model Anthropic ships next as a raw id, silently, with nothing to catch it.
    /// The cost of being structural is that an id shaped unlike anything seen before is
    /// merely title-cased rather than misread.
    ///
    /// The result is LOSSY (the date and the variant tag survive, the `claude-` vendor
    /// prefix does not), so a surface that shows it should keep the exact id reachable —
    /// the card puts it in the row's tooltip.
    static func modelName(_ id: String) -> String {
        let trimmed = id.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return id }

        // Analytics is shared by Claude and Codex. Recognise the unambiguous OpenAI
        // family here so the By Model card applies the same product-name formatting as
        // live Codex rate-limit gauges instead of exposing a raw `gpt-…` identifier.
        if trimmed.lowercased().hasPrefix("gpt-")
            || trimmed.caseInsensitiveCompare("gpt") == .orderedSame {
            return openAIModelName(trimmed)
        }

        // A trailing bracketed variant tag ("claude-opus-5[1m]") is part of the identity,
        // not noise: dropping it would collapse two distinct rows onto one label.
        var stem = trimmed
        var variant: String?
        if let open = stem.firstIndex(of: "["), stem.hasSuffix("]") {
            let tag = stem[stem.index(after: open)..<stem.index(before: stem.endIndex)]
            if !tag.isEmpty { variant = tag.uppercased() }
            stem = String(stem[..<open])
        }

        var tokens = stem.split(separator: "-").map { String($0).lowercased() }

        if tokens.first == "claude", tokens.count > 1 {
            tokens.removeFirst()
        } else if !(tokens.count == 1 && isWord(tokens[0])) {
            // Neither a `claude-…` id nor a bare family alias ("opus", which is a whole id
            // in Claude Code's own config): the caller is better served by the exact string
            // than by a guess at its shape.
            return trimmed
        }

        // Pull a release date out wherever it sits; it always renders last, in parentheses.
        var date: String?
        if let index = tokens.firstIndex(where: { releaseDate(from: $0) != nil }) {
            date = releaseDate(from: tokens[index])
            tokens.remove(at: index)
        }

        // Collapse runs of version tokens into dotted numbers: ["4", "5"] -> "4.5".
        var groups: [(text: String, isVersion: Bool)] = []
        for token in tokens {
            let version = isVersionNumber(token)
            if version, let last = groups.last, last.isVersion {
                groups[groups.count - 1].text = last.text + "." + token
            } else {
                groups.append((version ? token : token.capitalized, version))
            }
        }

        // Legacy ids put the version FIRST ("claude-3-5-haiku"); every current one puts it
        // after the family. Normalise to the spoken order so both read "Haiku 3.5".
        if groups.count >= 2, groups[0].isVersion, !groups[1].isVersion {
            groups.swapAt(0, 1)
        }

        var name = groups.map(\.text).joined(separator: " ")
        guard !name.isEmpty else { return trimmed }

        let parenthetical = [variant, date].compactMap { $0 }
        if !parenthetical.isEmpty {
            name += " (" + parenthetical.joined(separator: ", ") + ")"
        }
        return name
    }

    /// `"20251001"` -> `"2025-10-01"`; nil for anything that is not a plausible date stamp.
    /// The month/day ranges matter: without them a future 8-digit version token would be
    /// silently reformatted into a nonsense date.
    private static func releaseDate(from token: String) -> String? {
        guard token.count == 8, token.allSatisfy(\.isNumber) else { return nil }
        let digits = Array(token)
        let year = String(digits[0..<4])
        let month = String(digits[4..<6])
        let day = String(digits[6..<8])
        guard let m = Int(month), (1...12).contains(m),
              let d = Int(day), (1...31).contains(d),
              let y = Int(year), (2000...2999).contains(y)
        else { return nil }
        return "\(year)-\(month)-\(day)"
    }

    /// A version fragment: all digits, and short enough not to be a date or a serial.
    private static func isVersionNumber(_ token: String) -> Bool {
        !token.isEmpty && token.count <= 2 && token.allSatisfy(\.isNumber)
    }

    /// A name fragment rather than a number — used only to decide whether a single-token
    /// id is a bare family alias worth title-casing.
    private static func isWord(_ token: String) -> Bool {
        !token.isEmpty && token.allSatisfy { $0.isLetter }
    }

    private static func isOpenAIVersion(_ token: String) -> Bool {
        !token.isEmpty && token.allSatisfy { $0.isNumber || $0 == "." }
    }
}
