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
    var quantity: Double = 0
    /// On today's share basis, in the sale's own currency.
    var salePrice: Double = 0
    var currency: String = "USD"
    /// When the first lot the sale drew on was bought, if the broker said.
    var openExecutedAt: String?
    /// This sale's cost against everything held at cost just before it.
    var bookShare: Double?
    /// The position was added to at least 10% under its previous purchase
    /// while these shares were held.
    var wasAveragedDown = false

    init(id: String, ticker: String, saleDate: String, firstBuyDate: String?, holdingDays: Double?,
         costUSD: Double?, profitUSD: Double?, isEstimated: Bool) {
        self.id = id
        self.ticker = ticker
        self.saleDate = saleDate
        self.firstBuyDate = firstBuyDate
        self.holdingDays = holdingDays
        self.costUSD = costUSD
        self.profitUSD = profitUSD
        self.isEstimated = isEstimated
    }

    var returnPercent: Double? {
        guard let costUSD, costUSD > 0, let profitUSD else { return nil }
        let value = profitUSD / costUSD * 100
        return value.isFinite ? value : nil
    }

    var isWin: Bool { (profitUSD ?? 0) > 0 }
    var isLoss: Bool { (profitUSD ?? 0) < 0 }
}

/// The odd, telling and fun facts in a trading history. Pure: everything
/// comes from the ledger and today's prices passed in, so it can be tested
/// without the app.
///
/// Only what the ledger can answer is here. There are no daily prices in it,
/// so nothing is said about how a position moved while it was held — only
/// about the prices it was bought and sold at, and today's.
struct TradingInsights: Equatable, Sendable {
    struct SecurityResult: Equatable, Sendable {
        let ticker: String
        var profitUSD: Double
        var costUSD: Double?
        var saleCount: Int
        var winCount = 0
        var lossCount = 0
        /// Per-sale returns, for the steadiness measure.
        var returns: [Double] = []

        init(ticker: String, profitUSD: Double, costUSD: Double?, saleCount: Int) {
            self.ticker = ticker
            self.profitUSD = profitUSD
            self.costUSD = costUSD
            self.saleCount = saleCount
        }

        var returnPercent: Double? {
            guard let costUSD, costUSD > 0 else { return nil }
            let value = profitUSD / costUSD * 100
            return value.isFinite ? value : nil
        }

        var winRate: Double? {
            let decided = winCount + lossCount
            return decided > 0 ? Double(winCount) / Double(decided) : nil
        }

        var averageReturn: Double? { TradingInsights.mean(returns) }

        /// Mean return over its spread: a Sharpe-like score per sale.
        var steadiness: Double? {
            guard returns.count >= 3, let mean = averageReturn,
                  let spread = TradingInsights.standardDeviation(returns), spread > 0.0001 else { return nil }
            return mean / spread
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
        var quantity: Double = 0
        var usdRate: Double = 1

        init(ticker: String, saleDate: String, salePrice: Double, currentPrice: Double, currency: String) {
            self.ticker = ticker
            self.saleDate = saleDate
            self.salePrice = salePrice
            self.currentPrice = currentPrice
            self.currency = currency
        }

        var changePercent: Double { (currentPrice / salePrice - 1) * 100 }
        /// What the shares sold would be worth more (or less) today.
        var missedUSD: Double { (currentPrice - salePrice) * quantity * usdRate }
    }

    struct Quote: Equatable, Sendable {
        let price: Double
        let currency: String
    }

    /// Trades grouped by some property, with how they did.
    struct Bucket: Equatable, Sendable {
        let key: String
        var count = 0
        var wins = 0
        var losses = 0
        var returns: [Double] = []
        var profitUSD = 0.0

        var winRate: Double? { wins + losses > 0 ? Double(wins) / Double(wins + losses) : nil }
        var averageReturn: Double? { TradingInsights.mean(returns) }
    }

    /// Where in the trading day a fill landed, on its exchange's own clock.
    enum SessionPart: String, CaseIterable, Sendable {
        case open, midday, close, other
    }

    /// Ranges of how long a trade was held.
    enum HoldingRange: String, CaseIterable, Sendable {
        case day, week, month, quarter, longer

