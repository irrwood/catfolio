import SwiftUI
import Charts
import CryptoKit

struct OIContract: Codable {
    struct Details: Codable {
        let ticker: String
        let contract_type: String
        let expiration_date: String
        let strike_price: Double
        let shares_per_contract: Double?
    }
    let details: Details
    let open_interest: Double?
}

struct OISnapshot: Codable {
    let contracts: [OIContract]
    let fetchedAt: Date
    let from: String
    let through: String
    let excluded: Int
    /// Whether Yahoo lists any expiry at all for the symbol. False means it
    /// has no options, and the security page leaves the panel out. Nil in
    /// snapshots cached before this was recorded.
    var listsOptions: Bool? = nil
}

struct OIDistribution {
    struct Row: Identifiable {
        var id: Double { strike }
        let strike: Double
        var call: Double = 0
        var put: Double = 0
        var hasCall = false
        var hasPut = false
    }
    let rows: [Row]
    let callWalls: [Row]
    let putWalls: [Row]
    let concentration: ClosedRange<Double>?
    /// How far from the current price a strike can sit and still be read as a
    /// wall. A put wall is support and a call wall is resistance, so both are
    /// near the money by definition: a strike 79% below the price carrying a
    /// single old block is open interest, not a floor under the shares.
    static let wallBand = 0.2

    init(contracts: [OIContract], currentPrice: Double? = nil) {
        var grouped: [Double: Row] = [:]
        var seen = Set<String>()
        for contract in contracts {
            guard seen.insert(contract.details.ticker).inserted,
                  let oi = contract.open_interest, oi.isFinite, oi >= 0,
                  contract.details.strike_price.isFinite, contract.details.strike_price > 0,
                  ["call", "put"].contains(contract.details.contract_type) else { continue }
            let strike = contract.details.strike_price
            var row = grouped[strike] ?? Row(strike: strike)
            if contract.details.contract_type == "call" { row.call += oi; row.hasCall = true }
            else { row.put += oi; row.hasPut = true }
            grouped[strike] = row
        }
        rows = grouped.values.sorted { $0.strike < $1.strike }
        callWalls = Self.walls(in: rows, price: currentPrice, side: .call)
        putWalls = Self.walls(in: rows, price: currentPrice, side: .put)
        let total = rows.reduce(0) { $0 + $1.call + $1.put }
        if total > 0 {
            var cumulative = 0.0
            var low: Double?
            var high: Double?
            for row in rows {
                cumulative += row.call + row.put
                if low == nil && cumulative >= total * 0.15 { low = row.strike }
                if high == nil && cumulative >= total * 0.85 { high = row.strike }
            }
            concentration = low.flatMap { lower in high.map { lower...$0 } }
        } else { concentration = nil }
    }

    private enum Side { case call, put }

    /// The heaviest strike on the side that faces the price: puts at or below
    /// it, calls at or above it, and both within `wallBand` of it. Without a
    /// price there is no side to face, so the heaviest strike overall stands.
    /// Ties are all returned, as they always were.
    private static func walls(in rows: [Row], price: Double?, side: Side) -> [Row] {
        func heaviest(_ candidates: [Row]) -> [Row] {
            let value: (Row) -> Double = side == .call ? { $0.call } : { $0.put }
            let maximum = candidates.map(value).max() ?? 0
            guard maximum > 0 else { return [] }
            return candidates.filter { value($0) == maximum }
        }
        guard let price, price.isFinite, price > 0 else { return heaviest(rows) }
        let facing = rows.filter { side == .call ? $0.strike >= price : $0.strike <= price }
        let near = facing.filter { abs($0.strike - price) <= price * wallBand }
        // Widen rather than report nothing: a chain whose strikes all sit far
        // from the price still has a nearest heaviest one.
        let nearWall = heaviest(near)
        if !nearWall.isEmpty { return nearWall }
        let facingWall = heaviest(facing)
        return facingWall.isEmpty ? heaviest(rows) : facingWall
    }
}

/// Presentation geometry only. Vertices retain exact OI at each observed strike;
/// absent contracts and unusually wide strike gaps break the silhouette.
enum OIPlotRange: String, CaseIterable { case main, all }

