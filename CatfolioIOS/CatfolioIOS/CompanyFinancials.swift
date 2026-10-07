import Foundation

enum FinancialPeriodKind: String, Codable, Sendable {
    case annual
    case quarterly
}

struct IncomeStatementPeriod: Codable, Identifiable, Sendable {
    let periodEnd: String
    let filedDate: String?
    let fiscalYear: Int
    let fiscalPeriod: String
    let kind: FinancialPeriodKind
    let currency: String
    let revenue: Double
    let costOfRevenue: Double
    let grossProfit: Double
    let operatingExpenses: Double
    let operatingIncome: Double
    let netIncome: Double?

    var id: String { "income-\(kind.rawValue)-\(periodEnd)-\(fiscalPeriod)" }
}

struct BalanceSheetPeriod: Codable, Identifiable, Sendable {
    let periodEnd: String
    let filedDate: String?
    let fiscalYear: Int
    let fiscalPeriod: String
    let kind: FinancialPeriodKind
    let currency: String
    let assets: Double
    let liabilities: Double
    let equity: Double
    let cash: Double?
    let debt: Double?

    var id: String { "balance-\(kind.rawValue)-\(periodEnd)-\(fiscalPeriod)" }
}

struct CashFlowStatementPeriod: Codable, Identifiable, Sendable {
    let periodEnd: String
    let filedDate: String?
    let fiscalYear: Int
    let fiscalPeriod: String
    let kind: FinancialPeriodKind
    let currency: String
    let operatingCashFlow: Double
    let capitalExpenditure: Double
    let freeCashFlow: Double
    let investingCashFlow: Double?
    let financingCashFlow: Double?

    var id: String { "cash-\(kind.rawValue)-\(periodEnd)-\(fiscalPeriod)" }
}

struct CompanyFinancialsData: Codable, Sendable {
    let ticker: String
    let entityName: String
    let cik: Int?
    let source: String
    let income: [IncomeStatementPeriod]
    let balance: [BalanceSheetPeriod]
    let cashFlow: [CashFlowStatementPeriod]
    let warnings: [String]
    /// Diluted shares from the latest filing, for a market value against the
    /// statements; nil from providers other than SEC and on older caches.
    var sharesOutstanding: Double? = nil
    var valuationQuality: ValuationQuality? = nil
    var valuationSchemaVersion: Int? = nil

    var hasUsableStatements: Bool {
        income.contains { [$0.revenue, $0.costOfRevenue, $0.grossProfit, $0.operatingExpenses, $0.operatingIncome].allSatisfy(\.isFinite) }
        || balance.contains { [$0.assets, $0.liabilities, $0.equity].allSatisfy(\.isFinite) }
        || cashFlow.contains { [$0.operatingCashFlow, $0.capitalExpenditure, $0.freeCashFlow].allSatisfy(\.isFinite) }
    }
}

enum CompanyFinancialsError: LocalizedError, Equatable {
    case unsupportedTicker
    case invalidResponse
    case remote(String)
    case noStatements

    var errorDescription: String? {
        switch self {
        case .unsupportedTicker:
            L10n.text("SEC 没有找到这只证券对应的申报公司")
        case .invalidResponse:
            L10n.text("财务数据返回格式无法识别")
        case let .remote(message):
            L10n.message(message)
        case .noStatements:
            L10n.text("暂未读取到可用于财务图的年度或季度报表")
        }
    }
}

