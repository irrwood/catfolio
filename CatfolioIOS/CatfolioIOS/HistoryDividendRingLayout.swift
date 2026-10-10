import SwiftUI

/// Geometry only: the ledger's amounts and percentage labels stay untouched.
/// Tiny positive sources get a visible arc; larger sources share the remaining
/// angle proportionally. Hit testing uses these same displayed angles.
struct HistoryRingLayout<Row: Identifiable> {
    static var diameter: CGFloat { 195 }
    static var innerRadiusRatio: CGFloat { 0.66 }
    static var minimumFraction: Double { 0.02 }

    struct Segment: Identifiable {
        let row: Row
        let fraction: Double
        var id: Row.ID { row.id }
    }

    let segments: [Segment]

    init(rows: [Row], weight: (Row) -> Double) {
        let rows = rows.filter { weight($0).isFinite && weight($0) > 0 }
        let weights = rows.map(weight)
        var remainingWeight = weights.reduce(0, +)
        guard !rows.isEmpty, remainingWeight.isFinite, remainingWeight > 0 else {
            segments = []
            return
        }

        // With many sources, reserve at least half the circle for the real
        // distribution instead of letting minimum-sized arcs consume it all.
        let floor = min(Self.minimumFraction, 0.5 / Double(rows.count))
        var fractions = Array(repeating: 0.0, count: rows.count)
        var remainingFraction = 1.0
        let ascending = weights.indices.sorted { weights[$0] < weights[$1] }
        for (position, index) in ascending.enumerated() {
            if weights[index] / remainingWeight * remainingFraction < floor {
                fractions[index] = floor
                remainingFraction -= floor
                remainingWeight -= weights[index]
            } else {
                for rest in ascending[position...] {
                    fractions[rest] = weights[rest] / remainingWeight * remainingFraction
                }
                break
            }
        }
        segments = rows.indices.map { Segment(row: rows[$0], fraction: fractions[$0]) }
    }

    // Insets are in points. Cap the gaps and rounding for crowded rings so
    // they cannot consume a small sector at the narrow, inner edge.
    private var smallestInnerArc: CGFloat {
        CGFloat(segments.map(\.fraction).min() ?? 0)
            * .pi * Self.diameter * Self.innerRadiusRatio
    }

    var angularInset: CGFloat { min(1.5, smallestInnerArc / 4) }
    var cornerRadius: CGFloat { min(3, smallestInnerArc / 4) }

    func row(at fraction: Double) -> Row? {
        guard fraction.isFinite, (0...1).contains(fraction) else { return nil }
        var edge = 0.0
        for segment in segments {
            edge += segment.fraction
            if fraction < edge { return segment.row }
        }
        return segments.last?.row
    }
}

typealias HistoryDividendRingLayout = HistoryRingLayout<HistoryDividendBreakdown.Row>

extension HistoryRingLayout where Row == HistoryDividendBreakdown.Row {
    init(breakdown: HistoryDividendBreakdown) {
        self.init(rows: breakdown.rows) { breakdown.share(for: $0) ?? 0 }
    }
}
