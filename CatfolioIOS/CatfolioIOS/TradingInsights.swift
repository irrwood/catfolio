import Foundation

/// One sale, matched FIFO against the purchases before it in the same
/// account: what it cost, what it made, and how long the shares were held.
struct InsightClosedTrade: Equatable, Sendable {
    let id: String
    let ticker: String
    let saleDate: String
    /// The earliest purchase the sale drew on.
    let firstBuyDate: String?
    /// Days between purchase and sale, weighted by the shares each lot gave.
    let holdingDays: Double?
    /// Only when every share sold matched a purchase with a known price.
    let costUSD: Double?
    /// The broker's own result where it reported one, else proceeds less cost.
    let profitUSD: Double?
    /// Rebuilt here rather than reported by the broker.
    let isEstimated: Bool

    var returnPercent: Double? {
        guard let costUSD, costUSD > 0, let profitUSD else { return nil }
        let value = profitUSD / costUSD * 100
        return value.isFinite ? value : nil
    }
}

/// The odd, telling and fun facts in a trading history: the best and worst
/// trades, the hit rate, how long winners and losers were held, the busiest
/// day, the shares sold too early. Pure: everything comes from the ledger
/// and today's prices passed in, so it can be tested without the app.
struct TradingInsights: Equatable, Sendable {
    struct SecurityResult: Equatable, Sendable {
        let ticker: String
        let profitUSD: Double
        let costUSD: Double?
        let saleCount: Int

        var returnPercent: Double? {
            guard let costUSD, costUSD > 0 else { return nil }
            let value = profitUSD / costUSD * 100
            return value.isFinite ? value : nil
        }
    }

    struct Count: Equatable, Sendable {
        let key: String
        let count: Int
    }

    struct Amount: Equatable, Sendable {
        let ticker: String
        let date: String
        let usd: Double
    }

    /// A sale against today's price of the same security, still held.
    struct AfterSale: Equatable, Sendable {
        let ticker: String
        let saleDate: String
        let salePrice: Double
        let currentPrice: Double
        let currency: String

        var changePercent: Double { (currentPrice / salePrice - 1) * 100 }
    }

    struct Quote: Equatable, Sendable {
        let price: Double
        let currency: String
    }

    var trades: [InsightClosedTrade] = []
    var buyCount = 0
    var sellCount = 0
    var firstTrade: Amount?
    var busiestDay: Count?
    var busiestMonth: Count?
    /// Trades per weekday, Sunday first, as `Calendar` numbers them.
    var weekdayCounts = Array(repeating: 0, count: 7)
    var largestBuy: Amount?
    /// Purchases made at least 10% under the last purchase of the same
    /// security in the same account.
    var dipBuyCount = 0
    var mostDipBought: Count?
    var mostTraded: Count?
    var securityResults: [SecurityResult] = []
    var topDividend: Amount?
    var dividendTotalUSD = 0.0
    var soldTooEarly: AfterSale?
    var soldJustInTime: AfterSale?
    var longestWinStreak = 0
    var longestLossStreak = 0

    // MARK: Derived

    var valuedTrades: [InsightClosedTrade] { trades.filter { $0.profitUSD != nil } }
    var wins: [InsightClosedTrade] { valuedTrades.filter { ($0.profitUSD ?? 0) > 0 } }
    var losses: [InsightClosedTrade] { valuedTrades.filter { ($0.profitUSD ?? 0) < 0 } }
    var tradeCount: Int { buyCount + sellCount }
    var hasEstimates: Bool { valuedTrades.contains(where: \.isEstimated) }

    var winRate: Double? {
        let decided = wins.count + losses.count
        return decided > 0 ? Double(wins.count) / Double(decided) : nil
    }

    var averageWinUSD: Double? { Self.mean(wins.compactMap(\.profitUSD)) }
    var averageLossUSD: Double? { Self.mean(losses.compactMap(\.profitUSD)) }