actor CompanyFinancialsClient {
    static let shared = CompanyFinancialsClient()

    private struct CacheEntry: Codable {
        let fetchedAt: Date
        let data: CompanyFinancialsData
    }

    struct SECTickerRow: Codable {
        let cik: Int
        let ticker: String
        let title: String

        init(cik: Int, ticker: String, title: String) {
            self.cik = cik
            self.ticker = ticker
            self.title = title
        }

        enum CodingKeys: String, CodingKey {
            case cik = "cik_str"
            case ticker
            case title
        }
    }

    struct SECCompanyFacts: Decodable {
        let cik: Int
        let entityName: String
        let facts: [String: [String: SECFact]]
    }

    struct SECFact: Decodable {
        let label: String?
        let units: [String: [SECFactValue]]
    }

    struct SECFactValue: Decodable {
        let start: String?
        let end: String
        let value: Double
        let fiscalYear: Int?
        let fiscalPeriod: String?
        let form: String?
        let filed: String?
        let frame: String?
        var accession: String? = nil

        enum CodingKeys: String, CodingKey {
            case start
            case end
            case value = "val"
            case fiscalYear = "fy"
            case fiscalPeriod = "fp"
            case form
            case filed
            case frame
            case accession = "accn"
        }
    }

    struct FMPIncomeRow: Decodable {
        let date: String
        let reportedCurrency: String?
        let fiscalYear: String?
        let period: String?
        let revenue: Double?
        let costOfRevenue: Double?
        let grossProfit: Double?
        let operatingExpenses: Double?
        let operatingIncome: Double?
        let netIncome: Double?
        let fillingDate: String?
    }

    struct FMPBalanceRow: Decodable {
        let date: String
        let reportedCurrency: String?
        let fiscalYear: String?
        let period: String?
        let totalAssets: Double?
        let totalLiabilities: Double?
        let totalStockholdersEquity: Double?
        let cashAndCashEquivalents: Double?
        let totalDebt: Double?
        let fillingDate: String?
    }

    struct FMPCashRow: Decodable {
        let date: String
        let reportedCurrency: String?
        let fiscalYear: String?
        let period: String?
        let operatingCashFlow: Double?
        let capitalExpenditure: Double?
        let freeCashFlow: Double?
        let netCashProvidedByOperatingActivities: Double?
        let netCashUsedForInvestingActivites: Double?
        let netCashUsedProvidedByFinancingActivities: Double?
        let fillingDate: String?
    }

    struct NasdaqFinancialsResponse: Decodable {
        struct Status: Decodable { let rCode: Int? }
        let data: NasdaqFinancialsData?
        let status: Status?
        var allowsStatementRead: Bool {
            if let code = status?.rCode { return (200..<300).contains(code) }
            return data != nil
        }
    }

    struct NasdaqFinancialsData: Decodable {
        let symbol: String
        let incomeStatementTable: NasdaqStatementTable?
        let balanceSheetTable: NasdaqStatementTable?
        let cashFlowTable: NasdaqStatementTable?
    }

    struct NasdaqStatementTable: Decodable {
        let headers: [String: String]
        let rows: [[String: String]]
    }

    private static let secConcepts = SECConceptCatalog()
    private let session: URLSession
    private var statementCache: [String: CacheEntry] = [:]
    private var tickerMap: [String: SECTickerRow] = [:]
    private var didLoadStatementCache = false
    private var didLoadTickerCache = false
    private var tickerCacheDate: Date?
    private var secBackoffUntil: Date?
    private let freshness: TimeInterval = 24 * 60 * 60

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 18
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.urlCache = URLCache(
            memoryCapacity: 8 * 1_024 * 1_024,
            diskCapacity: 48 * 1_024 * 1_024
        )
        session = URLSession(configuration: configuration)
    }

    func load(ticker: String, forceRefresh: Bool = false) async throws -> CompanyFinancialsData {
        loadStatementCacheIfNeeded()
        let key = Self.normalizedTicker(ticker)
        let stale = statementCache[key]
        var onlyConfirmedAbsence = true
        if !forceRefresh,
           let stale,
           Date().timeIntervalSince(stale.fetchedAt) < freshness,
           (!stale.data.source.hasPrefix("SEC") || stale.data.valuationSchemaVersion == 1) {
            return stale.data
        }

        do {
            let secData = try await loadFromSEC(ticker: key, forceRefresh: forceRefresh || stale != nil)
            let merged = try await supplementFromFMPIfNeeded(secData, ticker: ticker)
            save(merged, key: key)
            return merged
        } catch {
            try Task.checkCancellation()
            onlyConfirmedAbsence = Self.confirmsNoStatements(error)
            // Continue through cache and fallback providers below.
        }

        // A recently cached report is more trustworthy than silently changing
        // providers merely because SEC is applying a temporary network block.
        if let stale,
           Date().timeIntervalSince(stale.fetchedAt) < 7 * 24 * 60 * 60 {
            return stale.data
        }

        if let apiKey = KeychainStore.string(for: LocalServiceKeys.fmp)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !apiKey.isEmpty {
            do {
                let fallback = try await loadFromFMP(ticker: ticker, apiKey: apiKey)
                save(fallback, key: key)
                return fallback
            } catch {
                try Task.checkCancellation()
                onlyConfirmedAbsence = onlyConfirmedAbsence && Self.confirmsNoStatements(error)
                // Continue to the keyless Nasdaq fallback below.
            }
        }

        do {
            let fallback = try await loadFromNasdaq(ticker: ticker)
            save(fallback, key: key)
            return fallback
        } catch {
            try Task.checkCancellation()
            if let stale { return stale.data }
            onlyConfirmedAbsence = onlyConfirmedAbsence && Self.confirmsNoStatements(error)
        }

        if onlyConfirmedAbsence { throw CompanyFinancialsError.noStatements }
        throw CompanyFinancialsError.remote(
            L10n.text("SEC 当前限制了此网络，备用财务数据也暂时不可用。请稍后下拉重试。")
        )
    }

    nonisolated static func confirmsNoStatements(_ error: Error) -> Bool {
        guard let error = error as? CompanyFinancialsError else { return false }
        return error == .noStatements || error == .unsupportedTicker
    }

    /// Read-only visibility check. Never runs SEC/FMP/Nasdaq or ages data out.
    func cached(ticker: String) -> CompanyFinancialsData? {
        loadStatementCacheIfNeeded()
        return statementCache[Self.normalizedTicker(ticker)]?.data
    }

    private func loadFromSEC(ticker: String, forceRefresh: Bool) async throws -> CompanyFinancialsData {
        let row = try await secTicker(for: ticker, forceRefresh: forceRefresh)
        let cik = String(format: "%010d", row.cik)
        let url = URL(string: "https://data.sec.gov/api/xbrl/companyfacts/CIK\(cik).json")!
        let data = try await request(url: url, isSEC: true, forceRefresh: forceRefresh)
        let payload: SECCompanyFacts
        do {
            payload = try JSONDecoder().decode(SECCompanyFacts.self, from: data)
        } catch {
            DataSourceHealth.reportUnusable(DataSource.of(url), "Company Facts 的格式无法识别", subject: ticker)
            throw CompanyFinancialsError.invalidResponse
        }

        let namespace = payload.facts["us-gaap"] ?? payload.facts["ifrs-full"] ?? [:]
        let income = Self.makeSECIncome(namespace: namespace)
        let balance = Self.makeSECBalance(namespace: namespace)
        let cashFlow = Self.makeSECCashFlow(namespace: namespace)
        guard !income.isEmpty || !balance.isEmpty || !cashFlow.isEmpty else {
            // The filing arrived; none of its tags formed a statement. Said
            // here, not left as an empty page, since the answer is usually a
            // tag the catalogue does not read yet (SoFi's, until 2026-09).
            DataSourceHealth.reportUnusable(DataSource.of(url), "申报里没有能组成报表的标签", subject: ticker)
            throw CompanyFinancialsError.noStatements
        }
        return CompanyFinancialsData(
            ticker: ticker,
            entityName: payload.entityName,
            cik: payload.cik,
            source: "SEC Company Facts · 10-K / 10-Q",
            income: income,
            balance: balance,
            cashFlow: cashFlow,
            warnings: [],
            sharesOutstanding: Self.latestShares(payload.facts),
            valuationQuality: SECQualityCalculator.calculate(payload.facts, cik: payload.cik),
            valuationSchemaVersion: 1
        )
    }

    /// The latest diluted weighted-average share count, a quarter's if there
    /// is one; failing that, the cover page's shares outstanding, summed over
    /// its share classes as of the latest date.
    static func latestShares(_ facts: [String: [String: SECFact]]) -> Double? {
        let gaap = facts["us-gaap"] ?? [:]
        if let diluted = gaap["WeightedAverageNumberOfDilutedSharesOutstanding"]?.units["shares"] {
            let usable = diluted.filter { entry in
                guard entry.value > 0, let kind = periodKind(entry, instantaneous: false) else { return false }
                return kind == .quarterly || kind == .annual
            }
            if let latest = usable.max(by: { ($0.end, $0.filed ?? "") < ($1.end, $1.filed ?? "") }) {
                return latest.value
            }
        }
        guard let cover = facts["dei"]?["EntityCommonStockSharesOutstanding"]?.units["shares"],
              let end = cover.map(\.end).max() else { return nil }
        let atEnd = cover.filter { $0.end == end && $0.value > 0 }
        guard let filed = atEnd.compactMap(\.filed).max() else { return atEnd.first?.value }
        let total = atEnd.filter { $0.filed == filed }.reduce(0) { $0 + $1.value }
        return total > 0 ? total : nil
    }

    private func supplementFromFMPIfNeeded(
        _ sec: CompanyFinancialsData,
        ticker: String
    ) async throws -> CompanyFinancialsData {
        guard sec.income.isEmpty || sec.balance.isEmpty || sec.cashFlow.isEmpty,
              let apiKey = KeychainStore.string(for: LocalServiceKeys.fmp)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !apiKey.isEmpty else { return sec }
        guard let fmp = try? await loadFromFMP(ticker: ticker, apiKey: apiKey) else { return sec }
        let usedFallback = sec.income.isEmpty || sec.balance.isEmpty || sec.cashFlow.isEmpty
        return CompanyFinancialsData(
            ticker: sec.ticker,
            entityName: sec.entityName,
            cik: sec.cik,
            source: usedFallback ? L10n.text("SEC 为主 · FMP 补充缺失报表") : sec.source,
            income: sec.income.isEmpty ? fmp.income : sec.income,
            balance: sec.balance.isEmpty ? fmp.balance : sec.balance,
            cashFlow: sec.cashFlow.isEmpty ? fmp.cashFlow : sec.cashFlow,
            warnings: usedFallback ? [L10n.text("部分报表在 SEC Company Facts 中缺失，已用 FMP 补充。")] : [],
            sharesOutstanding: sec.sharesOutstanding,
            valuationQuality: sec.valuationQuality,
            valuationSchemaVersion: sec.valuationSchemaVersion
        )
    }

    private func secTicker(for ticker: String, forceRefresh: Bool) async throws -> SECTickerRow {
        let normalized = ticker.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let catalog = try? CompanyReferenceCatalog.bundled.get()
        let entry = catalog?.entry(symbol: normalized, market: "US")
        let candidates = [normalized, entry?.symbol].compactMap { $0 }
        loadTickerCacheIfNeeded()
        let bundleDate = catalog.flatMap {
            ISO8601DateFormatter().date(from: $0.generatedOn + "T00:00:00Z")
        }
        if !forceRefresh, let cacheDate = tickerCacheDate,
           cacheDate >= (bundleDate ?? .distantPast),
           Date().timeIntervalSince(cacheDate) < 7 * 24 * 60 * 60 {
            for candidate in candidates {
                if let row = tickerMap[candidate] { return row }
            }
        }
        if !forceRefresh,
           let entry,
           let cik = entry.verifiedCIK {
            return SECTickerRow(cik: cik, ticker: entry.symbol, title: entry.name ?? entry.symbol)
        }
        try await loadTickerMap(forceRefresh: forceRefresh)
        // Only reviewed aliases can change spelling. Stripping .L/.HK/etc.
        // can accidentally select a different US company with the same code.
        for candidate in candidates {
            if let row = tickerMap[candidate.uppercased()] { return row }
        }
        throw CompanyFinancialsError.unsupportedTicker
    }

    /// The bundled reference already carries SEC-verified CIKs, so the map is
    /// seeded from it before anything is fetched. Financial statements then
    /// work offline and on first launch, instead of every lookup depending on
    /// a multi-megabyte download from sec.gov succeeding first.
    ///
    /// The download stays as a refresh: it covers registrants added since the
    /// bundle was generated, and its rows win when both have an entry.
    private static let bundledTickerRows: [String: SECTickerRow] = {
        guard let catalog = try? CompanyReferenceCatalog.bundled.get() else { return [:] }
        var rows: [String: SECTickerRow] = [:]
        for entry in catalog.entries.values {
            guard let cik = entry.verifiedCIK else { continue }
            rows[entry.symbol.uppercased()] = SECTickerRow(
                cik: cik, ticker: entry.symbol.uppercased(), title: entry.name ?? entry.symbol
            )
        }
        return rows
    }()

    private func loadTickerMap(forceRefresh: Bool) async throws {
        loadTickerCacheIfNeeded()
        if tickerMap.isEmpty { tickerMap = Self.bundledTickerRows }
        if !forceRefresh,
           !tickerMap.isEmpty,
           let tickerCacheDate,
           Date().timeIntervalSince(tickerCacheDate) < 7 * 24 * 60 * 60 { return }

        let url = URL(string: "https://www.sec.gov/files/company_tickers.json")!
        do {
            let data = try await request(url: url, isSEC: true, forceRefresh: forceRefresh)
            let rows: [String: SECTickerRow]
            do {
                rows = try JSONDecoder().decode([String: SECTickerRow].self, from: data)
            } catch {
                DataSourceHealth.reportUnusable(DataSource.of(url), issue: .invalidFormat)
                throw error
            }
            if rows.isEmpty {
                DataSourceHealth.reportUnusable(DataSource.of(url), issue: .emptyResult)
            }
            let fetched = Dictionary(uniqueKeysWithValues: rows.values.map { ($0.ticker.uppercased(), $0) })
            tickerMap = tickerMap.merging(fetched) { _, fresh in fresh }
            tickerCacheDate = Date()
            persistTickerCache()
        } catch {
            // A failed refresh is no longer fatal: the bundle answers on its own.
            if tickerMap.isEmpty { throw error }
        }
    }

    private func loadFromFMP(ticker: String, apiKey: String) async throws -> CompanyFinancialsData {
        let candidates = Self.fmpSymbolCandidates(ticker)
        var lastError: Error?
        var serviceError: Error?
        for symbol in candidates {
            do {
                let annualIncome: [FMPIncomeRow] = try await fmpRows(
                    endpoint: "income-statement", symbol: symbol, period: "annual", apiKey: apiKey
                )
                let quarterlyIncome: [FMPIncomeRow] = try await fmpRows(
                    endpoint: "income-statement", symbol: symbol, period: "quarter", apiKey: apiKey
                )
                let annualBalance: [FMPBalanceRow] = try await fmpRows(
                    endpoint: "balance-sheet-statement", symbol: symbol, period: "annual", apiKey: apiKey
                )
                let quarterlyBalance: [FMPBalanceRow] = try await fmpRows(
                    endpoint: "balance-sheet-statement", symbol: symbol, period: "quarter", apiKey: apiKey
                )
                let annualCash: [FMPCashRow] = try await fmpRows(
                    endpoint: "cash-flow-statement", symbol: symbol, period: "annual", apiKey: apiKey
                )
                let quarterlyCash: [FMPCashRow] = try await fmpRows(
                    endpoint: "cash-flow-statement", symbol: symbol, period: "quarter", apiKey: apiKey
                )
                let income = Self.makeFMPIncome(annualIncome, kind: .annual)
                    + Self.makeFMPIncome(quarterlyIncome, kind: .quarterly)
                let balance = Self.makeFMPBalance(annualBalance, kind: .annual)
                    + Self.makeFMPBalance(quarterlyBalance, kind: .quarterly)
                let cash = Self.makeFMPCashFlow(annualCash, kind: .annual)
                    + Self.makeFMPCashFlow(quarterlyCash, kind: .quarterly)
                guard !income.isEmpty || !balance.isEmpty || !cash.isEmpty else {
                    DataSourceHealth.reportUnusable(DataSource.named("fmp"), issue: .missingRequiredFields)
                    throw CompanyFinancialsError.noStatements
                }
                return CompanyFinancialsData(
                    ticker: ticker,
                    entityName: ticker,
                    cik: nil,
                    source: L10n.text("FMP · SEC 未覆盖时使用"),
                    income: income,
                    balance: balance,
                    cashFlow: cash,
                    warnings: [L10n.text("SEC 未返回该证券的可用报表，当前显示 FMP 标准化数据。")]
                )
            } catch {
                lastError = error
                if !Self.confirmsNoStatements(error) { serviceError = error }
            }
        }
        throw serviceError ?? lastError ?? CompanyFinancialsError.noStatements
    }

    private func fmpRows<Row: Decodable>(
        endpoint: String,
        symbol: String,
        period: String,
        apiKey: String
    ) async throws -> [Row] {
        var components = URLComponents(string: "https://financialmodelingprep.com/stable/\(endpoint)")!
        components.queryItems = [
            URLQueryItem(name: "symbol", value: symbol),
            URLQueryItem(name: "period", value: period),
            URLQueryItem(name: "limit", value: period == "annual" ? "6" : "12"),
            URLQueryItem(name: "apikey", value: apiKey),
        ]
        // Shares the app's FMP quota with the analyst card and the historical
        // bars that render on the same stock page.
        try await FMPRequestLimiter.shared.waitForTurn()
        let data = try await request(url: components.url!, isSEC: false, forceRefresh: true)
        do {
            let rows = try JSONDecoder().decode([Row].self, from: data)
            if rows.isEmpty {
                DataSourceHealth.reportUnusable(DataSource.of(components.url), issue: .emptyResult)
            }
            return rows
        } catch {
            DataSourceHealth.reportUnusable(DataSource.of(components.url), issue: .invalidFormat)
            throw CompanyFinancialsError.invalidResponse
        }
    }

    private func loadFromNasdaq(ticker: String) async throws -> CompanyFinancialsData {
        let symbol = Self.nasdaqSymbol(ticker)
        // A ticker with a space or other stray character from an import
        // makes no URL; that is an unsupported ticker, not a crash.
        guard !symbol.isEmpty,
              let encoded = symbol.addingPercentEncoding(
                  withAllowedCharacters: CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))),
              let annualURL = URL(string: "https://api.nasdaq.com/api/company/\(encoded)/financials?frequency=1"),
              let quarterlyURL = URL(string: "https://api.nasdaq.com/api/company/\(encoded)/financials?frequency=2")
        else { throw CompanyFinancialsError.unsupportedTicker }
        async let annualBytes = request(
            url: annualURL,
            isSEC: false,
            forceRefresh: false,
            isNasdaq: true
        )
        async let quarterlyBytes = request(
            url: quarterlyURL,
            isSEC: false,
            forceRefresh: false,
            isNasdaq: true
        )
        let (annualData, quarterlyData) = try await (annualBytes, quarterlyBytes)
        let decoder = JSONDecoder()
        let annualResponse: NasdaqFinancialsResponse
        let quarterlyResponse: NasdaqFinancialsResponse
        do {
            annualResponse = try decoder.decode(NasdaqFinancialsResponse.self, from: annualData)
            quarterlyResponse = try decoder.decode(NasdaqFinancialsResponse.self, from: quarterlyData)
        } catch {
            DataSourceHealth.reportUnusable(DataSource.of(annualURL), issue: .invalidFormat)
            throw CompanyFinancialsError.invalidResponse
        }
        guard annualResponse.allowsStatementRead, quarterlyResponse.allowsStatementRead else {
            // Nasdaq answers 200 and puts its refusal in the body.
            DataSourceHealth.reportUnusable(DataSource.of(annualURL), "返回里的状态码拒绝了请求", subject: ticker)
            throw CompanyFinancialsError.invalidResponse
        }
        let annual = annualResponse.data, quarterly = quarterlyResponse.data
        guard annual != nil || quarterly != nil else {
            DataSourceHealth.reportUnusable(DataSource.of(annualURL), "没有这只证券的报表", subject: ticker)
            throw CompanyFinancialsError.noStatements
        }

        let income = Self.makeNasdaqIncome(annual?.incomeStatementTable, kind: .annual)
            + Self.makeNasdaqIncome(quarterly?.incomeStatementTable, kind: .quarterly)
        let balance = Self.makeNasdaqBalance(annual?.balanceSheetTable, kind: .annual)
            + Self.makeNasdaqBalance(quarterly?.balanceSheetTable, kind: .quarterly)
        let cashFlow = Self.makeNasdaqCashFlow(annual?.cashFlowTable, kind: .annual)
            + Self.makeNasdaqCashFlow(quarterly?.cashFlowTable, kind: .quarterly)
        guard !income.isEmpty || !balance.isEmpty || !cashFlow.isEmpty else {
            DataSourceHealth.reportUnusable(DataSource.of(annualURL), issue: .missingRequiredFields)
            throw CompanyFinancialsError.noStatements
        }
        return CompanyFinancialsData(
            ticker: ticker,
            entityName: annual?.symbol ?? quarterly?.symbol ?? ticker,
            cik: nil,
            source: L10n.text("Nasdaq 财务数据 · SEC 网络受限时使用"),
            income: income,
            balance: balance,
            cashFlow: cashFlow,
            warnings: [L10n.text("SEC 当前限制了此网络的自动访问，已自动切换到 Nasdaq；恢复后仍会优先读取 SEC。")]
        )
    }

    private func request(
        url: URL,
        isSEC: Bool,
        forceRefresh: Bool,
        isNasdaq: Bool = false
    ) async throws -> Data {
        if isSEC, let secBackoffUntil, secBackoffUntil > Date() {
            throw CompanyFinancialsError.remote(L10n.text("SEC 正在限流冷却中"))
        }
        var request = URLRequest(
            url: url,
            cachePolicy: forceRefresh ? .reloadIgnoringLocalCacheData : .returnCacheDataElseLoad,
            timeoutInterval: 18
        )
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if isSEC {
            // SEC's edge answers 403 to a User-Agent carrying a URL, and a
            // 403 here also started a quarter-hour backoff — so every lookup
            // quietly fell back to Nasdaq. The shared name-and-email agent
            // passes.
            request.setValue(SecurityDebateResearch.userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("gzip, deflate", forHTTPHeaderField: "Accept-Encoding")
        } else if isNasdaq {
            request.setValue(
                "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Version/18.0 Mobile/15E148 Safari/604.1",
                forHTTPHeaderField: "User-Agent"
            )
            request.setValue("https://www.nasdaq.com", forHTTPHeaderField: "Origin")
            request.setValue("https://www.nasdaq.com/", forHTTPHeaderField: "Referer")
        }
        let (data, response) = try await session.recordedData(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CompanyFinancialsError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            if isSEC, http.statusCode == 403 || http.statusCode == 429 {
                let retrySeconds = http.value(forHTTPHeaderField: "Retry-After")
                    .flatMap(TimeInterval.init) ?? 15 * 60
                secBackoffUntil = Date().addingTimeInterval(max(60, min(retrySeconds, 60 * 60)))
                throw CompanyFinancialsError.remote(L10n.text("SEC 暂时限制了此网络的自动访问，请稍后重试"))
            }
            throw CompanyFinancialsError.remote(L10n.text("财务数据请求失败（HTTP \(http.statusCode)）"))
        }
        return data
    }

    private func save(_ data: CompanyFinancialsData, key: String) {
        statementCache[key] = CacheEntry(fetchedAt: Date(), data: data)
        let oldest = Date().addingTimeInterval(-30 * 24 * 60 * 60)
        statementCache = statementCache.filter { $0.value.fetchedAt >= oldest }
        guard let encoded = try? JSONEncoder().encode(statementCache) else { return }
        try? encoded.write(to: statementCacheURL, options: .atomic)
    }

    private func loadStatementCacheIfNeeded() {
        guard !didLoadStatementCache else { return }
        didLoadStatementCache = true
        guard let data = try? Data(contentsOf: statementCacheURL),
              let decoded = try? JSONDecoder().decode([String: CacheEntry].self, from: data) else { return }
        statementCache = decoded
    }

    private func loadTickerCacheIfNeeded() {
        guard !didLoadTickerCache else { return }
        didLoadTickerCache = true
        guard let data = try? Data(contentsOf: tickerCacheURL),
              let decoded = try? JSONDecoder().decode([String: SECTickerRow].self, from: data) else { return }
        tickerMap = decoded
        tickerCacheDate = (try? tickerCacheURL.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
    }

    private func persistTickerCache() {
        guard let encoded = try? JSONEncoder().encode(tickerMap) else { return }
        try? encoded.write(to: tickerCacheURL, options: .atomic)
    }

    private var statementCacheURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("catfolio-company-financials.json")
    }

    private var tickerCacheURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("catfolio-sec-tickers.json")
    }
}

