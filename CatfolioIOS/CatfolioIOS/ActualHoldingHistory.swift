import Foundation

/// The income-sources history as it really was: each day's own share counts,
/// open cost and realised results, rebuilt from the ledger.
///
/// The usual history (`LocalMarketDataClient.holdingValueHistory`) is today's
/// holdings carried back: a part-sold security is drawn at today's smaller
/// count on every day before its sale, an added-to one at today's larger
/// count before its purchase, and a security sold outright is not there at
/// all. Here every day holds what was held that day.
///
/// A position whose ledger does not account for its shares today — moved in
/// from another broker, or imported without its purchases — cannot be
/// rebuilt; it keeps the usual drawing, today's shares from its opening day,
/// and only its broker-reported results and dividends are added.
///
/// Per security, a day's value is what its shares were worth at that day's
/// close plus everything it had realised (sales and dividends) by then; its
/// cost is what its open shares cost. A security no longer held is worth its
/// realised result at no cost. The principal is the open cost that day.
enum ActualHoldingHistory {
    /// One security in one account.
    struct Plan {
        let key: String
        let ticker: String
        /// The currency its market price is drawn in.
        let currency: String
        let symbol: String
        /// Rebuilt from the ledger, or today's shares carried back.
        let isRebuilt: Bool
        let position: LocalPositionRecord?
        /// Buys and sells, in lot-matching order.
        let trades: [LocalTransactionRecord]
        let dividends: [LocalTransactionRecord]
        /// The ledger says shares are still held but no position holds them:
        /// they left the account after the last trade.
        let leftAfter: String?
        let startDate: String
    }

    static func plans(positions: [LocalPositionRecord], transactions: [LocalTransactionRecord],
                      splitAdjustment: (String, String) -> Double? = defaultSplit) -> [Plan] {
        let positionsByKey = Dictionary(positions.filter { $0.shares > 0 }.map {
            ("\($0.accountKey)|\($0.ticker.uppercased())", $0)
        }, uniquingKeysWith: { first, _ in first })
        var tradesByKey: [String: [LocalTransactionRecord]] = [:]
        var dividendsByKey: [String: [LocalTransactionRecord]] = [:]
        for transaction in transactions {
            let key = "\(transaction.accountKey)|\(transaction.ticker.uppercased())"
            if RealisedProfitCalculator.isBuy(transaction.action) || RealisedProfitCalculator.isSell(transaction.action) {
                tradesByKey[key, default: []].append(transaction)
            } else if PortfolioActivityKind(action: transaction.action) == .dividend {
                dividendsByKey[key, default: []].append(transaction)
            }
        }
        var plans: [Plan] = []
        for key in Set(positionsByKey.keys).union(tradesByKey.keys).sorted() {
            let position = positionsByKey[key]
            let trades = LocalTransactionRecord.orderedForLotMatching(tradesByKey[key] ?? [])
            let ticker = (position?.ticker ?? trades.last?.ticker ?? "").uppercased()
            guard !ticker.isEmpty else { continue }
            let ledgerShares = trades.reduce(0.0) { shares, trade in
                let split = splitAdjustment(trade.ticker, trade.date) ?? 1
                let quantity = abs(trade.quantity) * split
                return shares + (RealisedProfitCalculator.isBuy(trade.action) ? quantity : -quantity)
            }
            let held = position?.shares ?? 0
            let accounted = abs(ledgerShares - held) <= max(0.0001, held * 0.01)
            let isRebuilt = !trades.isEmpty && (accounted || position == nil)
            let currency = (position?.quoteCurrency ?? trades.last?.currency ?? "USD").uppercased()
            let firstTrade = trades.first?.date
            let start: String
            if isRebuilt {
                guard let firstTrade else { continue }
                start = firstTrade
            } else {
                guard let opened = position?.openedDate ?? firstTrade else { continue }
                start = opened
            }
            plans.append(Plan(
                key: key, ticker: ticker, currency: currency,
                symbol: LocalMarketDataClient.yahooSymbol(ticker: ticker, currency: currency),
                isRebuilt: isRebuilt, position: position, trades: trades,
                dividends: (dividendsByKey[key] ?? []).sorted { $0.date < $1.date },
                leftAfter: isRebuilt && position == nil && ledgerShares > 0.0001 ? trades.last?.date : nil,
                startDate: start))
        }
        return plans
    }

