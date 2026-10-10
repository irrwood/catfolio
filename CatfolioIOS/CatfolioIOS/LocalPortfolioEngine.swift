import Foundation
import CryptoKit

final class LocalCurrentFXCache: @unchecked Sendable {
    static let shared = LocalCurrentFXCache()
    private let lock = NSLock()
    private var records: [String: Record]
    struct Record: Codable { let rate: Double; let date: String }
    private init() {
        records = UserDefaults.standard.data(forKey: "catfolio.currentFX.v1")
            .flatMap { try? JSONDecoder().decode([String: Record].self, from: $0) } ?? [:]
    }
    func record(_ currency: String) -> Record? {
        lock.lock(); defer { lock.unlock() }
        return records[currency]
    }
    func update(_ incoming: [String: Record]) {
        lock.lock()
        records.merge(incoming) { _, new in new }
        let snapshot = records
        lock.unlock()
        // Persisted after the lock is released, never under it. Setting a
        // UserDefaults value posts `didChangeNotification` synchronously, and
        // `@AppStorage` answers it on the main thread — which is exactly the
        // thread that reads a rate here while it draws a figure. Holding the
        // lock across the write left this thread waiting on the main thread
        // and the main thread waiting on this lock: the app froze on launch
        // whenever the FX refresh landed while the home page was drawing.
        if let data = try? JSONEncoder().encode(snapshot) {
            UserDefaults.standard.set(data, forKey: "catfolio.currentFX.v1")
        }
    }
}

actor LocalCurrentFXRefresh {
    static let shared = LocalCurrentFXRefresh()
    private var lastAttempt = Date.distantPast
    private var running = false
    func refresh() async {
        guard !running, Date().timeIntervalSince(lastAttempt) > 1800 else { return }
        running = true; lastAttempt = Date()
        defer { running = false }
        let currencies = ["GBP", "EUR", "HKD", "CAD", "AUD", "SGD", "JPY", "CNY", "CNH"]
        let end = Date()
        let start = end.addingTimeInterval(-10 * 86400)
        let history = await LocalMarketDataClient().historicalCloses(symbols: currencies.map { "\($0)USD=X" },
            from: DayDateCodec.string(from: start), to: DayDateCodec.string(from: end))
        guard !Task.isCancelled else { return }
        var rates: [String: LocalCurrentFXCache.Record] = [:]
        for currency in currencies {
            if let latest = history["\(currency)USD=X"]?.filter({ $0.value.isFinite && $0.value > 0 }).max(by: { $0.key < $1.key }) {
                rates[currency] = .init(rate: latest.value, date: latest.key)
            }
        }
        LocalCurrentFXCache.shared.update(rates)
    }
}

enum LocalPortfolioEngine {
    struct Totals {
        let cost: Double
        let marketValue: Double
    }

    private static let usdRates: [String: Double] = [
        "USD": 1,
        "GBP": 1.346,
        "GBX": 0.01346,
        "EUR": 1.163,
        "HKD": 0.1275,
        "CAD": 0.726,
        "AUD": 0.655,
        "SGD": 0.777,
        "JPY": 0.0068,
        "CNY": 0.139,
        "CNH": 0.139,
    ]

    static func usd(_ amount: Double, currency: String) throws -> Double {
        let currency = currency.uppercased()
        guard let rate = usdRate(for: currency) else {
            throw LocalPortfolioError.unsupportedCurrency(currency)
        }
        return amount * rate
    }

    static func usdRate(for currency: String) -> Double? {
        let code = currency.uppercased()
        if code == "USD" { return 1 }
        if code == "GBX" { return usdRate(for: "GBP").map { $0 / 100 } }
        return LocalCurrentFXCache.shared.record(code)?.rate ?? usdRates[code]
    }

    static var fxStatus: String {
        if let record = LocalCurrentFXCache.shared.record(DisplayCurrency.current == .usd ? "GBP" : DisplayCurrency.current.rawValue) {
            return L10n.text("汇率缓存：\(record.date)。")
        }
        return L10n.text("汇率使用离线估值。")
    }