// Not private: the SEC concept preferences and the period merge are what the
// statements are read through, and the tests exercise them directly.
extension CompanyFinancialsClient {
    struct SECConceptCatalog {
        // Lenders and banks lead with revenue net of interest expense; their
        // contract revenue is only the fee part of the top line, and reading
        // it as the whole understated SoFi's 2025 revenue by five sixths.
        // Listed first so it wins the tie when a filer reports both.
        let revenue = [
            "RevenuesNetOfInterestExpense", "RevenueFromContractWithCustomerExcludingAssessedTax",
            "Revenues", "SalesRevenueNet", "Revenue",
        ]
        let costOfRevenue = [
            "CostOfRevenue", "CostOfGoodsAndServiceExcludingDepreciationDepletionAndAmortization",
            "CostOfGoodsSold", "CostOfSales",
        ]
        let grossProfit = ["GrossProfit"]
        let operatingExpenses = ["OperatingExpenses", "OperatingExpense"]
        // A single total-expense line, the shape lenders, banks and insurers
        // file in place of operating expenses under a gross profit. Read as
        // revenue less this, never as the gross less this.
        let totalCosts = [
            "NoninterestExpense", "CostsAndExpenses", "OperatingCostsAndExpenses",
            "BenefitsLossesAndExpenses",
        ]
        let operatingIncome = ["OperatingIncomeLoss", "ProfitLossFromOperatingActivities"]
        let netIncome = ["NetIncomeLoss", "ProfitLoss"]
        let assets = ["Assets"]
        let liabilities = ["Liabilities"]
        let equity = [
            "StockholdersEquity", "StockholdersEquityIncludingPortionAttributableToNoncontrollingInterest", "Equity",
        ]
        let cash = ["CashAndCashEquivalentsAtCarryingValue", "CashCashEquivalentsRestrictedCashAndRestrictedCashEquivalents"]
        let debt = [
            "LongTermDebtAndFinanceLeaseObligations", "LongTermDebtAndCapitalLeaseObligations",
            "LongTermDebt", "LongTermDebtCurrent",
        ]
        let operatingCashFlow = [
            "NetCashProvidedByUsedInOperatingActivities", "CashFlowsFromUsedInOperatingActivities",
        ]
        let capitalExpenditure = [
            "PaymentsToAcquirePropertyPlantAndEquipment", "PurchaseOfPropertyPlantAndEquipment",
        ]
        let investingCashFlow = [
            "NetCashProvidedByUsedInInvestingActivities", "CashFlowsFromUsedInInvestingActivities",
        ]
        let financingCashFlow = [
            "NetCashProvidedByUsedInFinancingActivities", "CashFlowsFromUsedInFinancingActivities",
        ]
    }