        static func of(days: Double) -> HoldingRange {
            switch days {
            case ...1: .day
            case ...7: .week
            case ...30: .month
            case ...90: .quarter
            default: .longer
            }
        }
    }

    /// How a ticker did after the reader traded it, against today's price.
    struct TradeTiming: Equatable, Sendable {
        let ticker: String
        var afterBuys: [Double] = []
        var afterSales: [Double] = []
        var averageAfterBuy: Double? { TradingInsights.mean(afterBuys) }
        var averageAfterSale: Double? { TradingInsights.mean(afterSales) }
    }

    var trades: [InsightClosedTrade] = []
    var buyCount = 0
    var sellCount = 0
    var firstTrade: Amount?
    var busiestDay: Count?
    var busiestMonth: Count?
    /// Trades per weekday, Sunday first, as `Calendar` numbers them.
    var weekdayCounts = Array(repeating: 0, count: 7)
    var buyWeekdayCounts = Array(repeating: 0, count: 7)
    var largestBuy: Amount?
    /// Purchases made at least 10% under the last purchase of the same
    /// security in the same account.
    var dipBuyCount = 0
    var mostDipBought: Count?
    /// Purchases made at least 10% over the last one: buying higher.
    var chaseBuyCount = 0
    /// Purchases of a security within a week of selling it at a loss.
    var revengeBuyCount = 0
    var revengeTicker: String?
    var mostTraded: Count?
    var securityResults: [SecurityResult] = []
    var topDividend: Amount?
    var dividendTotalUSD = 0.0
    var soldTooEarly: AfterSale?
    var soldJustInTime: AfterSale?
    /// The sale that, at today's price, left the most money behind.
    var costliestSale: AfterSale?
    var longestWinStreak = 0
    var longestLossStreak = 0
    var timing: [TradeTiming] = []
    /// Month of year (1–12) → purchases made at a higher price than the last.
    var chaseBuysByMonth: [Int: Int] = [:]
    struct Milestone: Equatable, Sendable {
        let count: Int
        let date: String
    }

    /// The dates the 100th, 500th, 1000th… trade was made.
    var milestones: [Milestone] = []
    /// Trades by year, for the year's keywords.
    var tradesByYearTicker: [String: [String: Int]] = [:]

    // MARK: Derived — results

    var valuedTrades: [InsightClosedTrade] { trades.filter { $0.profitUSD != nil } }
    var wins: [InsightClosedTrade] { valuedTrades.filter(\.isWin) }
    var losses: [InsightClosedTrade] { valuedTrades.filter(\.isLoss) }
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

    var realisedUSD: Double { valuedTrades.compactMap(\.profitUSD).reduce(0, +) }

    var bestTrade: InsightClosedTrade? {
        wins.max { ($0.profitUSD ?? 0) < ($1.profitUSD ?? 0) }
    }

    var worstTrade: InsightClosedTrade? {
        losses.min { ($0.profitUSD ?? 0) < ($1.profitUSD ?? 0) }
    }

    var bestReturn: InsightClosedTrade? {
        trades.filter { ($0.returnPercent ?? 0) > 0 }.max { ($0.returnPercent ?? 0) < ($1.returnPercent ?? 0) }
    }

    var worstReturn: InsightClosedTrade? {
        trades.filter { ($0.returnPercent ?? 0) < 0 }.min { ($0.returnPercent ?? 0) < ($1.returnPercent ?? 0) }
    }

    var bestSecurity: SecurityResult? {
        securityResults.filter { $0.profitUSD > 0 }.max { $0.profitUSD < $1.profitUSD }
    }

    var worstSecurity: SecurityResult? {
        securityResults.filter { $0.profitUSD < 0 }.min { $0.profitUSD < $1.profitUSD }
    }

    /// The highest hit rate among securities sold at least three times.
    var mostAccurateSecurity: SecurityResult? {
        securityResults.filter { $0.winCount + $0.lossCount >= 3 && ($0.winRate ?? 0) > 0 }
            .max { lhs, rhs in
                lhs.winRate == rhs.winRate ? lhs.profitUSD < rhs.profitUSD : (lhs.winRate ?? 0) < (rhs.winRate ?? 0)
            }
    }

