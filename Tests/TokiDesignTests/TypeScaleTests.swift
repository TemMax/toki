import Testing
@testable import TokiDesign

/// Resets `TypeScale.multiplier` after the one test below that touches it, since it is
/// process-wide mutable state and tests run in the same process.
private func withMultiplier<T>(_ value: Double, _ body: () -> T) -> T {
    let previous = TypeScale.multiplier
    TypeScale.multiplier = value
    defer { TypeScale.multiplier = previous }
    return body()
}

@Suite("The ladder")
struct LadderTests {
    @Test("is strictly ascending")
    func strictlyAscending() {
        let sizes = TypeScale.Step.allCases.map(\.rawValue)
        for (prev, next) in zip(sizes, sizes.dropFirst()) {
            #expect(prev < next, "\(prev) is not < \(next)")
        }
    }

    @Test("minimum step is >= 10")
    func minimumIsAtLeastTen() {
        let minimum = TypeScale.Step.allCases.map(\.rawValue).min()!
        #expect(minimum >= 10)
    }
}

@Suite("Roles resolve onto the ladder")
struct RoleLadderTests {
    @Test("every role's step is one of the ladder's own cases", arguments: TypeScale.Role.allCases)
    func roleUsesLadderStep(role: TypeScale.Role) {
        // `RoleSpec.step` is typed as `TypeScale.Step`, so this is really asserting no role
        // has silently grown an off-ladder raw size — the type system already forbids that
        // for anyone constructing a `RoleSpec` honestly, but this pins it as a behavior.
        #expect(TypeScale.Step.allCases.contains(role.spec.step))
    }

    @Test("metricInline is label-step, semibold, rounded, tabular digits")
    func metricInlineSpec() {
        let spec = TypeScale.Role.metricInline.spec
        #expect(spec.step == .label)
        #expect(spec.weight == .semibold)
        #expect(spec.design == .rounded)
        #expect(spec.monospacedDigits)
    }

    @Test("hero is hero-step, LIGHT (not semibold), rounded, tabular digits")
    func heroSpec() {
        // The deliberate weight contrast documented on `heroNumber()` (SectionHeader.swift):
        // a light huge number against a semibold tiny caps label. Pinned here so a future
        // edit can't silently reintroduce semibold and flatten that contrast.
        let spec = TypeScale.Role.hero.spec
        #expect(spec.step == .hero)
        #expect(spec.weight == .light)
        #expect(spec.design == .rounded)
        #expect(spec.monospacedDigits)
    }
}

/// These exercise `Role.size(multiplier:)`, the pure form, rather than assigning the global.
///
/// The first version of this suite went through `TypeScale.multiplier`, and it failed about
/// one run in four: swift-testing runs cases in parallel, so one case set the process-wide
/// multiplier while another was mid-read, and a role resolved at someone else's scale. The
/// fix was to give the arithmetic a pure entry point, not to serialise the suite — a shared
/// mutable global that only behaves when nothing else touches it is a defect in the API,
/// and hiding it behind `.serialized` would have left it for the app to hit instead.
@Suite("The scale multiplier")
struct MultiplierTests {
    @Test("at 1.0, every role resolves to exactly its ladder size")
    func identityAtOne() {
        for role in TypeScale.Role.allCases {
            #expect(role.size(multiplier: 1.0) == role.spec.step.rawValue, "\(role)")
        }
    }

    @Test("scales every role proportionally")
    func scalesProportionally() {
        let factor = 1.25
        for role in TypeScale.Role.allCases {
            let expected = role.spec.step.rawValue * factor
            #expect(abs(role.size(multiplier: factor) - expected) < 0.0001, "\(role)")
        }
    }

    @Test("clamps below the lower bound instead of passing the raw value through")
    func clampsLow() {
        #expect(TypeScale.clamped(0.5) == TypeScale.minimumMultiplier)
        for role in TypeScale.Role.allCases {
            #expect(role.size(multiplier: 0.5) == role.size(multiplier: TypeScale.minimumMultiplier))
        }
    }

    @Test("clamps above the upper bound instead of passing the raw value through")
    func clampsHigh() {
        #expect(TypeScale.clamped(5.0) == TypeScale.maximumMultiplier)
        for role in TypeScale.Role.allCases {
            #expect(role.size(multiplier: 5.0) == role.size(multiplier: TypeScale.maximumMultiplier))
        }
    }

    @Test("at the minimum multiplier, the smallest role still resolves to >= 8.5pt")
    func smallestRoleStaysReadableAtMinimum() {
        let smallest = TypeScale.Role.allCases
            .map { $0.size(multiplier: TypeScale.minimumMultiplier) }
            .min()!
        #expect(smallest >= 8.5, "smallest resolved size at minimum multiplier: \(smallest)")
    }
}

/// The ambient global gets one case, serialised, because it is the one thing here that
/// genuinely is shared state.
@Suite("The ambient multiplier", .serialized)
struct AmbientMultiplierTests {
    @Test("assigning it clamps, and roles follow it")
    func ambientFollowsAssignment() {
        withMultiplier(5.0) {
            #expect(TypeScale.multiplier == TypeScale.maximumMultiplier)
            #expect(TypeScale.Role.body.resolvedSize
                    == TypeScale.Role.body.size(multiplier: TypeScale.maximumMultiplier))
        }
    }
}
