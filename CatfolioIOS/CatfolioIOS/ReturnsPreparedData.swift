import SwiftUI

struct ReturnsDisplayData {
    let id = UUID()
    // Keep the animation revision with the plotted points. A picker change can
    // render before the new range's points have been prepared.
    let transitionKey: String
    let rangeTransitionKey: String
    let points: [ReturnsSeriesPoint]
    let grouped: [String: [ReturnsSeriesPoint]]
    let dates: [Date]
    let valuesByDate: [Date: [String: Double]]
    let returnsByDate: [Date: [String: Double]]
    let portfolioByDate: [Date: ReturnsSeriesPoint]
    let unavailableBenchmarks: [String]
    let domain: ClosedRange<Double>

    var hasDrawableLine: Bool {
        grouped.values.contains { $0.count > 1 }
    }

    static let empty = ReturnsDisplayData(
        transitionKey: "",
        rangeTransitionKey: "",
        points: [],
        grouped: [:],
        dates: [],
        valuesByDate: [:],
        returnsByDate: [:],
        portfolioByDate: [:],
        unavailableBenchmarks: ComparisonBenchmarkCatalog.symbols,
        domain: 0...1
    )
}

struct ReturnsPreparedRange {
    let points: [ReturnsSeriesPoint]
    let returnPoints: [ReturnsSeriesPoint]
    let unavailableBenchmarks: [String]

    static let empty = ReturnsPreparedRange(
        points: [],
        returnPoints: [],
        unavailableBenchmarks: ComparisonBenchmarkCatalog.symbols
    )
}

final class ReturnsPreparedData: @unchecked Sendable {
    private let cashFlowMatchedRanges: [ChartTimeRange: ReturnsPreparedRange]
    private let twrRanges: [ChartTimeRange: ReturnsPreparedRange]
    private let mwrRanges: [ChartTimeRange: ReturnsPreparedRange]
    private let cashFlowValuesByDate: [Date: [String: Double]]
    private let cashFlowDates: [Date]

    init(comparison: ComparisonResponse) {
        let cashFlowMatchedPoints = Self.makePoints(
            dates: comparison.dates,
            portfolio: comparison.portfolio,
            benchmarks: comparison.benchmarks,
            transform: { $0 }
        )
        let cashFlowReturnPoints = Self.makePoints(
            dates: comparison.dates,
            portfolio: comparison.cashFlowPortfolioReturns ?? [],
            benchmarks: comparison.cashFlowBenchmarkReturns ?? [:],
            transform: { $0 }
        )
        let twrPoints = Self.makePoints(
            dates: comparison.twrDates ?? [],
            portfolio: comparison.twrPortfolio ?? [],
            benchmarks: comparison.twrBenchmarks ?? [:],
            transform: { ($0 - 1) * 100 }
        )
        var valuesByDate: [Date: [String: Double]] = [:]
        for point in cashFlowMatchedPoints {
            valuesByDate[point.date, default: [:]][point.series] = point.value
        }
        cashFlowValuesByDate = valuesByDate
        cashFlowDates = valuesByDate.keys.sorted()
        cashFlowMatchedRanges = Self.makeRanges(
            from: cashFlowMatchedPoints,
            suppliedReturns: cashFlowReturnPoints,
            mode: .cashFlowMatched
        )
        twrRanges = Self.makeRanges(from: twrPoints, suppliedReturns: [], mode: .twr)
        mwrRanges = Self.makeMWRRanges(ledger: comparison.mwrLedger)
    }

