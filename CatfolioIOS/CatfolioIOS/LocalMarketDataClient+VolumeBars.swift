import Foundation
import CryptoKit
import FoundationModels
import OSLog

extension LocalMarketDataClient {
    func volumeProfile(
        ticker: String,
        currency: String,
        referencePrice: Double? = nil,
        forceRefresh: Bool = false,
        cachedOnly: Bool = false
    ) async throws -> VolumeProfile {
        let end = DayDateFormatter.shared.string(from: Date())
        return try await withVolumeBars(ticker: ticker, currency: currency,
            forceRefresh: forceRefresh, cachedOnly: cachedOnly) { bars in
            try Self.makeVolumeProfile(bars: bars, ticker: ticker, currency: currency,
                referencePrice: referencePrice, fallbackDate: end)
        }
    }

    func fiftyTwoWeekRange(ticker: String, currency: String) async throws -> Holding52WeekRange {
        let scale = Self.priceScale(ticker: ticker, currency: currency,
            referencePrice: nil, marketPrice: nil)
        return try await withVolumeBars(ticker: ticker, currency: currency) { bars in
            guard let range = Holding52WeekRange.make(bars: bars, currency: currency, scale: scale) else {
                throw LocalServiceError.noMarketData
            }
            return range
        }
    }

    /// The volume profile from the same cached daily bars as the 52-week range.
    func volumeRange(ticker: String, currency: String) async throws -> HoldingVolumeRange {
        guard let range = HoldingVolumeRange(profile: try await volumeProfile(ticker: ticker, currency: currency))
        else { throw LocalServiceError.noMarketData }
        return range
    }

    private func withVolumeBars<Value>(ticker: String, currency: String,
                                      forceRefresh: Bool = false, cachedOnly: Bool = false,
                                      transform: ([MarketDailyBar]) throws -> Value) async throws -> Value {
        let end = DayDateFormatter.shared.string(from: Date())
        let start = DayDateFormatter.shared.string(
            from: Calendar.current.date(byAdding: .day, value: -370, to: Date()) ?? Date()
        )
        let marketSymbol = Self.yahooSymbol(ticker: ticker, currency: currency)
        if let security = ChinaSecurity(marketSymbol) {
            return try await transform(ChinaMarketDataClient().daily(security, from: start, to: end,
                adjusted: false, forceRefresh: forceRefresh, cachedOnly: cachedOnly))
        }
        if let archive = DelistedPriceArchive.entry(for: marketSymbol) {
            return try transform(archive.dailyBars(from: start, to: end))
        }
        let cached = await LocalVolumeBarCache.shared.lookup(symbol: marketSymbol)
        if let cached, cachedOnly || (!forceRefresh && cached.isFresh) {
            return try transform(cached.bars)
        }

        guard !cachedOnly else { throw LocalServiceError.noMarketData }

        var latestError: Error?
        if Self.supportsMassiveStockSymbol(marketSymbol),
           let key = KeychainStore.string(for: LocalServiceKeys.massive), !key.isEmpty {
            do {
                let bars = try await massiveHistoricalBars(symbol: marketSymbol, from: start, to: end, key: key)
                await LocalVolumeBarCache.shared.save(symbol: marketSymbol, bars: bars)
                return try transform(bars)
            } catch {
                latestError = error
            }
        }

        do {
            let bars = try await yahooHistoricalBars(symbol: marketSymbol, from: start, to: end)
            await LocalVolumeBarCache.shared.save(symbol: marketSymbol, bars: bars)
            return try transform(bars)
        } catch {
            latestError = error
        }

        if Self.fmpCoversSymbol(marketSymbol),
           let key = KeychainStore.string(for: LocalServiceKeys.fmp), !key.isEmpty {
            do {
                let bars = try await fmpHistoricalBars(ticker: ticker, from: start, to: end, key: key)
                await LocalVolumeBarCache.shared.save(symbol: marketSymbol, bars: bars)
                return try transform(bars)
            } catch {
                latestError = error
            }
        }

        if let cached {
            return try transform(cached.bars)
        }
        throw latestError ?? LocalServiceError.noMarketData
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

    func fmpHistoricalBars(
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

    func massiveHistoricalBars(
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

    func yahooHistoricalBars(
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
        let (data, response) = try await MarketRequestCoalescer.shared.data(for: request, session: Self.yahooSession)
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
}