    /// Lost on most often: the security that keeps taking money.
    var nemesis: SecurityResult? {
        securityResults.filter { $0.lossCount >= 2 && $0.lossCount > $0.winCount }
            .max { lhs, rhs in
                lhs.lossCount == rhs.lossCount ? lhs.profitUSD > rhs.profitUSD : lhs.lossCount < rhs.lossCount
            }
    }

    /// Sold at least twice and never at a profit.
    var neverRecovered: [SecurityResult] {
        securityResults.filter { $0.lossCount >= 2 && $0.winCount == 0 }.sorted { $0.profitUSD < $1.profitUSD }
    }

    /// The best-returning sale of a position that was added to on the way
    /// down: bought more under water, and still left at a profit.
    var comebackTrade: InsightClosedTrade? {
        trades.filter { $0.wasAveragedDown && ($0.returnPercent ?? 0) > 0 }
            .max { ($0.returnPercent ?? 0) < ($1.returnPercent ?? 0) }
    }

    /// The best risk-adjusted security: mean return per sale over its spread.
    var steadiestSecurity: SecurityResult? {
        securityResults.filter { ($0.steadiness ?? 0) > 0 }.max { ($0.steadiness ?? 0) < ($1.steadiness ?? 0) }
    }

    /// The average loss a losing trade is closed at, and the average gain a
    /// winning one is taken at.
    var averageLossReturn: Double? { Self.mean(losses.compactMap(\.returnPercent)) }
    var averageWinReturn: Double? { Self.mean(wins.compactMap(\.returnPercent)) }

    /// The fewest of the largest losses that make up most of the realised
    /// loss, and the share they make.
    var lossConcentration: (count: Int, share: Double)? {
        let sizes = losses.compactMap { $0.profitUSD.map { -$0 } }.sorted(by: >)
        let total = sizes.reduce(0, +)
        guard sizes.count >= 5, total > 0 else { return nil }
        let count = min(3, sizes.count)
        return (count, sizes.prefix(count).reduce(0, +) / total)
    }

    /// Simulated: every loss stopped at −10% of its cost.
    var stopLossSavingUSD: Double? {
        let saving = losses.reduce(0.0) { sum, trade in
            guard let cost = trade.costUSD, let profit = trade.profitUSD, profit < -0.1 * cost else { return sum }
            return sum + (-profit - 0.1 * cost)
        }
        return saving > 0 ? saving : nil
    }

    // MARK: Derived — size

    private var sizedTrades: [InsightClosedTrade] {
        trades.filter { $0.costUSD != nil && $0.profitUSD != nil }.sorted { ($0.costUSD ?? 0) > ($1.costUSD ?? 0) }
    }

    /// The five largest trades by cost, and every other trade.
    var heavyTrades: (heavy: Bucket, rest: Bucket)? {
        let sized = sizedTrades
        guard sized.count >= 10 else { return nil }
        return (Self.bucket("heavy", sized.prefix(5)), Self.bucket("rest", sized.dropFirst(5)))
    }

    /// The best return among the smallest quarter of trades by cost.
    var smallPositionStar: InsightClosedTrade? {
        let sized = sizedTrades
        guard sized.count >= 8 else { return nil }
        return sized.suffix(max(2, sized.count / 4)).filter { ($0.returnPercent ?? 0) > 0 }
            .max { ($0.returnPercent ?? 0) < ($1.returnPercent ?? 0) }
    }

    // MARK: Derived — time

    var longestHold: InsightClosedTrade? {
        trades.filter { $0.holdingDays != nil }.max { ($0.holdingDays ?? 0) < ($1.holdingDays ?? 0) }
    }

    var quickestRoundTrip: InsightClosedTrade? {
        trades.filter { $0.holdingDays != nil }.min { ($0.holdingDays ?? 0) < ($1.holdingDays ?? 0) }
    }

    var averageHoldingDays: Double? { Self.mean(trades.compactMap(\.holdingDays)) }
    var averageWinnerHoldingDays: Double? { Self.mean(wins.compactMap(\.holdingDays)) }
    var averageLoserHoldingDays: Double? { Self.mean(losses.compactMap(\.holdingDays)) }

    /// The weekday traded on most, as `Calendar` numbers it (1 is Sunday).
    var favouriteWeekday: Int? {
        guard let top = weekdayCounts.max(), top > 0,
              let index = weekdayCounts.firstIndex(of: top) else { return nil }
        return index + 1
    }