    func cashFlowValue(for series: String, on date: Date?) -> Double? {
        guard let date else { return nil }
        if let exactValue = cashFlowValuesByDate[date]?[series] {
            return exactValue
        }
        guard !cashFlowDates.isEmpty else { return nil }
        var lower = 0
        var upper = cashFlowDates.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if cashFlowDates[middle] < date { lower = middle + 1 } else { upper = middle }
        }
        let nearestDate: Date
        if lower == 0 {
            nearestDate = cashFlowDates[0]
        } else if lower == cashFlowDates.count {
            nearestDate = cashFlowDates[cashFlowDates.count - 1]
        } else {
            let before = cashFlowDates[lower - 1]
            let after = cashFlowDates[lower]
            nearestDate = abs(before.timeIntervalSince(date)) <= abs(after.timeIntervalSince(date))
                ? before : after
        }
        return cashFlowValuesByDate[nearestDate]?[series]
    }

    func displayData(
        mode: ReturnsChartMode,
        range: ChartTimeRange,
        visibleSeries: Set<String>
    ) -> ReturnsDisplayData {
        let ranges: [ChartTimeRange: ReturnsPreparedRange]
        switch mode {
        case .cashFlowMatched: ranges = cashFlowMatchedRanges
        case .twr: ranges = twrRanges
        case .mwr: ranges = mwrRanges
        }
        guard let preparedRange = ranges[range], !preparedRange.points.isEmpty else { return .empty }

        var grouped: [String: [ReturnsSeriesPoint]] = [:]
        var points: [ReturnsSeriesPoint] = []
        let allGrouped = Dictionary(grouping: preparedRange.points, by: \.series)
        for series in ReturnsSeriesStyle.order where visibleSeries.contains(series) {
            guard let values = allGrouped[series], !values.isEmpty else { continue }
            grouped[series] = values
            points.append(contentsOf: values)
        }

        let dates = Array(Set(points.map(\.date))).sorted()
        var valuesByDate: [Date: [String: Double]] = [:]
        for point in preparedRange.points {
            valuesByDate[point.date, default: [:]][point.series] = point.value
        }
        var returnsByDate: [Date: [String: Double]] = [:]
        for point in preparedRange.returnPoints {
            returnsByDate[point.date, default: [:]][point.series] = point.value
        }
        let portfolioByDate = Dictionary(uniqueKeysWithValues:
            (allGrouped[ReturnsSeriesStyle.portfolio] ?? []).map { ($0.date, $0) }
        )
        let values = points.map(\.value)
        let domain: ClosedRange<Double>
        if let minimum = values.min(), let maximum = values.max() {
            let padding = max((maximum - minimum) * 0.12, max(abs(minimum), abs(maximum)) * 0.02, 1)
            domain = mode != .cashFlowMatched
                ? (minimum - padding)...(maximum + padding)
                : max(0, minimum - padding)...(maximum + padding)
        } else {
            domain = 0...1
        }

        return ReturnsDisplayData(
            transitionKey: "\(mode.rawValue)|\(range.rawValue)|\(visibleSeries.sorted().joined(separator: ","))",
            rangeTransitionKey: range.rawValue,
            points: points,
            grouped: grouped,
            dates: dates,
            valuesByDate: valuesByDate,
            returnsByDate: returnsByDate,
            portfolioByDate: portfolioByDate,
            unavailableBenchmarks: preparedRange.unavailableBenchmarks,
            domain: domain
        )
    }

    private static func makePoints(
        dates: [String],
        portfolio: [Double?],
        benchmarks: [String: [Double?]],
        transform: (Double) -> Double
    ) -> [ReturnsSeriesPoint] {
        let count = min(dates.count, portfolio.count)
        guard count > 0 else { return [] }
        let indices = Array(0..<count)
        let parsedDates = Dictionary(uniqueKeysWithValues: indices.compactMap { index in
            DayDateCodec.date(from: dates[index]).map { (index, $0) }
        })

        var result: [ReturnsSeriesPoint] = []
        for series in ReturnsSeriesStyle.order {
            for index in indices {
                guard let date = parsedDates[index] else { continue }
                let value: Double?
                if series == ReturnsSeriesStyle.portfolio {
                    value = portfolio[index]
                } else if let seriesValues = benchmarks[series], index < seriesValues.count {
                    value = seriesValues[index]
                } else {
                    value = nil
                }
                if let value {
                    result.append(ReturnsSeriesPoint(series: series, date: date, value: transform(value)))
                }
            }
        }
        return result
    }

    private static func makeMWRRanges(ledger: AccountMWRLedger?) -> [ChartTimeRange: ReturnsPreparedRange] {
        guard let ledger, let lastText = ledger.dates.last, let last = DayDateCodec.date(from: lastText) else {
            return Dictionary(uniqueKeysWithValues: ChartTimeRange.allCases.map { ($0, .empty) })
        }
        let dates = ledger.dates.compactMap { DayDateCodec.date(from: $0) }
        guard dates.count == ledger.dates.count else { return [:] }
        return Dictionary(uniqueKeysWithValues: ChartTimeRange.allCases.map { range in
            guard let first = dates.firstIndex(where: {
                range.includes($0, through: last, previousTradingDate: dates.dropLast().last,
                    calendar: ChartTimeRange.financeCalendar)
            }) else { return (range, .empty) }
            let values = ledger.returns(startIndex: max(0, first - 1))
            let points = makePoints(dates: values.dates, portfolio: values.portfolio,
                benchmarks: values.benchmarks, transform: { $0 * 100 })
                .filter { $0.date >= dates[first] }
            return (range, preparedRange(from: points, suppliedReturns: [], mode: .mwr))
        })
    }

    private static func makeRanges(
        from points: [ReturnsSeriesPoint],
        suppliedReturns: [ReturnsSeriesPoint],
        mode: ReturnsChartMode
    ) -> [ChartTimeRange: ReturnsPreparedRange] {
        guard let lastDate = points.map(\.date).max() else {
            return Dictionary(uniqueKeysWithValues: ChartTimeRange.allCases.map { ($0, .empty) })
        }
        let calendar = ChartTimeRange.financeCalendar
        let tradingDates = Array(Set(points.map(\.date))).sorted()
        let previousTradingDate = tradingDates.dropLast().last
        return Dictionary(uniqueKeysWithValues: ChartTimeRange.allCases.map { range in
            let filtered = points.filter {
                range.includes(
                    $0.date,
                    through: lastDate,
                    previousTradingDate: previousTradingDate,
                    calendar: calendar
                )
            }
            let filteredReturns = suppliedReturns.filter {
                range.includes(
                    $0.date,
                    through: lastDate,
                    previousTradingDate: previousTradingDate,
                    calendar: calendar
                )
            }
            return (range, preparedRange(from: filtered, suppliedReturns: filteredReturns, mode: mode))
        })
    }

    private static func preparedRange(
        from points: [ReturnsSeriesPoint],
        suppliedReturns: [ReturnsSeriesPoint],
        mode: ReturnsChartMode
    ) -> ReturnsPreparedRange {
        guard !points.isEmpty else { return .empty }
        let grouped = Dictionary(grouping: points, by: \.series)
        let displayPoints: [ReturnsSeriesPoint]
        let returnPoints: [ReturnsSeriesPoint]
        if mode == .cashFlowMatched {
            displayPoints = points
            returnPoints = suppliedReturns
        } else if mode == .twr {
            returnPoints = ReturnsSeriesStyle.order.flatMap { series -> [ReturnsSeriesPoint] in
                guard let values = grouped[series]?.sorted(by: { $0.date < $1.date }),
                      let first = values.first?.value else { return [] }
                let firstNAV = 1 + first / 100
                guard firstNAV != 0 else { return [] }
                return values.map { point in
                    ReturnsSeriesPoint(
                        series: series,
                        date: point.date,
                        value: (1 + point.value / 100) / firstNAV - 1
                    )
                }
            }
            displayPoints = returnPoints.map { point in
                ReturnsSeriesPoint(
                    series: point.series,
                    date: point.date,
                    value: point.value * 100
                )
            }
        } else {
            displayPoints = points
            returnPoints = points.map { point in
                ReturnsSeriesPoint(
                    series: point.series,
                    date: point.date,
                    value: point.value / 100
                )
            }
        }
        let available = Set(displayPoints.map(\.series))
        return ReturnsPreparedRange(
            points: sampled(displayPoints),
            returnPoints: returnPoints,
            unavailableBenchmarks: ComparisonBenchmarkCatalog.symbols.filter { !available.contains($0) }
        )
    }

    private static func sampled(_ points: [ReturnsSeriesPoint]) -> [ReturnsSeriesPoint] {
        let grouped = Dictionary(grouping: points, by: \.series)
        let portfolioDates = Array(Set(
            (grouped[ReturnsSeriesStyle.portfolio] ?? []).map(\.date)
        )).sorted()
        let sourceDates = portfolioDates.isEmpty
            ? Array(Set(points.map(\.date))).sorted()
            : portfolioDates

        guard sourceDates.count > 100 else {
            return ReturnsSeriesStyle.order.flatMap { series in
                (grouped[series] ?? []).sorted { $0.date < $1.date }
            }
        }

        let step = max(1, Int(ceil(Double(sourceDates.count) / 100)))
        var sampledDates = Set(sourceDates.enumerated().compactMap { index, date in
            index.isMultiple(of: step) ? date : nil
        })
        if let lastDate = sourceDates.last {
            sampledDates.insert(lastDate)
        }

        return ReturnsSeriesStyle.order.flatMap { series -> [ReturnsSeriesPoint] in
            guard let values = grouped[series] else { return [] }
            return values
                .filter { sampledDates.contains($0.date) }
                .sorted { $0.date < $1.date }
        }
    }
}

struct ReturnsSeriesPoint: Identifiable {
    let series: String
    let date: Date
    let value: Double

    var id: String { "\(series)-\(date.timeIntervalSinceReferenceDate)" }
}
