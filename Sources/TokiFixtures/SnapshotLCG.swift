/// Deterministic pseudo-random generator for fixture data. Ported verbatim from
/// `App/Sources/SnapshotRunner.swift`'s `SnapshotLCG` so scenario builders never reach for
/// `Int.random`/`Double.random` — the same seed always produces the same sequence.
struct SnapshotLCG {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed
    }

    private mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }

    /// A deterministic pseudo-random value in [0, 1).
    mutating func nextUnit() -> Double {
        Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)   // 2^53
    }
}
