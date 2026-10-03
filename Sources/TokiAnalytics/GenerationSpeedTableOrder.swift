/// GenerationSpeedTableOrder — how the speed table lays a provider's groups out: one block per
/// model, newest model first (by the version in its id) and ordered by effort inside it. Pure, so the view and its keyboard order share it.
import Foundation

public enum GenerationSpeedTableOrder {
    /// One model's rows, in display order.
    public struct ModelBlock: Sendable, Equatable, Identifiable {
        public let id: String                 // the model id
        public let groups: [GenerationSpeedReport.Group]

        public init(id: String, groups: [GenerationSpeedReport.Group]) {
            self.id = id
            self.groups = groups
        }
    }

    /// Blocks for one provider's groups: models newest first by the version in the model id
    /// (`modelVersion`; ids without one last), then by total responses (descending), then by model
    /// id; inside a model by effort rank, then Standard before Fast.
    public static func blocks(_ groups: [GenerationSpeedReport.Group]) -> [ModelBlock] {
        let byModel = Dictionary(grouping: groups, by: \.model)
        let totals = byModel.mapValues { $0.reduce(0) { $0 + $1.count } }
        let versions = Dictionary(uniqueKeysWithValues: byModel.keys.map { ($0, modelVersion($0)) })
        return byModel.keys
            .sorted { a, b in
                let (va, vb) = (versions[a]!, versions[b]!)
                if va.isEmpty != vb.isEmpty { return !va.isEmpty }
                let order = compare(va, vb)
                if order != 0 { return order > 0 }
                if totals[a]! != totals[b]! { return totals[a]! > totals[b]! }
                return a < b
            }
            .map { model in
                ModelBlock(id: model, groups: byModel[model]!.sorted(by: inBlockOrder))
            }
    }

    /// The version components in a model id, or `[]` when it has none. A trailing `[...]` variant
    /// is dropped and the id split on `-`. The version starts at the first token that begins with a
    /// digit and is at most 4 characters long (so a date is never a version): a token with a `.`
    /// splits into its numeric parts (`6.1` is `[6, 1]`); otherwise it is the major, and the next
    /// token is the minor when it is all digits and at most 2 characters.
    public static func modelVersion(_ id: String) -> [Int] {
        let base = id.split(separator: "[", maxSplits: 1, omittingEmptySubsequences: false)[0]
        let tokens = base.split(separator: "-", omittingEmptySubsequences: false)
        guard let index = tokens.firstIndex(where: { $0.first?.isASCII == true && $0.first!.isNumber && $0.count <= 4 })
        else { return [] }
        let token = tokens[index]
        if token.contains(".") {
            return token.split(separator: ".").compactMap { Int($0.prefix(while: \.isASCII).prefix(while: \.isNumber)) }
        }
        guard let major = Int(token.prefix(while: \.isNumber)) else { return [] }
        let next = index + 1 < tokens.count ? tokens[index + 1] : ""
        if !next.isEmpty, next.count <= 2, next.allSatisfy({ $0.isASCII && $0.isNumber }), let minor = Int(next) {
            return [major, minor]
        }
        return [major]
    }

    /// Component-wise comparison, a missing component counting as 0: positive when `a` is newer.
    private static func compare(_ a: [Int], _ b: [Int]) -> Int {
        for i in 0..<max(a.count, b.count) {
            let (x, y) = (i < a.count ? a[i] : 0, i < b.count ? b[i] : 0)
            if x != y { return x > y ? 1 : -1 }
        }
        return 0
    }

    /// Lower sorts first: minimal 0, low 1, medium 2, high 3, xhigh 4, max 5; any other value
    /// after those, alphabetically among themselves; nil last.
    public static func effortRank(_ effort: String?) -> (Int, String) {
        switch effort {
        case "minimal": return (0, "")
        case "low": return (1, "")
        case "medium": return (2, "")
        case "high": return (3, "")
        case "xhigh": return (4, "")
        case "max": return (5, "")
        case let other?: return (6, other)
        case nil: return (7, "")
        }
    }

    /// Effort rank, then Standard before Fast; the id last, so the order is total.
    private static func inBlockOrder(_ a: GenerationSpeedReport.Group, _ b: GenerationSpeedReport.Group) -> Bool {
        let (ra, rb) = (effortRank(a.effort), effortRank(b.effort))
        if ra != rb { return ra < rb }
        if a.isFast != b.isFast { return !a.isFast }
        return a.id < b.id
    }
}