    /// How trades did by the weekday they were opened, Monday to Friday.
    var openingWeekdays: [Bucket] {
        let grouped = Dictionary(grouping: valuedTrades.filter { $0.firstBuyDate != nil }) {
            Self.weekday(of: $0.firstBuyDate ?? "") ?? 0
        }
        return (2...6).compactMap { day in
            guard let group = grouped[day], group.count >= 3 else { return nil }
            return Self.bucket(String(day), group)
        }
    }

    /// How trades did by where in the trading day they were opened.
    var sessionParts: [Bucket] {
        let grouped = Dictionary(grouping: valuedTrades) {
            Self.sessionPart(executedAt: $0.openExecutedAt, currency: $0.currency)
        }
        return SessionPart.allCases.compactMap { part in
            guard let group = grouped[part], group.count >= 3 else { return nil }
            return Self.bucket(part.rawValue, group)
        }
    }

    /// How trades did by how long they were held.
    var holdingRanges: [Bucket] {
        let grouped = Dictionary(grouping: valuedTrades.filter { $0.holdingDays != nil }) {
            HoldingRange.of(days: $0.holdingDays ?? 0)
        }
        return HoldingRange.allCases.compactMap { range in
            guard let group = grouped[range], !group.isEmpty else { return nil }
            return Self.bucket(range.rawValue, group)
        }
    }

    /// Trades held a week or less: what all that activity came to.
    var shortTermTrades: Bucket? {
        let short = valuedTrades.filter { ($0.holdingDays ?? .infinity) <= 7 }
        return short.count >= 3 ? Self.bucket("short", short) : nil
    }

    /// Bought and sold within three days.
    var quickFlipCount: Int { trades.filter { ($0.holdingDays ?? .infinity) <= 3 }.count }

    /// The month of the year most given to buying higher, and the one whose
    /// sales were held longest.
    var chasingMonth: Int? {
        chaseBuysByMonth.filter { $0.value >= 2 }
            .max { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }?.key
    }

    var patientMonth: Int? {
        let grouped = Dictionary(grouping: trades.filter { $0.holdingDays != nil }) {
            Int($0.saleDate.dropFirst(5).prefix(2)) ?? 0
        }
        let held = grouped.filter { $0.key > 0 && $0.value.count >= 2 }
            .mapValues { Self.mean($0.compactMap(\.holdingDays)) ?? 0 }
        return held.max { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }?.key
    }

    // MARK: Derived — timing against today

    /// The security bought best — up most since the reader's purchases — and
    /// the one sold best — down most since the sales.
    var bestBuyer: TradeTiming? {
        timing.filter { $0.afterBuys.count >= 2 && ($0.averageAfterBuy ?? 0) > 0 }
            .max { ($0.averageAfterBuy ?? 0) < ($1.averageAfterBuy ?? 0) }
    }

    var bestSeller: TradeTiming? {
        timing.filter { !$0.afterSales.isEmpty && ($0.averageAfterSale ?? 0) < 0 }
            .min { ($0.averageAfterSale ?? 0) < ($1.averageAfterSale ?? 0) }
    }

    var averageAfterBuy: Double? { Self.mean(timing.flatMap(\.afterBuys)) }
    var averageAfterSale: Double? { Self.mean(timing.flatMap(\.afterSales)) }

    // MARK: Derived — persona

    enum Persona: String, CaseIterable, Sendable {
        case sniper, longHolder, letsWinnersRun, waitsToBreakEven, dipHunter, trendFollower, rapidTrier, explorer
    }

    /// Up to three labels for how the reader trades, strongest first.
    var personas: [Persona] {
        var labels: [Persona] = []
        if let rate = winRate, rate >= 0.65, valuedTrades.count >= 10 { labels.append(.sniper) }
        if let held = averageHoldingDays, held >= 180 { labels.append(.longHolder) }
        if let held = averageHoldingDays, held <= 14, sellCount >= 20 { labels.append(.rapidTrier) }
        if buyCount > 0, dipBuyCount >= 3, Double(dipBuyCount) / Double(buyCount) >= 0.15 { labels.append(.dipHunter) }
        if buyCount > 0, chaseBuyCount >= 3, Double(chaseBuyCount) / Double(buyCount) >= 0.15 {
            labels.append(.trendFollower)
        }
        if let winners = averageWinnerHoldingDays, let losers = averageLoserHoldingDays {
            if losers > winners * 1.2 { labels.append(.waitsToBreakEven) }
            if winners > losers * 1.2 { labels.append(.letsWinnersRun) }
        }
        if labels.isEmpty { labels.append(.explorer) }
        return Array(labels.prefix(3))
    }

