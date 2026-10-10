import SwiftUI
import UIKit

final class CostMarketPreparedSource: @unchecked Sendable {
    let points: [CostMarketPlotPoint]
    let lastDate: Date?
    let previousTradingDate: Date?
    let accountRowsByDate: [String: ChartPoint]
    let accountNAV: [String: Double]?

    init(response: PortfolioChartResponse) {
        accountNAV = response.accountNAV
        accountRowsByDate = response.accountNAV == nil ? [:] : Dictionary(
            response.positionHistory.rows.map { ($0.dateText, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        // The latest observation may replace a same-day historical point or
        // extend it. Never let a nonempty history hide the current endpoint.
        var source = response.positionHistory.rows
        if response.currentPoint.marketValue.isFinite, response.currentPoint.cost.isFinite {
            source.removeAll { $0.dateText == response.currentPoint.dateText }
            source.append(response.currentPoint)
        }
        points = source.compactMap { row -> CostMarketPlotPoint? in
            guard row.marketValue.isFinite, row.cost.isFinite,
                  let date = DayDateCodec.date(from: row.dateText) else { return nil }
            return CostMarketPlotPoint(
                dateText: row.dateText,
                date: date,
                marketValue: row.marketValue,
                cost: row.cost
            )
        }.sorted { $0.date < $1.date }
        lastDate = points.last?.date
        if let sessions = response.marketDates?.sorted(), sessions.count >= 2 {
            let baseline = sessions[sessions.count - 2]
            previousTradingDate = points.last(where: { $0.dateText <= baseline })?.date
                ?? points.first?.date
        } else {
            previousTradingDate = points.dropLast().last?.date
        }
    }
}

final class CostMarketPreparedData: @unchecked Sendable {
    private let ranges: [ChartTimeRange: CostMarketRangeData]
    private let accountRowsByDate: [String: ChartPoint]
    private let accountNAV: [String: Double]?

    init(
        source: CostMarketPreparedSource,
        requestedRanges: [ChartTimeRange] = ChartTimeRange.allCases
    ) {
        let points = source.points
        accountRowsByDate = source.accountRowsByDate
        accountNAV = source.accountNAV

        guard let last = source.lastDate else {
            ranges = [:]
            return
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        ranges = Dictionary(uniqueKeysWithValues: requestedRanges.map { range in
            // Portfolio history is daily rather than intraday. Use the latest
            // two trading snapshots so 1D still shows the day-over-day move
            // instead of collapsing to an unhelpful single point.
            var filtered = points.filter {
                range.includes(
                    $0.date,
                    through: last,
                    previousTradingDate: source.previousTradingDate,
                    calendar: calendar
                )
            }
            // YTD starts at the prior year-end closing valuation.
            if range == .yearToDate, let first = filtered.first,
               let prior = points.last(where: { $0.date < first.date }) {
                filtered.insert(prior, at: 0)
            }
            return (range, Self.prepare(filtered))
        })
    }

    func data(for range: ChartTimeRange) -> CostMarketRangeData {
        ranges[range] ?? ranges[.maximum] ?? .empty
    }

    static func shouldReplace(_ cached: CostMarketPreparedData?, with fresh: CostMarketPreparedData) -> Bool {
        !(fresh.data(for: .maximum).rows.count <= 1 && (cached?.data(for: .maximum).rows.count ?? 0) > 1)
    }

    func accountPerformance(from startDate: String, to endDate: String) -> (amount: Double, percentage: Double) {
        guard let accountNAV, let start = accountRowsByDate[startDate],
              let end = accountRowsByDate[endDate], startDate <= endDate,
              let base = accountNAV[startDate], base > 0,
              let last = accountNAV[endDate] else { return (.nan, .nan) }
        return ((end.marketValue - start.marketValue) - (end.cost - start.cost), (last / base - 1) * 100)
    }

    private static func prepare(_ points: [CostMarketPlotPoint]) -> CostMarketRangeData {
        guard !points.isEmpty else { return .empty }
        // Range-dependent decimation changes the curve at shared dates. Keep
        // every daily vertex so the transition's union and the resting path
        // have identical geometry inside the final viewport.

        var minimum = Double.greatestFiniteMagnitude
        var maximum = -Double.greatestFiniteMagnitude
        for point in points {
            minimum = min(minimum, point.marketValue, point.cost)
            maximum = max(maximum, point.marketValue, point.cost)
        }
        let span = max(maximum - minimum, max(abs(minimum), abs(maximum)) * 0.02, 1)
        let padding = span * 0.12
        return CostMarketRangeData(
            rows: points,
            plottedRows: points,
            domain: (minimum < 0 ? minimum - padding : max(0, minimum - padding))...(maximum + padding)
        )
    }
}

struct CostMarketRangeData {
    /// A freshly prepared range gets a fresh identity, while copies of that
    /// range keep it so chart-only state changes reuse its geometry.
    let id = UUID()
    let rows: [CostMarketPlotPoint]
    let plottedRows: [CostMarketPlotPoint]
    let domain: ClosedRange<Double>

    static let empty = CostMarketRangeData(rows: [], plottedRows: [], domain: 0...1)

    func nearest(to date: Date) -> CostMarketPlotPoint? {
        guard !rows.isEmpty else { return nil }
        var lower = 0
        var upper = rows.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if rows[middle].date < date {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        guard lower > 0 else { return rows[0] }
        guard lower < rows.count else { return rows[rows.count - 1] }
        let before = rows[lower - 1]
        let after = rows[lower]
        return abs(before.date.timeIntervalSince(date)) <= abs(after.date.timeIntervalSince(date)) ? before : after
    }
}

struct CostMarketPlotPoint: Identifiable {
    let dateText: String
    let date: Date
    let marketValue: Double
    let cost: Double

    var id: String { dateText }
}

/// Change in the chart's cost-adjusted value, not a ledger-backed TWR/IRR.
/// Inputs share the chart's reporting currency; do not convert either endpoint twice.
func costMarketChange(
    from start: CostMarketPlotPoint, to end: CostMarketPlotPoint
) -> (amount: Double, percentage: Double) {
    let amount = (end.marketValue - start.marketValue) - (end.cost - start.cost)
    return (amount, start.marketValue == 0 ? 0 : amount / start.marketValue * 100)
}