    /// Average win over average loss: above 1, the wins outweigh the losses.
    var payoffRatio: Double? {
        guard let win = averageWinUSD, let loss = averageLossUSD, loss < 0 else { return nil }
        return win / -loss
    }

    var bestTrade: InsightClosedTrade? {
        valuedTrades.filter { ($0.profitUSD ?? 0) > 0 }.max { ($0.profitUSD ?? 0) < ($1.profitUSD ?? 0) }
    }

    var worstTrade: InsightClosedTrade? {
        valuedTrades.filter { ($0.profitUSD ?? 0) < 0 }.min { ($0.profitUSD ?? 0) < ($1.profitUSD ?? 0) }
    }

    var bestReturn: InsightClosedTrade? {
        trades.filter { ($0.returnPercent ?? 0) > 0 }.max { ($0.returnPercent ?? 0) < ($1.returnPercent ?? 0) }
    }

    var worstReturn: InsightClosedTrade? {
        trades.filter { ($0.returnPercent ?? 0) < 0 }.min { ($0.returnPercent ?? 0) < ($1.returnPercent ?? 0) }
    }

    var longestHold: InsightClosedTrade? {
        trades.filter { $0.holdingDays != nil }.max { ($0.holdingDays ?? 0) < ($1.holdingDays ?? 0) }
    }

    var quickestRoundTrip: InsightClosedTrade? {
        trades.filter { $0.holdingDays != nil }.min { ($0.holdingDays ?? 0) < ($1.holdingDays ?? 0) }
    }

    var averageHoldingDays: Double? { Self.mean(trades.compactMap(\.holdingDays)) }
    var averageWinnerHoldingDays: Double? { Self.mean(wins.compactMap(\.holdingDays)) }
    var averageLoserHoldingDays: Double? { Self.mean(losses.compactMap(\.holdingDays)) }

    var bestSecurity: SecurityResult? {
        securityResults.filter { $0.profitUSD > 0 }.max { $0.profitUSD < $1.profitUSD }
    }

    var worstSecurity: SecurityResult? {
        securityResults.filter { $0.profitUSD < 0 }.min { $0.profitUSD < $1.profitUSD }
    }

    /// The weekday traded on most, as `Calendar` numbers it (1 is Sunday).
    var favouriteWeekday: Int? {
        guard let top = weekdayCounts.max(), top > 0,
              let index = weekdayCounts.firstIndex(of: top) else { return nil }
        return index + 1
    }

    var isEmpty: Bool { tradeCount == 0 && dividendTotalUSD == 0 }

    private static func mean(_ values: [Double]) -> Double? {
        let finite = values.filter(\.isFinite)
        return finite.isEmpty ? nil : finite.reduce(0, +) / Double(finite.count)
    }

    // MARK: Build

    private struct Lot {
        var quantity: Double
        let costPerShareUSD: Double?
        let date: String
    }

