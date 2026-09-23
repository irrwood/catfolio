import Foundation
import CryptoKit
import FoundationModels
import OSLog

struct LocalMarketDataClient {
    private static let yahooSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = URLCache(
            memoryCapacity: 24 * 1_024 * 1_024,
            diskCapacity: 120 * 1_024 * 1_024
        )
        return URLSession(configuration: configuration)
    }()

    private struct YahooChartResponse: Decodable {
        struct Chart: Decodable {
            let result: [Result]?
            let error: YahooError?
        }

        struct Result: Decodable {
            struct Meta: Decodable { let currency: String? }
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

    private struct MassiveAggregatesResponse: Decodable {
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
        let symbols = positions.map {
            Self.yahooSymbol(ticker: $0.ticker, currency: $0.quoteCurrency)
        }.uniqued()
        let rawPrices = await withTaskGroup(of: (String, ObservedMarketQuote?).self) { group in
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
    private func currentOpenPositionsHistory(
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

        return holdings.reduce(into: [String: Double]()) { result, holding in
            let symbol = Self.yahooSymbol(
                ticker: holding.ticker,
                currency: holding.quoteCurrency ?? "USD"
            )
            let closes = Self.homeCloses(histories[symbol] ?? [:], symbol: symbol,
                currency: nil, positions: positions, through: end)
            guard let change = Self.latestDailyChange(in: closes) else { return }
            result[holding.ticker.uppercased()] = change
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
        if bars == nil,
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

    private static func latestDailyChange(in history: [String: Double]?) -> Double? {
        guard let closes = history?.sorted(by: { $0.key < $1.key }),
              closes.count > 1 else { return nil }
        let latest = closes[closes.count - 1].value
        let previous = closes[closes.count - 2].value
        guard latest.isFinite, previous.isFinite, latest > 0, previous > 0 else { return nil }
        return (latest / previous - 1) * 100
    }

    func volumeProfile(
        ticker: String,
        currency: String,
        referencePrice: Double? = nil,
        forceRefresh: Bool = false,
        cachedOnly: Bool = false
    ) async throws -> VolumeProfile {
        let end = DayDateFormatter.shared.string(from: Date())
        let start = DayDateFormatter.shared.string(
            from: Calendar.current.date(byAdding: .day, value: -370, to: Date()) ?? Date()
        )
        let marketSymbol = Self.yahooSymbol(ticker: ticker, currency: currency)
        let cached = await LocalVolumeBarCache.shared.lookup(symbol: marketSymbol)
        if let cached, cachedOnly || (!forceRefresh && cached.isFresh) {
            return try Self.makeVolumeProfile(
                bars: cached.bars,
                ticker: ticker,
                currency: currency,
                referencePrice: referencePrice,
                fallbackDate: end
            )
        }

        guard !cachedOnly else { throw LocalServiceError.noMarketData }

        var latestError: Error?
        if Self.supportsMassiveStockSymbol(marketSymbol),
           let key = KeychainStore.string(for: LocalServiceKeys.massive), !key.isEmpty {
            do {
                let bars = try await massiveHistoricalBars(symbol: marketSymbol, from: start, to: end, key: key)
                await LocalVolumeBarCache.shared.save(symbol: marketSymbol, bars: bars)
                return try Self.makeVolumeProfile(
                    bars: bars,
                    ticker: ticker,
                    currency: currency,
                    referencePrice: referencePrice,
                    fallbackDate: end
                )
            } catch {
                latestError = error
            }
        }

        do {
            let bars = try await yahooHistoricalBars(symbol: marketSymbol, from: start, to: end)
            await LocalVolumeBarCache.shared.save(symbol: marketSymbol, bars: bars)
            return try Self.makeVolumeProfile(
                bars: bars,
                ticker: ticker,
                currency: currency,
                referencePrice: referencePrice,
                fallbackDate: end
            )
        } catch {
            latestError = error
        }

        if let key = KeychainStore.string(for: LocalServiceKeys.fmp), !key.isEmpty {
            do {
                let bars = try await fmpHistoricalBars(ticker: ticker, from: start, to: end, key: key)
                await LocalVolumeBarCache.shared.save(symbol: marketSymbol, bars: bars)
                return try Self.makeVolumeProfile(
                    bars: bars,
                    ticker: ticker,
                    currency: currency,
                    referencePrice: referencePrice,
                    fallbackDate: end
                )
            } catch {
                latestError = error
            }
        }

        if let cached {
            return try Self.makeVolumeProfile(
                bars: cached.bars,
                ticker: ticker,
                currency: currency,
                referencePrice: referencePrice,
                fallbackDate: end
            )
        }
        throw latestError ?? LocalServiceError.noMarketData
    }

    func securityPriceHistory(
        ticker: String,
        currency: String,
        referencePrice: Double? = nil,
        document: LocalPortfolioDocument,
        forceRefresh: Bool = false,
        cachedOnly: Bool = false
    ) async throws -> SecurityPriceHistory {
        let normalizedTicker = ticker.uppercased()
        let transactions = (document.transactions ?? []).filter {
            $0.ticker.uppercased() == normalizedTicker
                && SecurityTrade.canonicalAction($0.action) != nil
        }
        let matchingPositions = document.positions
            .filter { $0.ticker.uppercased() == normalizedTicker }
        // MAX means the security's available market history, not the user's
        // holding period. Providers naturally begin at the IPO/listing date.
        // The early sentinel covers Yahoo's oldest daily series; Massive/FMP
        // return the portion covered by the user's plan.
        let start = "1900-01-01"
        let end = DayDateCodec.string(from: Date())
        let symbol = Self.yahooSymbol(ticker: ticker, currency: currency)
        async let dailyCloses = historicalCloses(symbol: symbol, from: start, to: end,
                                                cachedOnly: cachedOnly, forceRefresh: forceRefresh)
        async let latestIntradayBars = intradayBars(symbol: symbol, forceRefresh: forceRefresh, cachedOnly: cachedOnly)
        let closes = try await dailyCloses
        let intradayBars = (try? await latestIntradayBars) ?? []
        guard !closes.isEmpty else { throw LocalServiceError.noHistoricalPrices }

        let latestMarketClose = closes.max(by: { $0.key < $1.key })?.value
        let scale = Self.priceScale(ticker: ticker, currency: currency, referencePrice: referencePrice, marketPrice: latestMarketClose)
        // referencePrice is only a unit-normalization hint, not a timestamped
        // quote. SecurityPriceHistory merges the dated minute observation.
        let points = closes
            .compactMap { dateText, value -> SecurityPricePoint? in
                let adjusted = value * scale
                guard adjusted.isFinite, adjusted > 0 else { return nil }
                return SecurityPricePoint(dateText: dateText, close: adjusted)
            }
            .sorted { $0.dateText < $1.dateText }
        guard points.count > 1 else { throw LocalServiceError.noHistoricalPrices }
        let intradayPoints = intradayBars.compactMap { bar -> SecurityPricePoint? in
            let adjusted = bar.close * scale
            guard adjusted.isFinite, adjusted > 0 else { return nil }
            return SecurityPricePoint(
                dateText: String(Int(bar.timestamp.timeIntervalSince1970)),
                close: adjusted,
                timestamp: bar.timestamp
            )
        }

        var trades = SecurityTrade.grouped(transactions)
        // Trading 212 can provide the API position snapshot before its paged
        // order history has finished syncing. The broker-supplied openedDate
        // still gives us a trustworthy first-entry marker; later buys and all
        // sells appear once the complete transaction history is available.
        if trades.isEmpty {
            let inferredBuys = Dictionary(grouping: matchingPositions.compactMap { position -> (String, Double, String)? in
                guard let date = position.openedDate else { return nil }
                return (date, position.shares, position.accountKey)
            }, by: { $0.0 })
            trades = inferredBuys.map { date, rows in
                SecurityTrade(
                    dateText: date,
                    action: "BUY",
                    quantity: rows.reduce(0) { $0 + abs($1.1) },
                    tradeCount: rows.count,
                    accountKeys: Set(rows.map(\.2)),
                    executions: rows.map {
                        SecurityTrade.Execution(accountKey: $0.2, quantity: abs($0.1), amount: nil,
                            currency: currency, profit: nil, profitCurrency: nil)
                    }
                )
            }
        }
        trades.sort {
            $0.dateText == $1.dateText ? $0.action < $1.action : $0.dateText < $1.dateText
        }

        return SecurityPriceHistory(
            ticker: ticker,
            currency: currency,
            points: points,
            intradayPoints: intradayPoints,
            trades: trades
        )
    }

    private func intradayBars(symbol: String, forceRefresh: Bool = false, allowsStaleFallback: Bool = true,
                              cachedOnly: Bool = false) async throws -> [MarketIntradayBar] {
        let cached = await LocalIntradayPriceCache.shared.lookup(symbol: symbol)
        if cachedOnly { return cached?.bars ?? [] }
        if !forceRefresh, let cached, cached.isFresh { return cached.bars }

        var latestError: Error?
        if Self.supportsMassiveStockSymbol(symbol),
           let key = KeychainStore.string(for: LocalServiceKeys.massive), !key.isEmpty {
            do {
                let bars = try await massiveIntradayBars(symbol: symbol, key: key)
                await LocalIntradayPriceCache.shared.save(symbol: symbol, bars: bars)
                return bars
            } catch {
                latestError = error
            }
        }

        do {
            let bars = try await yahooIntradayBars(symbol: symbol)
            await LocalIntradayPriceCache.shared.save(symbol: symbol, bars: bars)
            return bars
        } catch {
            latestError = error
        }

        if allowsStaleFallback, let cached { return cached.bars }
        throw latestError ?? LocalServiceError.noMarketData
    }

    private func massiveIntradayBars(symbol: String, key: String) async throws -> [MarketIntradayBar] {
        let endDate = Date()
        let startDate = Calendar(identifier: .gregorian).date(
            byAdding: .day,
            value: -7,
            to: endDate
        ) ?? endDate
        let start = DayDateCodec.string(from: startDate)
        let end = DayDateCodec.string(from: endDate)
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))
        let encodedSymbol = symbol.addingPercentEncoding(withAllowedCharacters: allowed) ?? symbol
        var components = URLComponents(
            string: "https://api.massive.com/v2/aggs/ticker/\(encodedSymbol)/range/5/minute/\(start)/\(end)"
        )!
        components.queryItems = [
            URLQueryItem(name: "adjusted", value: "true"),
            URLQueryItem(name: "sort", value: "asc"),
            URLQueryItem(name: "limit", value: "50000"),
        ]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 12
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await LocalRequestSessions.ephemeral.recordedData(for: request)
        guard let http = response as? HTTPURLResponse else { throw LocalServiceError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw LocalServiceError.remote(Self.message(from: data, fallback: "Massive 日内行情请求失败（\(http.statusCode)）"))
        }
        let payload: MassiveAggregatesResponse
        do {
            payload = try JSONDecoder().decode(MassiveAggregatesResponse.self, from: data)
        } catch {
            DataSourceHealth.reportUnusable(DataSource.of(request.url), issue: .invalidFormat)
            throw error
        }
        if let error = payload.error ?? payload.message, !error.isEmpty {
            throw LocalServiceError.remote(error)
        }
        guard payload.status?.uppercased() == "OK", let aggregates = payload.results else {
            throw LocalServiceError.noMarketData
        }
        let bars = aggregates.compactMap { aggregate -> MarketIntradayBar? in
            guard aggregate.close.isFinite, aggregate.close > 0 else { return nil }
            return MarketIntradayBar(
                timestamp: Date(timeIntervalSince1970: TimeInterval(aggregate.timestamp) / 1_000),
                close: aggregate.close
            )
        }
        return try Self.latestMarketSession(from: bars, symbol: symbol)
    }

    private func yahooIntradayBars(symbol: String) async throws -> [MarketIntradayBar] {
        let endDate = Date()
        let startDate = Calendar(identifier: .gregorian).date(
            byAdding: .day,
            value: -7,
            to: endDate
        ) ?? endDate
        let escapedSymbol = symbol.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? symbol
        var components = URLComponents(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(escapedSymbol)")!
        components.queryItems = [
            URLQueryItem(name: "period1", value: String(Int(startDate.timeIntervalSince1970))),
            URLQueryItem(name: "period2", value: String(Int(endDate.timeIntervalSince1970) + 60)),
            URLQueryItem(name: "interval", value: "5m"),
            URLQueryItem(name: "events", value: "history"),
            URLQueryItem(name: "includePrePost", value: "false"),
        ]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 9
        request.setValue("Mozilla/5.0 Catfolio-iOS", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await Self.yahooSession.recordedData(for: request)
        guard let http = response as? HTTPURLResponse else { throw LocalServiceError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw LocalServiceError.remote("Yahoo 日内行情请求失败（\(http.statusCode)）")
        }
        let payload: YahooChartResponse
        do {
            payload = try JSONDecoder().decode(YahooChartResponse.self, from: data)
        } catch {
            DataSourceHealth.reportUnusable(DataSource.of(request.url), issue: .invalidFormat)
            throw error
        }
        if let error = payload.chart.error {
            throw LocalServiceError.remote(error.description ?? error.code ?? "Yahoo 日内行情读取失败")
        }
        guard let result = payload.chart.result?.first,
              let timestamps = result.timestamp,
              let closes = result.indicators.quote?.first?.close else {
            throw LocalServiceError.noMarketData
        }
        guard let unitScale = InstrumentCurrencyRules.providerPriceScale(symbol: symbol, sourceCurrency: result.meta?.currency) else {
            throw LocalServiceError.remote("行情报价币种无法确认：\(symbol)")
        }
        var bars: [MarketIntradayBar] = []
        bars.reserveCapacity(timestamps.count)
        for (index, timestamp) in timestamps.enumerated() where index < closes.count {
            guard let close = closes[index], close.isFinite, close > 0 else { continue }
            bars.append(MarketIntradayBar(
                timestamp: Date(timeIntervalSince1970: TimeInterval(timestamp)),
                close: close * unitScale
            ))
        }
        return try Self.latestMarketSession(from: bars, symbol: symbol)
    }

    private static func latestMarketSession(
        from bars: [MarketIntradayBar],
        symbol: String
    ) throws -> [MarketIntradayBar] {
        let sorted = bars.sorted { $0.timestamp < $1.timestamp }
        let grouped = Dictionary(grouping: sorted) {
            sessionKey(for: $0.timestamp, symbol: symbol)
        }
        guard let latestKey = grouped.keys.max(),
              let latest = grouped[latestKey], latest.count > 1 else {
            throw LocalServiceError.noMarketData
        }
        // Massive includes pre-market and after-hours aggregates, whereas the
        // Yahoo fallback is requested with includePrePost=false. Normalize U.S.
        // listings to the regular session so the same 1D range is shown no
        // matter which provider answered.
        guard supportsMassiveStockSymbol(symbol) else { return latest }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = marketTimeZone(for: symbol)
        let regularSession = latest.filter { bar in
            let values = calendar.dateComponents([.hour, .minute], from: bar.timestamp)
            let minute = (values.hour ?? 0) * 60 + (values.minute ?? 0)
            return minute >= 9 * 60 + 30 && minute <= 16 * 60
        }
        return regularSession.count > 1 ? regularSession : latest
    }

    static func marketDayStart(_ day: String, symbol: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = marketTimeZone(for: symbol)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: day)
    }

    private static func sessionKey(for date: Date, symbol: String) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = marketTimeZone(for: symbol)
        let values = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", values.year ?? 0, values.month ?? 0, values.day ?? 0)
    }

    private static func marketTimeZone(for symbol: String) -> TimeZone {
        if symbol.hasSuffix(".L") { return TimeZone(identifier: "Europe/London")! }
        if symbol.hasSuffix(".HK") { return TimeZone(identifier: "Asia/Hong_Kong")! }
        if symbol.hasSuffix(".T") { return TimeZone(identifier: "Asia/Tokyo")! }
        if symbol.hasSuffix(".DE") { return TimeZone(identifier: "Europe/Berlin")! }
        return TimeZone(identifier: "America/New_York")!
    }

    /// A direct Massive probe for Settings; it intentionally bypasses local
    /// caches and the other providers so an invalid key cannot appear valid.
    func testMassiveConnection(apiKey: String? = nil) async throws -> Int {
        let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? KeychainStore.string(for: LocalServiceKeys.massive)
            ?? ""
        guard !key.isEmpty else {
            throw LocalServiceError.missingMassiveKey
        }
        let end = DayDateFormatter.shared.string(from: Date())
        let start = DayDateFormatter.shared.string(
            from: Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
        )
        return try await massiveHistoricalBars(symbol: "AAPL", from: start, to: end, key: key).count
    }

    private func fmpHistoricalBars(
        ticker: String,
        from start: String,
        to end: String,
        key: String
    ) async throws -> [MarketDailyBar] {
        // This endpoint has no currency metadata. Do not use it for London
        // listings where pounds and pence cannot be distinguished safely.
        guard !ticker.uppercased().hasSuffix(".L"), InstrumentCurrencyRules.marketDataSymbol(for: ticker) == nil else {
            throw LocalServiceError.remote("FMP 无法确认伦敦标的报价币种")
        }
        var components = URLComponents(string: "https://financialmodelingprep.com/stable/historical-price-eod/full")!
        components.queryItems = [
            URLQueryItem(name: "symbol", value: ticker),
            URLQueryItem(name: "from", value: start),
            URLQueryItem(name: "to", value: end),
            URLQueryItem(name: "apikey", value: key),
        ]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 25
        try await FMPRequestLimiter.shared.waitForTurn()
        let (data, response) = try await LocalRequestSessions.waiting.recordedData(for: request)
        guard let http = response as? HTTPURLResponse else { throw LocalServiceError.invalidResponse }
        if http.statusCode == 429 {
            await FMPRequestLimiter.shared.backOff(retryAfter: http.value(forHTTPHeaderField: "Retry-After"))
            let wait = await FMPRequestLimiter.shared.secondsUntilFreeSlot
            throw FMPFailure.rateLimited(retryAfterSeconds: Int(wait.rounded(.up)))
        }
        guard (200..<300).contains(http.statusCode) else {
            throw LocalServiceError.remote(Self.message(from: data, fallback: "行情请求失败（\(http.statusCode)）"))
        }
        let bars: [MarketDailyBar]
        do {
            bars = try JSONDecoder().decode([MarketDailyBar].self, from: data)
        } catch {
            DataSourceHealth.reportUnusable(DataSource.of(request.url), issue: .invalidFormat)
            throw LocalServiceError.remote(Self.message(from: data, fallback: "FMP 返回格式无法识别"))
        }
        guard !bars.isEmpty else { throw LocalServiceError.noMarketData }
        return bars
    }

    private func massiveHistoricalBars(
        symbol: String,
        from start: String,
        to end: String,
        key: String
    ) async throws -> [MarketDailyBar] {
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))
        let encodedSymbol = symbol.addingPercentEncoding(withAllowedCharacters: allowed) ?? symbol
        var components = URLComponents(
            string: "https://api.massive.com/v2/aggs/ticker/\(encodedSymbol)/range/1/day/\(start)/\(end)"
        )!
        components.queryItems = [
            URLQueryItem(name: "adjusted", value: "true"),
            URLQueryItem(name: "sort", value: "asc"),
            URLQueryItem(name: "limit", value: "50000"),
        ]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 20
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await LocalRequestSessions.ephemeral.recordedData(for: request)
        guard let http = response as? HTTPURLResponse else { throw LocalServiceError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw LocalServiceError.remote(Self.message(from: data, fallback: "Massive 行情请求失败（\(http.statusCode)）"))
        }
        let payload: MassiveAggregatesResponse
        do {
            payload = try JSONDecoder().decode(MassiveAggregatesResponse.self, from: data)
        } catch {
            DataSourceHealth.reportUnusable(DataSource.of(request.url), issue: .invalidFormat)
            throw LocalServiceError.remote("Massive 返回格式无法识别")
        }
        if let error = payload.error ?? payload.message, !error.isEmpty {
            throw LocalServiceError.remote(error)
        }
        guard payload.status?.uppercased() == "OK", let aggregates = payload.results, !aggregates.isEmpty else {
            throw LocalServiceError.noMarketData
        }
        let bars = aggregates.compactMap { aggregate -> MarketDailyBar? in
            guard aggregate.close > 0, aggregate.high > 0, aggregate.low > 0 else { return nil }
            return MarketDailyBar(
                date: DayDateCodec.string(
                    from: Date(timeIntervalSince1970: TimeInterval(aggregate.timestamp) / 1_000)
                ),
                close: aggregate.close,
                high: aggregate.high,
                low: aggregate.low,
                volume: aggregate.volume
            )
        }
        guard !bars.isEmpty else { throw LocalServiceError.noMarketData }
        return bars
    }

    private func yahooHistoricalBars(
        symbol: String,
        from start: String,
        to end: String
    ) async throws -> [MarketDailyBar] {
        guard let fromDate = DayDateCodec.date(from: start),
              let toDate = DayDateCodec.date(from: end) else {
            throw LocalServiceError.invalidResponse
        }
        let period1 = Int(fromDate.timeIntervalSince1970)
        let period2Date = Calendar(identifier: .gregorian).date(byAdding: .day, value: 1, to: toDate) ?? toDate
        let period2 = Int(period2Date.timeIntervalSince1970)
        let escapedSymbol = symbol.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? symbol
        var components = URLComponents(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(escapedSymbol)")!
        components.queryItems = [
            URLQueryItem(name: "period1", value: String(period1)),
            URLQueryItem(name: "period2", value: String(period2)),
            URLQueryItem(name: "interval", value: "1d"),
            URLQueryItem(name: "events", value: "history"),
        ]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 9
        request.setValue("Mozilla/5.0 Catfolio-iOS", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await Self.yahooSession.recordedData(for: request)
        guard let http = response as? HTTPURLResponse else { throw LocalServiceError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw LocalServiceError.remote("Yahoo 成交量请求失败（\(http.statusCode)）")
        }
        let payload: YahooChartResponse
        do {
            payload = try JSONDecoder().decode(YahooChartResponse.self, from: data)
        } catch {
            DataSourceHealth.reportUnusable(DataSource.of(request.url), issue: .invalidFormat)
            throw error
        }
        if let error = payload.chart.error {
            throw LocalServiceError.remote(error.description ?? error.code ?? "Yahoo 成交量读取失败")
        }
        guard let result = payload.chart.result?.first,
              let timestamps = result.timestamp,
              let quote = result.indicators.quote?.first,
              let closes = quote.close,
              let highs = quote.high,
              let lows = quote.low,
              let volumes = quote.volume else {
            throw LocalServiceError.noMarketData
        }
        guard let unitScale = InstrumentCurrencyRules.providerPriceScale(symbol: symbol, sourceCurrency: result.meta?.currency) else {
            throw LocalServiceError.remote("行情报价币种无法确认：\(symbol)")
        }
        var bars: [MarketDailyBar] = []
        for index in timestamps.indices {
            guard index < closes.count, index < highs.count, index < lows.count, index < volumes.count,
                  let close = closes[index], let high = highs[index], let low = lows[index], let volume = volumes[index],
                  close > 0, high > 0, low > 0 else { continue }
            bars.append(MarketDailyBar(
                date: DayDateCodec.string(from: Date(timeIntervalSince1970: TimeInterval(timestamps[index]))),
                close: close * unitScale,
                high: high * unitScale,
                low: low * unitScale,
                volume: volume
            ))
        }
        guard !bars.isEmpty else { throw LocalServiceError.noMarketData }
        return bars
    }

    private static func makeVolumeProfile(
        bars: [MarketDailyBar],
        ticker: String,
        currency: String,
        referencePrice: Double?,
        fallbackDate: String
    ) throws -> VolumeProfile {
        let annualSessions = Array(bars.sorted { $0.date > $1.date }.prefix(252))
        let sessions = Array(annualSessions.prefix(160))
        let scale = Self.priceScale(
            ticker: ticker, currency: currency,
            referencePrice: referencePrice,
            marketPrice: annualSessions.first?.close
        )
        let todayChangePercent: Double? = {
            guard annualSessions.count > 1, annualSessions[1].close > 0 else { return nil }
            return (annualSessions[0].close / annualSessions[1].close - 1) * 100
        }()
        let minimum = sessions.map { $0.low * scale }.min() ?? 0
        let maximum = sessions.map { $0.high * scale }.max() ?? 0
        guard maximum > minimum else { throw LocalServiceError.noMarketData }
        let binCount = 36
        let width = (maximum - minimum) / Double(binCount)
        var bins = Array(repeating: 0.0, count: binCount)
        for bar in sessions where bar.volume > 0 {
            let typical = (bar.high + bar.low + bar.close) / 3 * scale
            let index = min(binCount - 1, max(0, Int((typical - minimum) / width)))
            bins[index] += bar.volume
        }
        guard let pocIndex = bins.indices.max(by: { bins[$0] < bins[$1] }), bins[pocIndex] > 0 else {
            throw LocalServiceError.noMarketData
        }
        let target = bins.reduce(0, +) * 0.70
        var lowIndex = pocIndex
        var highIndex = pocIndex
        var covered = bins[pocIndex]
        while covered < target, lowIndex > 0 || highIndex < binCount - 1 {
            let lower = lowIndex > 0 ? bins[lowIndex - 1] : -1
            let upper = highIndex < binCount - 1 ? bins[highIndex + 1] : -1
            if upper >= lower {
                highIndex += 1
                covered += bins[highIndex]
            } else {
                lowIndex -= 1
                covered += bins[lowIndex]
            }
        }
        func midpoint(_ index: Int) -> Double { minimum + (Double(index) + 0.5) * width }
        return VolumeProfile(
            ticker: ticker,
            currency: currency,
            available: true,
            valueAreaHigh: midpoint(highIndex),
            pointOfControl: midpoint(pocIndex),
            valueAreaLow: midpoint(lowIndex),
            sessions: sessions.count,
            valueAreaPercent: 70,
            asOf: sessions.map(\.date).max() ?? fallbackDate,
            fiftyTwoWeekHigh: annualSessions.map { $0.high * scale }.max(),
            fiftyTwoWeekLow: annualSessions.map { $0.low * scale }.min(),
            // The oldest close in the same 252-session window is the period
            // start used by the 52-week performance segment.
            fiftyTwoWeekStartPrice: annualSessions.last.map { $0.close * scale },
            todayChangePercent: todayChangePercent,
            bins: bins.indices.map { index in
                VolumeProfileBin(
                    priceLow: minimum + Double(index) * width,
                    priceHigh: minimum + Double(index + 1) * width,
                    volume: bins[index]
                )
            }
        )
    }

    func comparison(document: LocalPortfolioDocument) async throws -> ComparisonResponse {
        guard !document.positions.isEmpty || !(document.transactions ?? []).isEmpty else { throw LocalPortfolioError.noPortfolio }
        let end = DayDateCodec.string(from: Date())
        // All three modes share the same private, on-device account ledger.
        let benchmarkSymbols = ComparisonBenchmarkCatalog.symbols
        var dates: [String] = []
        var portfolio: [Double?] = []
        var series = Dictionary(uniqueKeysWithValues: benchmarkSymbols.map { ($0, [Double?]()) })
        var portfolioReturnSeries: [Double?] = []
        var benchmarkReturnSeries = Dictionary(
            uniqueKeysWithValues: benchmarkSymbols.map { ($0, [Double?]()) }
        )
        var mwrPortfolioSeries: [Double?] = []
        var mwrBenchmarkSeries = Dictionary(
            uniqueKeysWithValues: benchmarkSymbols.map { ($0, [Double?]()) }
        )
        var returns = Dictionary(uniqueKeysWithValues: benchmarkSymbols.map { ($0, Optional<Double>.none) })
        var comparisonWarnings: [String] = []
        var cashFlowPortfolioReturn: Double?

        var twr: (dates: [String], portfolio: [Double?], benchmarks: [String: [Double?]], ledger: AccountMWRLedger?, assumptions: [String]) = ([], [], [:], nil, [])
        var dataIssues: [String] = []
        // Fills every view from one rebuilt account, however it was rebuilt.
        func present(_ account: (dates: [String], portfolio: [Double?], benchmarks: [String: [Double?]], ledger: AccountMWRLedger?, assumptions: [String])) -> Bool {
            guard let ledger = account.ledger, let mirrored = ledger.cashFlowComparison() else { return false }
            twr = account
            dates = ledger.dates
            portfolio = mirrored.portfolio
            series = mirrored.benchmarks
            portfolioReturnSeries = mirrored.portfolioReturns
            benchmarkReturnSeries = mirrored.benchmarkReturns
            cashFlowPortfolioReturn = mirrored.portfolioReturns.last ?? nil
            for symbol in benchmarkSymbols { returns[symbol] = mirrored.benchmarkReturns[symbol]?.last ?? nil }
            let unavailable = benchmarkSymbols.filter { (mirrored.benchmarks[$0]?.last ?? nil) == nil }
            if !unavailable.isEmpty {
                comparisonWarnings.append("现金流镜像：\(unavailable.joined(separator: L10n.listSeparator)) 缺少可用行情或无法支付同额出金，最新结果不可用。")
            }
            let mwr = ledger.returns()
            mwrPortfolioSeries = mwr.portfolio
            mwrBenchmarkSeries = mwr.benchmarks
            return true
        }
        var failure: String?
        if !document.isPublicDisclosure && document.isSynthetic != true {
            do {
                let account = try await tolerantAccountSeries(document: document, to: end)
                if present((account.dates, account.portfolio, account.benchmarks, account.ledger, account.assumptions)) {
                    dataIssues = account.assumptions
                    if !account.assumptions.isEmpty { comparisonWarnings.append(Self.impliedFundingNote) }
                    comparisonWarnings.append("现金流镜像：组合与基准使用相同日期、相同金额的真实外部资金流。曲线为剩余资产（含现金）＋累计取出金额，单位 USD；百分比为累计盈亏÷累计入金。基准按同日可用收盘总收益价格模拟，不含额外交易费用，非实际日内成交。现金余额尚未与券商核对。")
                    comparisonWarnings.append("每日 TWR 基于资金流水重建；入金按日初、出金按日末处理，股息按到账日计入。期末现金尚未与券商余额核对。")
                    comparisonWarnings.append("MWR：按实际入出金日期和含现金的账户净值计算所选期间收益，非年化；股息按到账日计入，现金余额尚未与券商核对。基准按同日收盘价模拟资金进出。")
                } else {
                    failure = "缺少完整入金和出金金额。"
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failure = error.localizedDescription.replacingOccurrences(of: "TWR：", with: "")
            }
        }
        if twr.ledger == nil {
            // No ledger could be rebuilt — or the portfolio is a sample or a
            // public filing, which has none. The views are drawn from its
            // value and funding lines instead, and say so.
            let lines: [(date: String, value: Double, funding: Double)]
            if document.isPublicDisclosure {
                lines = document.snapshots.map { ($0.date, $0.marketValueUSD, $0.costUSD) }
            } else if document.isSynthetic == true {
                lines = ((try? LocalPortfolioEngine.presentation(for: document).1.positionHistory.rows) ?? [])
                    .map { ($0.dateText, $0.marketValue, $0.cost) }
            } else {
                lines = ((try? await currentOpenPositionsHistory(document: document, end: end, fundingAtEntryValue: true))?.rows ?? [])
                    .map { ($0.dateText, $0.marketValue, $0.cost) }
            }
            let days = Self.impliedLedgerDays(values: lines)
            if days.count > 1 {
                let assembled = await accountLedger(days, end: end, cachedOnly: false, includeBenchmarks: true)
                if present((assembled.dates, assembled.portfolio, assembled.benchmarks, assembled.ledger, [])) {
                    let basis = L10n.text("收益按持仓市值和成本推算：成本增加视为入金、减少视为出金，没有现金流水。")
                    if let failure { dataIssues = [L10n.text("收益对比没能按流水重建：\(failure)"), basis] }
                    comparisonWarnings.append("每日 TWR " + basis)
                    comparisonWarnings.append("MWR：" + basis)
                    comparisonWarnings.append("现金流镜像：" + basis)
                }
            }
        }
        if twr.ledger == nil {
            let reason = failure ?? "缺少可用的历史市值。"
            comparisonWarnings.append("TWR：\(reason)")
            comparisonWarnings.append("MWR：" + reason)
            comparisonWarnings.append("现金流镜像：" + reason)
            dataIssues = [L10n.text("收益对比没能按流水重建：\(reason)")]
        }
        return ComparisonResponse(
            available: !dates.isEmpty || !twr.dates.isEmpty,
            dates: dates,
            portfolio: portfolio,
            benchmarks: series,
            cashFlowPortfolioReturns: portfolioReturnSeries,
            cashFlowBenchmarkReturns: benchmarkReturnSeries,
            mwrPortfolio: mwrPortfolioSeries,
            mwrBenchmarks: mwrBenchmarkSeries,
            twrDates: twr.dates,
            twrPortfolio: twr.portfolio,
            twrBenchmarks: twr.benchmarks,
            warnings: comparisonWarnings.isEmpty ? nil : comparisonWarnings,
            summary: ComparisonSummary(
                portfolioReturn: cashFlowPortfolioReturn,
                benchmarkReturn: returns["SPY"] ?? nil,
                benchmarkReturns: returns
            ),
            mwrLedger: twr.ledger,
            dataIssues: dataIssues.isEmpty ? nil : dataIssues
        )
    }

    /// Said wherever an account was rebuilt on implied funding.
    static let impliedFundingNote = "资金流水不完整：部分交易没有导入现金金额，已按「股数 × 成交价」推算；当天现金不够付款的部分视为当天入金，交易记录解释不了的持仓视为在最早有价格的那天按收盘价转入。这些推算都按市值入金，不会凭空产生收益。"

    /// All private ledger data stays on-device. Only public symbols/dates are
    /// sent to the market provider. Core is not a runtime dependency.
    /// The account rebuild that does not give up: from the recorded cash
    /// where the ledger holds together, and on implied funding for every
    /// account where it does not. What went wrong is kept as an assumption
    /// for Settings to list, not a reason to draw nothing.
    private func tolerantAccountSeries(
        document: LocalPortfolioDocument, to end: String, cachedOnly: Bool = false, includeBenchmarks: Bool = true,
        homeValuation: Bool = false, forceRefresh: Bool = false
    ) async throws -> (dates: [String], portfolio: [Double?], benchmarks: [String: [Double?]], ledger: AccountMWRLedger?, assumptions: [String], marketDates: [String]) {
        do {
            return try await accountTimeWeightedSeries(document: document, to: end, cachedOnly: cachedOnly, includeBenchmarks: includeBenchmarks, homeValuation: homeValuation, forceRefresh: forceRefresh)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if cachedOnly { throw error }
            let reason = error.localizedDescription.replacingOccurrences(of: "TWR：", with: "")
            var retry = try await accountTimeWeightedSeries(document: document, to: end, includeBenchmarks: includeBenchmarks, rebuildAll: true, homeValuation: homeValuation, forceRefresh: forceRefresh)
            retry.assumptions.append(L10n.text("按原始流水重建时出错（\(reason)），已对全部账户按推算重建。"))
            return retry
        }
    }

    private func accountTimeWeightedSeries(
        document: LocalPortfolioDocument, to end: String, cachedOnly: Bool = false, includeBenchmarks: Bool = true,
        rebuildAll: Bool = false, homeValuation: Bool = false, forceRefresh: Bool = false
    ) async throws -> (dates: [String], portfolio: [Double?], benchmarks: [String: [Double?]], ledger: AccountMWRLedger?, assumptions: [String], marketDates: [String]) {
        typealias T = DailyTimeWeightedReturn
        let records = document.transactions ?? []
        // An account with positions and no rows starts where the broker says
        // its positions were opened.
        let unrecorded = Set(document.positions.map(\.accountKey)).subtracting(records.map(\.accountKey))
        let openings = document.positions.filter { unrecorded.contains($0.accountKey) }.compactMap(\.openedDate)
        guard document.isSynthetic != true, !document.isPublicDisclosure,
              let start = (records.map(\.date) + openings).min(), start <= end else {
            throw T.Failure(message: "TWR：需要完整账户资金流水。")
        }
        var events: [T.Event] = []
        var currencies = Set<String>()
        var symbols = Set<String>()
        // Accounts rebuilt on the implied-funding assumptions: some row came
        // without its cash legs, or the account has positions and no rows.
        var inferredAccounts = rebuildAll ? Set(document.positions.map(\.accountKey)).union(records.map(\.accountKey)) : unrecorded
        // One unusual row costs the account an assumption, stated here, and
        // never the whole history: a takeover, a transfer or a gap in a
        // broker's export is ordinary in real accounts.
        var skippedTypes: [String] = []
        var unpriced: [Int] = []
        for row in records {
            let action = row.action.uppercased()
            let trade = action == "BUY" || action == "SELL"
            let known = ["BUY", "SELL", "DEPOSIT", "WITHDRAWAL", "DIVIDEND", "INTEREST", "FEE", "TAX"].contains(action)
            var cash = row.cashPostings ?? []
            let debit = ["BUY", "WITHDRAWAL", "FEE", "TAX"].contains(action)
            guard known, row.quantity.isFinite, !trade || row.quantity > 0,
                  cash.allSatisfy({ !$0.amount.isNaN && (debit ? $0.amount <= 0 : $0.amount >= 0) }) else {
                // A row the ledger cannot read. Leaving it out is safe: the
                // holdings it moved are matched to today's below.
                inferredAccounts.insert(row.accountKey)
                skippedTypes.append(row.action)
                continue
            }
            if cash.isEmpty {
                // Imported without its cash legs. A trade's are its fill; a
                // cash row's amount is unknown, and it is left out — a
                // deposit it recorded is implied later if it was needed.
                inferredAccounts.insert(row.accountKey)
                guard trade else { continue }
                if row.price.isFinite, row.price > 0 {
                    let amount = Decimal(row.quantity) * Decimal(row.price)
                    cash = [T.Cash(currency: row.currency.uppercased(), amount: action == "BUY" ? -amount : amount)]
                } else {
                    // No price either — often a takeover's exchange. Valued
                    // at the market's close once prices are in.
                    unpriced.append(events.count)
                }
            }
            let symbol = trade ? Self.yahooSymbol(ticker: row.ticker, currency: row.currency) : nil
            if let symbol { symbols.insert(symbol) }
            currencies.formUnion(cash.map(\.currency))
            events.append(T.Event(id: row.id, date: row.date, account: row.accountKey,
                symbol: symbol, quantity: trade ? Decimal(row.quantity) * (action == "BUY" ? 1 : -1) : 0,
                cash: cash, external: action == "DEPOSIT" || action == "WITHDRAWAL"))
        }
        var expected: [String: [String: Decimal]] = [:]
        var openedDates: [String: [String: String]] = [:]
        for position in document.positions {
            let symbol = Self.yahooSymbol(ticker: position.ticker, currency: position.quoteCurrency)
            expected[position.accountKey, default: [:]][symbol, default: 0] += Decimal(position.shares)
            if unrecorded.contains(position.accountKey), let opened = position.openedDate {
                openedDates[position.accountKey, default: [:]][symbol] = min(openedDates[position.accountKey]?[symbol] ?? opened, opened)
            }
            // An implied opening needs the price of what it opens.
            if inferredAccounts.contains(position.accountKey) { symbols.insert(symbol) }
        }
        var prices: [String: LedgerPriceHistory] = [:]
        var splits: [T.Split] = []
        var unpricedSymbols: [String] = []
        let histories = try await withThrowingTaskGroup(of: (String, LedgerPriceHistory?).self) { group in
            var iterator = symbols.sorted().makeIterator()
            func enqueue(_ symbol: String) {
                group.addTask {
                    do {
                        try Task.checkCancellation()
                        return (symbol, try await ledgerPriceHistory(symbol: symbol, from: start, to: end, cachedOnly: cachedOnly, forceRefresh: forceRefresh))
                    } catch {
                        if cachedOnly || error is CancellationError { throw error }
                        return (symbol, nil)
                    }
                }
            }
            for _ in 0..<min(4, symbols.count) {
                if let symbol = iterator.next() { enqueue(symbol) }
            }
            var results: [(String, LedgerPriceHistory?)] = []
            while let result = try await group.next() {
                results.append(result)
                if let symbol = iterator.next() { enqueue(symbol) }
            }
            return results.sorted { $0.0 < $1.0 }
        }
        try Task.checkCancellation()
        for (symbol, history) in histories {
            if var history {
                if homeValuation {
                    history.closes = Self.homeCloses(history.closes, symbol: symbol,
                        currency: history.currency, positions: document.positions, through: end)
                }
                prices[symbol] = history
                currencies.insert(history.currency)
                splits += history.splits
            } else { unpricedSymbols.append(symbol) }
        }
        // A security with no price history cannot be valued on any day. It
        // is left out of the history altogether, trades and all, and the
        // accounts it was in are rebuilt around it.
        var valuationDrops = Set<Int>()
        if !unpricedSymbols.isEmpty {
            let missing = Set(unpricedSymbols)
            for (index, event) in events.enumerated() where event.symbol.map(missing.contains) == true {
                valuationDrops.insert(index)
                inferredAccounts.insert(event.account)
            }
            for account in Array(expected.keys) {
                for symbol in missing where expected[account]?[symbol] != nil {
                    expected[account]?[symbol] = nil
                    inferredAccounts.insert(account)
                }
            }
        }
        var valuedFills: [String] = []
        for index in unpriced where !valuationDrops.contains(index) {
            guard let symbol = events[index].symbol, let history = prices[symbol] else { continue }
            let closes = history.closes.mapValues { T.Quote(price: Decimal($0), currency: history.currency) }
            guard let near = T.close(near: events[index].date, in: closes) else {
                valuationDrops.insert(index)
                continue
            }
            let amount = events[index].quantity * near.quote.price
            events[index].cash = [T.Cash(currency: near.quote.currency, amount: -amount)]
            valuedFills.append(symbol)
        }
        let unvaluedFills = unpriced.filter { valuationDrops.contains($0) && !(events[$0].symbol.map(Set(unpricedSymbols).contains) ?? false) }
            .compactMap { events[$0].symbol }
        events = events.enumerated().filter { !valuationDrops.contains($0.offset) }.map(\.element)
        var fx: [String: [String: Double]] = [:]
        for currency in currencies where currency != "USD" {
            let normalized = currency == "GBX" ? "GBP" : currency
            let fxStart = DayDateCodec.string(from: DayDateCodec.date(from: start)!.addingTimeInterval(-7 * 86400))
            let history = try await historicalCloses(symbol: "\(normalized)USD=X", from: fxStart, to: end, cachedOnly: cachedOnly, forceRefresh: forceRefresh)
            fx[currency] = history.mapValues { currency == "GBX" ? $0 / 100 : $0 }
        }
        guard var date = DayDateCodec.date(from: start), let last = DayDateCodec.date(from: end) else {
            throw T.Failure(message: "TWR：日期无效。")
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var days: [T.Day] = []
        var lastQuotes: [String: (date: Date, quote: T.Quote)] = [:]
        var lastRates: [String: (date: Date, rate: Decimal)] = [:]
        for (symbol, history) in prices {
            if let key = history.closes.keys.filter({ $0 < start }).max(), let close = history.closes[key], let prior = DayDateCodec.date(from: key) {
                lastQuotes[symbol] = (prior, T.Quote(price: Decimal(close), currency: history.currency))
            }
        }
        for (currency, history) in fx {
            if let key = history.keys.filter({ $0 < start }).max(), let rate = history[key], let prior = DayDateCodec.date(from: key) {
                lastRates[currency] = (prior, Decimal(rate))
            }
        }
        while date <= last {
            let key = DayDateCodec.string(from: date)
            // A pre-split close cannot value post-split quantities. Require a
            // fresh quote on the new basis even within the short carry window.
            for split in splits where split.date == key { lastQuotes.removeValue(forKey: split.symbol) }
            for (symbol, history) in prices {
                if let close = history.closes[key] {
                    lastQuotes[symbol] = (date, T.Quote(price: Decimal(close), currency: history.currency))
                }
            }
            for (currency, history) in fx {
                if let rate = history[key], rate.isFinite, rate > 0 { lastRates[currency] = (date, Decimal(rate)) }
            }
            // Carry an already observed close across short market closures;
            // never backfill from a future quote or flatten long missing spans.
            // A rebuild on assumptions also bridges longer gaps in a
            // security's data, rather than failing on them.
            let maxAge: TimeInterval = (rebuildAll ? 21 : 4) * 86_400
            let quotes = lastQuotes.filter { date.timeIntervalSince($0.value.date) <= maxAge }.mapValues(\.quote)
            let rates = lastRates.filter { date.timeIntervalSince($0.value.date) <= maxAge }.mapValues(\.rate)
            days.append(T.Day(date: key, quotes: quotes, usdRates: rates))
            date = calendar.date(byAdding: .day, value: 1, to: date)!
        }
        var assumptions: [String] = []
        if !inferredAccounts.isEmpty {
            let quotes = prices.mapValues { history in
                history.closes.filter { $0.key >= start && $0.key <= end }
                    .mapValues { T.Quote(price: Decimal($0), currency: history.currency) }
            }
            events += T.openingTransfers(events: events, splits: splits, expected: expected, quotes: quotes,
                                         start: start, openedDates: openedDates, accounts: inferredAccounts)
            let closings = T.closingTransfers(events: events, splits: splits, expected: expected, quotes: quotes,
                                              accounts: inferredAccounts)
            events += closings.events
            events += T.fundingShortfalls(events: events, accounts: inferredAccounts)

            func names(_ symbols: [String]) -> String {
                let unique = Array(NSOrderedSet(array: symbols.map { $0.replacingOccurrences(of: ".L", with: "") })) as? [String] ?? []
                return unique.prefix(4).joined(separator: L10n.listSeparator) + (unique.count > 4 ? L10n.text(" 等") : "")
            }
            assumptions.append(Self.impliedFundingNote)
            if !valuedFills.isEmpty {
                assumptions.append(L10n.text("\(names(valuedFills)) 有 \(valuedFills.count) 笔交易没有成交价（常见于并购换股），按当天或最近的收盘价估值。"))
            }
            if !unvaluedFills.isEmpty {
                assumptions.append(L10n.text("\(names(unvaluedFills)) 有 \(unvaluedFills.count) 笔交易前后 10 天都没有收盘价，已跳过。"))
            }
            if !skippedTypes.isEmpty {
                let kinds = Array(NSOrderedSet(array: skippedTypes)) as? [String] ?? []
                assumptions.append(L10n.text("\(skippedTypes.count) 条流水（\(kinds.prefix(3).joined(separator: L10n.listSeparator))）暂时读不懂，已跳过；持仓按当前账户对齐。"))
            }
            if !closings.symbols.isEmpty {
                assumptions.append(L10n.text("\(names(closings.symbols)) 已不在当前持仓里，但没有卖出记录，按最后一个收盘价转出。"))
            }
            if !unpricedSymbols.isEmpty {
                assumptions.append(L10n.text("\(names(unpricedSymbols)) 找不到历史行情，没有计入账户历史。"))
            }
        }
        let result = try T.calculate(events: events, days: days, splits: splits,
                                     inferUnfundedShareTransfers: !inferredAccounts.isEmpty)
        if !result.inferredShareTransfers.isEmpty {
            let dates = result.inferredShareTransfers.map(\.date).joined(separator: L10n.listSeparator)
            assumptions.append(L10n.text("\(dates) 的无现金证券变动按当日价格计为转入或转出；价格和汇率涨跌仍计入收益。"))
        }
        for account in Set(expected.keys).union(result.holdings.keys) {
            for symbol in Set(expected[account]?.keys.map { $0 } ?? []).union(result.holdings[account]?.keys.map { $0 } ?? []) {
                let difference = (expected[account]?[symbol] ?? 0) - (result.holdings[account]?[symbol] ?? 0)
                guard abs(NSDecimalNumber(decimal: difference).doubleValue) < 0.000001 else {
                    throw T.Failure(message: "TWR：\(symbol) 重建持仓与当前账户不符，请核查流水、拆股和证券转账。")
                }
            }
        }
        let points = result.points.map {
            LedgerDay(date: $0.date, value: NSDecimalNumber(decimal: $0.value).doubleValue,
                      inflow: NSDecimalNumber(decimal: $0.inflow).doubleValue,
                      outflow: NSDecimalNumber(decimal: $0.outflow).doubleValue,
                      nav: NSDecimalNumber(decimal: $0.nav).doubleValue)
        }
        let assembled = await accountLedger(points, end: end, cachedOnly: cachedOnly, includeBenchmarks: includeBenchmarks)
        return (assembled.dates, assembled.portfolio, assembled.benchmarks, assembled.ledger, assumptions, Array(Set(prices.values.flatMap { $0.closes.keys })).filter { $0 <= end }.sorted())
    }

    /// One day of a rebuilt account, in USD.
    struct LedgerDay: Equatable, Sendable {
        var date: String
        var value: Double
        var inflow: Double
        var outflow: Double
        var nav: Double
    }

    /// Days from a value line and a funding line — today's holdings backcast
    /// against what they cost, or a public filing's snapshots — for when no
    /// ledger can be rebuilt. A rise in the funding line is a deposit, a fall
    /// a withdrawal, and the unit value is chain-linked the way the ledger's
    /// is, so every return view can still draw.
    static func impliedLedgerDays(values: [(date: String, value: Double, funding: Double)]) -> [LedgerDay] {
        var days: [LedgerDay] = []
        var previousValue = 0.0, previousFunding = 0.0, nav = 1.0, started = false
        for row in values.sorted(by: { $0.date < $1.date }) where row.value.isFinite && row.funding.isFinite {
            let change = row.funding - previousFunding
            var inflow = max(0, change), outflow = max(0, -change)
            let capital = previousValue + inflow
            if capital > 0 {
                let growth = (row.value + outflow) / capital
                // As in the ledger: a whole-account move no price explains
                // is a gap in the data, taken as a transfer, not a return.
                if previousValue > 0, growth > 1.5 || growth < 1 / 1.5 {
                    let gap = row.value + outflow - capital
                    if gap > 0 { inflow += gap } else { outflow -= gap }
                } else {
                    nav *= growth
                }
                started = true
            }
            if started { days.append(LedgerDay(date: row.date, value: row.value, inflow: inflow, outflow: outflow, nav: nav)) }
            previousValue = row.value
            previousFunding = row.funding
        }
        return days
    }

    /// A rebuilt account dressed for the three return views: a baseline day
    /// before the first, benchmarks on the same dates, and benchmarks
    /// mirroring the account's own deposits and withdrawals.
    func accountLedger(
        _ points: [LedgerDay], end: String, cachedOnly: Bool, includeBenchmarks: Bool,
        fetchHistory: (([String], String, String) async -> [String: [String: Double]])? = nil
    ) async -> (dates: [String], portfolio: [Double?], benchmarks: [String: [Double?]], ledger: AccountMWRLedger) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        // An explicit baseline preserves the first funded day's return when
        // the chart rebases the selected range to its first point.
        let baseline = calendar.date(byAdding: .day, value: -1, to: DayDateCodec.date(from: points[0].date)!)!
        let dates = [DayDateCodec.string(from: baseline)] + points.map(\.date)
        let benchmarkSymbols = includeBenchmarks ? ComparisonBenchmarkCatalog.symbols : []
        // The baseline or the first deposit can fall on a weekend/holiday.
        // Fetch the preceding close as well; prices after the baseline cannot
        // establish its NAV and must never be used to backfill it.
        let historyStart = DayDateCodec.string(from: baseline.addingTimeInterval(-7 * 86_400))
        let benchmarks: [String: [String: Double]]
        if let fetchHistory {
            benchmarks = await fetchHistory(benchmarkSymbols, historyStart, end)
        } else {
            benchmarks = await historicalCloses(symbols: benchmarkSymbols, from: historyStart, to: end, cachedOnly: cachedOnly)
        }
        var series: [String: [Double?]] = [:]
        for symbol in benchmarkSymbols {
            let closes = Self.closes(onOrBefore: dates, in: benchmarks[symbol] ?? [:])
            // No different starting line for a benchmark missing the baseline.
            if let first = closes.first, let base = first, base > 0 {
                series[symbol] = closes.map { $0.map { $0 / base } }
            }
        }
        let flows = [0.0] + points.map { $0.inflow - $0.outflow }
        var benchmarkValues: [String: [Double?]] = [:]
        for symbol in benchmarkSymbols {
            let history = benchmarks[symbol] ?? [:]
            let aligned = Self.closes(onOrBefore: dates, in: history, maximumAgeDays: 4)
            benchmarkValues[symbol] = AccountMWRLedger.mirror(cashFlows: flows, prices: aligned)
        }
        let ledger = AccountMWRLedger(dates: dates, cashFlows: flows,
            values: [0] + points.map(\.value),
            benchmarkValues: benchmarkValues,
            inflows: [0] + points.map(\.inflow),
            outflows: [0] + points.map(\.outflow))
        return (dates, [1] + points.map(\.nav), series, ledger)
    }

    private struct LedgerPriceHistory: Codable {
        var currency: String
        var closes: [String: Double]
        var splits: [DailyTimeWeightedReturn.Split]
        var fetchedAt: Date
    }

    /// Yahoo quote.close is split-adjusted. Undo subsequent splits to get the
    /// contemporaneous price used with actual historical share quantities.
    private func ledgerPriceHistory(symbol: String, from: String, to: String, cachedOnly: Bool = false, forceRefresh: Bool = false) async throws -> LedgerPriceHistory {
        let cacheKey = Data("ledger-v1|\(symbol)|\(from)|\(to)".utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
        let cacheURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(cacheKey + ".json")
        let cached = (try? Data(contentsOf: cacheURL)).flatMap { try? JSONDecoder().decode(LedgerPriceHistory.self, from: $0) }
        if cachedOnly {
            guard let cached else { throw LocalServiceError.noHistoricalPrices }
            return cached
        }
        if !forceRefresh, let cached, Date().timeIntervalSince(cached.fetchedAt) < 12 * 3600 { return cached }
        guard let start = DayDateCodec.date(from: from), let end = DayDateCodec.date(from: to) else { throw LocalServiceError.invalidResponse }
        var url = URLComponents(string: "https://query1.finance.yahoo.com/v8/finance/chart/")!
        url.path += symbol
        url.queryItems = [URLQueryItem(name: "period1", value: String(Int(start.timeIntervalSince1970 - 7 * 86400))),
            URLQueryItem(name: "period2", value: String(Int(end.timeIntervalSince1970 + 86400))),
            URLQueryItem(name: "interval", value: "1d"), URLQueryItem(name: "events", value: "splits")]
        var request = URLRequest(url: url.url!)
        request.timeoutInterval = 15
        request.setValue("Mozilla/5.0 Catfolio-iOS", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await Self.yahooSession.recordedData(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw LocalServiceError.invalidResponse }
            guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let chart = root["chart"] as? [String: Any],
                  let result = (chart["result"] as? [[String: Any]])?.first,
                  let meta = result["meta"] as? [String: Any], let currency = meta["currency"] as? String,
                  let timezone = meta["exchangeTimezoneName"] as? String, let zone = TimeZone(identifier: timezone),
                  let timestamps = result["timestamp"] as? [Double],
                  let indicators = result["indicators"] as? [String: Any],
                  let quote = (indicators["quote"] as? [[String: Any]])?.first,
                  let closes = quote["close"] as? [Any] else {
                DataSourceHealth.reportUnusable(DataSource.of(request.url), issue: .missingRequiredFields)
                throw LocalServiceError.invalidResponse
            }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = zone
            formatter.dateFormat = "yyyy-MM-dd"
            func day(_ timestamp: Double) -> String { formatter.string(from: Date(timeIntervalSince1970: timestamp)) }
            let eventMap = result["events"] as? [String: Any]
            let rawSplits = eventMap?["splits"] as? [String: [String: Any]] ?? [:]
            var splits: [DailyTimeWeightedReturn.Split] = []
            for event in rawSplits.values {
                guard let timestamp = event["date"] as? Double, let numerator = event["numerator"] as? Double,
                      let denominator = event["denominator"] as? Double, numerator > 0, denominator > 0 else {
                    DataSourceHealth.reportUnusable(DataSource.of(request.url), issue: .missingRequiredFields)
                    throw LocalServiceError.invalidResponse
                }
                splits.append(.init(date: day(timestamp), symbol: symbol, factor: Decimal(numerator / denominator)))
            }
            var values: [String: Double] = [:]
            for (index, timestamp) in timestamps.enumerated() where closes.indices.contains(index) {
                guard let close = closes[index] as? Double, close.isFinite, close > 0 else { continue }
                let date = day(timestamp)
                let factor = splits.filter { $0.date > date }.reduce(1.0) { $0 * NSDecimalNumber(decimal: $1.factor).doubleValue }
                values[date] = close * factor
            }
            guard !values.isEmpty else { throw LocalServiceError.noHistoricalPrices }
            let history = LedgerPriceHistory(currency: currency == "GBp" ? "GBX" : currency.uppercased(), closes: values,
                splits: splits.filter { $0.date >= from && $0.date <= to }, fetchedAt: Date())
            try? JSONEncoder().encode(history).write(to: cacheURL, options: .atomic)
            return history
        } catch {
            if let cached { return cached }
            throw error
        }
    }

    func historicalCloses(
        symbols: [String],
        from: String,
        to: String,
        dividendAdjusted: Bool = true,
        cachedOnly: Bool = false,
        forceRefresh: Bool = false
    ) async -> [String: [String: Double]] {
        await withTaskGroup(of: (String, [String: Double]?).self) { group in
            // A large broker CSV can contain hundreds of symbols. Sending all
            // Yahoo requests at once is both slower on iPhone and commonly
            // triggers 429 responses, which previously erased the whole chart.
            var iterator = symbols.makeIterator()
            let concurrencyLimit = min(8, symbols.count)
            for _ in 0..<concurrencyLimit {
                guard let symbol = iterator.next() else { break }
                group.addTask {
                    (symbol, try? await historicalCloses(
                        symbol: symbol,
                        from: from,
                        to: to,
                        dividendAdjusted: dividendAdjusted,
                        cachedOnly: cachedOnly,
                        forceRefresh: forceRefresh
                    ))
                }
            }

            var result: [String: [String: Double]] = [:]
            while let (symbol, history) = await group.next() {
                if let history, !history.isEmpty {
                    result[symbol] = history
                }
                if let nextSymbol = iterator.next() {
                    group.addTask {
                        (nextSymbol, try? await historicalCloses(
                            symbol: nextSymbol,
                            from: from,
                            to: to,
                            dividendAdjusted: dividendAdjusted,
                            cachedOnly: cachedOnly,
                            forceRefresh: forceRefresh
                        ))
                    }
                }
            }
            return result
        }
    }

    private func historicalCloses(
        symbol: String,
        from: String,
        to: String,
        dividendAdjusted: Bool = true,
        cachedOnly: Bool = false,
        forceRefresh: Bool = false
    ) async throws -> [String: Double] {
        let cacheSymbol = dividendAdjusted ? symbol : symbol + "#split-only"
        let cached = await LocalHistoricalPriceCache.shared.lookup(symbol: cacheSymbol, from: from, to: to)
        if cachedOnly {
            guard let cached, cached.values.count > 1 else {
                throw LocalServiceError.noHistoricalPrices
            }
            return cached.values
        }
        if !forceRefresh, let cached, cached.isFresh, cached.values.count > 1 {
            return cached.values
        }
        // A stale history is extended, not refetched: only the days since the
        // last saved one, with a week of overlap to line the two up.
        if !forceRefresh, let cached, cached.coversStart, cached.values.count > 1,
           let last = cached.lastDate, let lastDay = DayDateCodec.date(from: last) {
            let overlapStart = DayDateCodec.string(from: lastDay.addingTimeInterval(-7 * 86_400))
            let tailFrom = max(from, overlapStart)
            if tailFrom > to { return cached.values }
            if let tail = try? await yahooHistoricalCloses(symbol: symbol, from: tailFrom, to: to, dividendAdjusted: dividendAdjusted),
               !tail.isEmpty,
               let merged = await LocalHistoricalPriceCache.shared.extend(symbol: cacheSymbol, tail: tail, requestedTo: to) {
                return merged.filter { $0.key >= from && $0.key <= to }
            }
        }
        var latestError: Error?
        do {
            let yahoo = try await yahooHistoricalCloses(symbol: symbol, from: from, to: to, dividendAdjusted: dividendAdjusted)
            if !yahoo.isEmpty {
                await LocalHistoricalPriceCache.shared.save(
                    symbol: cacheSymbol,
                    values: yahoo,
                    requestedFrom: from,
                    requestedTo: to
                )
                return yahoo
            }
        } catch {
            latestError = error
        }

        if !dividendAdjusted {
            if let cached, cached.values.count > 1 { return cached.values }
            throw latestError ?? LocalServiceError.noHistoricalPrices
        }

        if Self.supportsMassiveStockSymbol(symbol),
           let key = KeychainStore.string(for: LocalServiceKeys.massive), !key.isEmpty {
            do {
                let bars = try await massiveHistoricalBars(symbol: symbol, from: from, to: to, key: key)
                let massive = Dictionary(uniqueKeysWithValues: bars.map { ($0.date, $0.close) })
                await LocalHistoricalPriceCache.shared.save(
                    symbol: cacheSymbol,
                    values: massive,
                    requestedFrom: from,
                    requestedTo: to
                )
                return massive
            } catch {
                latestError = error
            }
        }

        if KeychainStore.string(for: LocalServiceKeys.fmp)?.isEmpty == false {
            do {
                let fmp = try await fmpHistoricalCloses(symbol: symbol, from: from, to: to)
                await LocalHistoricalPriceCache.shared.save(
                    symbol: cacheSymbol,
                    values: fmp,
                    requestedFrom: from,
                    requestedTo: to
                )
                return fmp
            } catch {
                latestError = error
            }
        }

        if let cached { return cached.values }
        throw latestError ?? LocalServiceError.noHistoricalPrices
    }

    private func yahooHistoricalCloses(symbol: String, from: String, to: String, dividendAdjusted: Bool = true) async throws -> [String: Double] {
        guard let fromDate = DayDateCodec.date(from: from),
              let toDate = DayDateCodec.date(from: to) else {
            throw LocalServiceError.invalidResponse
        }
        let period1 = Int(fromDate.timeIntervalSince1970)
        let period2Date = Calendar(identifier: .gregorian).date(byAdding: .day, value: 1, to: toDate) ?? toDate
        let period2 = Int(period2Date.timeIntervalSince1970)
        let escapedSymbol = symbol.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? symbol
        var components = URLComponents(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(escapedSymbol)")!
        components.queryItems = [
            URLQueryItem(name: "period1", value: String(period1)),
            URLQueryItem(name: "period2", value: String(period2)),
            URLQueryItem(name: "interval", value: "1d"),
            URLQueryItem(name: "events", value: "history"),
        ]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 9
        request.setValue("Mozilla/5.0 Catfolio-iOS", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await Self.yahooSession.recordedData(for: request)
        guard let http = response as? HTTPURLResponse else { throw LocalServiceError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw LocalServiceError.remote("Yahoo 历史行情请求失败（\(http.statusCode)）")
        }
        let payload: YahooChartResponse
        do {
            payload = try JSONDecoder().decode(YahooChartResponse.self, from: data)
        } catch {
            DataSourceHealth.reportUnusable(DataSource.of(request.url), issue: .invalidFormat)
            throw LocalServiceError.remote("Yahoo 历史行情返回格式无法识别")
        }
        if let error = payload.chart.error {
            throw LocalServiceError.remote(error.description ?? error.code ?? "Yahoo 历史行情读取失败")
        }
        guard let result = payload.chart.result?.first,
              let timestamps = result.timestamp else {
            throw LocalServiceError.noMarketData
        }
        let adjusted = result.indicators.adjclose?.first?.adjclose ?? []
        let raw = result.indicators.quote?.first?.close ?? []
        let closes = dividendAdjusted && adjusted.contains(where: { $0 != nil }) ? adjusted : raw
        guard let unitScale = InstrumentCurrencyRules.providerPriceScale(symbol: symbol, sourceCurrency: result.meta?.currency) else {
            throw LocalServiceError.remote("行情报价币种无法确认：\(symbol)")
        }
        var values: [String: Double] = [:]
        for (index, timestamp) in timestamps.enumerated() where index < closes.count {
            guard let close = closes[index], close > 0 else { continue }
            let date = DayDateCodec.string(from: Date(timeIntervalSince1970: TimeInterval(timestamp)))
            values[date] = close * unitScale
        }
        guard !values.isEmpty else { throw LocalServiceError.noMarketData }
        return values
    }

    /// Dividends per share over the last two years, by ex-date, in the
    /// listing's own quote currency. Kept for half a day.
    func dividendPayments(symbol: String) async throws -> [DividendForecast.Payment] {
        if let cached = await DividendScheduleCache.shared.lookup(symbol) { return cached }
        var components = URLComponents(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(symbol.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? symbol)")!
        components.queryItems = [
            URLQueryItem(name: "range", value: "2y"),
            URLQueryItem(name: "interval", value: "1mo"),
            URLQueryItem(name: "events", value: "div"),
        ]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 9
        request.setValue("Mozilla/5.0 Catfolio-iOS", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await Self.yahooSession.recordedData(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw LocalServiceError.remote("Yahoo 股息记录请求失败")
        }
        let payload: YahooChartResponse
        do {
            payload = try JSONDecoder().decode(YahooChartResponse.self, from: data)
        } catch {
            DataSourceHealth.reportUnusable(DataSource.of(request.url), issue: .invalidFormat)
            throw error
        }
        guard let result = payload.chart.result?.first else { throw LocalServiceError.noMarketData }
        let listed = result.meta?.currency ?? "USD"
        let currency = listed == "GBp" ? "GBX" : listed.uppercased()
        let payments = (result.events?.dividends?.values.map { $0 } ?? []).map {
            DividendForecast.Payment(
                exDate: DayDateCodec.string(from: Date(timeIntervalSince1970: TimeInterval($0.date))),
                perShare: $0.amount, currency: currency)
        }.sorted { $0.exDate < $1.exDate }
        await DividendScheduleCache.shared.save(payments, for: symbol)
        return payments
    }

    /// What today's holdings should still pay before the year is out, in
    /// USD, on the assumption that each repeats last year's payments.
    ///
    /// - Returns: the amount, and how many holdings had a schedule to go on.
    func remainingDividends(for holdings: [Holding], today: Date = Date()) async -> (usd: Double, covered: Int) {
        let held = holdings.filter { $0.shares > 0 && $0.publicDisclosure == nil }
        let schedules = await withTaskGroup(of: (Holding, [DividendForecast.Payment]?).self) { group in
            var iterator = held.makeIterator()
            for _ in 0..<min(8, held.count) {
                guard let holding = iterator.next() else { break }
                group.addTask { (holding, try? await dividendPayments(symbol: Self.yahooSymbol(ticker: holding.ticker, currency: holding.quoteCurrency ?? "USD"))) }
            }
            var result: [(Holding, [DividendForecast.Payment])] = []
            while let (holding, payments) = await group.next() {
                if let payments { result.append((holding, payments)) }
                if let next = iterator.next() {
                    group.addTask { (next, try? await dividendPayments(symbol: Self.yahooSymbol(ticker: next.ticker, currency: next.quoteCurrency ?? "USD"))) }
                }
            }
            return result
        }
        var total = 0.0
        var covered = 0
        for (holding, payments) in schedules {
            let expected = DividendForecast.remaining(shares: holding.shares, payments: payments, today: today)
            guard expected.amount > 0, let usd = try? LocalPortfolioEngine.usd(expected.amount, currency: expected.currency) else { continue }
            total += usd
            covered += 1
        }
        return (total, covered)
    }

    private func fmpHistoricalCloses(symbol: String, from: String, to: String) async throws -> [String: Double] {
        guard !symbol.uppercased().hasSuffix(".L"), InstrumentCurrencyRules.marketDataSymbol(for: symbol) == nil else {
            throw LocalServiceError.remote("FMP 无法确认伦敦标的报价币种")
        }
        guard let key = KeychainStore.string(for: LocalServiceKeys.fmp), !key.isEmpty else {
            throw LocalServiceError.missingMarketKey
        }
        var components = URLComponents(string: "https://financialmodelingprep.com/stable/historical-price-eod/full")!
        components.queryItems = [
            URLQueryItem(name: "symbol", value: symbol),
            URLQueryItem(name: "from", value: from),
            URLQueryItem(name: "to", value: to),
            URLQueryItem(name: "apikey", value: key),
        ]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 25
        try await FMPRequestLimiter.shared.waitForTurn()
        let (data, response) = try await LocalRequestSessions.ephemeral.recordedData(for: request)
        guard let http = response as? HTTPURLResponse else { throw LocalServiceError.invalidResponse }
        if http.statusCode == 429 {
            await FMPRequestLimiter.shared.backOff(retryAfter: http.value(forHTTPHeaderField: "Retry-After"))
            let wait = await FMPRequestLimiter.shared.secondsUntilFreeSlot
            throw FMPFailure.rateLimited(retryAfterSeconds: Int(wait.rounded(.up)))
        }
        guard (200..<300).contains(http.statusCode) else {
            throw LocalServiceError.remote(Self.message(from: data, fallback: "行情请求失败（\(http.statusCode)）"))
        }
        guard let bars = try? JSONDecoder().decode([MarketDailyBar].self, from: data) else {
            DataSourceHealth.reportUnusable(DataSource.of(request.url), issue: .invalidFormat)
            throw LocalServiceError.remote(Self.message(from: data, fallback: "FMP 返回格式无法识别"))
        }
        return Dictionary(uniqueKeysWithValues: bars.map { ($0.date, $0.close) })
    }

    static func yahooSymbol(ticker: String, currency: String) -> String {
        let normalized = ticker.uppercased()
        let overrides = [
            "BRK.B": "BRK-B",
            "VUAG": "VUAG.L",
            "VUSA": "VUSA.L",
            "BARC": "BARC.L",
        ]
        if currency.uppercased() == "EUR", ["ENR", "RWE"].contains(normalized) {
            return "\(normalized).DE"
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

    /// Massive's stocks aggregates cover U.S. listings. Exchange-suffixed
    /// Yahoo symbols such as VUSA.L and RWE.DE must stay on the existing
    /// Yahoo/FMP route instead of spending a request that cannot return data.
    private static func supportsMassiveStockSymbol(_ symbol: String) -> Bool {
        !symbol.contains(".") && !symbol.contains("=") && !symbol.contains("^")
    }

    private static func close(onOrBefore date: String, in history: [String: Double]) -> Double? {
        if let exact = history[date] { return exact }
        return history.keys.filter { $0 <= date }.max().flatMap { history[$0] }
    }

    /// Aligns a sorted date axis in one pass. Chart preparation calls this for
    /// every holding; repeatedly scanning an entire price dictionary for every
    /// point made the returns tab unnecessarily expensive on iPhone.
    private static func closes(
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

    private static func message(from data: Data, fallback: String) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return fallback }
        return object["Error Message"] as? String
            ?? object["error"] as? String
            ?? object["message"] as? String
            ?? fallback
    }
}
