import Foundation
import CryptoKit
import FoundationModels
import OSLog

struct LocalMarketDataClient {
    static let yahooSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = URLCache(
            memoryCapacity: 24 * 1_024 * 1_024,
            diskCapacity: 120 * 1_024 * 1_024
        )
        return URLSession(configuration: configuration.simulatingOffline())
    }()

    struct YahooChartResponse: Decodable {
        struct Chart: Decodable {
            let result: [Result]?
            let error: YahooError?
        }

        struct Result: Decodable {
            struct Meta: Decodable {
                let currency: String?
                let tradingPeriods: YahooTradingPeriods?
                let currentTradingPeriod: YahooCurrentTradingPeriods?

                func sessionWindow(at date: Date) -> MarketSessionWindow? {
                    (tradingPeriods?.windows ?? []).first { $0.contains(date) }
                        ?? currentTradingPeriod?.windows.first { $0.contains(date) }
                }
            }
            let meta: Meta?
            let timestamp: [Int]?
            let indicators: Indicators
            /// Present when the request asks for `div` events.
            let events: Events?
        }

        struct Events: Decodable {
            struct Dividend: Decodable {
                let amount: Double
                let date: Int
            }
            let dividends: [String: Dividend]?
        }

        struct Indicators: Decodable {
            let quote: [Quote]?
            let adjclose: [AdjustedClose]?
        }

        struct Quote: Decodable {
            let close: [Double?]?
            let high: [Double?]?
            let low: [Double?]?
            let volume: [Double?]?
        }

        struct AdjustedClose: Decodable {
            let adjclose: [Double?]?
        }

        struct YahooError: Decodable {
            let code: String?
            let description: String?
        }

        let chart: Chart
    }

    struct MassiveAggregatesResponse: Decodable {
        struct Aggregate: Decodable {
            let close: Double
            let high: Double
            let low: Double
            let timestamp: Int64
            let volume: Double

            enum CodingKeys: String, CodingKey {
                case close = "c"
                case high = "h"
                case low = "l"
                case timestamp = "t"
                case volume = "v"
            }
        }

        let status: String?
        let results: [Aggregate]?
        let error: String?
        let message: String?
    }

    func portfolioChart(
        document: LocalPortfolioDocument,
        cachedOnly: Bool = false,
        forceRefresh: Bool = false
    ) async throws -> PortfolioChartResponse {
        if document.isPublicDisclosure, let current = document.snapshots.last {
            let rows = document.snapshots.map { ChartPoint(dateText: $0.date, marketValue: $0.marketValueUSD, cost: $0.costUSD) }
            return PortfolioChartResponse(positionCount: document.positions.count,
                positionHistory: PositionHistory(available: rows.count > 1, rows: rows),
                currentPoint: ChartPoint(dateText: current.date, marketValue: current.marketValueUSD, cost: current.costUSD),
                warning: nil)
        }
        if document.isSynthetic == true { return try LocalPortfolioEngine.presentation(for: document).1 }
        do {
            let account = try await tolerantAccountSeries(document: document,
                to: DayDateCodec.string(from: Date()), cachedOnly: cachedOnly, includeBenchmarks: false,
                homeValuation: true, forceRefresh: forceRefresh)
            guard let ledger = account.ledger else { throw LocalServiceError.noHistoricalPrices }
            var response = PortfolioChartResponse.accountHistory(ledger: ledger, nav: account.portfolio, positionCount: document.positions.count,
                                   assumptions: account.assumptions)
            response.marketDates = account.marketDates
            return response
        } catch {
            let reason = error.localizedDescription.replacingOccurrences(of: "TWR：", with: "")
            // Last resort, still a chart: today's positions backcast at
            // each day's close against what they cost, as before the ledger.
            if let backcast = try? await currentOpenPositionsHistory(document: document, end: DayDateCodec.string(from: Date()), cachedOnly: cachedOnly, forceRefresh: forceRefresh),
               let last = backcast.rows.last, backcast.rows.count > 1 {
                var response = PortfolioChartResponse(positionCount: document.positions.count,
                    positionHistory: PositionHistory(available: true, rows: backcast.rows), currentPoint: last,
                    warning: L10n.text("账户历史暂时无法按流水重建，首页先按当前持仓回推市值显示；蓝线是持仓成本，不是净入金。明细见 设置 → 本机数据 → 数据问题。"))
                response.dataIssues = [L10n.text("账户历史重建失败：\(reason)")] + backcast.warnings
                return response
            }
            if cachedOnly { throw error }
            var response = PortfolioChartResponse.unavailableAccountHistory(positionCount: document.positions.count,
                reason: error.localizedDescription.replacingOccurrences(of: "TWR：", with: "账户历史："))
            response.dataIssues = [L10n.text("账户历史重建失败：\(reason)")]
            return response
        }
    }

    /// The home chart's history, kept apart by holding: each current
    /// holding's shares at each day's close from the day it was first bought,
    /// by the same method as `currentOpenPositionsHistory`, so the holdings of
    /// a day add up to the home chart's value for it. Values are USD, keyed by
    /// upper-cased ticker with accounts added together; `cost` is the same
    /// net-deposit line the home chart draws.
    func holdingValueHistory(
        document: LocalPortfolioDocument,
        cachedOnly: Bool = false
    ) async throws -> HoldingValueHistory {
        guard !document.positions.isEmpty else { throw LocalPortfolioError.noPortfolio }
        let end = DayDateCodec.string(from: Date())
        var earliestBuyDates: [String: String] = [:]
        for transaction in document.transactions ?? [] where transaction.action.uppercased() == "BUY" {
            let key = "\(transaction.accountKey)|\(transaction.ticker.uppercased())"
            earliestBuyDates[key] = min(earliestBuyDates[key] ?? transaction.date, transaction.date)
        }
        let dated = document.positions.compactMap { position -> CurrentOpenBackcastPosition? in
            let key = "\(position.accountKey)|\(position.ticker.uppercased())"
            guard let startDate = position.openedDate ?? earliestBuyDates[key],
                  DayDateCodec.date(from: startDate) != nil else { return nil }
            return CurrentOpenBackcastPosition(position: position, startDate: startDate)
        }
        guard let start = dated.map(\.startDate).min() else { return HoldingValueHistory(rows: [], costs: [:], names: [:]) }

        let symbols = dated.map { Self.yahooSymbol(ticker: $0.position.ticker, currency: $0.position.quoteCurrency) }.uniqued()
        let histories = await historicalCloses(symbols: symbols, from: start, to: end, cachedOnly: cachedOnly)
        var scales: [String: Double] = [:]
        for item in dated {
            let symbol = Self.yahooSymbol(ticker: item.position.ticker, currency: item.position.quoteCurrency)
            guard let latest = histories[symbol]?.max(by: { $0.key < $1.key })?.value else { continue }
            scales[symbol] = Self.priceScale(ticker: item.position.ticker, currency: item.position.quoteCurrency,
                                             referencePrice: item.position.quotePrice, marketPrice: latest)
        }

        var lastClose: [String: Double] = [:]
        var rows: [HoldingValueHistory.Row] = []
        for date in histories.values.flatMap(\.keys).sorted().uniqued() where date >= start {
            var values: [String: Double] = [:]
            var costs: [String: Double] = [:]
            var cost = 0.0
            for item in dated where date >= item.startDate {
                let position = item.position
                let positionCost = try LocalPortfolioEngine.usd(position.shares * position.averageCost, currency: position.currency)
                cost += positionCost
                costs[position.ticker.uppercased(), default: 0] += positionCost
                let symbol = Self.yahooSymbol(ticker: position.ticker, currency: position.quoteCurrency)
                if let close = histories[symbol]?[date] { lastClose[symbol] = close }
                let value = try lastClose[symbol].map {
                    try LocalPortfolioEngine.usd(position.shares * $0 * (scales[symbol] ?? 1), currency: position.quoteCurrency)
                } ?? positionCost
                values[position.ticker.uppercased(), default: 0] += value
            }
            if !values.isEmpty { rows.append(.init(dateText: date, cost: cost, values: values, costs: costs)) }
        }
        var costs: [String: Double] = [:]
        var names: [String: String] = [:]
        for item in dated {
            let key = item.position.ticker.uppercased()
            costs[key, default: 0] += try LocalPortfolioEngine.usd(item.position.shares * item.position.averageCost,
                                                                   currency: item.position.currency)
            names[key] = names[key] ?? item.position.name
        }
        return HoldingValueHistory(rows: rows, costs: costs, names: names)
    }

    /// Today's share counts held through the whole window, priced at each
    /// day's close. Unlike `holdingValueHistory`, nothing enters on its
    /// purchase date, so a buy never reads as a rise: the total's fall from a
    /// high splits exactly into each holding's own fall, which is what the
    /// underwater analysis draws. A holding with no close yet — listed later
    /// than the window starts — sits at its first close until it trades.
    func fixedShareHistory(
        document: LocalPortfolioDocument,
        years: Int = 5,
        cachedOnly: Bool = false
    ) async throws -> HoldingValueHistory {
        let positions = document.positions.filter { $0.shares > 0 }
        guard !positions.isEmpty else { throw LocalPortfolioError.noPortfolio }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let endDate = Date()
        let startDate = calendar.date(byAdding: .year, value: -years, to: endDate) ?? endDate
        let symbols = positions.map { Self.yahooSymbol(ticker: $0.ticker, currency: $0.quoteCurrency) }.uniqued()
        let histories = await historicalCloses(symbols: symbols, from: DayDateCodec.string(from: startDate),
                                               to: DayDateCodec.string(from: endDate), cachedOnly: cachedOnly)
        var scales: [String: Double] = [:]
        var lastClose: [String: Double] = [:]
        for position in positions {
            let symbol = Self.yahooSymbol(ticker: position.ticker, currency: position.quoteCurrency)
            guard let history = histories[symbol], let latest = history.max(by: { $0.key < $1.key })?.value else { continue }
            scales[symbol] = Self.priceScale(ticker: position.ticker, currency: position.quoteCurrency,
                                             referencePrice: position.quotePrice, marketPrice: latest)
            lastClose[symbol] = history.min(by: { $0.key < $1.key })?.value
        }
        var rows: [HoldingValueHistory.Row] = []
        for date in histories.values.flatMap(\.keys).sorted().uniqued() {
            var values: [String: Double] = [:]
            for position in positions {
                let symbol = Self.yahooSymbol(ticker: position.ticker, currency: position.quoteCurrency)
                if let close = histories[symbol]?[date] { lastClose[symbol] = close }
                guard let close = lastClose[symbol] else { continue }
                values[position.ticker.uppercased(), default: 0] += try LocalPortfolioEngine.usd(
                    position.shares * close * (scales[symbol] ?? 1), currency: position.quoteCurrency)
            }
            if !values.isEmpty { rows.append(.init(dateText: date, cost: 0, values: values)) }
        }
        var names: [String: String] = [:]
        for position in positions { names[position.ticker.uppercased()] = names[position.ticker.uppercased()] ?? position.name }
        return HoldingValueHistory(rows: rows, costs: [:], names: names)
    }

    /// Refreshes the quote carried by every locally stored position. The
    /// result is keyed by ticker and quote currency so multiple broker
    /// accounts for the same instrument share one market request while still
    /// preserving their independent quantities and costs.
    func latestQuotes(for positions: [LocalPositionRecord], forceRefresh: Bool = false) async -> [String: ObservedMarketQuote] {
        guard !positions.isEmpty else { return [:] }
        let robinhoodGeneration = await RobinhoodMCPClient.shared.connectionGeneration()
        let robinhoodSymbols = positions.filter { $0.quoteCurrency.uppercased() == "USD" }
            .map { Self.yahooSymbol(ticker: $0.ticker, currency: $0.quoteCurrency) }
        let robinhood = await RobinhoodMCPClient.shared.quotes(symbols: robinhoodSymbols)
        let symbols = positions.map {
            Self.yahooSymbol(ticker: $0.ticker, currency: $0.quoteCurrency)
        }.uniqued().filter { robinhood[$0] == nil }
        var rawPrices = await withTaskGroup(of: (String, ObservedMarketQuote?).self) { group in
            var iterator = symbols.makeIterator()
            let concurrencyLimit = min(8, symbols.count)
            for _ in 0..<concurrencyLimit {
                guard let symbol = iterator.next() else { break }
                group.addTask { (symbol, await latestRawPrice(for: symbol, forceRefresh: forceRefresh)) }
            }

            var result: [String: ObservedMarketQuote] = [:]
            while let (symbol, price) = await group.next() {
                if let price, price.price.isFinite, price.price > 0 {
                    result[symbol] = price
                }
                if let next = iterator.next() {
                    group.addTask { (next, await latestRawPrice(for: next, forceRefresh: forceRefresh)) }
                }
            }
            return result
        }

        // A disconnect/reconnect while another provider is pending invalidates
        // the previous user's in-flight quote batch.
        if await RobinhoodMCPClient.shared.connectionGeneration() == robinhoodGeneration {
            for (symbol, quote) in robinhood {
                rawPrices[symbol] = ObservedMarketQuote(price: quote.price, observedAt: quote.observedAt)
            }
        }

        return positions.reduce(into: [String: ObservedMarketQuote]()) { result, position in
            let symbol = Self.yahooSymbol(
                ticker: position.ticker,
                currency: position.quoteCurrency
            )
            guard let rawPrice = rawPrices[symbol] else { return }
            let adjusted = rawPrice.price * Self.priceScale(
                ticker: position.ticker, currency: position.quoteCurrency,
                referencePrice: position.quotePrice,
                marketPrice: rawPrice.price
            )
            guard adjusted.isFinite, adjusted > 0 else { return }
            result[LocalMarketQuoteKey.make(
                ticker: position.ticker,
                currency: position.quoteCurrency
            )] = ObservedMarketQuote(price: adjusted, observedAt: rawPrice.observedAt)
        }
    }

    /// Overlay only the observed market session, never today's calendar date.
    /// `currency == nil` denotes raw provider units; ledger callers supply
    /// their explicit denomination so GBP and GBX cannot be mixed.
    static func homeCloses(_ closes: [String: Double], symbol: String, currency: String?,
                           positions: [LocalPositionRecord], through end: String,
                           now: Date = .now) -> [String: Double] {
        guard let position = positions.filter({
            yahooSymbol(ticker: $0.ticker, currency: $0.quoteCurrency) == symbol
                && $0.quotePrice.isFinite && $0.quotePrice > 0
                && $0.quoteObservedAt.map { $0 <= now.addingTimeInterval(60)
                    && $0 >= now.addingTimeInterval(-7 * 86_400) } == true
        }).max(by: { $0.quoteObservedAt! < $1.quoteObservedAt! }),
              let observedAt = position.quoteObservedAt else { return closes }
        let day = sessionKey(for: observedAt, symbol: symbol)
        guard day <= end, day >= (closes.keys.max() ?? day) else { return closes }
        let price: Double
        if let currency {
            func unit(_ code: String) -> (String, Double) {
                code == "GBp" || code.uppercased() == "GBX" ? ("GBP", 0.01) : (code.uppercased(), 1)
            }
            let source = unit(position.quoteCurrency), target = unit(currency)
            guard source.0 == target.0 else { return closes }
            price = position.quotePrice * source.1 / target.1
        } else {
            let scale = priceScale(ticker: position.ticker, currency: position.quoteCurrency,
                referencePrice: position.quotePrice, marketPrice: closes[closes.keys.max() ?? ""] ?? position.quotePrice)
            price = position.quotePrice / scale
        }
        var result = closes
        result[day] = price
        return result
    }

    private func latestRawPrice(for symbol: String, forceRefresh: Bool) async -> ObservedMarketQuote? {
        if let security = ChinaSecurity(symbol) {
            guard let quote = try? await ChinaMarketDataClient().quote(security) else { return nil }
            return ObservedMarketQuote(price: quote.price, observedAt: quote.observedAt)
        }
        // Display charts may retain stale bars; a failed live refresh must
        // never turn those bars into a newly observed portfolio quote.
        if let bars = try? await intradayBars(symbol: symbol, forceRefresh: forceRefresh, allowsStaleFallback: false),
           let bar = bars.max(by: { $0.timestamp < $1.timestamp }),
           bar.close.isFinite, bar.close > 0 {
            return ObservedMarketQuote(price: bar.close, observedAt: bar.timestamp)
        }
        guard !Task.isCancelled else { return nil }
        // Some listings have daily data only. Keep its actual trading date,
        // conservatively using midnight because this feed omits the close time.
        // The store rejects this if a newer broker/live quote already exists.
        let now = Date()
        guard let closes = try? await historicalCloses(symbol: symbol,
                from: DayDateCodec.string(from: now.addingTimeInterval(-7 * 86400)),
                to: DayDateCodec.string(from: now), dividendAdjusted: false, forceRefresh: forceRefresh),
              let day = closes.keys.max(), let observedAt = Self.marketDayStart(day, symbol: symbol),
              let price = closes[day], price.isFinite, price > 0 else { return nil }
        return ObservedMarketQuote(price: price, observedAt: observedAt)
    }

    /// Mirrors the desktop/Web chart rule: backcast the currently open broker
    /// positions from their initial fill date using cached daily market prices.
    /// The latest point is calibrated separately from the live broker snapshot.
    /// - Parameter fundingAtEntryValue: for the return views. Each position
    ///   is funded with its market value on the first day it has a price,
    ///   rather than with today's cost basis: a position built up over time
    ///   has an average cost far from the price on the day it began, and
    ///   funding it at that cost books the difference as a gain or loss that
    ///   never happened. The home chart keeps the cost line.
    func currentOpenPositionsHistory(
        document: LocalPortfolioDocument,
        end: String,
        cachedOnly: Bool = false,
        fundingAtEntryValue: Bool = false,
        forceRefresh: Bool = false
    ) async throws -> (rows: [ChartPoint], warnings: [String]) {
        var earliestBuyDates: [String: String] = [:]
        for transaction in document.transactions ?? [] where transaction.action.uppercased() == "BUY" {
            let key = "\(transaction.accountKey)|\(transaction.ticker.uppercased())"
            earliestBuyDates[key] = min(earliestBuyDates[key] ?? transaction.date, transaction.date)
        }
        let datedPositions = document.positions.compactMap { position -> CurrentOpenBackcastPosition? in
            let key = "\(position.accountKey)|\(position.ticker.uppercased())"
            let startDate = position.openedDate ?? earliestBuyDates[key]
            guard let startDate, DayDateCodec.date(from: startDate) != nil else { return nil }
            return CurrentOpenBackcastPosition(position: position, startDate: startDate)
        }
        guard let start = datedPositions.map(\.startDate).min() else {
            return ([], ["持仓缺少首次建仓日期，当前只能显示最新值。"])
        }

        let symbols = datedPositions.map {
            Self.yahooSymbol(ticker: $0.position.ticker, currency: $0.position.quoteCurrency)
        }.uniqued()
        var histories = await historicalCloses(
            symbols: symbols,
            from: start,
            to: end,
            dividendAdjusted: fundingAtEntryValue,
            cachedOnly: cachedOnly,
            forceRefresh: forceRefresh
        )
        if cachedOnly, histories.count != symbols.count {
            throw LocalServiceError.noHistoricalPrices
        }
        if !fundingAtEntryValue {
            for symbol in symbols {
                histories[symbol] = Self.homeCloses(histories[symbol] ?? [:], symbol: symbol,
                    currency: nil, positions: document.positions, through: end)
            }
        }
        let dates = histories.values.flatMap(\.keys).sorted().uniqued()
        guard !dates.isEmpty else {
            return ([], ["暂未读取到当前持仓的历史行情，当前只能显示最新值。"])
        }

        var scales: [String: Double] = [:]
        for item in datedPositions {
            let position = item.position
            let symbol = Self.yahooSymbol(ticker: position.ticker, currency: position.quoteCurrency)
            guard let latest = histories[symbol]?.max(by: { $0.key < $1.key })?.value else { continue }
            scales[symbol] = Self.priceScale(
                ticker: position.ticker, currency: position.quoteCurrency,
                referencePrice: position.quotePrice,
                marketPrice: latest
            )
        }

        var lastClose: [String: Double] = [:]
        // By position: its value on the first day it had a price.
        var entryValues: [Int: Double] = [:]
        var rows: [ChartPoint] = []
        for date in dates where date >= start {
            var marketValue = 0.0
            var cost = 0.0
            var activePositions = 0
            for (index, item) in datedPositions.enumerated() {
                guard date >= item.startDate else { continue }
                let position = item.position
                activePositions += 1
                let positionCost = try LocalPortfolioEngine.usd(
                    position.shares * position.averageCost,
                    currency: position.currency
                )

                let symbol = Self.yahooSymbol(ticker: position.ticker, currency: position.quoteCurrency)
                if let close = histories[symbol]?[date] {
                    lastClose[symbol] = close
                }
                if let close = lastClose[symbol] {
                    let value = try LocalPortfolioEngine.usd(
                        position.shares * close * (scales[symbol] ?? 1),
                        currency: position.quoteCurrency
                    )
                    marketValue += value
                    if fundingAtEntryValue, entryValues[index] == nil { entryValues[index] = value }
                    cost += fundingAtEntryValue ? entryValues[index] ?? value : positionCost
                } else {
                    // No price yet: carried at cost on both sides, so its
                    // wait for a first close is neither a gain nor a loss.
                    marketValue += positionCost
                    cost += positionCost
                }
            }
            if activePositions > 0 {
                rows.append(ChartPoint(dateText: date, marketValue: marketValue, cost: cost))
            }
        }

        var warnings: [String] = []
        let missingSymbols = symbols.filter { histories[$0]?.isEmpty != false }
        if !missingSymbols.isEmpty {
            let preview = missingSymbols.prefix(6).joined(separator: L10n.listSeparator)
            let remainder = missingSymbols.count > 6 ? L10n.text(" 等 \(missingSymbols.count) 个标的") : ""
            warnings.append("\(preview)\(remainder)缺少历史行情，市值暂按成本估算。")
        }
        let missingDateCount = document.positions.count - datedPositions.count
        if missingDateCount > 0 {
            warnings.append("\(missingDateCount) 个持仓缺少首次建仓日期，只计入最新值。")
        }
        return (rows, warnings)
    }

    /// Reads the latest two cached daily closes for every holding in one bounded
    /// batch. This powers the heatmap without issuing a separate volume-profile
    /// request for every tile.
    func dailyChanges(for holdings: [Holding], positions: [LocalPositionRecord] = [], forceRefresh: Bool = false) async -> [String: Double] {
        await recentCloses(for: holdings, positions: positions, forceRefresh: forceRefresh)
            .compactMapValues { Self.latestDailyChange(in: $0) }
    }

    /// Each holding's last two weeks of daily closes, keyed by upper-cased
    /// ticker, the latest session taken from its live quote: what
    /// `dailyChanges` reads, and what a change since a given day is read from.
    func recentCloses(for holdings: [Holding], positions: [LocalPositionRecord] = [], forceRefresh: Bool = false) async -> [String: [String: Double]] {
        guard !holdings.isEmpty else { return [:] }

        let endDate = Date.now
        let startDate = Calendar(identifier: .gregorian).date(
            byAdding: .day,
            value: -14,
            to: endDate
        ) ?? endDate
        let start = DayDateCodec.string(from: startDate)
        let end = DayDateCodec.string(from: endDate)
        let symbols = holdings.map {
            Self.yahooSymbol(ticker: $0.ticker, currency: $0.quoteCurrency ?? "USD")
        }.uniqued()
        let histories = await historicalCloses(symbols: symbols, from: start, to: end, dividendAdjusted: false, forceRefresh: forceRefresh)

        return holdings.reduce(into: [String: [String: Double]]()) { result, holding in
            let symbol = Self.yahooSymbol(
                ticker: holding.ticker,
                currency: holding.quoteCurrency ?? "USD"
            )
            let closes = Self.homeCloses(histories[symbol] ?? [:], symbol: symbol,
                currency: nil, positions: positions, through: end)
            guard closes.count > 1 else { return }
            result[holding.ticker.uppercased()] = closes
        }
    }

    /// Fetches changes for a bounded list of ETF constituents without creating
    /// synthetic portfolio holdings. Callers keep this list small so enabling
    /// look-through does not fan out across an entire index.
    func dailyChanges(tickers: [String]) async -> [String: Double] {
        let tickers = tickers
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
            .filter { !$0.isEmpty && $0 != "ETF 其他" }
            .uniqued()
        guard !tickers.isEmpty else { return [:] }

        let endDate = Date.now
        let startDate = Calendar(identifier: .gregorian).date(
            byAdding: .day,
            value: -14,
            to: endDate
        ) ?? endDate
        let start = DayDateCodec.string(from: startDate)
        let end = DayDateCodec.string(from: endDate)
        let symbolByTicker = Dictionary(uniqueKeysWithValues: tickers.map {
            ($0, Self.yahooSymbol(ticker: $0, currency: "USD"))
        })
        let histories = await historicalCloses(
            symbols: Array(Set(symbolByTicker.values)),
            from: start,
            to: end
        )

        return symbolByTicker.reduce(into: [String: Double]()) { result, entry in
            guard let change = Self.latestDailyChange(in: histories[entry.value]) else { return }
            result[entry.key] = change
        }
    }

    func dailyChange(ticker: String, currency: String = "USD", forceRefresh: Bool = false) async -> Double? {
        if let security = ChinaSecurity(ticker, currency: currency) {
            return try? await ChinaMarketDataClient().quote(security).changePercent
        }
        let endDate = Date.now
        let startDate = Calendar(identifier: .gregorian).date(
            byAdding: .day,
            value: -14,
            to: endDate
        ) ?? endDate
        let start = DayDateCodec.string(from: startDate)
        let end = DayDateCodec.string(from: endDate)
        let symbol = Self.yahooSymbol(ticker: ticker, currency: currency)
        let histories = await historicalCloses(symbols: [symbol], from: start, to: end, dividendAdjusted: false, forceRefresh: forceRefresh)
        return Self.latestDailyChange(in: histories[symbol])
    }

    /// Returns one year of daily OHLCV for Catfolio's deterministic attention
    /// engine. The engine, rather than the language model, calculates every
    /// market signal from these bars.
    func portfolioAttentionBars(
        ticker: String,
        currency: String,
        referencePrice: Double
    ) async throws -> [PortfolioAttentionDailyBar] {
        let endDate = Date.now
        let startDate = Calendar(identifier: .gregorian).date(
            byAdding: .day,
            value: -400,
            to: endDate
        ) ?? endDate
        let start = DayDateCodec.string(from: startDate)
        let end = DayDateCodec.string(from: endDate)
        let symbol = Self.yahooSymbol(ticker: ticker, currency: currency)
        let cached = await LocalVolumeBarCache.shared.lookup(symbol: symbol)
        var bars: [MarketDailyBar]?
        var latestError: Error?

        if let security = ChinaSecurity(symbol) {
            let chinaBars = try await ChinaMarketDataClient().daily(security, from: start, to: end, adjusted: false)
            return chinaBars.map { .init(date: $0.date, close: $0.close, high: $0.high, low: $0.low, volume: $0.volume) }
        }
        if let cached, cached.isFresh {
            bars = cached.bars
        }
        if bars == nil,
           Self.supportsMassiveStockSymbol(symbol),
           let key = KeychainStore.string(for: LocalServiceKeys.massive), !key.isEmpty {
            do {
                let fetched = try await massiveHistoricalBars(symbol: symbol, from: start, to: end, key: key)
                await LocalVolumeBarCache.shared.save(symbol: symbol, bars: fetched)
                bars = fetched
            } catch {
                latestError = error
            }
        }
        if bars == nil {
            do {
                let fetched = try await yahooHistoricalBars(symbol: symbol, from: start, to: end)
                await LocalVolumeBarCache.shared.save(symbol: symbol, bars: fetched)
                bars = fetched
            } catch {
                latestError = error
            }
        }
        if bars == nil, Self.fmpCoversSymbol(symbol),
           let key = KeychainStore.string(for: LocalServiceKeys.fmp), !key.isEmpty {
            do {
                let fetched = try await fmpHistoricalBars(ticker: ticker, from: start, to: end, key: key)
                await LocalVolumeBarCache.shared.save(symbol: symbol, bars: fetched)
                bars = fetched
            } catch {
                latestError = error
            }
        }
        if bars == nil { bars = cached?.bars }
        guard let bars, !bars.isEmpty else {
            throw latestError ?? LocalServiceError.noHistoricalPrices
        }
        let ordered = bars.sorted { $0.date < $1.date }
        let scale = Self.priceScale(ticker: ticker, currency: currency, referencePrice: referencePrice, marketPrice: ordered.last?.close)
        return ordered.map {
            PortfolioAttentionDailyBar(
                date: $0.date,
                close: $0.close * scale,
                high: $0.high * scale,
                low: $0.low * scale,
                volume: $0.volume
            )
        }
    }

    static func latestDailyChange(in history: [String: Double]?) -> Double? {
        guard let closes = history?.sorted(by: { $0.key < $1.key }),
              closes.count > 1 else { return nil }
        let latest = closes[closes.count - 1].value
        let previous = closes[closes.count - 2].value
        guard latest.isFinite, previous.isFinite, latest > 0, previous > 0 else { return nil }
        return (latest / previous - 1) * 100
    }

    static func yahooSymbol(ticker: String, currency: String) -> String {
        TickerRenames.currentSymbol(for: listingSymbol(ticker: ticker, currency: currency))
    }

    private static func listingSymbol(ticker: String, currency: String) -> String {
        let normalized = ticker.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if let security = ChinaSecurity(normalized, currency: currency) { return security.ticker }
        let overrides = [
            "BRK.B": "BRK-B",
            "VUAG": "VUAG.L",
            "VUSA": "VUSA.L",
            "BARC": "BARC.L",
        ]
        if currency.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "EUR" {
            // Same-currency quote sources for verified broker listings. Keep
            // these out of TickerRenames: the broker's position/trade identity
            // stays intact when we use another venue's prices.
            let euroQuoteSymbols = [
                "ANAE": "ANA.MC",  // Acciona, ES0125220311 (Cboe ANAe)
                "IBEE": "IBE.MC",  // Iberdrola, ES0144580Y14 (Cboe IBEe)
                "DHER": "DHER.DE",  // Delivery Hero, DE000A2E4K43
                "ENL1": "ENL.DE", "ENL1.DE": "ENL.DE",  // Trading 212's Enel identifier
                "MIH.DE": "MIH.F",  // Mitsubishi Heavy Industries, JP3900000005
                "FOT.DE": "FOT.F",  // Fortum, FI0009007132
                "SDV1.DE": "SDV1.F",  // Saab B, SE0021921269
            ]
            if let symbol = euroQuoteSymbols[normalized] { return symbol }
            if ["ENR", "RWE"].contains(normalized) { return "\(normalized).DE" }
        }
        if let override = overrides[normalized] { return override }
        if let londonSymbol = InstrumentCurrencyRules.marketDataSymbol(for: normalized) {
            return londonSymbol
        }
        if ["GBP", "GBX"].contains(currency.uppercased()), !normalized.contains(".") {
            return "\(normalized).L"
        }
        return normalized
    }

    /// FMP's daily endpoint carries no currency, so London prices cannot be
    /// told apart in pounds or pence. Skip it rather than let its refusal
    /// replace the real Yahoo error on screen.
    static func fmpCoversSymbol(_ symbol: String) -> Bool {
        !symbol.uppercased().hasSuffix(".L") && InstrumentCurrencyRules.marketDataSymbol(for: symbol) == nil
    }

    /// Massive's stocks aggregates cover U.S. listings. Exchange-suffixed
    /// Yahoo symbols such as VUSA.L and RWE.DE must stay on the existing
    /// Yahoo/FMP route instead of spending a request that cannot return data.
    static func supportsMassiveStockSymbol(_ symbol: String) -> Bool {
        !symbol.contains(".") && !symbol.contains("=") && !symbol.contains("^")
    }

    private static func close(onOrBefore date: String, in history: [String: Double]) -> Double? {
        if let exact = history[date] { return exact }
        return history.keys.filter { $0 <= date }.max().flatMap { history[$0] }
    }

    /// Aligns a sorted date axis in one pass. Chart preparation calls this for
    /// every holding; repeatedly scanning an entire price dictionary for every
    /// point made the returns tab unnecessarily expensive on iPhone.
    static func closes(
        onOrBefore dates: [String],
        in history: [String: Double],
        maximumAgeDays: Int? = nil
    ) -> [Double?] {
        let sortedHistory = history.sorted { $0.key < $1.key }
        var historyIndex = 0
        var lastClose: Double?
        var lastQuoteDate: String?
        var result: [Double?] = []
        result.reserveCapacity(dates.count)
        for date in dates {
            while historyIndex < sortedHistory.count,
                  sortedHistory[historyIndex].key <= date {
                lastClose = sortedHistory[historyIndex].value
                lastQuoteDate = sortedHistory[historyIndex].key
                historyIndex += 1
            }
            if let maximumAgeDays {
                guard let lastQuoteDate, let quoted = DayDateCodec.date(from: lastQuoteDate),
                      let day = DayDateCodec.date(from: date),
                      day.timeIntervalSince(quoted) <= Double(maximumAgeDays) * 86_400 else {
                    result.append(nil)
                    continue
                }
            }
            result.append(lastClose)
        }
        return result
    }

    private static func close(
        onOrAfter date: String,
        in history: [String: Double],
        maximumDayGap: Int = 7
    ) -> Double? {
        if let exact = history[date] { return exact }
        guard let nextDate = history.keys.filter({ $0 >= date }).min(),
              let requested = DayDateCodec.date(from: date),
              let matched = DayDateCodec.date(from: nextDate),
              let dayGap = Calendar(identifier: .gregorian).dateComponents(
                [.day],
                from: requested,
                to: matched
              ).day,
              dayGap <= maximumDayGap else { return nil }
        return history[nextDate]
    }

    static func priceScale(ticker: String, currency: String, referencePrice: Double?, marketPrice: Double?) -> Double {
        let symbol = yahooSymbol(ticker: ticker, currency: currency)
        // A London suffix alone does not identify pounds vs pence. Only the
        // verified listing currency can authorize a 100x unit conversion.
        let scale = InstrumentCurrencyRules.marketPriceScale(symbol: symbol, targetCurrency: currency)
        if let referencePrice, let marketPrice,
           referencePrice.isFinite, marketPrice.isFinite,
           referencePrice > 0, marketPrice > 0 {
            let ratio = marketPrice * scale / referencePrice
            if ratio < 0.25 || ratio > 4 {
                Logger(subsystem: "com.catfolio.ios", category: "PriceUnits")
                    .warning("Price cross-check failed for \(symbol, privacy: .public); retaining declared currency scale \(scale)")
            }
        }
        return scale
    }

    static func message(from data: Data, fallback: String) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return fallback }
        return object["Error Message"] as? String
            ?? object["error"] as? String
            ?? object["message"] as? String
            ?? fallback
    }
}