    struct AnchorPeriod {
        let entry: SECFactValue
        let unit: String
        let kind: FinancialPeriodKind
    }

    static func makeSECIncome(namespace: [String: SECFact]) -> [IncomeStatementPeriod] {
        let anchors = anchors(for: secConcepts.revenue, namespace: namespace, instantaneous: false)
        return anchors.compactMap { anchor in
            guard let revenue = value(for: secConcepts.revenue, namespace: namespace, anchor: anchor) else { return nil }
            let reportedCost = value(for: secConcepts.costOfRevenue, namespace: namespace, anchor: anchor)
            let reportedGross = value(for: secConcepts.grossProfit, namespace: namespace, anchor: anchor)
            guard let gross = reportedGross ?? reportedCost.map({ revenue - $0 }) else { return nil }
            let cost = reportedCost ?? (revenue - gross)
            let reportedOperating = value(for: secConcepts.operatingIncome, namespace: namespace, anchor: anchor)
            let reportedExpenses = value(for: secConcepts.operatingExpenses, namespace: namespace, anchor: anchor)
            // SoFi stopped tagging both of those after 2021, as lenders do,
            // and every period was dropped for want of an operating line —
            // the whole statement came back empty. Their total expense line
            // stands in, taken off revenue rather than off the gross, which
            // already has the cost of revenue out of it.
            let reportedTotalCosts = reportedOperating == nil && reportedExpenses == nil
                ? value(for: secConcepts.totalCosts, namespace: namespace, anchor: anchor)
                : nil
            guard let operating = reportedOperating
                ?? reportedExpenses.map({ gross - $0 })
                ?? reportedTotalCosts.map({ revenue - $0 }) else { return nil }
            let expenses = reportedExpenses ?? (gross - operating)
            return IncomeStatementPeriod(
                periodEnd: anchor.entry.end,
                filedDate: anchor.entry.filed,
                fiscalYear: year(from: anchor.entry.end),
                fiscalPeriod: anchor.entry.fiscalPeriod ?? (anchor.kind == .annual ? "FY" : "Q"),
                kind: anchor.kind,
                currency: anchor.unit,
                revenue: revenue,
                costOfRevenue: cost,
                grossProfit: gross,
                operatingExpenses: expenses,
                operatingIncome: operating,
                netIncome: value(for: secConcepts.netIncome, namespace: namespace, anchor: anchor)
            )
        }
        .sorted { $0.periodEnd > $1.periodEnd }
    }

