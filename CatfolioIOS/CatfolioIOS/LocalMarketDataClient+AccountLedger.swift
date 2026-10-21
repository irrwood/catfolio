import Foundation
import CryptoKit
import FoundationModels
import OSLog

extension LocalMarketDataClient {
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
    func tolerantAccountSeries(
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
        if let archive = DelistedPriceArchive.entry(for: symbol) {
            let closes = archive.closes(from: from, to: to)
            guard !closes.isEmpty else { throw LocalServiceError.noHistoricalPrices }
            return LedgerPriceHistory(currency: archive.currency, closes: closes, splits: [],
                fetchedAt: DayDateCodec.date(from: archive.retrievedAt) ?? .distantPast)
        }
        let cacheKey = Data("ledger-v1|\(symbol)|\(from)|\(to)".utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
        let cacheURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(cacheKey + ".json")
        let cached = (try? Data(contentsOf: cacheURL)).flatMap { try? JSONDecoder().decode(LedgerPriceHistory.self, from: $0) }
        if cachedOnly {
            guard let cached else { throw LocalServiceError.noHistoricalPrices }
            return cached
        }
        if !forceRefresh, let cached, MarketCacheFreshness.isFresh(fetchedAt: cached.fetchedAt, lifetime: MarketCacheFreshness.history) { return cached }
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
            let (data, response) = try await MarketRequestCoalescer.shared.data(for: request, session: Self.yahooSession)
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
            func unsplit(_ close: Double, on date: String) -> Double {
                close * splits.filter { $0.date > date }.reduce(1.0) { $0 * NSDecimalNumber(decimal: $1.factor).doubleValue }
            }
            var values: [String: Double] = [:]
            var gaps: [String] = []
            for (index, timestamp) in timestamps.enumerated() where closes.indices.contains(index) {
                let date = day(timestamp)
                guard let close = closes[index] as? Double, close.isFinite, close > 0 else {
                    gaps.append(date)
                    continue
                }
                values[date] = unsplit(close, on: date)
            }
            // Yahoo at times drops a close it reported before, leaving the
            // session with no price. The closes kept across fetches still
            // have it; carrying the session before instead would count two
            // days' move as one, and the home 1D would disagree with Today.
            if !gaps.isEmpty, let scale = InstrumentCurrencyRules.providerPriceScale(symbol: symbol, sourceCurrency: currency),
               scale > 0,
               let kept = await LocalHistoricalPriceCache.shared.lookup(symbol: symbol + "#split-only", from: from, to: to)?.values {
                for date in gaps where values[date] == nil {
                    guard let close = kept[date], close.isFinite, close > 0 else { continue }
                    values[date] = unsplit(close / scale, on: date)
                }
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
}
