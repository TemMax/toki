import Testing
@testable import TokiDesign

@Suite("IconSize")
struct IconSizeTests {
    @Test("is strictly ascending, small to hero")
    func strictlyAscending() {
        let ordered: [IconSize] = [.small, .regular, .medium, .large, .hero]
        let sizes = ordered.map(\.pointSize)
        for (prev, next) in zip(sizes, sizes.dropFirst()) {
            #expect(prev < next, "\(prev) is not < \(next)")
        }
    }

    @Test("minimum step is >= 10, matching the smallest defensible interface glyph")
    func minimumIsAtLeastTen() {
        let minimum = IconSize.allCases.map(\.pointSize).min()!
        #expect(minimum >= 10)
    }

    @Test("every case has a distinct point size")
    func noDuplicateSizes() {
        let sizes = IconSize.allCases.map(\.pointSize)
        #expect(Set(sizes).count == sizes.count)
    }

    @Test("hero is the largest step, matching TypeScale.Step.hero's raw size", arguments: [
        (IconSize.small, TypeScale.Step.caption),
        (IconSize.regular, TypeScale.Step.label),
        (IconSize.medium, TypeScale.Step.body),
        (IconSize.large, TypeScale.Step.metric),
        (IconSize.hero, TypeScale.Step.hero),
    ])
    func matchesTheCorrespondingTextStep(icon: IconSize, step: TypeScale.Step) {
        // Not the same ladder (icons don't take the text-scale multiplier — see
        // `IconSize.pointSize`'s doc comment), but derived from the same inventoried sizes,
        // so at scale 1.0 they land on identical points. Pins that relationship as a
        // behavior rather than leaving it an unstated coincidence.
        #expect(icon.pointSize == step.rawValue)
    }
}