    private struct Lot {
        var quantity: Double
        let costPerShareUSD: Double
    }

    /// Where one plan stands on a day.
    private struct State {
        var next = 0
        var nextDividend = 0
        var shares = 0.0
        var lots: [Lot] = []
        var realisedUSD = 0.0
    }

    /// - Parameters:
    ///   - closes: split-adjusted, not dividend-adjusted, closes by symbol and
    ///     day: the trades were made at those prices, and dividends are
    ///     counted as received.
    ///   - scales: how a symbol's market price converts to its plan's currency.
    static func build(plans: [Plan], closes: [String: [String: Double]], scales: [String: Double],
                      names: [String: String] = [:],
                      usdRate: (String) -> Double? = { LocalPortfolioEngine.usdRate(for: $0) },
                      splitAdjustment: (String, String) -> Double? = defaultSplit) -> HoldingValueHistory {
        guard let start = plans.map(\.startDate).min() else {
            return HoldingValueHistory(rows: [], costs: [:], names: [:])
        }
        let dates = Set(closes.values.flatMap(\.keys)).filter { $0 >= start }.sorted()
        var states = Array(repeating: State(), count: plans.count)
        var lastClose: [String: Double] = [:]
        var rows: [HoldingValueHistory.Row] = []
        let symbols = Set(plans.map(\.symbol))

        for date in dates {
            var values: [String: Double] = [:]
            var costs: [String: Double] = [:]
            var principal = 0.0
            for symbol in symbols {
                if let close = closes[symbol]?[date] { lastClose[symbol] = close }
            }
            for (index, plan) in plans.enumerated() where date >= plan.startDate {
                guard let marketRate = usdRate(plan.currency) else { continue }
                var state = states[index]
                advance(&state, plan: plan, to: date, usdRate: usdRate, splitAdjustment: splitAdjustment)
                states[index] = state

                let openCost: Double
                let shares: Double
                if plan.isRebuilt {
                    let gone = plan.leftAfter.map { date > $0 } ?? false
                    shares = gone ? 0 : state.shares
                    openCost = gone ? 0 : state.lots.reduce(0) { $0 + $1.quantity * $1.costPerShareUSD }
                } else if let position = plan.position {
                    shares = position.shares
                    openCost = (usdRate(position.currency) ?? marketRate) * position.shares * position.averageCost
                } else {
                    continue
                }
                let marketValue = lastClose[plan.symbol].map {
                    shares * $0 * (scales[plan.symbol] ?? 1) * marketRate
                } ?? openCost
                guard shares > 0.000_000_1 || state.realisedUSD != 0 else { continue }
                values[plan.ticker, default: 0] += marketValue + state.realisedUSD
                costs[plan.ticker, default: 0] += openCost
                principal += openCost
            }
            if !values.isEmpty {
                rows.append(.init(dateText: date, cost: principal, values: values, costs: costs))
            }
        }
        var allNames = names
        for plan in plans where allNames[plan.ticker] == nil {
            if let name = plan.position?.name, !name.isEmpty { allNames[plan.ticker] = name }
        }
        return HoldingValueHistory(rows: rows, costs: rows.last?.costs ?? [:], names: allNames)
    }