    static func makeSECBalance(namespace: [String: SECFact]) -> [BalanceSheetPeriod] {
        let anchors = anchors(for: secConcepts.assets, namespace: namespace, instantaneous: true)
        return anchors.compactMap { anchor in
            guard let assets = value(for: secConcepts.assets, namespace: namespace, anchor: anchor),
                  let equity = value(for: secConcepts.equity, namespace: namespace, anchor: anchor) else { return nil }
            let liabilities = value(for: secConcepts.liabilities, namespace: namespace, anchor: anchor)
                ?? (assets - equity)
            return BalanceSheetPeriod(
                periodEnd: anchor.entry.end,
                filedDate: anchor.entry.filed,
                fiscalYear: year(from: anchor.entry.end),
                fiscalPeriod: anchor.entry.fiscalPeriod ?? (anchor.kind == .annual ? "FY" : "Q"),
                kind: anchor.kind,
                currency: anchor.unit,
                assets: assets,
                liabilities: liabilities,
                equity: equity,
                cash: value(for: secConcepts.cash, namespace: namespace, anchor: anchor),
                debt: value(for: secConcepts.debt, namespace: namespace, anchor: anchor)
            )
        }
        .sorted { $0.periodEnd > $1.periodEnd }
    }

    static func makeSECCashFlow(namespace: [String: SECFact]) -> [CashFlowStatementPeriod] {
        let anchors = anchors(for: secConcepts.operatingCashFlow, namespace: namespace, instantaneous: false)
        return anchors.compactMap { anchor in
            guard let operating = value(for: secConcepts.operatingCashFlow, namespace: namespace, anchor: anchor) else { return nil }
            let capex = abs(value(for: secConcepts.capitalExpenditure, namespace: namespace, anchor: anchor) ?? 0)
            return CashFlowStatementPeriod(
                periodEnd: anchor.entry.end,
                filedDate: anchor.entry.filed,
                fiscalYear: year(from: anchor.entry.end),
                fiscalPeriod: anchor.entry.fiscalPeriod ?? (anchor.kind == .annual ? "FY" : "Q"),
                kind: anchor.kind,
                currency: anchor.unit,
                operatingCashFlow: operating,
                capitalExpenditure: capex,
                freeCashFlow: operating - capex,
                investingCashFlow: value(for: secConcepts.investingCashFlow, namespace: namespace, anchor: anchor),
                financingCashFlow: value(for: secConcepts.financingCashFlow, namespace: namespace, anchor: anchor)
            )
        }
        .sorted { $0.periodEnd > $1.periodEnd }
    }

