import Foundation

private struct CachedFundamental: Codable, Sendable {
    let ticker: String
    let providerSymbol: String
    let trailingPE: Double?
    let forwardPE: Double?
    let epsGrowthYoY: Double?
    let revenueGrowthYoY: Double?
    let fetchedAt: Date
}

private actor LocalFundamentalsCache {
    struct Lookup: Sendable {
        let record: CachedFundamental?
        let isFresh: Bool
        let wasAttemptedRecently: Bool
    }

    private struct Payload: Codable {
        var rows: [String: CachedFundamental]
        var attemptedAt: [String: Date]
    }

    static let shared = LocalFundamentalsCache()
    private static let ttl: TimeInterval = 12 * 60 * 60
    private static let failedAttemptTTL: TimeInterval = 5 * 60

    private var rows: [String: CachedFundamental] = [:]
    private var attemptedAt: [String: Date] = [:]
    private var hasLoaded = false

    func lookup(ticker: String) -> Lookup {
        loadIfNeeded()
        let key = ticker.uppercased()
        let row = rows[key]
        return Lookup(
            record: row,
            isFresh: row.map { Date().timeIntervalSince($0.fetchedAt) < Self.ttl } ?? false,
            wasAttemptedRecently: attemptedAt[key].map {
                Date().timeIntervalSince($0) < Self.failedAttemptTTL
            } ?? false
        )
    }

    func save(_ row: CachedFundamental) {
        loadIfNeeded()
        let key = row.ticker.uppercased()
        rows[key] = row
        attemptedAt[key] = Date()
        persist()
    }

    func markAttempt(ticker: String) {
        loadIfNeeded()
        attemptedAt[ticker.uppercased()] = Date()
        persist()
    }

    func clearFailedAttempts() {
        loadIfNeeded()
        attemptedAt = attemptedAt.filter { rows[$0.key] != nil }
        persist()
    }

    private func loadIfNeeded() {
        guard !hasLoaded else { return }
        hasLoaded = true
        guard let data = try? Data(contentsOf: cacheURL),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return }
        rows = payload.rows
        attemptedAt = payload.attemptedAt
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(Payload(rows: rows, attemptedAt: attemptedAt)) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }

    private var cacheURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("catfolio-fundamentals.json")
    }
}

struct LocalReturnsAnalyticsClient {
    private enum PartialResult: Sendable {
        case drawdown(DrawdownSeries)
        case valuation(ValuationMatrix)

        var part: ReturnsAnalyticsPart {
            switch self {
            case .drawdown: .drawdown
            case .valuation: .valuation
            }
        }
    }

    private struct ValuationSeed: Sendable {
        let ticker: String
        let yahooSymbol: String
        let displayName: String
        let marketValue: Double
        let weight: Double
    }

    private struct FundamentalFetchResult: Sendable {
        let ticker: String
        let record: CachedFundamental?
        let warning: String?
    }

    private static let fmpSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    static func resetFailedFundamentalAttempts() async {
        await LocalFundamentalsCache.shared.clearFailedAttempts()
    }

    /// Settings probes the same fundamental endpoints that power the valuation
    /// matrix. A historical-price success alone does not prove this feature can
    /// load P/E and growth data.
    func testFMPValuationConnection(apiKey: String) async throws -> String {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw LocalServiceError.missingMarketKey }

        let ratios = try await Self.fmpJSON(
            endpoint: "ratios-ttm",
            symbol: "AAPL",
            apiKey: key
        )
        let growth = try await Self.fmpJSON(
            endpoint: "income-statement-growth",
            symbol: "AAPL",
            apiKey: key,
            extraQuery: ["limit": "1"]
        )