enum OIPriceLabel {
    static func text(_ value: Double, locale: Locale) -> String {
        guard value.isFinite else { return "—" }
        return "$" + value.formatted(.number.precision(.fractionLength(0...4)).locale(locale))
    }
}

struct OIPlotGeometry {
    enum Side { case put, call }
    struct Vertex: Equatable { let strike: Double; let width: Double }
    let rows: [OIDistribution.Row]
    let maximum: Double
    let domain: ClosedRange<Double>
    let step: Double

    init(_ distribution: OIDistribution, markers: [Double] = [], range: OIPlotRange = .all,
         currentPrice: Double? = nil) {
        rows = distribution.rows
        maximum = max(1, rows.map { max($0.put, $0.call) }.max() ?? 1)
        let gaps = zip(rows, rows.dropFirst()).map { $1.strike - $0.strike }.filter { $0 > 0 }.sorted()
        step = gaps.isEmpty ? max(0.01, (rows.first?.strike ?? 1) * 0.01) : gaps[(gaps.count - 1) / 2]
        var low = rows.first?.strike ?? 0
        var high = rows.last?.strike ?? 1
        let total = rows.reduce(0) { $0 + $1.put + $1.call }
        if range == .main {
            // Zoomed in means the band the reader came for: the two walls with
            // the price between them. A cumulative 5%–95% cut used to stand
            // here, but a chain's tails are heavy — on META it kept 210 of 262
            // strikes, so zooming in changed almost nothing.
            var lower: Double?
            var upper: Double?
            for wall in distribution.putWalls + distribution.callWalls {
                lower = min(lower ?? wall.strike, wall.strike)
                upper = max(upper ?? wall.strike, wall.strike)
            }
            if let currentPrice, currentPrice.isFinite, currentPrice > 0 {
                lower = min(lower ?? currentPrice, currentPrice)
                upper = max(upper ?? currentPrice, currentPrice)
            }
            if let lower, let upper {
                low = lower
                high = upper
            } else if total > 0 {
                // No walls and no quote to centre on: the middle half of the
                // open interest, which is still tighter than the whole chain.
                var cumulative = 0.0
                var quarter: Double?
                for row in rows {
                    cumulative += row.put + row.call
                    if quarter == nil && cumulative >= total * 0.25 { quarter = row.strike }
                    if cumulative >= total * 0.75 { high = row.strike; break }
                }
                low = quarter ?? low
            }
            // Room to read either side of the band rather than clipping it.
            let margin = max((high - low) * 0.08, step * 3)
            low -= margin
            high += margin
        }
        let span = max(step * 2, high - low)
        // Nearby quotes help orient the reader. Remote references belong in the
        // edge notice/summary, and cost never determines the OI viewport.
        if let currentPrice, currentPrice.isFinite, currentPrice > 0,
           currentPrice >= low - span * 0.25, currentPrice <= high + span * 0.25 {
            low = min(low, currentPrice); high = max(high, currentPrice)
        }
        for marker in markers where marker.isFinite && marker > 0 {
            low = min(low, marker); high = max(high, marker)
        }
        // A thin margin: the strike range, and so the waves, fill the height.
        // Never less than a wave's tapered end cap, which reaches half a
        // strike step beyond the outermost strike.
        let padding = max(step * 0.75, (high - low) * 0.04)
        domain = max(0, low - padding)...(high + padding)
    }

    var visibleRows: [OIDistribution.Row] { rows.filter { domain.contains($0.strike) } }
    var outsideFraction: Double {
        let total = rows.reduce(0) { $0 + $1.put + $1.call }
        guard total > 0 else { return 0 }
        return rows.filter { !domain.contains($0.strike) }.reduce(0) { $0 + $1.put + $1.call } / total
    }

    func nearest(to price: Double) -> OIDistribution.Row? {
        guard price.isFinite else { return nil }
        return visibleRows.min { abs($0.strike - price) < abs($1.strike - price) }
    }