    static func totals(for positions: [LocalPositionRecord]) throws -> Totals {
        var cost = 0.0
        var marketValue = 0.0
        for position in positions {
            cost += position.publicDisclosure == nil ? try usd(position.shares * position.averageCost, currency: position.currency) : .nan
            marketValue += try usd(position.publicDisclosure.map { $0.value ?? .nan } ?? (position.shares * position.quotePrice), currency: position.quoteCurrency)
        }
        return Totals(cost: cost, marketValue: marketValue)
    }

    static func presentation(
        for document: LocalPortfolioDocument
    ) throws -> (PortfolioOverview, PortfolioChartResponse, [Holding]) {
        if document.isPublicDisclosure && (document.positions.isEmpty || document.positions.contains(where: { $0.publicDisclosure != nil })) { return try PublicInvestorAccountAdapter.presentation(for: document) }
        let totals = try totals(for: document.positions)
        let displayPositions = consolidated(document.positions)
        let unrealized = totals.marketValue - totals.cost
        let asOf = document.updatedAt == .distantPast
            ? nil
            : document.updatedAt.formatted(date: .abbreviated, time: .shortened)
        let summary = PortfolioSummary(
            totalCost: totals.cost,
            openPositions: document.positions.count,
            asOf: asOf,
            marketValue: totals.marketValue,
            unrealized: unrealized
        )
        let overview = PortfolioOverview(summary: summary)
        // Decoded once for the whole page rather than per position: each is
        // a bundled package, and a 135-position portfolio would otherwise ask
        // for them 135 times.
        let fxRates = try? GBPFXRates.bundled.get()
        let splitCatalog = try? StockSplitCatalog.bundled.get()
        let fxTickers = Set(displayPositions.filter { $0.fxPnl == nil && $0.brokerPnl == nil }.map(\.ticker))
        let fxPrepared = fxRates != nil && !fxTickers.isEmpty
            ? FXImpactCalculator.prepare(transactions: document.transactions ?? [], tickers: fxTickers, splits: splitCatalog)
            : nil
        let fxAsOf = Date()

        let rows = try displayPositions.map { position -> Holding in
            let costUSD = try usd(position.shares * position.averageCost, currency: position.currency)
            let marketUSD = try usd(position.shares * position.quotePrice, currency: position.quoteCurrency)
            let pnl = marketUSD - costUSD
            let fxPnlUSD: Double?
            let fxPnlStatus: String?
            let fxPnlSource: String?
            if let brokerFX = position.fxPnl {
                fxPnlUSD = try usd(brokerFX, currency: position.fxPnlCurrency ?? "USD")
                fxPnlStatus = position.fxPnlStatus ?? "broker_reported"
                fxPnlSource = position.fxPnlSource
            } else if let brokerPnl = position.brokerPnl {
                // Legacy Trading 212 responses may omit the explicit FX
                // component. Their total position P&L includes FX, while
                // `market - cost` is the pure price component at the current
                // report rate, so the difference recovers the FX contribution.
                let brokerPnlUSD = try usd(
                    brokerPnl,
                    currency: position.brokerPnlCurrency ?? "USD"
                )
                fxPnlUSD = brokerPnlUSD - pnl
                fxPnlStatus = "estimated"
                fxPnlSource = "broker_total_pnl_residual"
            } else if let fxRates, let fxPrepared, let reconstructed = FXImpactCalculator.impact(
                ticker: position.ticker,
                prepared: fxPrepared,
                rates: fxRates,
                asOf: fxAsOf
            ) {
                // No broker in this ledger reports an FX component, so
                // without this every position showed "—". Rebuilt from the
                // trade dates already on file and ECB's published rates.
                fxPnlUSD = try usd(reconstructed.amount, currency: reconstructed.currency)
                fxPnlStatus = reconstructed.isExact ? "reconstructed" : "estimated"
                fxPnlSource = reconstructed.isExact
                    ? "ecb_daily_on_trade_dates"
                    : "ecb_daily_nearest_prior"
            } else {
                fxPnlUSD = nil
                fxPnlStatus = position.fxPnlStatus
                fxPnlSource = position.fxPnlSource
            }
            return Holding(
                ticker: position.ticker,
                logoSymbol: position.ticker,
                displayName: position.name.isEmpty ? position.ticker : position.name,
                // Funds resolve to nil rather than to one of the sectors they
                // hold; anything wanting their spread asks SectorAttribution
                // for it directly.
                sector: SectorAttribution.primarySector(ticker: position.ticker)?.displayName,
                source: position.source,
                shares: position.shares,
                averageCost: position.averageCost,
                costCurrency: position.currency,
                quotePrice: position.quotePrice,
                quoteCurrency: position.quoteCurrency,
                todayChangePercent: nil,
                marketValue: marketUSD,
                weight: totals.marketValue > 0 ? marketUSD / totals.marketValue : 0,
                unrealized: pnl,
                unrealizedPercent: costUSD > 0 ? pnl / costUSD * 100 : 0,
                fxPnl: fxPnlUSD,
                fxPnlPercent: fxPnlUSD.flatMap { costUSD > 0 ? $0 / costUSD * 100 : nil },
                fxPnlStatus: fxPnlStatus,
                fxPnlSource: fxPnlSource
            )
        }.sorted { $0.marketValue > $1.marketValue }

        let chartRows = document.snapshots.map {
            ChartPoint(dateText: $0.date, marketValue: $0.marketValueUSD, cost: $0.costUSD)
        }
        let current = chartRows.last ?? ChartPoint(
            dateText: DayDateFormatter.shared.string(from: Date()),
            marketValue: totals.marketValue,
            cost: totals.cost
        )
        var chart = PortfolioChartResponse(
            positionCount: rows.count,
            positionHistory: PositionHistory(available: !chartRows.isEmpty, rows: chartRows),
            currentPoint: current,
            warning: chartRows.count > 1 ? nil : "没有历史成交记录或多日快照，当前只能显示最新值。"
        )
        if document.isSynthetic != true {
            chart = .unavailableAccountHistory(positionCount: rows.count,
                reason: "账户历史需要完整资金流水和历史估值；正在准备数据，持仓市值可在持仓列表查看。")
        }
        return (overview, chart, rows)
    }

