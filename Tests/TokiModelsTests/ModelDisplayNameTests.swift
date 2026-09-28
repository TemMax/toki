import Testing
import Foundation
@testable import TokiModels

@Suite("ModelDisplayName")
struct ModelDisplayNameTests {

    @Test("OpenAI limit names read like product names")
    func openAIProductNames() {
        #expect(DisplayFormat.openAIModelName("GPT-5.3-Codex-Spark") == "GPT-5.3 Codex Spark")
        #expect(DisplayFormat.openAIModelName("gpt-5-codex-mini") == "GPT-5 Codex Mini")
        #expect(DisplayFormat.openAIModelName("codex_other") == "Codex Other")
        #expect(DisplayFormat.modelName("gpt-5.3-codex") == "GPT-5.3 Codex")
    }

    // MARK: - Current ids

    @Test("Dotted versions: claude-fable-5-1 reads as Fable 5.1")
    func dottedVersion() {
        #expect(DisplayFormat.modelName("claude-fable-5-1") == "Fable 5.1")
        #expect(DisplayFormat.modelName("claude-mythos-5-1") == "Mythos 5.1")
        #expect(DisplayFormat.modelName("claude-sonnet-4-6") == "Sonnet 4.6")
        #expect(DisplayFormat.modelName("claude-haiku-4-5") == "Haiku 4.5")
    }

    @Test("A single-part version keeps no trailing dot")
    func singlePartVersion() {
        #expect(DisplayFormat.modelName("claude-fable-5") == "Fable 5")
        #expect(DisplayFormat.modelName("claude-opus-5") == "Opus 5")
        #expect(DisplayFormat.modelName("claude-opus-5-5") == "Opus 5.5")
        #expect(DisplayFormat.modelName("claude-opus-5-5[1m]") == "Opus 5.5 (1M)")
        #expect(DisplayFormat.modelName("claude-sonnet-5") == "Sonnet 5")
    }

    /// The row that prompted this: `haiku-4-5-20251001` on a card read at a glance.
    @Test("A release-date suffix moves into parentheses, hyphenated")
    func releaseDateInParentheses() {
        #expect(DisplayFormat.modelName("claude-haiku-4-5-20251001") == "Haiku 4.5 (2025-10-01)")
        #expect(DisplayFormat.modelName("claude-sonnet-4-20250514") == "Sonnet 4 (2025-05-14)")
        #expect(DisplayFormat.modelName("claude-opus-4-1-20250805") == "Opus 4.1 (2025-08-05)")
    }

    /// The pre-2025 naming put the version before the family. Both orders have to reach the
    /// same spoken name, or the same model reads as two different ones on one card.
    @Test("Legacy version-first ids are reordered: claude-3-5-haiku reads as Haiku 3.5")
    func legacyVersionFirstOrder() {
        #expect(DisplayFormat.modelName("claude-3-5-haiku") == "Haiku 3.5")
        #expect(DisplayFormat.modelName("claude-3-5-haiku-20241022") == "Haiku 3.5 (2024-10-22)")
    }

    // MARK: - Variant tags

    /// Two rows for `claude-opus-5` and `claude-opus-5[1m]` are two DIFFERENT rows; a
    /// formatter that dropped the tag would print one label twice with two different
    /// numbers beside it.
    @Test("A bracketed variant tag survives as a parenthetical")
    func variantTagSurvives() {
        #expect(DisplayFormat.modelName("claude-opus-5[1m]") == "Opus 5 (1M)")
        #expect(DisplayFormat.modelName("claude-fable-5-1[1m]") == "Fable 5.1 (1M)")
        #expect(DisplayFormat.modelName("claude-opus-5") != DisplayFormat.modelName("claude-opus-5[1m]"))
    }

    @Test("A variant tag and a release date share one parenthetical")
    func variantAndDateTogether() {
        #expect(DisplayFormat.modelName("claude-opus-5-20260101[1m]") == "Opus 5 (1M, 2026-01-01)")
    }

    // MARK: - Suffixed and unfamiliar shapes

    @Test("Trailing words keep their position rather than jumping the version")
    func trailingWordsKeepPosition() {
        #expect(DisplayFormat.modelName("claude-opus-4-8-thinking") == "Opus 4.8 Thinking")
        #expect(DisplayFormat.modelName("claude-sonnet-5-preview") == "Sonnet 5 Preview")
        #expect(DisplayFormat.modelName("claude-haiku-4-5-mini") == "Haiku 4.5 Mini")
    }

    /// The formatter knows no family names on purpose (see its doc comment), so a model
    /// nobody has seen yet still comes out readable instead of raw.
    @Test("An unfamiliar Claude id is title-cased rather than left as a wire string")
    func unfamiliarClaudeID() {
        #expect(DisplayFormat.modelName("claude-experimental-vision-large") == "Experimental Vision Large")
        #expect(DisplayFormat.modelName("claude-instant-legacy") == "Instant Legacy")
    }

    @Test("A bare family alias is title-cased")
    func bareFamilyAlias() {
        #expect(DisplayFormat.modelName("opus") == "Opus")
        #expect(DisplayFormat.modelName("fable") == "Fable")
    }

    // MARK: - Inputs that must pass through untouched

    @Test("An unknown non-Claude id is returned unchanged")
    func nonClaudeIDUnchanged() {
        #expect(DisplayFormat.modelName("some/vendor/model-x") == "some/vendor/model-x")
    }

    @Test("An empty or whitespace id is returned unchanged")
    func emptyIDUnchanged() {
        #expect(DisplayFormat.modelName("") == "")
        #expect(DisplayFormat.modelName("   ") == "   ")
    }

    @Test("A bare 'claude' with nothing after it title-cases like any other lone word")
    func bareVendorPrefixAlone() {
        #expect(DisplayFormat.modelName("claude") == "Claude")
    }

    /// An 8-digit token only becomes a date when it could actually BE one — otherwise a
    /// future version or serial would be reformatted into a nonsense date.
    @Test("An 8-digit token that is not a plausible date stays a plain token")
    func implausibleDateIsNotReformatted() {
        #expect(DisplayFormat.modelName("claude-opus-99999999") == "Opus 99999999")
        #expect(DisplayFormat.modelName("claude-opus-20251345") == "Opus 20251345")
    }

    // MARK: - Case handling

    @Test("Formatting is case-insensitive on input")
    func caseInsensitiveInput() {
        #expect(DisplayFormat.modelName("CLAUDE-OPUS-5") == "Opus 5")
        #expect(DisplayFormat.modelName("Claude-Fable-5-1") == "Fable 5.1")
    }
}
