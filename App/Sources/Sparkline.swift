/// Sparkline & MiniBars — lightweight hand-drawn chart primitives.
///
/// Sparkline: filled area gradient + smoothed (Catmull-Rom) stroked path + endpoint dot.
/// No Swift Charts dependency. The curve animates its shape when `values` changes
/// (e.g. the user switches Today / 7 Days / 30 Days) by interpolating an
/// `AnimatableVector` of normalized y-fractions carried in `animatableData`.
///
/// MiniBars: a row of thin rounded capsule bars for daily breakdowns; bars spring
/// to their new heights on value change.
///
/// Both normalize to the max value and are ~36pt tall, filling available width.
/// Default color is Palette.accent (fired clay).
import SwiftUI

// MARK: - AnimatableVector

/// A variable-length vector of Doubles conforming to `VectorArithmetic` so it can
/// be carried as a Shape's `animatableData`. `AnimatablePair` cannot carry a
/// variable-length array, which is why this exists.
///
/// When two vectors of differing length are combined (the point count changes
/// across renders — Today=1, 7D≈7, 30D≈30) the shorter operand is padded to the
/// longer length by repeating its last element (the baseline / final value), so
/// interpolation is always well-defined and the new chart grows in smoothly.
struct AnimatableVector: VectorArithmetic, Equatable {
    var values: [Double]

    init(_ values: [Double] = []) {
        self.values = values
    }

    static let zero = AnimatableVector([])

    /// Pads `a` and `b` to equal length by repeating each one's last element
    /// (or 0 when empty). Returns the aligned pair.
    private static func aligned(
        _ a: [Double],
        _ b: [Double]
    ) -> (lhs: [Double], rhs: [Double]) {
        let n = Swift.max(a.count, b.count)
        func pad(_ v: [Double]) -> [Double] {
            guard v.count < n else { return v }
            let fill = v.last ?? 0
            return v + Array(repeating: fill, count: n - v.count)
        }
        return (pad(a), pad(b))
    }

    static func + (lhs: AnimatableVector, rhs: AnimatableVector) -> AnimatableVector {
        let (l, r) = aligned(lhs.values, rhs.values)
        return AnimatableVector(zip(l, r).map(+))
    }

    static func - (lhs: AnimatableVector, rhs: AnimatableVector) -> AnimatableVector {
        let (l, r) = aligned(lhs.values, rhs.values)
        return AnimatableVector(zip(l, r).map(-))
    }

    mutating func scale(by rhs: Double) {
        for i in values.indices { values[i] *= rhs }
    }

    var magnitudeSquared: Double {
        values.reduce(0) { $0 + $1 * $1 }
    }
}

// MARK: - Curve geometry

/// Shared geometry helpers so the line shape, area shape, and endpoint dot all
/// build identical curves from the same normalized fractions.
private enum SparkGeometry {
    /// Builds CGPoints from normalized y-fractions (0 = baseline/bottom, 1 = top)
    /// laid out evenly across `size.width`. A single fraction renders as a flat
    /// horizontal line spanning the full width.
    static func points(fractions: [Double], size: CGSize) -> [CGPoint] {
        guard !fractions.isEmpty else { return [] }
        func y(_ f: Double) -> CGFloat {
            size.height - CGFloat(f) * size.height
        }
        if fractions.count == 1 {
            let yy = y(fractions[0])
            return [CGPoint(x: 0, y: yy), CGPoint(x: size.width, y: yy)]
        }
        let last = CGFloat(fractions.count - 1)
        return fractions.enumerated().map { idx, f in
            CGPoint(x: (CGFloat(idx) / last) * size.width, y: y(f))
        }
    }

    /// A gently smoothed open curve through the points using Catmull-Rom
    /// interpolation converted to cubic Beziers. `tension` is small so corners
    /// are softened without overshoot; control points are y-clamped to the
    /// segment's own envelope so the curve never balloons past the data.
    static func smoothedPath(through pts: [CGPoint], tension: CGFloat = 0.20) -> Path {
        var path = Path()
        guard let first = pts.first else { return path }
        path.move(to: first)
        guard pts.count > 2 else {
            // 0/1/2 points: a straight segment is the faithful (and safe) render.
            pts.dropFirst().forEach { path.addLine(to: $0) }
            return path
        }

        for i in 0 ..< pts.count - 1 {
            let p0 = pts[Swift.max(i - 1, 0)]
            let p1 = pts[i]
            let p2 = pts[i + 1]
            let p3 = pts[Swift.min(i + 2, pts.count - 1)]

            // Catmull-Rom → Bezier control points, scaled by tension.
            var c1 = CGPoint(
                x: p1.x + (p2.x - p0.x) * tension / 3.0,
                y: p1.y + (p2.y - p0.y) * tension / 3.0
            )
            var c2 = CGPoint(
                x: p2.x - (p3.x - p1.x) * tension / 3.0,
                y: p2.y - (p3.y - p1.y) * tension / 3.0
            )

            // Clamp control-point y to the segment envelope to prevent overshoot
            // beyond the local min/max of the data.
            let loY = Swift.min(p1.y, p2.y)
            let hiY = Swift.max(p1.y, p2.y)
            c1.y = Swift.min(Swift.max(c1.y, loY), hiY)
            c2.y = Swift.min(Swift.max(c2.y, loY), hiY)

            path.addCurve(to: p2, control1: c1, control2: c2)
        }
        return path
    }
}