    static func anchors(
        for concepts: [String],
        namespace: [String: SECFact],
        instantaneous: Bool
    ) -> [AnchorPeriod] {
        // Every listed concept the company has used, newest-reporting first.
        // Companies switch tags — NVIDIA's revenue moved off the first name
        // in the list in 2022 — and taking only the first one present left
        // the statements frozen at the year it was last filed. Periods merge
        // across the concepts; where two report the same one, the concept
        // still in use wins.
        // Two concepts reported through the same quarter are ranked by the
        // order they are listed in, which states the preference; the sort is
        // not stable, so without the rank a filer that tags both — SoFi tags
        // fee revenue and revenue net of interest expense alike — got one or
        // the other depending on the run.
        let sources: [(rank: Int, unit: String, values: [SECFactValue])] = concepts.enumerated()
            .compactMap { rank, concept in
                guard let fact = namespace[concept], let unit = preferredMonetaryUnit(fact.units),
                      let values = fact.units[unit], !values.isEmpty else { return nil }
                return (rank, unit, values)
            }.sorted { lhs, rhs in
                let lhsEnd = lhs.values.map(\.end).max() ?? ""
                let rhsEnd = rhs.values.map(\.end).max() ?? ""
                if lhsEnd != rhsEnd { return lhsEnd > rhsEnd }
                return lhs.rank < rhs.rank
            }
        guard !sources.isEmpty else { return [] }
        var best: [String: AnchorPeriod] = [:]
        for source in sources {
            var fromThisConcept: [String: AnchorPeriod] = [:]
            for entry in source.values {
                guard let kind = periodKind(entry, instantaneous: instantaneous) else { continue }
                let key = "\(kind.rawValue)|\(entry.end)|\(entry.fiscalPeriod ?? "")"
                if best[key] != nil { continue }
                let candidate = AnchorPeriod(entry: entry, unit: source.unit, kind: kind)
                if let current = fromThisConcept[key], (current.entry.filed ?? "") >= (entry.filed ?? "") { continue }
                fromThisConcept[key] = candidate
            }
            best.merge(fromThisConcept) { current, _ in current }
        }
        return best.values
            .sorted { $0.entry.end > $1.entry.end }
            .prefix(20)
            .map { $0 }
    }