    /// - Parameters:
    ///   - transactions: the ledger, every account; cash rows are ignored.
    ///   - quotes: today's price of each security still held, by ticker.
    static func build(transactions: [LocalTransactionRecord],
                      quotes: [String: Quote] = [:],
                      usdRate: (String) -> Double? = { LocalPortfolioEngine.usdRate(for: $0) },
                      splitAdjustment: (String, String) -> Double? = { ticker, date in
                          (try? StockSplitCatalog.bundled.get())?.adjustment(ticker: ticker, from: date)
                      }) -> TradingInsights {
        var result = TradingInsights()
        var lotsByPosition: [String: [Lot]] = [:]
        var lastBuyPrice: [String: Double] = [:]
        var dipBuysByTicker: [String: Int] = [:]
        var tradesByTicker: [String: Int] = [:]
        var tradesByDay: [String: Int] = [:]
        var tradesByMonth: [String: Int] = [:]
        var dividendsByTicker: [String: Double] = [:]
        var resultByTicker: [String: (profit: Double, cost: Double, costComplete: Bool, count: Int)] = [:]
        var lastSaleByTicker: [String: (date: String, price: Double, currency: String)] = [:]
        var afterSales: [AfterSale] = []

        for transaction in transactions where PortfolioActivityKind(action: transaction.action) == .dividend {
            guard let rate = usdRate(transaction.currency) else { continue }
            let usd = transaction.quantity * transaction.price * rate
            guard usd.isFinite else { continue }
            let ticker = transaction.ticker.uppercased()
            dividendsByTicker[ticker, default: 0] += usd
            result.dividendTotalUSD += usd
        }

        let ordered = LocalTransactionRecord.orderedForLotMatching(transactions.filter {
            RealisedProfitCalculator.isBuy($0.action) || RealisedProfitCalculator.isSell($0.action)
        })

        for transaction in ordered {
            let ticker = transaction.ticker.uppercased()
            let key = "\(transaction.accountKey)|\(ticker)"
            let rate = usdRate(transaction.currency).flatMap { $0.isFinite ? $0 : nil }
            // Today's share basis, as the realised calculator puts it.
            let split = splitAdjustment(transaction.ticker, transaction.date) ?? 1
            let quantity = abs(transaction.quantity) * split
            let price = split > 0 ? transaction.price / split : transaction.price
            let isBuy = RealisedProfitCalculator.isBuy(transaction.action)

            tradesByTicker[ticker, default: 0] += 1
            tradesByDay[transaction.date, default: 0] += 1
            tradesByMonth[String(transaction.date.prefix(7)), default: 0] += 1
            if let weekday = weekday(of: transaction.date) { result.weekdayCounts[weekday - 1] += 1 }
            if result.firstTrade == nil {
                result.firstTrade = Amount(ticker: ticker, date: transaction.date,
                                           usd: rate.map { quantity * price * $0 } ?? .nan)
            }

            if isBuy {
                result.buyCount += 1
                if let rate {
                    let usd = quantity * price * rate
                    if usd.isFinite, usd > (result.largestBuy?.usd ?? 0) {
                        result.largestBuy = Amount(ticker: ticker, date: transaction.date, usd: usd)
                    }
                }
                if let last = lastBuyPrice[key], last > 0, price > 0, price <= last * 0.9 {
                    result.dipBuyCount += 1
                    dipBuysByTicker[ticker, default: 0] += 1
                }
                if price > 0 { lastBuyPrice[key] = price }
                lotsByPosition[key, default: []].append(Lot(
                    quantity: quantity, costPerShareUSD: rate.map { price * $0 }, date: transaction.date))
                continue
            }

            result.sellCount += 1
            var remaining = quantity
            var lots = lotsByPosition[key] ?? []
            var matchedCost = 0.0
            var costComplete = true
            var weightedDays = 0.0
            var matchedQuantity = 0.0
            var firstBuy: String?
            while remaining > 0.000_000_1, !lots.isEmpty {
                let matched = min(remaining, lots[0].quantity)
                if let cost = lots[0].costPerShareUSD { matchedCost += cost * matched } else { costComplete = false }
                if let days = days(from: lots[0].date, to: transaction.date) {
                    weightedDays += days * matched
                    matchedQuantity += matched
                }
                firstBuy = firstBuy ?? lots[0].date
                remaining -= matched
                lots[0].quantity -= matched
                if lots[0].quantity <= 0.000_000_1 { lots.removeFirst() }
            }
            lotsByPosition[key] = lots
            let fullyMatched = remaining <= max(0.000_000_1, quantity * 0.000_001)
            let cost = fullyMatched && costComplete ? matchedCost : nil

            let broker = brokerUSD(for: transaction, usdRate: usdRate)
            let estimated = cost.flatMap { cost in rate.map { price * $0 * quantity - cost } }
            let profit = (broker ?? estimated).flatMap { $0.isFinite ? $0 : nil }
            result.trades.append(InsightClosedTrade(
                id: transaction.id, ticker: ticker, saleDate: transaction.date, firstBuyDate: firstBuy,
                holdingDays: matchedQuantity > 0 ? weightedDays / matchedQuantity : nil,
                costUSD: cost, profitUSD: profit, isEstimated: broker == nil && profit != nil))
            if let profit {
                var entry = resultByTicker[ticker] ?? (0, 0, true, 0)
                entry.profit += profit
                if let cost { entry.cost += cost } else { entry.costComplete = false }
                entry.count += 1
                resultByTicker[ticker] = entry
            }
            if price > 0 {
                lastSaleByTicker[ticker] = (transaction.date, price, transaction.currency.uppercased())
            }
        }

        for (ticker, sale) in lastSaleByTicker {
            guard let quote = quotes[ticker], quote.price > 0,
                  quote.currency.uppercased() == sale.currency else { continue }
            afterSales.append(AfterSale(ticker: ticker, saleDate: sale.date, salePrice: sale.price,
                                        currentPrice: quote.price, currency: sale.currency))
        }
        result.soldTooEarly = afterSales.filter { $0.changePercent >= 5 }
            .max { $0.changePercent < $1.changePercent }
        result.soldJustInTime = afterSales.filter { $0.changePercent <= -5 }
            .min { $0.changePercent < $1.changePercent }

        var streak = (wins: 0, losses: 0)
        for trade in result.trades {
            guard let profit = trade.profitUSD, profit != 0 else { continue }
            if profit > 0 {
                streak = (streak.wins + 1, 0)
            } else {
                streak = (0, streak.losses + 1)
            }
            result.longestWinStreak = max(result.longestWinStreak, streak.wins)
            result.longestLossStreak = max(result.longestLossStreak, streak.losses)
        }

        result.securityResults = resultByTicker.map { ticker, entry in
            SecurityResult(ticker: ticker, profitUSD: entry.profit,
                           costUSD: entry.costComplete ? entry.cost : nil, saleCount: entry.count)
        }.sorted { $0.ticker < $1.ticker }
        result.busiestDay = top(tradesByDay, minimum: 2)
        result.busiestMonth = top(tradesByMonth, minimum: 2)
        result.mostTraded = top(tradesByTicker, minimum: 2)
        result.mostDipBought = top(dipBuysByTicker, minimum: 1)
        if let dividend = dividendsByTicker.filter({ $0.value > 0 })
            .max(by: { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }) {
            result.topDividend = Amount(ticker: dividend.key, date: "", usd: dividend.value)
        }
        return result
    }