    /// The weekday most bought on, and the one most losses were taken on.
    var impulsiveWeekday: Int? {
        guard let top = buyWeekdayCounts.max(), top >= 3,
              let index = buyWeekdayCounts.firstIndex(of: top) else { return nil }
        return index + 1
    }

    var cuttingWeekday: Int? {
        let grouped = Dictionary(grouping: losses) { Self.weekday(of: $0.saleDate) ?? 0 }
        return grouped.filter { $0.key > 0 && $0.value.count >= 2 }
            .max { $0.value.count == $1.value.count ? $0.key > $1.key : $0.value.count < $1.value.count }?.key
    }

    /// The latest year traded, and its most traded securities.
    var keywordYear: String? { tradesByYearTicker.keys.max() }

    var keywordTickers: [String] {
        guard let year = keywordYear, let counts = tradesByYearTicker[year] else { return [] }
        return counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.prefix(2).map(\.key)
    }

    var isEmpty: Bool { tradeCount == 0 && dividendTotalUSD == 0 }

    // MARK: Helpers

    static func mean(_ values: [Double]) -> Double? {
        let finite = values.filter(\.isFinite)
        return finite.isEmpty ? nil : finite.reduce(0, +) / Double(finite.count)
    }

    static func standardDeviation(_ values: [Double]) -> Double? {
        let finite = values.filter(\.isFinite)
        guard finite.count >= 2, let average = mean(finite) else { return nil }
        let variance = finite.reduce(0) { $0 + ($1 - average) * ($1 - average) } / Double(finite.count - 1)
        return variance.squareRoot()
    }

    private static func bucket<S: Sequence>(_ key: String, _ trades: S) -> Bucket where S.Element == InsightClosedTrade {
        var bucket = Bucket(key: key)
        for trade in trades {
            bucket.count += 1
            if trade.isWin { bucket.wins += 1 }
            if trade.isLoss { bucket.losses += 1 }
            if let value = trade.returnPercent { bucket.returns.append(value) }
            bucket.profitUSD += trade.profitUSD ?? 0
        }
        return bucket
    }

    // MARK: Build

    private struct Lot {
        var quantity: Double
        let costPerShareUSD: Double?
        let date: String
        let executedAt: String?
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
        var averagedDown: Set<String> = []
        var lastLosingSale: [String: String] = [:]
        var dipBuysByTicker: [String: Int] = [:]
        var revengeByTicker: [String: Int] = [:]
        var tradesByTicker: [String: Int] = [:]
        var tradesByDay: [String: Int] = [:]
        var tradesByMonth: [String: Int] = [:]
        var dividendsByTicker: [String: Double] = [:]
        var securities: [String: SecurityResult] = [:]
        var securityCostComplete: [String: Bool] = [:]
        var lastSaleByTicker: [String: AfterSale] = [:]
        var timingByTicker: [String: TradeTiming] = [:]
        var openBookUSD = 0.0
        var tradeNumber = 0
        let milestoneCounts: Set<Int> = [100, 250, 500, 1000, 2000, 5000]

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
            let currency = transaction.currency.uppercased()
            let rate = usdRate(transaction.currency).flatMap { $0.isFinite ? $0 : nil }
            // Today's share basis, as the realised calculator puts it.
            let split = splitAdjustment(transaction.ticker, transaction.date) ?? 1
            let quantity = abs(transaction.quantity) * split
            let price = split > 0 ? transaction.price / split : transaction.price
            let isBuy = RealisedProfitCalculator.isBuy(transaction.action)
            let quote = quotes[ticker].flatMap { $0.price > 0 && $0.currency.uppercased() == currency ? $0 : nil }