    static func value(
        for concepts: [String],
        namespace: [String: SECFact],
        anchor: AnchorPeriod
    ) -> Double? {
        for concept in concepts {
            guard let fact = namespace[concept] else { continue }
            let values = fact.units[anchor.unit] ?? fact.units[preferredMonetaryUnit(fact.units) ?? ""] ?? []
            let candidates = values.filter { item in
                guard item.end == anchor.entry.end else { return false }
                if let anchorStart = anchor.entry.start, let itemStart = item.start {
                    return abs(daysBetween(anchorStart, itemStart)) <= 8
                }
                return anchor.entry.start == nil || item.start == nil
            }
            if let best = candidates.max(by: { ($0.filed ?? "") < ($1.filed ?? "") }) {
                return best.value.isFinite ? best.value : nil
            }
        }
        return nil
    }

    static func periodKind(_ entry: SECFactValue, instantaneous: Bool) -> FinancialPeriodKind? {
        let form = entry.form ?? ""
        let annualForms: Set<String> = ["10-K", "20-F", "40-F"]
        let quarterlyForms: Set<String> = ["10-Q", "6-K"]
        if instantaneous {
            if annualForms.contains(form), entry.fiscalPeriod == "FY" { return .annual }
            if quarterlyForms.contains(form) { return .quarterly }
            return nil
        }
        guard let start = entry.start else { return nil }
        let days = abs(daysBetween(start, entry.end))
        if annualForms.contains(form), entry.fiscalPeriod == "FY", (280...430).contains(days) { return .annual }
        if quarterlyForms.contains(form), (60...130).contains(days) { return .quarterly }
        return nil
    }

    static func preferredMonetaryUnit(_ units: [String: [SECFactValue]]) -> String? {
        let priority = ["USD", "EUR", "GBP", "JPY", "CNY", "CAD", "CHF"]
        return priority.first(where: { units[$0] != nil })
            ?? units.keys.first(where: { !$0.contains("shares") && $0 != "pure" })
    }

    static func makeFMPIncome(_ rows: [FMPIncomeRow], kind: FinancialPeriodKind) -> [IncomeStatementPeriod] {
        rows.compactMap { row in
            guard let revenue = row.revenue,
                  let gross = row.grossProfit ?? row.costOfRevenue.map({ revenue - $0 }),
                  let operating = row.operatingIncome ?? row.operatingExpenses.map({ gross - $0 }) else { return nil }
            return IncomeStatementPeriod(
                periodEnd: row.date,
                filedDate: row.fillingDate,
                fiscalYear: Int(row.fiscalYear ?? "") ?? year(from: row.date),
                fiscalPeriod: row.period ?? (kind == .annual ? "FY" : "Q"),
                kind: kind,
                currency: row.reportedCurrency ?? "USD",
                revenue: revenue,
                costOfRevenue: row.costOfRevenue ?? (revenue - gross),
                grossProfit: gross,
                operatingExpenses: row.operatingExpenses ?? (gross - operating),
                operatingIncome: operating,
                netIncome: row.netIncome
            )
        }
    }

    static func makeFMPBalance(_ rows: [FMPBalanceRow], kind: FinancialPeriodKind) -> [BalanceSheetPeriod] {
        rows.compactMap { row in
            guard let assets = row.totalAssets,
                  let liabilities = row.totalLiabilities,
                  let equity = row.totalStockholdersEquity else { return nil }
            return BalanceSheetPeriod(
                periodEnd: row.date,
                filedDate: row.fillingDate,
                fiscalYear: Int(row.fiscalYear ?? "") ?? year(from: row.date),
                fiscalPeriod: row.period ?? (kind == .annual ? "FY" : "Q"),
                kind: kind,
                currency: row.reportedCurrency ?? "USD",
                assets: assets,
                liabilities: liabilities,
                equity: equity,
                cash: row.cashAndCashEquivalents,
                debt: row.totalDebt
            )
        }
    }

    static func makeFMPCashFlow(_ rows: [FMPCashRow], kind: FinancialPeriodKind) -> [CashFlowStatementPeriod] {
        rows.compactMap { row in
            guard let operating = row.operatingCashFlow ?? row.netCashProvidedByOperatingActivities else { return nil }
            let capex = abs(row.capitalExpenditure ?? 0)
            return CashFlowStatementPeriod(
                periodEnd: row.date,
                filedDate: row.fillingDate,
                fiscalYear: Int(row.fiscalYear ?? "") ?? year(from: row.date),
                fiscalPeriod: row.period ?? (kind == .annual ? "FY" : "Q"),
                kind: kind,
                currency: row.reportedCurrency ?? "USD",
                operatingCashFlow: operating,
                capitalExpenditure: capex,
                freeCashFlow: row.freeCashFlow ?? (operating - capex),
                investingCashFlow: row.netCashUsedForInvestingActivites,
                financingCashFlow: row.netCashUsedProvidedByFinancingActivities
            )
        }
    }

    static func makeNasdaqIncome(
        _ table: NasdaqStatementTable?,
        kind: FinancialPeriodKind
    ) -> [IncomeStatementPeriod] {
        guard let table else { return [] }
        let rows = nasdaqRows(table)
        return nasdaqColumns(table).compactMap { column, periodEnd in
            guard let revenue = nasdaqValue(["Total Revenue"], column: column, rows: rows),
                  let gross = nasdaqValue(["Gross Profit"], column: column, rows: rows),
                  let operating = nasdaqValue(["Operating Income"], column: column, rows: rows) else {
                return nil
            }
            let cost = nasdaqValue(["Cost of Revenue"], column: column, rows: rows)
                ?? (revenue - gross)
            let expenses = nasdaqValue(["Operating Expenses"], column: column, rows: rows)
                ?? (gross - operating)
            return IncomeStatementPeriod(
                periodEnd: periodEnd,
                filedDate: nil,
                fiscalYear: year(from: periodEnd),
                fiscalPeriod: nasdaqFiscalPeriod(periodEnd, kind: kind),
                kind: kind,
                currency: "USD",
                revenue: revenue,
                costOfRevenue: cost,
                grossProfit: gross,
                operatingExpenses: expenses,
                operatingIncome: operating,
                netIncome: nasdaqValue(["Net Income"], column: column, rows: rows)
            )
        }
        .sorted { $0.periodEnd > $1.periodEnd }
    }

