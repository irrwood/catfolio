import Foundation
import CryptoKit
import FoundationModels
import OSLog

extension LocalMarketDataClient {
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
        let chinaConfiguration = ChinaMarketConfiguration.scope(ticker: symbol, currency: currency)
        let closes: [String: Double]
        let intradayBars: [MarketIntradayBar]
        let chinaAttribution: ChinaMarketAttribution?
        if let security = ChinaSecurity(symbol), let chinaConfiguration {
            let history = try await ChinaMarketDataClient(selection: chinaConfiguration.source)
                .history(security, from: start, to: end, forceRefresh: forceRefresh, cachedOnly: cachedOnly)
            guard chinaConfiguration == .current else { throw CancellationError() }
            closes = Dictionary(uniqueKeysWithValues: history.daily.map { ($0.date, $0.close) })
            intradayBars = history.intraday
            chinaAttribution = history.attribution
        } else {
            async let dailyCloses = historicalCloses(symbol: symbol, from: start, to: end,
                                                    cachedOnly: cachedOnly, forceRefresh: forceRefresh)
            async let latestIntradayBars = self.intradayBars(symbol: symbol, forceRefresh: forceRefresh,
                                                        cachedOnly: cachedOnly, includingExtendedHours: true)
            closes = try await dailyCloses
            intradayBars = (try? await latestIntradayBars) ?? []
            chinaAttribution = nil
        }
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
        let allIntradayPoints = intradayBars.compactMap { bar -> SecurityPricePoint? in
            let adjusted = bar.close * scale
            guard adjusted.isFinite, adjusted > 0 else { return nil }
            return SecurityPricePoint(
                dateText: String(Int(bar.timestamp.timeIntervalSince1970)),
                close: adjusted,
                timestamp: bar.timestamp,
                sessionWindow: bar.sessionWindow
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

        let hasExtendedHours = Self.supportsMassiveStockSymbol(symbol)
        let extendedPoints = allIntradayPoints.filter { hasExtendedHours && $0.marketSession.isExtended }
        let regularPoints = allIntradayPoints.filter { !hasExtendedHours || $0.marketSession == .regular }
        return SecurityPriceHistory(
            ticker: ticker,
            currency: currency,
            points: points,
            intradayPoints: regularPoints,
            trades: trades,
            extendedHoursPoints: extendedPoints,
            chinaMarketAttribution: chinaAttribution,
            chinaMarketConfiguration: chinaConfiguration
        )
    }

    func intradayBars(symbol: String, forceRefresh: Bool = false, allowsStaleFallback: Bool = true,
                      cachedOnly: Bool = false, includingExtendedHours: Bool = false) async throws -> [MarketIntradayBar] {
        if DelistedPriceArchive.entry(for: symbol) != nil { return [] }
        if let security = ChinaSecurity(symbol) {
            return try await ChinaMarketDataClient().intraday(security, forceRefresh: forceRefresh,
                cachedOnly: cachedOnly, allowsStaleFallback: allowsStaleFallback)
        }
        return try await Self.loadIntradayBars(symbol: symbol, forceRefresh: forceRefresh,
            allowsStaleFallback: allowsStaleFallback, cachedOnly: cachedOnly,
            includingExtendedHours: includingExtendedHours, cache: .shared,
            yahoo: { try await yahooIntradayBars(symbol: symbol) },
            massive: {
                guard let key = KeychainStore.string(for: LocalServiceKeys.massive), !key.isEmpty else {
                    throw LocalServiceError.noMarketData
                }
                return try await massiveIntradayBars(symbol: symbol, key: key)
            })
    }

    /// Keep provider ordering, validation and cache fallback in one path, so
    /// a failed or empty Yahoo response reaches Massive before stale data.
    static func loadIntradayBars(
        symbol: String, forceRefresh: Bool = false, allowsStaleFallback: Bool = true,
        cachedOnly: Bool = false, includingExtendedHours: Bool = false,
        cache: LocalIntradayPriceCache,
        yahoo: @escaping () async throws -> [MarketIntradayBar],
        massive: @escaping () async throws -> [MarketIntradayBar]
    ) async throws -> [MarketIntradayBar] {
        try Task.checkCancellation()
        let cached = await cache.lookup(symbol: symbol)
        func session(_ bars: [MarketIntradayBar]) throws -> [MarketIntradayBar] {
            try Self.latestMarketSession(from: bars, symbol: symbol, includingExtendedHours: includingExtendedHours)
        }
        if cachedOnly { return (try? session(cached?.bars ?? [])) ?? [] }
        if !forceRefresh, let cached, cached.isFresh,
           !includingExtendedHours || !Self.supportsMassiveStockSymbol(symbol)
               || cached.includesExtendedHours,
           let bars = try? session(cached.bars) { return bars }

        var latestError: Error?
        // Extended-hours detail requests prefer Yahoo's actual session
        // windows so early closes are classified by the feed itself.
        let providers = Self.supportsMassiveStockSymbol(symbol)
            ? (includingExtendedHours ? [yahoo, massive] : [massive, yahoo])
            : [yahoo]
        for fetch in providers {
            do {
                let bars = try await fetch()
                try Task.checkCancellation()
                let selected = try session(bars)
                await cache.save(symbol: symbol, bars: bars, includesExtendedHours: includingExtendedHours)
                return selected
            } catch {
                // Closing the page is not an outage: do not start another
                // network request or replace its cache after cancellation.
                if error is CancellationError || (error as? URLError)?.code == .cancelled {
                    throw error
                }
                try Task.checkCancellation()
                latestError = error
            }
        }

        if allowsStaleFallback, let cached { return try session(cached.bars) }
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
        return bars
    }

    private func yahooIntradayBars(symbol: String) async throws -> [MarketIntradayBar] {
        let request = Self.yahooIntradayRequest(symbol: symbol)
        let (data, response) = try await MarketRequestCoalescer.shared.data(for: request, session: Self.yahooSession)
        guard let http = response as? HTTPURLResponse else { throw LocalServiceError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw LocalServiceError.remote("Yahoo 日内行情请求失败（\(http.statusCode)）")
        }
        do {
            return try Self.decodeYahooIntradayBars(data, symbol: symbol)
        } catch let error as DecodingError {
            DataSourceHealth.reportUnusable(DataSource.of(request.url), issue: .invalidFormat)
            throw error
        }
    }

    static func yahooIntradayRequest(symbol: String, now: Date = .now) -> URLRequest {
        let endDate = now
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
            URLQueryItem(name: "includePrePost", value: "true"),
        ]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 9
        request.setValue("Mozilla/5.0 Catfolio-iOS", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    static func decodeYahooIntradayBars(_ data: Data, symbol: String) throws -> [MarketIntradayBar] {
        let payload = try JSONDecoder().decode(YahooChartResponse.self, from: data)
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
            let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
            bars.append(MarketIntradayBar(
                timestamp: date,
                close: close * unitScale,
                sessionWindow: result.meta?.sessionWindow(at: date)
            ))
        }
        guard !bars.isEmpty else { throw LocalServiceError.noMarketData }
        return bars
    }

    static func latestMarketSession(
        from bars: [MarketIntradayBar],
        symbol: String,
        includingExtendedHours: Bool = false
    ) throws -> [MarketIntradayBar] {
        let usStock = supportsMassiveStockSymbol(symbol)
        // Filter before choosing the day: at 04:00 today's first pre-market
        // bar must not displace yesterday's regular quote for portfolio math.
        let sorted = bars.filter { bar in
            guard bar.close.isFinite, bar.close > 0 else { return false }
            guard usStock else { return true }
            let session = bar.marketSession
            return session == .regular || (includingExtendedHours && session.isExtended)
        }.sorted { $0.timestamp < $1.timestamp }
        let grouped = Dictionary(grouping: sorted) {
            sessionKey(for: $0.timestamp, symbol: symbol)
        }
        guard let latestKey = grouped.keys.max(),
              let latest = grouped[latestKey], !latest.isEmpty else {
            throw LocalServiceError.noMarketData
        }
        return latest
    }

    static func marketDayStart(_ day: String, symbol: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = marketTimeZone(for: symbol)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: day)
    }

    static func sessionKey(for date: Date, symbol: String) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = marketTimeZone(for: symbol)
        let values = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", values.year ?? 0, values.month ?? 0, values.day ?? 0)
    }

    private static func marketTimeZone(for symbol: String) -> TimeZone {
        if ChinaSecurity(symbol) != nil { return ChinaSecurity.timeZone }
        if symbol.hasSuffix(".L") { return TimeZone(identifier: "Europe/London")! }
        if symbol.hasSuffix(".HK") { return TimeZone(identifier: "Asia/Hong_Kong")! }
        if symbol.hasSuffix(".T") { return TimeZone(identifier: "Asia/Tokyo")! }
        if symbol.hasSuffix(".DE") { return TimeZone(identifier: "Europe/Berlin")! }
        return TimeZone(identifier: "America/New_York")!
    }
}