    func segments(for side: Side) -> [[Vertex]] {
        var result: [[Vertex]] = []
        var run: [OIDistribution.Row] = []
        func flush() {
            guard let first = run.first, let last = run.last else { return }
            let points = run.map { Vertex(strike: $0.strike, width: (side == .put ? $0.put : $0.call) / maximum) }
            // End caps taper to zero within half a nominal strike interval.
            result.append([Vertex(strike: first.strike - step / 2, width: 0)] + points +
                          [Vertex(strike: last.strike + step / 2, width: 0)])
            run.removeAll(keepingCapacity: true)
        }
        for row in rows {
            let observed = side == .put ? row.hasPut : row.hasCall
            if !observed { flush(); continue }
            if let previous = run.last, row.strike - previous.strike > step * 1.5 { flush() }
            run.append(row)
        }
        flush()
        return result
    }

    /// Monotone cubic tangents keep a continuous derivative at observed strikes
    /// without shifting peaks, averaging widths, or overshooting the source OI.
    static func edgeSlopes(_ vertices: [Vertex]) -> [Double] {
        guard vertices.count > 1 else { return vertices.map { _ in 0 } }
        let gaps = zip(vertices, vertices.dropFirst()).map { $1.strike - $0.strike }
        let slopes = zip(vertices, vertices.dropFirst()).enumerated().map { index, pair in
            (pair.1.width - pair.0.width) / gaps[index]
        }
        var result = [slopes[0]]
        for index in 1..<(vertices.count - 1) {
            let before = slopes[index - 1], after = slopes[index]
            if before * after <= 0 { result.append(0); continue }
            let w1 = 2 * gaps[index] + gaps[index - 1]
            let w2 = gaps[index] + 2 * gaps[index - 1]
            result.append((w1 + w2) / (w1 / before + w2 / after))
        }
        result.append(slopes.last!)
        return result
    }

    /// Clip axis-aligned overlay lines around every visible glass label. The
    /// clearance includes the stroke radius so neither its edge nor short
    /// fragments can show through or hug a pill when markers crowd together.
    static func uncoveredLineIntervals(from start: CGFloat, to end: CGFloat, at cross: CGFloat,
                                       vertical: Bool = false, excluding frames: [CGRect],
                                       lineWidth: CGFloat = 1) -> [ClosedRange<CGFloat>] {
        let lower = min(start, end), upper = max(start, end)
        guard upper - lower >= 8 else { return [] }
        let clearance = 4 + lineWidth / 2
        var runs = [lower...upper]
        for frame in frames {
            let box = frame.insetBy(dx: -clearance, dy: -clearance)
            let crossRange = vertical ? box.minX...box.maxX : box.minY...box.maxY
            guard crossRange.contains(cross) else { continue }
            let cut = vertical ? box.minY...box.maxY : box.minX...box.maxX
            runs = runs.flatMap { run -> [ClosedRange<CGFloat>] in
                guard cut.upperBound > run.lowerBound, cut.lowerBound < run.upperBound else { return [run] }
                var parts: [ClosedRange<CGFloat>] = []
                if cut.lowerBound - run.lowerBound >= 8 { parts.append(run.lowerBound...cut.lowerBound) }
                if run.upperBound - cut.upperBound >= 8 { parts.append(cut.upperBound...run.upperBound) }
                return parts
            }
        }
        return runs
    }

    /// Keep labels within a lane, separated by their full height. Rules stay at
    /// their actual strike and a short leader connects any displaced label.
    static func labelPositions(_ desired: [Double], height: Double, spacing: Double = 28) -> [Double] {
        guard !desired.isEmpty else { return [] }
        let inset = spacing / 2
        var positions = desired.map { min(height - inset, max(inset, $0)) }
        for index in positions.indices.dropFirst() { positions[index] = max(positions[index], positions[index - 1] + spacing) }
        if let last = positions.last, last > height - inset {
            positions[positions.count - 1] = height - inset
            for index in positions.indices.dropLast().reversed() {
                positions[index] = min(positions[index], positions[index + 1] - spacing)
            }
        }
        return positions
    }
}

// Yahoo contract timestamps encode the expiry DATE at UTC midnight, not New York midnight.