    static func makeNasdaqBalance(
        _ table: NasdaqStatementTable?,
        kind: FinancialPeriodKind
    ) -> [BalanceSheetPeriod] {
        guard let table else { return [] }
        let rows = nasdaqRows(table)
        return nasdaqColumns(table).compactMap { column, periodEnd in
            guard let assets = nasdaqValue(["Total Assets"], column: column, rows: rows),
                  let liabilities = nasdaqValue(["Total Liabilities"], column: column, rows: rows),
                  let equity = nasdaqValue(
                    ["Total Equity", "Stock Holders Equity"],
                    column: column,
                    rows: rows
                  ) else { return nil }
            let shortDebt = nasdaqValue(
                ["Short-Term Debt / Current Portion of Long-Term Debt"],
                column: column,
                rows: rows
            )
            let longDebt = nasdaqValue(["Long-Term Debt"], column: column, rows: rows)
            let debt = (shortDebt != nil || longDebt != nil)
                ? (shortDebt ?? 0) + (longDebt ?? 0)
                : nil
            return BalanceSheetPeriod(
                periodEnd: periodEnd,
                filedDate: nil,
                fiscalYear: year(from: periodEnd),
                fiscalPeriod: nasdaqFiscalPeriod(periodEnd, kind: kind),
                kind: kind,
                currency: "USD",
                assets: assets,
                liabilities: liabilities,
                equity: equity,
                cash: nasdaqValue(["Cash and Cash Equivalents"], column: column, rows: rows),
                debt: debt
            )
        }
        .sorted { $0.periodEnd > $1.periodEnd }
    }

    static func makeNasdaqCashFlow(
        _ table: NasdaqStatementTable?,
        kind: FinancialPeriodKind
    ) -> [CashFlowStatementPeriod] {
        guard let table else { return [] }
        let rows = nasdaqRows(table)
        return nasdaqColumns(table).compactMap { column, periodEnd in
            guard let operating = nasdaqValue(
                ["Net Cash Flow-Operating"],
                column: column,
                rows: rows
            ) else { return nil }
            let capex = abs(nasdaqValue(["Capital Expenditures"], column: column, rows: rows) ?? 0)
            return CashFlowStatementPeriod(
                periodEnd: periodEnd,
                filedDate: nil,
                fiscalYear: year(from: periodEnd),
                fiscalPeriod: nasdaqFiscalPeriod(periodEnd, kind: kind),
                kind: kind,
                currency: "USD",
                operatingCashFlow: operating,
                capitalExpenditure: capex,
                freeCashFlow: operating - capex,
                investingCashFlow: nasdaqValue(
                    ["Net Cash Flows-Investing"],
                    column: column,
                    rows: rows
                ),
                financingCashFlow: nasdaqValue(
                    ["Net Cash Flows-Financing"],
                    column: column,
                    rows: rows
                )
            )
        }
        .sorted { $0.periodEnd > $1.periodEnd }
    }

    static func nasdaqRows(_ table: NasdaqStatementTable) -> [String: [String: String]] {
        table.rows.reduce(into: [:]) { result, row in
            guard let label = row["value1"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !label.isEmpty else { return }
            result[label.lowercased()] = row
        }
    }

    static func nasdaqColumns(_ table: NasdaqStatementTable) -> [(String, String)] {
        table.headers.compactMap { key, rawDate -> (String, String)? in
            guard key != "value1", let date = normalizedNasdaqDate(rawDate) else { return nil }
            return (key, date)
        }
        .sorted { $0.1 > $1.1 }
    }

    static func nasdaqValue(
        _ labels: [String],
        column: String,
        rows: [String: [String: String]]
    ) -> Double? {
        for label in labels {
            guard let raw = rows[label.lowercased()]?[column],
                  let parsed = parsedNasdaqNumber(raw) else { continue }
            // Nasdaq's financial statement table is displayed in thousands.
            return parsed * 1_000
        }
        return nil
    }

    static func parsedNasdaqNumber(_ raw: String) -> Double? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value != "--", value != "N/A" else { return nil }
        let parenthesized = value.hasPrefix("(") && value.hasSuffix(")")
        value = value
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "(", with: "")
            .replacingOccurrences(of: ")", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let number = Double(value) else { return nil }
        return parenthesized ? -number : number
    }

    static func normalizedNasdaqDate(_ raw: String) -> String? {
        let parts = raw.split(separator: "/")
        guard parts.count == 3,
              let month = Int(parts[0]),
              let day = Int(parts[1]),
              let year = Int(parts[2]) else { return nil }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    static func nasdaqFiscalPeriod(_ periodEnd: String, kind: FinancialPeriodKind) -> String {
        guard kind == .quarterly,
              let month = Int(periodEnd.dropFirst(5).prefix(2)) else { return "FY" }
        return "Q\(max(1, min(4, (month + 2) / 3)))"
    }

    static func nasdaqSymbol(_ ticker: String) -> String {
        normalizedTicker(ticker)
            .split(separator: ".", maxSplits: 1)
            .first
            .map(String.init) ?? normalizedTicker(ticker)
    }

    static func fmpSymbolCandidates(_ ticker: String) -> [String] {
        var candidates = [ticker.uppercased()]
        if ticker.uppercased().hasSuffix(".L") {
            candidates.append(String(ticker.dropLast(2)).uppercased())
        }
        return candidates.reduce(into: []) { result, candidate in
            guard !result.contains(candidate) else { return }
            result.append(candidate)
        }
    }

    static func normalizedTicker(_ ticker: String) -> String {
        ticker.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    static func year(from date: String) -> Int {
        Int(date.prefix(4)) ?? 0
    }

    static func daysBetween(_ lhs: String, _ rhs: String) -> Int {
        guard let left = FinancialDateCodec.date(from: lhs),
              let right = FinancialDateCodec.date(from: rhs) else { return .max }
        return Calendar(identifier: .gregorian).dateComponents([.day], from: left, to: right).day ?? .max
    }
}

private enum FinancialDateCodec {
    static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func date(from text: String) -> Date? {
        formatter.date(from: text)
    }
}