// MARK: - Shapes

/// The smoothed line stroke. Interpolates the normalized y-fractions so the line
/// visually rises/falls into its new shape when the data changes.
private struct SparkLineShape: Shape {
    var fractions: AnimatableVector

    var animatableData: AnimatableVector {
        get { fractions }
        set { fractions = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let pts = SparkGeometry.points(fractions: fractions.values, size: rect.size)
        return SparkGeometry.smoothedPath(through: pts)
    }
}

/// The same smoothed curve, closed to the baseline for the area gradient fill.
private struct SparkAreaShape: Shape {
    var fractions: AnimatableVector

    var animatableData: AnimatableVector {
        get { fractions }
        set { fractions = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let pts = SparkGeometry.points(fractions: fractions.values, size: rect.size)
        var path = SparkGeometry.smoothedPath(through: pts)
        guard let first = pts.first, let last = pts.last else { return path }
        path.addLine(to: CGPoint(x: last.x, y: rect.size.height))
        path.addLine(to: CGPoint(x: first.x, y: rect.size.height))
        path.closeSubpath()
        return path
    }
}

/// The "today" endpoint dot. Carries the same fractions so it rides the end of
/// the curve in lockstep with the animating line.
private struct SparkEndpointDot: Shape {
    var fractions: AnimatableVector
    var diameter: CGFloat

    var animatableData: AnimatableVector {
        get { fractions }
        set { fractions = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let pts = SparkGeometry.points(fractions: fractions.values, size: rect.size)
        guard let last = pts.last else { return Path() }
        let r = diameter / 2
        return Path(ellipseIn: CGRect(x: last.x - r, y: last.y - r,
                                      width: diameter, height: diameter))
    }
}

// MARK: - Sparkline

struct Sparkline: View {
    let values: [Double]
    var color: Color = Palette.accent

    /// Diameter of the endpoint dot drawn at the last data point.
    private let dotDiameter: CGFloat = 4

    /// Normalized y-fractions (0 = baseline, 1 = top), shared by line/area/dot.
    /// Derived purely from `values`, so the static (non-animating) and
    /// `SnapshotConfig.flatSurfaces` renders show the correct final curve.
    private var fractions: AnimatableVector {
        guard !values.isEmpty else { return AnimatableVector([]) }
        let maxVal = values.max() ?? 1
        let safeMax = maxVal == 0 ? 1 : maxVal
        return AnimatableVector(values.map { $0 / safeMax })
    }

    var body: some View {
        let frac = fractions
        ZStack {
            // Filled area below the smoothed curve.
            SparkAreaShape(fractions: frac)
                .fill(
                    LinearGradient(
                        colors: [color.opacity(0.18), color.opacity(0)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

            // Smoothed line stroke.
            SparkLineShape(fractions: frac)
                .stroke(
                    color,
                    style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
                )

            // "Today" endpoint dot riding the end of the curve.
            if !values.isEmpty {
                SparkEndpointDot(fractions: frac, diameter: dotDiameter)
                    .fill(color)
            }
        }
        .frame(height: 36)
    }
}

// MARK: - MiniBars

/// A row of thin rounded-rectangle bars for small daily breakdowns.
/// Bars are normalized to the max value, fill the available width, and spring to
/// their new heights when `values` changes.
struct MiniBars: View {
    let values: [Double]
    var color: Color = Palette.accent

    private let barSpacing: CGFloat = 2

    var body: some View {
        GeometryReader { geo in
            let maxVal = values.max() ?? 1
            let safeMax = maxVal == 0 ? 1 : maxVal
            let count = max(values.count, 1)
            let totalSpacing = barSpacing * CGFloat(count - 1)
            let barWidth = (geo.size.width - totalSpacing) / CGFloat(count)

            HStack(alignment: .bottom, spacing: barSpacing) {
                ForEach(Array(values.enumerated()), id: \.offset) { _, val in
                    let fraction = val / safeMax
                    let height = max(fraction * geo.size.height, 2)  // 2pt minimum
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(color.opacity(0.80))
                        .frame(width: barWidth, height: height)
                        .animation(.spring(response: 0.45, dampingFraction: 0.82),
                                   value: height)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        .frame(height: 36)
    }
}

// MARK: - Preview

#Preview("Sparkline + MiniBars") {
    let valuesA: [Double] = [12, 45, 28, 67, 50, 89, 72, 55, 91, 64, 38, 77]
    let valuesB: [Double] = [40, 22, 88]  // different length → morph

    struct MorphDemo: View {
        let a: [Double]
        let b: [Double]
        @State private var toggled = false

        var body: some View {
            let v = toggled ? b : a
            VStack(spacing: 20) {
                Sparkline(values: v, color: Palette.accent)
                    .frame(width: 200)
                Sparkline(values: v, color: Palette.ok)
                    .frame(width: 200)
                MiniBars(values: v, color: Palette.accent)
                    .frame(width: 200)
                // Edge cases
                Sparkline(values: [], color: Palette.accent)
                    .frame(width: 200)
                Sparkline(values: [42], color: Palette.warn)
                    .frame(width: 200)

                Button("Toggle range (morph)") {
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
                        toggled.toggle()
                    }
                }
            }
            .padding(20)
            .background(Palette.surface)
        }
    }

    return MorphDemo(a: valuesA, b: valuesB)
}
