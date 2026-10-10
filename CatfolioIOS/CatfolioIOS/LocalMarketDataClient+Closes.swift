import Foundation
import CryptoKit
import FoundationModels
import OSLog

extension LocalMarketDataClient {
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

    func historicalCloses(
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
            let fetched = try await yahooHistoricalCloses(symbol: symbol, from: from, to: to, dividendAdjusted: dividendAdjusted)
            if !fetched.isEmpty {
                let yahoo = Self.keepingDroppedCloses(fetched, saved: cached?.values)
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

        if Self.fmpCoversSymbol(symbol), KeychainStore.string(for: LocalServiceKeys.fmp)?.isEmpty == false {
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

    /// A full fetch can come back with a session Yahoo reported before now
    /// left empty. Keep the saved close for such a day inside the fetched
    /// span, on the fetched basis: a split or dividend since re-bases every
    /// earlier close, and the earliest day both share says by how much.
    static func keepingDroppedCloses(_ fetched: [String: Double], saved: [String: Double]?) -> [String: Double] {
        guard let saved, let first = fetched.keys.min(), let last = fetched.keys.max(),
              let anchor = fetched.keys.filter({ saved[$0] != nil }).min(),
              let then = saved[anchor], then > 0, let now = fetched[anchor] else { return fetched }
        let ratio = now / then
        var result = fetched
        for (date, close) in saved where date > first && date < last && result[date] == nil && close > 0 {
            result[date] = close * ratio
        }
        return result
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
        let (data, response) = try await MarketRequestCoalescer.shared.data(for: request, session: Self.yahooSession)
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
        let (data, response) = try await MarketRequestCoalescer.shared.data(for: request, session: Self.yahooSession)
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
}
