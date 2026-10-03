/// SpeedSamples — the generation speed report's input, as columns.
import Foundation

/// Which requests count as speed samples. The SQL that selects them and the partial index
/// that serves it are generated from these literals (see `TranscriptStore.speedSamplesSQL`),
/// so changing one changes all three.
public enum SpeedSampleFilter {
    /// Shorter responses are dominated by time to first token, not generation.
    public static let minOutputTokens = 200
    /// Exclusive: anything this fast is a clock artefact.
    public static let minGenerationMs = 300
    /// Inclusive: past 15 minutes the request almost certainly waited on something else.
    public static let maxGenerationMs = 900_000
}

public struct SpeedSampleGroup: Sendable, Hashable {
    public let model: String
    public let effort: String?
    public let isFast: Bool

    public init(model: String, effort: String?, isFast: Bool) {
        self.model = model
        self.effort = effort
        self.isFast = isFast
    }
}

/// Every measurable request as parallel arrays — no per-row struct, `String` or `Date`.
/// Rows are in group-then-time order and each group's rows are contiguous.
public struct SpeedSamples: Sendable, Equatable {
    public var groups: [SpeedSampleGroup]
    /// Index into `groups`, per row.
    public var group: [UInt16]
    public var timestampMs: [Int64]
    public var outputTokens: [Int32]
    public var generationMs: [Int32]

    public var count: Int { group.count }

    public static let empty = SpeedSamples(groups: [], group: [], timestampMs: [], outputTokens: [], generationMs: [])

    public init(groups: [SpeedSampleGroup], group: [UInt16], timestampMs: [Int64], outputTokens: [Int32], generationMs: [Int32]) {
        self.groups = groups
        self.group = group
        self.timestampMs = timestampMs
        self.outputTokens = outputTokens
        self.generationMs = generationMs
    }
}

/// The source of speed samples (the transcript index; a stub in probes).
public protocol SpeedSampleProviding: Sendable {
    func speedSamples() async throws -> SpeedSamples
}
