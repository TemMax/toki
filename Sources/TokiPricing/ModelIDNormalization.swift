/// ModelIDNormalization — canonicalises a raw model id before pricing lookup so that
/// context-window variant tags and short family aliases still resolve to a known rate.
/// Shared by both `PricingTable` (static) and `LivePricingTable` (date-aware) so the two
/// providers price these variants identically.
import Foundation

/// Canonicalises `raw` for pricing lookup:
///  - Strips a trailing bracketed variant tag, e.g. `claude-opus-4-8[1m]` -> `claude-opus-4-8`
///    (the 1M-context variant is billed at the base model's per-token rate, so it must
///    match the base prefix; the `[` would otherwise fail the `-`/end boundary check).
///  - Expands a bare family alias to the current model id: `fable` -> `claude-fable-5-1`,
///    `opus` -> `claude-opus-5-5`, `sonnet` -> `claude-sonnet-5`, `haiku` -> `claude-haiku-4-5`.
///    These aliases carry no version, so we resolve to whichever model each family currently
///    serves — which is what the CLI itself picks when the user selects a bare family name.
///    `sonnet` used to resolve to 4.6 to dodge Sonnet 5's introductory-pricing window; that
///    window was never closed (see `BundledRates`), so the dodge only mis-priced the model
///    people are actually running. Update this mapping whenever a family's default moves.
///  - Expands OpenAI's moving `gpt-5.6` alias to the currently documented Sol variant.
///
/// Any other id is returned unchanged apart from the bracket-tag strip. Case is preserved;
/// callers lowercase for prefix matching as before.
func canonicalModelID(_ raw: String) -> String {
    var id = raw
    if let bracket = id.firstIndex(of: "[") {
        id = String(id[..<bracket])
    }
    id = id.trimmingCharacters(in: .whitespaces)

    switch id.lowercased() {
    case "fable":  return "claude-fable-5-1"
    case "mythos": return "claude-mythos-5-1"
    case "opus":   return "claude-opus-5-5"
    case "sonnet": return "claude-sonnet-5"
    case "haiku":  return "claude-haiku-4-5"
    case "gpt-5.6": return "gpt-5.6-sol"
    default:       return id
    }
}

/// Models that deliberately have no public token price must not fall through to a broader
/// priced prefix. GPT-5.3 Codex Spark is a research-preview ChatGPT model, so pricing it as
/// ordinary GPT-5.3 Codex would fabricate a dollar estimate. Auto Review is likewise a
/// Codex product operation without a published per-token API rate.
func isExplicitlyUnpricedModelID(_ canonicalID: String) -> Bool {
    let id = canonicalID.lowercased()
    return hasModelPrefix("gpt-5.3-codex-spark", in: id)
        || hasModelPrefix("codex-auto-review", in: id)
}

private func hasModelPrefix(_ prefix: String, in id: String) -> Bool {
    guard id.hasPrefix(prefix) else { return false }
    let suffix = id.dropFirst(prefix.count)
    return suffix.isEmpty || suffix.first == "-"
}