    static func consolidated(_ positions: [LocalPositionRecord]) -> [LocalPositionRecord] {
        var grouped: [String: LocalPositionRecord] = [:]
        for position in positions {
            let key = "\(position.ticker.uppercased())|\(position.currency)|\(position.quoteCurrency)"
            guard let existing = grouped[key] else {
                grouped[key] = position
                continue
            }
            let shares = existing.shares + position.shares
            guard shares > 0 else { continue }
            let sources = Set([existing.source, position.source]).sorted().joined(separator: " + ")
            let combinedFX = combinedFXPnl(existing, position)
            let combinedBrokerFX = combinedBrokerFXPnl(existing, position)
            let combinedBroker = combinedBrokerPnl(existing, position)
            grouped[key] = LocalPositionRecord(
                ticker: position.ticker.uppercased(),
                name: existing.name.isEmpty ? position.name : existing.name,
                shares: shares,
                averageCost: (existing.averageCost * existing.shares + position.averageCost * position.shares) / shares,
                currency: existing.currency,
                quotePrice: (existing.quotePrice * existing.shares + position.quotePrice * position.shares) / shares,
                quoteCurrency: existing.quoteCurrency,
                source: sources,
                openedDate: [existing.openedDate, position.openedDate].compactMap { $0 }.min(),
                accountCurrency: existing.accountCurrency == position.accountCurrency
                    ? existing.accountCurrency
                    : nil,
                brokerPnl: combinedBroker.value,
                brokerPnlCurrency: combinedBroker.currency,
                brokerFxPnl: combinedBrokerFX.value,
                brokerFxPnlCurrency: combinedBrokerFX.currency,
                fxPnl: combinedFX.value,
                fxPnlCurrency: combinedFX.currency,
                fxPnlStatus: combinedFX.value == nil ? nil : Self.combinedFXStatus(existing, position),
                fxPnlSource: combinedFX.value == nil ? nil : Self.combinedFXSource(existing, position)
            )
        }
        return grouped.values.sorted { $0.ticker < $1.ticker }
    }

