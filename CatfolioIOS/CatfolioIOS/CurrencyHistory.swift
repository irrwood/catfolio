import Foundation

/// A currency's daily closes against the dollar, so an amount can be read at
/// the rate of its own day.
///
/// The app keeps every amount in US dollars and shows it at today's rate.
/// That is right for a figure about now, but a history converted that way
/// leaves out what the display currency itself did: a pound reader's US
/// shares would neither gain nor lose when the pound moved, while their
/// London shares would, which is the wrong way round.
struct CurrencyHistory: Equatable, Sendable {
    let currency: String
    /// US dollars per unit at each day's close, keyed yyyy-MM-dd.
    let closes: [String: Double]
    /// The day the history was asked for from, yyyy-MM-dd.
    let from: String
    private let dates: [String]

    init(currency: String, closes: [String: Double], from: String = "") {
        self.currency = Self.normalized(currency)
        self.from = from
        self.closes = closes.filter { $0.value.isFinite && $0.value > 0 }
        dates = self.closes.keys.sorted()
    }

    /// Pence trade as pounds: GBX moves with GBP.
    static func normalized(_ currency: String) -> String {
        let code = currency.uppercased()
        return code == "GBX" ? "GBP" : code
    }

    /// The dollar's history is flat.
    var isDollar: Bool { currency == "USD" }

    /// The close on `date`, or the last one before it; before the history
    /// starts, its first.
    func rate(on date: String) -> Double? {
        if isDollar { return 1 }
        guard !dates.isEmpty else { return nil }
        var low = 0
        var high = dates.count
        while low < high {
            let middle = (low + high) / 2
            if dates[middle] <= date { low = middle + 1 } else { high = middle }
        }
        return closes[dates[max(low - 1, 0)]]
    }
}

extension PortfolioChartResponse {
    /// This history as the display currency saw it: each day at that day's
    /// rate, still written in dollars at `current` so the app converts it as
    /// it converts everything else. Deposits count at the rate of the day
    /// they arrived, so a pound paid in stays one pound. Today and later read
    /// at `current` itself, the rate every amount on screen is shown at.
    func rebased(to display: CurrencyHistory, current: Double, today: String) -> PortfolioChartResponse {
        guard !display.isDollar, current.isFinite, current > 0 else { return self }
        func scale(_ date: String) -> Double {
            guard date < today, let rate = display.rate(on: date) else { return 1 }
            return current / rate
        }
        func rebase(_ points: [ChartPoint]) -> [ChartPoint] {
            var rawCost = 0.0
            var cost = 0.0
            return points.sorted { $0.dateText < $1.dateText }.map { point in
                let factor = scale(point.dateText)
                guard point.cost.isFinite else {
                    return ChartPoint(dateText: point.dateText, marketValue: point.marketValue * factor, cost: point.cost)
                }
                cost += (point.cost - rawCost) * factor
                rawCost = point.cost
                return ChartPoint(dateText: point.dateText, marketValue: point.marketValue * factor, cost: cost)
            }
        }
        let rows = rebase(positionHistory.rows)
        // The latest point may stand in for its day's row with fresher
        // figures; it follows the rows before it.
        let latest = rebase(positionHistory.rows.filter { $0.dateText < currentPoint.dateText } + [currentPoint]).last!
        return PortfolioChartResponse(positionCount: positionCount,
            positionHistory: PositionHistory(available: positionHistory.available, rows: rows),
            currentPoint: latest, warning: warning,
            accountNAV: accountNAV.map { $0.reduce(into: [:]) { $0[$1.key] = $1.value * scale($1.key) } },
            dataIssues: dataIssues, marketDates: marketDates)
    }
}

/// What the exchange rate did to a holding since the previous session, read
/// in the display currency: the home chart's 1D counts it, and so do the
/// day's figures beside it.
struct CurrencyDayMoves: Sendable {
    /// The previous session, yyyy-MM-dd: the home chart's 1D baseline.
    let since: String
    let display: CurrencyHistory
    /// Other currencies the holdings are priced in.
    let others: [String: CurrencyHistory]
    /// US dollars per unit now, keyed by normalized code.
    let now: [String: Double]

    /// 1.01 when the rate alone added 1% to a holding priced in `currency`.
    func factor(for currency: String) -> Double? {
        let code = CurrencyHistory.normalized(currency)
        guard code != display.currency else { return 1 }
        let history = code == "USD" ? CurrencyHistory(currency: "USD", closes: [:]) : others[code]
        guard let unitNow = code == "USD" ? 1 : now[code],
              let displayNow = display.isDollar ? 1 : now[display.currency],
              let unitThen = history?.rate(on: since),
              let displayThen = display.rate(on: since),
              unitNow > 0, displayNow > 0 else { return nil }
        let value = (unitNow / displayNow) / (unitThen / displayThen)
        return value.isFinite && value > 0 ? value : nil
    }

    /// A day's change in percent, with what the rate did folded in.
    func change(_ percent: Double, currency: String) -> Double {
        guard let factor = factor(for: currency) else { return percent }
        return ((1 + percent / 100) * factor - 1) * 100
    }
}