        let ratiosPE = Self.firstNumber(
            in: ratios,
            keys: ["priceToEarningsRatioTTM", "priceEarningsRatioTTM"]
        )
        var trailingPE = ratiosPE
        if !Self.isTruthy(trailingPE) {
            let metrics = try await Self.fmpJSON(
                endpoint: "key-metrics-ttm",
                symbol: "AAPL",
                apiKey: key
            )
            trailingPE = Self.firstNumber(in: metrics, keys: ["peRatioTTM"])
        }
        if !Self.isTruthy(trailingPE) {
            let profile = try await Self.fmpJSON(
                endpoint: "profile",
                symbol: "AAPL",
                apiKey: key
            )
            trailingPE = Self.firstNumber(in: profile, keys: ["pe"])
        }

        let epsGrowth = Self.firstNumber(
            in: growth,
            keys: ["growthEPSDiluted", "growthEPS"]
        )
        let revenueGrowth = Self.firstNumber(in: growth, keys: ["growthRevenue"])

        guard Self.isTruthy(trailingPE) else {
            throw LocalServiceError.remote("FMP 未返回 AAPL 的 P/E 数据")
        }
        guard epsGrowth != nil || revenueGrowth != nil else {
            throw LocalServiceError.remote("FMP 未返回 AAPL 的成长数据")
        }
        return "连接成功，AAPL 的 P/E 与成长数据可用"
    }

    func load(
        document: LocalPortfolioDocument,
        onUpdate: @escaping @MainActor (
            _ completedPart: ReturnsAnalyticsPart,
            _ response: ReturnsAnalyticsResponse
        ) -> Void = { _, _ in }
    ) async -> ReturnsAnalyticsResponse {
        await withTaskGroup(of: PartialResult.self) { group in
            group.addTask {
                .drawdown(await Self.withTimeout(
                    seconds: 35,
                    fallback: DrawdownSeries(
                        rows: [],
                        maxDrawdown: 0,
                        warnings: ["回撤历史行情读取超时，请检查网络后下拉刷新。"]
                    )
                ) {
                    await drawdown(document: document)
                })
            }
            group.addTask {
                .valuation(await Self.withTimeout(
                    seconds: 35,
                    fallback: ValuationMatrix(
                        rows: [],
                        warnings: ["估值数据读取超时，请检查 FMP API Key 或网络后下拉刷新。"]
                    )
                ) {
                    await valuationMatrix(document: document)
                })
            }

            var drawdownResult: DrawdownSeries?
            var valuationResult: ValuationMatrix?
            for await result in group {
                switch result {
                case let .drawdown(value):
                    drawdownResult = value
                case let .valuation(value):
                    valuationResult = value
                }
                let response = Self.response(
                    drawdown: drawdownResult ?? .empty,
                    valuation: valuationResult ?? .empty
                )
                await onUpdate(result.part, response)
            }
            return Self.response(
                drawdown: drawdownResult ?? .empty,
                valuation: valuationResult ?? .empty
            )
        }
    }

    private static func response(
        drawdown: DrawdownSeries,
        valuation: ValuationMatrix
    ) -> ReturnsAnalyticsResponse {
        ReturnsAnalyticsResponse(
            drawdown: drawdown,
            valuation: valuation,
            warnings: unique(drawdown.warnings + valuation.warnings)
        )
    }

    private static func withTimeout<Value: Sendable>(
        seconds: TimeInterval,
        fallback: Value,
        operation: @escaping @Sendable () async -> Value
    ) async -> Value {
        await withTaskGroup(of: Value.self) { group in
            group.addTask { await operation() }
            group.addTask {
                do {
                    try await Task.sleep(
                        nanoseconds: UInt64(max(0, seconds) * 1_000_000_000)
                    )
                } catch {
                    return fallback
                }
                return fallback
            }
            let value = await group.next() ?? fallback
            group.cancelAll()
            return value
        }
    }

    // Mirrors Web `grouped_universe` + `drawdown_curve`: current market-value
    // weights, strict shared trading dates and a five-year model NAV.
    private func drawdown(document: LocalPortfolioDocument) async -> DrawdownSeries {
        var valuesBySymbol: [String: Double] = [:]
        for position in document.positions {
            let symbol = LocalMarketDataClient.yahooSymbol(
                ticker: position.ticker,
                currency: position.quoteCurrency
            )
            let marketValue = (try? LocalPortfolioEngine.usd(
                position.shares * position.quotePrice,
                currency: position.quoteCurrency
            )) ?? 0
            let costValue = (try? LocalPortfolioEngine.usd(
                position.shares * position.averageCost,
                currency: position.currency
            )) ?? 0
            let value = marketValue > 0 ? marketValue : costValue
            if value > 0 { valuesBySymbol[symbol, default: 0] += value }
        }

        let symbols = valuesBySymbol
            .sorted { $0.value > $1.value }
            .prefix(35)
            .map(\.key)
        guard !symbols.isEmpty else { return .empty }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let endDate = Date()
        let startDate = calendar.date(byAdding: .year, value: -5, to: endDate) ?? endDate
        let histories = await LocalMarketDataClient().historicalCloses(
            symbols: symbols,
            from: DayDateCodec.string(from: startDate),
            to: DayDateCodec.string(from: endDate)
        )

        // Web only admits symbols present in the history cache, then preserves
        // each admitted symbol's current value when aliases are grouped.
        let availableSymbols = symbols.filter { histories[$0] != nil }
        let missingSymbols = symbols.filter { histories[$0] == nil }
        var groups: [String: [String: Double]] = [:]
        for symbol in availableSymbols {
            let canonical = Self.canonicalSymbol(symbol)
            groups[canonical, default: [:]][symbol] = valuesBySymbol[symbol] ?? 0
        }
        guard !groups.isEmpty else {
            return DrawdownSeries(
                rows: [], maxDrawdown: 0,
                warnings: ["回撤曲线暂未读取到持仓历史行情。"]
            )
        }

        var groupValues: [String: Double] = [:]
        var returnsByGroup: [String: [String: Double]] = [:]
        for (groupName, members) in groups {
            let memberReturns = Dictionary(uniqueKeysWithValues: members.keys.map { symbol in
                (symbol, Self.dailyReturns(from: histories[symbol] ?? [:]))
            })
            let populatedDateSets = memberReturns.values
                .filter { !$0.isEmpty }
                .map { Set($0.keys) }
            let memberDates = Self.intersection(populatedDateSets)
            let memberTotal = max(members.values.reduce(0, +), 1)
            var groupReturns: [String: Double] = [:]
            for date in memberDates {
                groupReturns[date] = members.reduce(into: 0) { result, member in
                    guard let dailyReturn = memberReturns[member.key]?[date] else { return }
                    result += dailyReturn * member.value / memberTotal
                }
            }
            groupValues[groupName] = members.values.reduce(0, +)
            returnsByGroup[groupName] = groupReturns
        }

        let total = groupValues.values.reduce(0, +)
        guard total > 0 else { return .empty }
        let weights = groupValues.mapValues { $0 / total }
        let commonDates = Self.intersection(returnsByGroup.values.map { Set($0.keys) })
        guard !commonDates.isEmpty else {
            return DrawdownSeries(
                rows: [], maxDrawdown: 0,
                warnings: ["持仓行情没有足够的共同交易日，暂时无法计算回撤。"]
            )
        }

        var nav = 1.0
        var peak = 1.0
        var maxDrawdown = 0.0
        var rows: [DrawdownPoint] = []
        rows.reserveCapacity(commonDates.count)
        for date in commonDates {
            let dailyReturn = weights.reduce(into: 0) { result, item in
                result += (returnsByGroup[item.key]?[date] ?? 0) * item.value
            }
            nav *= 1 + dailyReturn
            peak = max(peak, nav)
            let value = peak > 0 ? nav / peak - 1 : 0
            maxDrawdown = min(maxDrawdown, value)
            rows.append(DrawdownPoint(dateText: date, drawdown: value))
        }

        var warnings: [String] = []
        if !missingSymbols.isEmpty {
            let preview = missingSymbols.prefix(8).joined(separator: "、")
            warnings.append("回撤曲线未计入缺少行情的持仓：\(preview)\(missingSymbols.count > 8 ? "…" : "")")
        }
        return DrawdownSeries(rows: rows, maxDrawdown: maxDrawdown, warnings: warnings)
    }

    private func valuationMatrix(document: LocalPortfolioDocument) async -> ValuationMatrix {
        let totalMarketValue = document.positions.reduce(into: 0.0) { result, position in
            result += (try? LocalPortfolioEngine.usd(
                position.shares * position.quotePrice,
                currency: position.quoteCurrency
            )) ?? 0
        }
        guard totalMarketValue > 0 else { return .empty }

        var grouped: [String: (displayName: String, yahooSymbol: String, marketValue: Double)] = [:]
        for position in document.positions where position.currency.uppercased() == "USD" {
            let ticker = position.ticker.uppercased()
            let value = (try? LocalPortfolioEngine.usd(
                position.shares * position.quotePrice,
                currency: position.quoteCurrency
            )) ?? 0
            guard value > 0 else { continue }
            let yahooSymbol = LocalMarketDataClient.yahooSymbol(
                ticker: ticker,
                currency: position.quoteCurrency
            )
            if let old = grouped[ticker] {
                grouped[ticker] = (old.displayName, old.yahooSymbol, old.marketValue + value)
            } else {
                grouped[ticker] = (
                    position.name.isEmpty ? ticker : position.name,
                    yahooSymbol,
                    value
                )
            }
        }

        let seeds = grouped.map { ticker, value in
            ValuationSeed(
                ticker: ticker,
                yahooSymbol: value.yahooSymbol,
                displayName: value.displayName,
                marketValue: value.marketValue,
                weight: value.marketValue / totalMarketValue
            )
        }.sorted { $0.marketValue > $1.marketValue }
        guard !seeds.isEmpty else {
            return ValuationMatrix(
                rows: [],
                warnings: ["估值矩阵目前只计算以 USD 为成本币种的持仓。"]
            )
        }

        var fundamentals: [String: CachedFundamental] = [:]
        var needsFetch: [ValuationSeed] = []
        for seed in seeds {
            let cached = await LocalFundamentalsCache.shared.lookup(ticker: seed.ticker)
            if let row = cached.record { fundamentals[seed.ticker] = row }
            if !cached.isFresh && !cached.wasAttemptedRecently { needsFetch.append(seed) }
        }

        var warnings: [String] = []
        if !needsFetch.isEmpty {
            guard let apiKey = KeychainStore.string(for: LocalServiceKeys.fmp), !apiKey.isEmpty else {
                warnings.append("估值矩阵需要 FMP API Key；可在设置中填写，Key 只保存在本机。")
                return Self.makeValuationMatrix(seeds: seeds, fundamentals: fundamentals, warnings: warnings)
            }
            let results = await Self.fetchFundamentals(seeds: needsFetch, apiKey: apiKey)
            guard !Task.isCancelled else {
                return Self.makeValuationMatrix(
                    seeds: seeds,
                    fundamentals: fundamentals,
                    warnings: warnings
                )
            }
            for result in results {
                if let record = result.record {
                    fundamentals[result.ticker] = record
                    await LocalFundamentalsCache.shared.save(record)
                } else {
                    await LocalFundamentalsCache.shared.markAttempt(ticker: result.ticker)
                }
                if let warning = result.warning { warnings.append(warning) }
            }
        }

        return Self.makeValuationMatrix(seeds: seeds, fundamentals: fundamentals, warnings: warnings)
    }

    private static func makeValuationMatrix(
        seeds: [ValuationSeed],
        fundamentals: [String: CachedFundamental],
        warnings: [String]
    ) -> ValuationMatrix {
        var rows: [ValuationBubble] = []
        for seed in seeds {
            guard let fundamental = fundamentals[seed.ticker] else { continue }
            let pe: Double?
            if let forward = fundamental.forwardPE, forward.isFinite, forward > 0 {
                pe = forward
            } else if let trailing = fundamental.trailingPE, trailing.isFinite, trailing > 0 {
                pe = trailing
            } else {
                pe = nil
            }
            guard let pe else { continue }

            let rawGrowth: Double?
            let source: String
            if let eps = fundamental.epsGrowthYoY, eps.isFinite {
                rawGrowth = eps
                source = "EPS 同比"
            } else if let revenue = fundamental.revenueGrowthYoY, revenue.isFinite {
                rawGrowth = revenue
                source = "营收同比"
            } else {
                rawGrowth = nil
                source = ""
            }
            guard let rawGrowth else { continue }
            let growth = abs(rawGrowth) <= 2 ? rawGrowth * 100 : rawGrowth
            rows.append(ValuationBubble(
                ticker: seed.ticker,
                displayName: seed.displayName,
                sector: Self.sector(for: seed.ticker),
                pe: pe,
                growthPercent: growth,
                growthSource: source,
                weight: seed.weight
            ))
        }

        let missing = seeds.filter { fundamentals[$0.ticker] == nil }.map(\.ticker)
        var combinedWarnings = warnings
        if !missing.isEmpty {
            let preview = missing.prefix(8).joined(separator: "、")
            combinedWarnings.append("暂未读取到估值数据：\(preview)\(missing.count > 8 ? "…" : "")")
        }
        let incomplete = seeds.compactMap { seed -> String? in
            guard let row = fundamentals[seed.ticker] else { return nil }
            let hasPE = [row.forwardPE, row.trailingPE]
                .compactMap { $0 }
                .contains { $0.isFinite && $0 > 0 }
            let hasGrowth = row.epsGrowthYoY?.isFinite == true
                || row.revenueGrowthYoY?.isFinite == true
            return hasPE && hasGrowth ? nil : seed.ticker
        }
        if !incomplete.isEmpty {
            let preview = incomplete.prefix(8).joined(separator: "、")
            combinedWarnings.append("缺少 P/E 或成长数据：\(preview)\(incomplete.count > 8 ? "…" : "")")
        }
        return ValuationMatrix(
            rows: rows.sorted { $0.weight > $1.weight },
            warnings: unique(combinedWarnings)
        )
    }

    private static func fetchFundamentals(
        seeds: [ValuationSeed],
        apiKey: String
    ) async -> [FundamentalFetchResult] {
        await withTaskGroup(of: FundamentalFetchResult.self) { group in
            var iterator = seeds.makeIterator()
            for _ in 0..<min(2, seeds.count) {
                guard let seed = iterator.next() else { break }
                group.addTask { await fetchFundamental(seed: seed, apiKey: apiKey) }
            }
            var results: [FundamentalFetchResult] = []
            while let result = await group.next() {
                results.append(result)
                if let seed = iterator.next() {
                    group.addTask { await fetchFundamental(seed: seed, apiKey: apiKey) }
                }
            }
            return results
        }
    }

    private static func fetchFundamental(
        seed: ValuationSeed,
        apiKey: String
    ) async -> FundamentalFetchResult {
        var lastError: Error?
        for symbol in fmpSymbolCandidates(seed) {
            guard !Task.isCancelled else {
                return FundamentalFetchResult(ticker: seed.ticker, record: nil, warning: nil)
            }
            do {
                let ratios = try await fmpJSON(endpoint: "ratios-ttm", symbol: symbol, apiKey: apiKey)
                let growth = try await fmpJSON(
                    endpoint: "income-statement-growth", symbol: symbol,
                    apiKey: apiKey, extraQuery: ["limit": "1"]
                )
                let ratiosPE = firstNumber(
                    in: ratios,
                    keys: ["priceToEarningsRatioTTM", "priceEarningsRatioTTM"]
                )
                let metricsPE: Double?
                if Self.isTruthy(ratiosPE) {
                    metricsPE = nil
                } else {
                    let metrics = try await fmpJSON(
                        endpoint: "key-metrics-ttm", symbol: symbol, apiKey: apiKey
                    )
                    metricsPE = firstNumber(in: metrics, keys: ["peRatioTTM"])
                }
                let profilePE: Double?
                if Self.isTruthy(ratiosPE) || Self.isTruthy(metricsPE) {
                    profilePE = nil
                } else {
                    let profile = try await fmpJSON(endpoint: "profile", symbol: symbol, apiKey: apiKey)
                    profilePE = firstNumber(in: profile, keys: ["pe"])
                }
                let trailingPE = firstTruthyNumber(ratiosPE, metricsPE, profilePE)
                let epsGrowth = firstNumber(in: growth, keys: ["growthEPSDiluted", "growthEPS"])
                let revenueGrowth = firstNumber(in: growth, keys: ["growthRevenue"])
                if trailingPE != nil || epsGrowth != nil || revenueGrowth != nil {
                    return FundamentalFetchResult(
                        ticker: seed.ticker,
                        record: CachedFundamental(
                            ticker: seed.ticker,
                            providerSymbol: symbol,
                            trailingPE: trailingPE,
                            forwardPE: nil,
                            epsGrowthYoY: epsGrowth,
                            revenueGrowthYoY: revenueGrowth,
                            fetchedAt: Date()
                        ),
                        warning: nil
                    )
                }
            } catch is CancellationError {
                return FundamentalFetchResult(ticker: seed.ticker, record: nil, warning: nil)
            } catch {
                lastError = error
            }
            do {
                try await Task.sleep(nanoseconds: 80_000_000)
            } catch {
                return FundamentalFetchResult(ticker: seed.ticker, record: nil, warning: nil)
            }
        }
        return FundamentalFetchResult(
            ticker: seed.ticker,
            record: nil,
            warning: "\(seed.ticker) 估值数据读取失败：\(lastError?.localizedDescription ?? "暂无数据")"
        )
    }

    private static func fmpJSON(
        endpoint: String,
        symbol: String,
        apiKey: String,
        extraQuery: [String: String] = [:]
    ) async throws -> Any {
        var components = URLComponents(string: "https://financialmodelingprep.com/stable/\(endpoint)")!
        components.queryItems = (["symbol": symbol, "apikey": apiKey].merging(extraQuery) { first, _ in first })
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for attempt in 0..<3 {
            try Task.checkCancellation()
            try await FMPRequestLimiter.shared.waitForTurn()
            let (data, response) = try await fmpSession.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw LocalServiceError.invalidResponse }
            if (200..<300).contains(http.statusCode) {
                return try JSONSerialization.jsonObject(with: data)
            }
            if http.statusCode == 429, attempt < 2 {
                let retryAfter = http.value(forHTTPHeaderField: "Retry-After")
                    .flatMap(Double.init) ?? pow(2, Double(attempt))
                try await Task.sleep(nanoseconds: UInt64(max(0.5, retryAfter) * 1_000_000_000))
                continue
            }
            throw LocalServiceError.remote(
                fmpMessage(from: data, fallback: "FMP 请求失败（\(http.statusCode)）")
            )
        }
        throw LocalServiceError.remote("FMP 请求次数已达限制，请稍后重试")
    }

    private static func firstNumber(in payload: Any, keys: [String]) -> Double? {
        let dictionary: [String: Any]?
        if let rows = payload as? [[String: Any]] {
            dictionary = rows.first
        } else {
            dictionary = payload as? [String: Any]
        }
        guard let dictionary else { return nil }
        for key in keys {
            if let number = dictionary[key] as? NSNumber {
                let value = number.doubleValue
                if value.isFinite { return value }
            }
            if let text = dictionary[key] as? String,
               let value = Double(text), value.isFinite { return value }
        }
        return nil
    }

    private static func firstTruthyNumber(_ values: Double?...) -> Double? {
        values.compactMap { $0 }.first { $0 != 0 }
    }

    private static func isTruthy(_ value: Double?) -> Bool {
        value.map { $0 != 0 } ?? false
    }

    private static func fmpMessage(from data: Data, fallback: String) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return fallback }
        return (object["Error Message"] as? String)
            ?? (object["message"] as? String)
            ?? (object["error"] as? String)
            ?? fallback
    }

    private static func fmpSymbolCandidates(_ seed: ValuationSeed) -> [String] {
        var result: [String] = []
        for symbol in [seed.ticker, seed.yahooSymbol] {
            var variants = [symbol]
            if symbol == "BRK.B" { variants.append("BRK-B") }
            if symbol.hasSuffix(".L") { variants.append(String(symbol.dropLast(2))) }
            for candidate in variants where !candidate.isEmpty && !result.contains(candidate) {
                result.append(candidate)
            }
        }
        return result
    }

    private static func dailyReturns(from history: [String: Double]) -> [String: Double] {
        var previous: Double?
        var result: [String: Double] = [:]
        for (date, close) in history.sorted(by: { $0.key < $1.key }) where close > 0 {
            if let previous, previous > 0 { result[date] = close / previous - 1 }
            previous = close
        }
        return result
    }

    private static func intersection(_ sets: [Set<String>]) -> [String] {
        guard let first = sets.first else { return [] }
        return sets.dropFirst().reduce(first) { $0.intersection($1) }.sorted()
    }

    private static func canonicalSymbol(_ symbol: String) -> String {
        ["VUAG.L": "S&P 500 Fund", "VUSA.L": "S&P 500 Fund"][symbol] ?? symbol
    }

    private static func sector(for ticker: String) -> String {
        var base = ticker.uppercased().replacingOccurrences(of: ".L", with: "")
        base = base.replacingOccurrences(of: "_EQ", with: "")
        return sectorByTicker[base] ?? "Other / Unclassified"
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    // Keep this mapping aligned with the Web analytics layer. It intentionally
    // remains local/approximate so the same holding receives the same color.
    private static let sectorByTicker: [String: String] = [
        "AAPL": "Technology", "AVGO": "Technology", "CHKP": "Technology",
        "GOOG": "Communication Services", "GOOGL": "Communication Services",
        "META": "Communication Services", "MRVL": "Technology", "MSFT": "Technology",
        "NVDA": "Technology", "ORCL": "Technology", "PANW": "Technology",
        "QCOM": "Technology", "SNOW": "Technology", "ZS": "Technology",
        "BARC": "Financials", "BATS": "Consumer Staples", "BRK.B": "Financials",
        "BRK-B": "Financials", "CEG": "Utilities", "CLS": "Technology",
        "EQGB": "ETF / Multi-Asset", "FTNT": "Technology",
        "GAW": "Consumer Discretionary", "GSK": "Healthcare", "LGEN": "Financials",
        "LLOY": "Financials", "MNG": "Financials", "NG": "Utilities",
        "NXT": "Consumer Discretionary", "OKTA": "Technology", "OSB": "Financials",
        "PHNX": "Financials", "PHP": "Real Estate", "RR": "Industrials",
        "RWE": "Utilities", "SGLN": "Commodities", "SIE": "Industrials",
        "SILG": "Commodities", "VUAG": "ETF / S&P 500", "VUSA": "ETF / S&P 500",
        "VHVG": "ETF / Global Equity", "VEUA": "ETF / Europe Equity",
        "XUSE": "ETF / S&P 500", "NOK": "Communication Equipment",
        "GEV": "Industrials", "AES": "Utilities", "ANAE": "ETF / Clean Energy",
        "ANRJ": "ETF / Clean Energy", "AV": "Financials", "CNA": "Utilities",
        "CNX1": "ETF / Nasdaq 100", "CUKX": "ETF / UK Equity", "ENL1": "Utilities",
        "ENR": "Industrials", "FPP": "Consumer Discretionary",
        "IBEE": "ETF / Clean Energy", "IITU": "ETF / Technology",
        "SOHO": "Real Estate", "SPGP": "Commodities", "SSLN": "Commodities",
        "VIEP": "ETF / Europe Equity"
    ]
}