    /// Desktop aggregates every broker FX component after translating the
    /// account currency to USD. Do the same when the same ticker is held in
    /// accounts with different base currencies instead of discarding the FX
    /// result during consolidation.
    private static func combinedFXPnl(
        _ lhs: LocalPositionRecord,
        _ rhs: LocalPositionRecord
    ) -> (value: Double?, currency: String?) {
        guard let lhsValue = lhs.fxPnl, let rhsValue = rhs.fxPnl else {
            return (nil, nil)
        }
        let lhsCurrency = (lhs.fxPnlCurrency ?? "USD").uppercased()
        let rhsCurrency = (rhs.fxPnlCurrency ?? "USD").uppercased()
        if lhsCurrency == rhsCurrency {
            return (lhsValue + rhsValue, lhsCurrency)
        }
        guard let lhsUSD = try? usd(lhsValue, currency: lhsCurrency),
              let rhsUSD = try? usd(rhsValue, currency: rhsCurrency) else {
            return (nil, nil)
        }
        return (lhsUSD + rhsUSD, "USD")
    }

    private static func combinedBrokerPnl(
        _ lhs: LocalPositionRecord,
        _ rhs: LocalPositionRecord
    ) -> (value: Double?, currency: String?) {
        guard let lhsValue = lhs.brokerPnl, let rhsValue = rhs.brokerPnl else {
            return (nil, nil)
        }
        let lhsCurrency = (lhs.brokerPnlCurrency ?? "USD").uppercased()
        let rhsCurrency = (rhs.brokerPnlCurrency ?? "USD").uppercased()
        if lhsCurrency == rhsCurrency {
            return (lhsValue + rhsValue, lhsCurrency)
        }
        guard let lhsUSD = try? usd(lhsValue, currency: lhsCurrency),
              let rhsUSD = try? usd(rhsValue, currency: rhsCurrency) else {
            return (nil, nil)
        }
        return (lhsUSD + rhsUSD, "USD")
    }

    private static func combinedBrokerFXPnl(
        _ lhs: LocalPositionRecord,
        _ rhs: LocalPositionRecord
    ) -> (value: Double?, currency: String?) {
        combineOptionalMoney(
            lhs.brokerFxPnl,
            currency: lhs.brokerFxPnlCurrency,
            rhs.brokerFxPnl,
            currency: rhs.brokerFxPnlCurrency
        )
    }

    private static func combineOptionalMoney(
        _ lhsValue: Double?,
        currency lhsCurrencyValue: String?,
        _ rhsValue: Double?,
        currency rhsCurrencyValue: String?
    ) -> (value: Double?, currency: String?) {
        guard let lhsValue, let rhsValue else { return (nil, nil) }
        let lhsCurrency = (lhsCurrencyValue ?? "USD").uppercased()
        let rhsCurrency = (rhsCurrencyValue ?? "USD").uppercased()
        if lhsCurrency == rhsCurrency { return (lhsValue + rhsValue, lhsCurrency) }
        guard let lhsUSD = try? usd(lhsValue, currency: lhsCurrency),
              let rhsUSD = try? usd(rhsValue, currency: rhsCurrency) else {
            return (nil, nil)
        }
        return (lhsUSD + rhsUSD, "USD")
    }

