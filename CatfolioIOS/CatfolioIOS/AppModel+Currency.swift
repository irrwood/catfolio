import Foundation

/// The home figures read in the reader's currency, exchange rate included.
/// The chart takes each day at that day's rate and the day's figures fold in
/// what the rate did since the previous session, so the chart's 1D and the
/// Today card count the same thing.
extension AppModel {
    /// The home chart as the reader's currency saw it, once that currency's
    /// history is in; the dollar figures as they are until then.
    func displayedPortfolioChart(_ chart: PortfolioChartResponse,
                                 currency: DisplayCurrency = .current) -> PortfolioChartResponse {
        guard let history = displayCurrencyHistory(for: chart, currency: currency),
              let current = LocalPortfolioEngine.usdRate(for: currency.rawValue) else { return chart }
        return chart.rebased(to: history, current: current, today: DayDateCodec.string(from: .now))
    }

    /// The reader's currency's history, once it reaches back to the chart's
    /// first day; nil for a dollar reader.
    func displayCurrencyHistory(for chart: PortfolioChartResponse,
                                currency: DisplayCurrency = .current) -> CurrencyHistory? {
        guard currency != .usd, let history = currencyHistories[currency.rawValue] else { return nil }
        let first = chart.positionHistory.rows.first?.dateText ?? chart.currentPoint.dateText
        return history.from <= first ? history : nil
    }

    /// The session the home chart's 1D starts from.
    var previousSessionDate: String? {
        guard let sessions = portfolioChart?.marketDates?.sorted(), sessions.count >= 2 else { return nil }
        return sessions[sessions.count - 2]
    }

    var currencyDayMoves: CurrencyDayMoves? {
        let display = DisplayCurrency.current.rawValue
        guard let since = previousSessionDate,
              let history = display == "USD" ? CurrencyHistory(currency: "USD", closes: [:]) : currencyHistories[display]
        else { return nil }
        let codes = Set(currencyHistories.keys).union([display])
        let now = codes.reduce(into: [String: Double]()) { result, code in
            result[code] = LocalPortfolioEngine.usdRate(for: code)
        }
        return CurrencyDayMoves(since: since, display: history, others: currencyHistories, now: now)
    }

    /// Each holding's change since the session the home chart's 1D starts
    /// from, in the reader's currency: its price move and what the exchange
    /// rate did, together. A market that has not opened since then has not
    /// moved, so London trading in the morning does not pair with New York's
    /// close of the day before.
    var holdingDayReturns: [String: Double] {
        guard let since = previousSessionDate else { return holdingDailyChanges }
        let moves = currencyDayMoves
        var result = holdingDailyChanges
        for holding in holdings {
            let key = holding.ticker.uppercased()
            guard let change = Self.change(of: holding, closes: holdingRecentCloses[key], since: since)
                    ?? holdingDailyChanges[key] ?? holding.todayChangePercent else { continue }
            result[key] = moves?.change(change, currency: holding.quoteCurrency ?? "USD") ?? change
        }
        return result
    }

    /// A holding's change in percent from the close on or before `date` to
    /// its own quote — the price its value is shown at, so the day's figure
    /// and the holding's value never come from two different moments.
    static func change(of holding: Holding, closes: [String: Double]?, since date: String) -> Double? {
        guard let closes, let base = close(in: closes, onOrBefore: date) else { return nil }
        guard holding.quotePrice.isFinite, holding.quotePrice > 0 else { return change(in: closes, since: date) }
        let scale = LocalMarketDataClient.priceScale(ticker: holding.ticker, currency: holding.quoteCurrency ?? "USD",
            referencePrice: holding.quotePrice, marketPrice: base)
        let now = holding.quotePrice / scale
        guard now.isFinite, now > 0 else { return nil }
        return (now / base - 1) * 100
    }

    /// The change in percent from the close on or before `date` to the
    /// latest close.
    static func change(in closes: [String: Double], since date: String) -> Double? {
        guard let base = close(in: closes, onOrBefore: date),
              let latest = closes.filter({ $0.value.isFinite && $0.value > 0 }).max(by: { $0.key < $1.key })?.value
        else { return nil }
        return (latest / base - 1) * 100
    }

    static func close(in closes: [String: Double], onOrBefore date: String) -> Double? {
        closes.filter { $0.key <= date && $0.value.isFinite && $0.value > 0 }.max { $0.key < $1.key }?.value
    }

    /// What `currencyHistories` should hold, from when: the display
    /// currency back to the chart's first day, the holdings' other
    /// currencies for the last few weeks.
    var wantedCurrencyHistories: [String: String] {
        let display = DisplayCurrency.current.rawValue
        let recent = DayDateCodec.string(from: Date.now.addingTimeInterval(-21 * 86_400))
        var wanted: [String: String] = [:]
        if display != "USD" {
            let first = (portfolioChart?.positionHistory.rows.first?.dateText)
                .flatMap(DayDateCodec.date(from:))
                .map { DayDateCodec.string(from: $0.addingTimeInterval(-7 * 86_400)) }
            wanted[display] = min(first ?? recent, recent)
        }
        for holding in holdings {
            let code = CurrencyHistory.normalized(holding.quoteCurrency ?? "USD")
            guard code != "USD", wanted[code] == nil else { continue }
            wanted[code] = recent
        }
        return wanted
    }

    /// `cachedOnly` reads what is already on disk, at once: the chart waits
    /// for that rather than draw the dollar figures and then redraw.
    func loadCurrencyHistories(cachedOnly: Bool = false, forceRefresh: Bool = false) async {
        let wanted = wantedCurrencyHistories
        guard !wanted.isEmpty else { return }
        let client = LocalMarketDataClient()
        let today = DayDateCodec.string(from: .now)
        let loaded = await withTaskGroup(of: CurrencyHistory?.self) { group in
            for (code, start) in wanted {
                group.addTask {
                    guard let closes = try? await client.historicalCloses(
                        symbol: "\(code)USD=X", from: start, to: today,
                        cachedOnly: cachedOnly, forceRefresh: forceRefresh),
                          !closes.isEmpty else { return nil }
                    return CurrencyHistory(currency: code, closes: closes, from: start)
                }
            }
            var result: [CurrencyHistory] = []
            for await history in group { if let history { result.append(history) } }
            return result
        }
        guard !Task.isCancelled else { return }
        for history in loaded where currencyHistories[history.currency] != history {
            currencyHistories[history.currency] = history
        }
    }
}