    /// The broker's Result in USD, when it reported a well-formed one.
    private static func brokerUSD(for transaction: LocalTransactionRecord,
                                  usdRate: (String) -> Double?) -> Double? {
        guard let raw = transaction.realisedProfitLoss, raw.isFinite else { return nil }
        let currency = transaction.realisedProfitLossCurrency?
            .trimmingCharacters(in: .whitespacesAndNewlines).uppercased() ?? ""
        guard currency.count == 3, currency.utf8.allSatisfy({ (65...90).contains($0) }),
              let rate = usdRate(currency), rate.isFinite else { return nil }
        return raw * rate
    }

    /// The largest count, the earliest key on a tie so the answer is stable.
    private static func top(_ counts: [String: Int], minimum: Int) -> Count? {
        guard let best = counts.max(by: { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }),
              best.value >= minimum else { return nil }
        return Count(key: best.key, count: best.value)
    }

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar
    }()

    static func date(_ text: String) -> Date? {
        let parts = text.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    static func days(from start: String, to end: String) -> Double? {
        guard let from = date(start), let to = date(end) else { return nil }
        return max(0, to.timeIntervalSince(from) / 86_400).rounded()
    }

    static func weekday(of text: String) -> Int? {
        date(text).map { calendar.component(.weekday, from: $0) }
    }
}