    private static func combinedFXStatus(
        _ lhs: LocalPositionRecord,
        _ rhs: LocalPositionRecord
    ) -> String {
        let statuses = Set([lhs.fxPnlStatus, rhs.fxPnlStatus].compactMap { $0 })
        if statuses.contains("estimated") { return "estimated" }
        if statuses.contains("reconstructed") { return "reconstructed" }
        if statuses == ["not_applicable"] { return "not_applicable" }
        return statuses.count == 1 ? statuses.first ?? "broker_reported" : "mixed"
    }

    private static func combinedFXSource(
        _ lhs: LocalPositionRecord,
        _ rhs: LocalPositionRecord
    ) -> String {
        Set([lhs.fxPnlSource, rhs.fxPnlSource].compactMap { $0 })
            .sorted()
            .joined(separator: " + ")
    }

    /// Offline, without prices: the portfolio's own snapshots, value against
    /// what went in, drawn in every view with no benchmark beside it. Only
    /// a portfolio without two snapshots comes back unavailable.
    static func comparison(for document: LocalPortfolioDocument) throws -> ComparisonResponse {
        let days = LocalMarketDataClient.impliedLedgerDays(values: document.snapshots.map { ($0.date, $0.marketValueUSD, $0.costUSD) })
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        if days.count > 1, let first = DayDateCodec.date(from: days[0].date),
           let baseline = calendar.date(byAdding: .day, value: -1, to: first) {
            let dates = [DayDateCodec.string(from: baseline)] + days.map(\.date)
            let ledger = AccountMWRLedger(dates: dates, cashFlows: [0] + days.map { $0.inflow - $0.outflow },
                values: [0] + days.map(\.value), benchmarkValues: [:],
                inflows: [0] + days.map(\.inflow), outflows: [0] + days.map(\.outflow))
            if let mirrored = ledger.cashFlowComparison() {
                let mwr = ledger.returns()
                let basis = L10n.text("收益按持仓市值和成本推算：成本增加视为入金、减少视为出金，没有现金流水。")
                return ComparisonResponse(
                    available: true,
                    dates: dates,
                    portfolio: mirrored.portfolio,
                    benchmarks: [:],
                    cashFlowPortfolioReturns: mirrored.portfolioReturns,
                    cashFlowBenchmarkReturns: [:],
                    mwrPortfolio: mwr.portfolio,
                    mwrBenchmarks: [:],
                    twrDates: dates,
                    twrPortfolio: [1] + days.map(\.nav),
                    twrBenchmarks: [:],
                    warnings: ["每日 TWR " + basis, "MWR：" + basis, "现金流镜像：" + basis],
                    summary: ComparisonSummary(
                        portfolioReturn: mirrored.portfolioReturns.last ?? nil,
                        benchmarkReturn: nil,
                        benchmarkReturns: Dictionary(uniqueKeysWithValues: ComparisonBenchmarkCatalog.symbols.map {
                            ($0, Optional<Double>.none)
                        })
                    ),
                    mwrLedger: ledger
                )
            }
        }
        return ComparisonResponse(
            available: false,
            dates: [],
            portfolio: [],
            benchmarks: [:],
            cashFlowPortfolioReturns: nil,
            cashFlowBenchmarkReturns: nil,
            mwrPortfolio: nil,
            mwrBenchmarks: nil,
            twrDates: nil,
            twrPortfolio: nil,
            twrBenchmarks: nil,
            warnings: ["现金流镜像：缺少完整资金账本和账户估值，暂不可用。", "MWR：缺少完整资金账本和账户估值，暂不可用。", "TWR：缺少完整资金账本和账户估值，暂不可用。"],
            summary: ComparisonSummary(
                portfolioReturn: nil,
                benchmarkReturn: nil,
                benchmarkReturns: Dictionary(uniqueKeysWithValues: ComparisonBenchmarkCatalog.symbols.map {
                    ($0, Optional<Double>.none)
                })
            )
        )
    }
}