    /// Applies a plan's trades and dividends made on or before `date`.
    private static func advance(_ state: inout State, plan: Plan, to date: String,
                                usdRate: (String) -> Double?, splitAdjustment: (String, String) -> Double?) {
        while state.nextDividend < plan.dividends.count, plan.dividends[state.nextDividend].date <= date {
            let dividend = plan.dividends[state.nextDividend]
            if let rate = usdRate(dividend.currency) {
                let usd = dividend.quantity * dividend.price * rate
                if usd.isFinite { state.realisedUSD += usd }
            }
            state.nextDividend += 1
        }
        while state.next < plan.trades.count, plan.trades[state.next].date <= date {
            let trade = plan.trades[state.next]
            state.next += 1
            let split = splitAdjustment(trade.ticker, trade.date) ?? 1
            let quantity = abs(trade.quantity) * split
            let price = split > 0 ? trade.price / split : trade.price
            let rate = usdRate(trade.currency)
            if RealisedProfitCalculator.isBuy(trade.action) {
                guard plan.isRebuilt else { continue }
                state.shares += quantity
                state.lots.append(Lot(quantity: quantity, costPerShareUSD: price * (rate ?? 0)))
                continue
            }
            let broker = brokerUSD(trade, usdRate: usdRate)
            guard plan.isRebuilt else {
                // Without its purchases only the broker's own result is known.
                if let broker { state.realisedUSD += broker }
                continue
            }
            var remaining = quantity
            var matchedCost = 0.0
            while remaining > 0.000_000_1, !state.lots.isEmpty {
                let matched = min(remaining, state.lots[0].quantity)
                matchedCost += matched * state.lots[0].costPerShareUSD
                remaining -= matched
                state.lots[0].quantity -= matched
                if state.lots[0].quantity <= 0.000_000_1 { state.lots.removeFirst() }
            }
            state.shares = max(0, state.shares - quantity)
            let rebuilt = rate.map { price * $0 * (quantity - remaining) - matchedCost }
            if let profit = broker ?? rebuilt, profit.isFinite { state.realisedUSD += profit }
        }
    }

    private static func brokerUSD(_ transaction: LocalTransactionRecord, usdRate: (String) -> Double?) -> Double? {
        guard let raw = transaction.realisedProfitLoss, raw.isFinite else { return nil }
        let currency = transaction.realisedProfitLossCurrency?
            .trimmingCharacters(in: .whitespacesAndNewlines).uppercased() ?? ""
        guard currency.count == 3, currency.utf8.allSatisfy({ (65...90).contains($0) }),
              let rate = usdRate(currency), rate.isFinite else { return nil }
        return raw * rate
    }

    static let defaultSplit: (String, String) -> Double? = { ticker, date in
        (try? StockSplitCatalog.bundled.get())?.adjustment(ticker: ticker, from: date)
    }
}

extension LocalMarketDataClient {
    /// The income-sources history with every day's own holdings. See
    /// `ActualHoldingHistory`.
    func actualHoldingValueHistory(document: LocalPortfolioDocument,
                                   cachedOnly: Bool = false) async throws -> HoldingValueHistory {
        let plans = ActualHoldingHistory.plans(positions: document.positions,
                                               transactions: document.transactions ?? [])
        guard let start = plans.map(\.startDate).min() else { throw LocalPortfolioError.noPortfolio }
        let end = DayDateCodec.string(from: Date())
        let symbols = plans.map(\.symbol).uniqued()
        // Split-adjusted only: the ledger's prices are what was paid and
        // received, and dividends are counted as cash, not folded into price.
        let closes = await historicalCloses(symbols: symbols, from: start, to: end,
                                            dividendAdjusted: false, cachedOnly: cachedOnly)
        var scales: [String: Double] = [:]
        for plan in plans where scales[plan.symbol] == nil {
            let reference = plan.position?.quotePrice ?? plan.trades.last?.price
            let latest = closes[plan.symbol]?.max(by: { $0.key < $1.key })?.value
            scales[plan.symbol] = Self.priceScale(ticker: plan.ticker, currency: plan.currency,
                                                  referencePrice: reference, marketPrice: latest)
        }
        return ActualHoldingHistory.build(plans: plans, closes: closes, scales: scales)
    }
}