            tradeNumber += 1
            if milestoneCounts.contains(tradeNumber) { result.milestones.append(Milestone(count: tradeNumber, date: transaction.date)) }
            tradesByTicker[ticker, default: 0] += 1
            tradesByDay[transaction.date, default: 0] += 1
            tradesByMonth[String(transaction.date.prefix(7)), default: 0] += 1
            result.tradesByYearTicker[String(transaction.date.prefix(4)), default: [:]][ticker, default: 0] += 1
            if let day = weekday(of: transaction.date) {
                result.weekdayCounts[day - 1] += 1
                if isBuy { result.buyWeekdayCounts[day - 1] += 1 }
            }
            if result.firstTrade == nil {
                result.firstTrade = Amount(ticker: ticker, date: transaction.date,
                                           usd: rate.map { quantity * price * $0 } ?? .nan)
            }

            if isBuy {
                result.buyCount += 1
                let costUSD = rate.map { quantity * price * $0 }
                if let usd = costUSD, usd.isFinite {
                    openBookUSD += usd
                    if usd > (result.largestBuy?.usd ?? 0) {
                        result.largestBuy = Amount(ticker: ticker, date: transaction.date, usd: usd)
                    }
                }
                if let last = lastBuyPrice[key], last > 0, price > 0 {
                    if price <= last * 0.9 {
                        result.dipBuyCount += 1
                        dipBuysByTicker[ticker, default: 0] += 1
                        if !(lotsByPosition[key] ?? []).isEmpty { averagedDown.insert(key) }
                    } else if price >= last * 1.1 {
                        result.chaseBuyCount += 1
                        if let month = Int(transaction.date.dropFirst(5).prefix(2)) {
                            result.chaseBuysByMonth[month, default: 0] += 1
                        }
                    }
                }
                if let lossDate = lastLosingSale[key], let gap = days(from: lossDate, to: transaction.date), gap <= 7 {
                    result.revengeBuyCount += 1
                    revengeByTicker[ticker, default: 0] += 1
                    lastLosingSale[key] = nil
                }
                if price > 0 { lastBuyPrice[key] = price }
                if let quote, price > 0 {
                    timingByTicker[ticker, default: TradeTiming(ticker: ticker)].afterBuys
                        .append((quote.price / price - 1) * 100)
                }
                lotsByPosition[key, default: []].append(Lot(
                    quantity: quantity, costPerShareUSD: rate.map { price * $0 }, date: transaction.date,
                    executedAt: transaction.executedAt))
                continue
            }

            result.sellCount += 1
            var remaining = quantity
            var lots = lotsByPosition[key] ?? []
            var matchedCost = 0.0
            var costComplete = true
            var weightedDays = 0.0
            var matchedQuantity = 0.0
            var firstLot: Lot?
            while remaining > 0.000_000_1, !lots.isEmpty {
                let matched = min(remaining, lots[0].quantity)
                if let cost = lots[0].costPerShareUSD { matchedCost += cost * matched } else { costComplete = false }
                if let held = days(from: lots[0].date, to: transaction.date) {
                    weightedDays += held * matched
                    matchedQuantity += matched
                }
                firstLot = firstLot ?? lots[0]
                remaining -= matched
                lots[0].quantity -= matched
                if lots[0].quantity <= 0.000_000_1 { lots.removeFirst() }
            }
            lotsByPosition[key] = lots
            let fullyMatched = remaining <= max(0.000_000_1, quantity * 0.000_001)
            let cost = fullyMatched && costComplete ? matchedCost : nil
            let bookBefore = openBookUSD
            if costComplete { openBookUSD = max(0, openBookUSD - matchedCost) }

            let broker = brokerUSD(for: transaction, usdRate: usdRate)
            let estimated = cost.flatMap { cost in rate.map { price * $0 * quantity - cost } }
            let profit = (broker ?? estimated).flatMap { $0.isFinite ? $0 : nil }
            var trade = InsightClosedTrade(
                id: transaction.id, ticker: ticker, saleDate: transaction.date, firstBuyDate: firstLot?.date,
                holdingDays: matchedQuantity > 0 ? weightedDays / matchedQuantity : nil,
                costUSD: cost, profitUSD: profit, isEstimated: broker == nil && profit != nil)
            trade.quantity = quantity
            trade.salePrice = price
            trade.currency = currency
            trade.openExecutedAt = firstLot?.executedAt
            if let cost, bookBefore > 0 { trade.bookShare = min(1, cost / bookBefore) }
            trade.wasAveragedDown = averagedDown.contains(key)
            if lots.isEmpty { averagedDown.remove(key) }
            result.trades.append(trade)

            if let profit {
                var entry = securities[ticker]
                    ?? SecurityResult(ticker: ticker, profitUSD: 0, costUSD: 0, saleCount: 0)
                entry.profitUSD += profit
                entry.costUSD = (entry.costUSD ?? 0) + (cost ?? 0)
                entry.saleCount += 1
                if profit > 0 { entry.winCount += 1 }
                if profit < 0 { entry.lossCount += 1 }
                if let value = trade.returnPercent { entry.returns.append(value) }
                securities[ticker] = entry
                if cost == nil { securityCostComplete[ticker] = false }
                if profit < 0 { lastLosingSale[key] = transaction.date }
            }
            if price > 0, let quote {
                var sale = AfterSale(ticker: ticker, saleDate: transaction.date, salePrice: price,
                                     currentPrice: quote.price, currency: currency)
                sale.quantity = quantity
                sale.usdRate = rate ?? 0
                // Every sale counts for the costliest, not only the last of each.
                if (result.costliestSale?.missedUSD ?? 0) < sale.missedUSD { result.costliestSale = sale }
                lastSaleByTicker[ticker] = sale
                timingByTicker[ticker, default: TradeTiming(ticker: ticker)].afterSales.append(sale.changePercent)
            }
        }

        let afterSales = Array(lastSaleByTicker.values)
        result.soldTooEarly = afterSales.filter { $0.changePercent >= 5 }
            .max { $0.changePercent < $1.changePercent }
        result.soldJustInTime = afterSales.filter { $0.changePercent <= -5 }
            .min { $0.changePercent < $1.changePercent }
        if (result.costliestSale?.missedUSD ?? 0) <= 0 { result.costliestSale = nil }

        var streak = (wins: 0, losses: 0)
        for trade in result.trades {
            guard let profit = trade.profitUSD, profit != 0 else { continue }
            if profit > 0 {
                streak.wins += 1
                streak.losses = 0
            } else {
                streak.losses += 1
                streak.wins = 0
            }
            result.longestWinStreak = max(result.longestWinStreak, streak.wins)
            result.longestLossStreak = max(result.longestLossStreak, streak.losses)
        }

        // A security with any sale of unknown cost has no total return.
        result.securityResults = securities.values.map { entry in
            var entry = entry
            if securityCostComplete[entry.ticker] == false { entry.costUSD = nil }
            return entry
        }.sorted { $0.ticker < $1.ticker }
        result.timing = timingByTicker.values.sorted { $0.ticker < $1.ticker }
        result.busiestDay = top(tradesByDay, minimum: 2)
        result.busiestMonth = top(tradesByMonth, minimum: 2)
        result.mostTraded = top(tradesByTicker, minimum: 2)
        result.mostDipBought = top(dipBuysByTicker, minimum: 1)
        result.revengeTicker = top(revengeByTicker, minimum: 1)?.key
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

    /// Where in its exchange's day a fill landed: the first and last half
    /// hour, midday (12:00–14:00), or the rest. Nil without a time, outside
    /// the session — a date-only import is stored at midnight — or for a
    /// currency whose exchange is not known here.
    static func sessionPart(executedAt: String?, currency: String) -> SessionPart? {
        guard let executedAt else { return nil }
        let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        guard let instant = (try? fractional.parse(executedAt)) ?? (try? Date.ISO8601FormatStyle().parse(executedAt))
        else { return nil }
        let session: (zone: String, open: Int, close: Int)
        switch currency.uppercased() {
        case "USD": session = ("America/New_York", 570, 960)
        case "GBP", "GBX": session = ("Europe/London", 480, 990)
        case "EUR": session = ("Europe/Berlin", 540, 1050)
        default: return nil
        }
        guard let zone = TimeZone(identifier: session.zone) else { return nil }
        var local = Calendar(identifier: .gregorian)
        local.timeZone = zone
        let parts = local.dateComponents([.hour, .minute], from: instant)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        guard minute >= session.open, minute < session.close else { return nil }
        if minute < session.open + 30 { return .open }
        if minute >= session.close - 30 { return .close }
        if (720..<840).contains(minute) { return .midday }
        return .other
    }
}
