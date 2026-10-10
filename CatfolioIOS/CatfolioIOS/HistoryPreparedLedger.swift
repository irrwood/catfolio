import SwiftUI
import Charts
import UniformTypeIdentifiers

struct ActivityDateGroup: Identifiable {
    let id: String
    let title: String
    let activities: [PortfolioActivity]
}

struct HistoryHeaderPosition: Equatable {
    let pullDown: CGFloat
    let materialOpacity: Double

    private init(pullDown: CGFloat, materialOpacity: Double) {
        self.pullDown = pullDown
        self.materialOpacity = materialOpacity
    }

    static func interpolated(from: Self, to: Self, fraction: CGFloat) -> Self {
        let t = min(1, max(0, fraction))
        return Self(pullDown: from.pullDown + (to.pullDown - from.pullDown) * t,
                    materialOpacity: from.materialOpacity + (to.materialOpacity - from.materialOpacity) * Double(t))
    }

    init(scrollOffset: CGFloat) {
        pullDown = max(0, -scrollOffset)
        let progress = min(1, max(0, scrollOffset / 16))
        materialOpacity = Double(progress * progress * (3 - 2 * progress))
    }
}

struct HistoryPreparationKey: Hashable {
    let revision: Int
    let accountIDs: Set<String>
    let locale: String
}

struct HistoryActivityPage {
    var activities: [PortfolioActivity] = []
    var groups: [ActivityDateGroup] = []
    var totalUSD: Double = 0
    var dividendBreakdown = HistoryDividendBreakdown()
    var ordersBreakdown = HistoryOrdersBreakdown()
}

/// Uses the same account/year scope and USD conversion as the ledger total.
/// Built with the page indexes, never while scrolling or swiping categories.
struct HistoryDividendBreakdown {
    struct Row: Identifiable {
        let ticker: String
        let name: String
        let amountUSD: Double?
        var id: String { ticker }
    }

    var rows: [Row] = []
    var positiveTotalUSD: Double = 0
    var isComplete = true
    var hasNegativeTotals: Bool { rows.contains { ($0.amountUSD ?? 0) < 0 } }

    func share(for row: Row) -> Double? {
        guard isComplete, positiveTotalUSD.isFinite, positiveTotalUSD > 0,
              let amount = row.amountUSD, amount >= 0 else { return nil }
        return min(1, max(0, amount / positiveTotalUSD))
    }

    static func build(_ activities: [PortfolioActivity]) -> Self {
        let grouped = Dictionary(grouping: activities.filter { $0.kind == .dividend }) {
            let ticker = $0.transaction.ticker.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            return ticker.isEmpty ? "CASH" : ticker
        }
        let rows = grouped.map { ticker, entries in
            let amounts = entries.map(\.amountUSD)
            let sum = amounts.reduce(0, +)
            let amount = amounts.allSatisfy(\.isFinite) && sum.isFinite ? sum : nil
            let name = ticker == "CASH" ? L10n.text("未识别标的") : (entries.first?.displayTitle ?? ticker)
            return Row(ticker: ticker, name: name, amountUSD: amount)
        }.sorted {
            if $0.amountUSD != $1.amountUSD {
                return ($0.amountUSD ?? -.infinity) > ($1.amountUSD ?? -.infinity)
            }
            return $0.ticker < $1.ticker
        }
        let total = rows.reduce(0) { $0 + max(0, $1.amountUSD ?? 0) }
        return Self(rows: rows, positiveTotalUSD: total,
                    isComplete: rows.allSatisfy { $0.amountUSD != nil } && total.isFinite)
    }
}

/// Immutable UI indexes, rebuilt off the main actor only when the ledger or
/// account scope changes. A category tap or a scroll never runs FIFO, parses
/// the catalogues, sorts transactions, or regroups a whole history.
/// Prepared once alongside the ledger, rather than formatting on row reuse.
struct HistoryRowPresentation {
    let title: String
    let amount: String
    let quantity: String

    init(_ activity: PortfolioActivity) {
        let isOrder = activity.kind == .buy || activity.kind == .sell
        title = activity.displayTitle
        amount = DisplayFormat.money(isOrder ? abs(activity.nativeAmount) : activity.nativeAmount,
                                     currency: activity.transaction.currency, signed: !isOrder)
        quantity = isOrder ? L10n.text("\(DisplayFormat.shares(activity.transaction.quantity)) shares") : ""
    }
}

/// What an order has made or lost, ready to print under its amount.
struct HistoryRowGain: Equatable, Sendable {
    let text: String
    /// Only the sign is read: it picks the colour.
    let value: Double

    init(text: String, value: Double) {
        self.text = text
        self.value = value
    }

    /// The broker's own figure stays in its own currency.
    init?(_ outcome: RealisedSale.Outcome) {
        switch outcome {
        case let .broker(value, currency, _):
            let amount = NSDecimalNumber(decimal: value).doubleValue
            self.init(text: DisplayFormat.money(amount, currency: currency, signed: true, fractionDigits: 2), value: amount)
        case let .estimated(usd):
            guard usd.isFinite else { return nil }
            self.init(text: DisplayFormat.money(usd, signed: true, fractionDigits: 2), value: usd)
        case .unavailable:
            return nil
        }
    }

    /// Each purchase at today's quote, on today's share basis, in USD.
    /// Skipped when the security is no longer held or either side lacks a rate.
    static func purchaseGains(_ activities: [PortfolioActivity], holdings: [Holding]) -> [String: Double] {
        let quotes = Dictionary(holdings.map { ($0.ticker.uppercased(), $0) }, uniquingKeysWith: { first, _ in first })
        let splits = try? StockSplitCatalog.bundled.get()
        var gains: [String: Double] = [:]
        for activity in activities where activity.kind == .buy {
            let transaction = activity.transaction
            guard let holding = quotes[transaction.ticker.uppercased()], holding.quotePrice > 0,
                  let quoteRate = LocalPortfolioEngine.usdRate(for: holding.quoteCurrency ?? transaction.currency),
                  let costRate = LocalPortfolioEngine.usdRate(for: transaction.currency) else { continue }
            let split = splits?.adjustment(ticker: transaction.ticker, from: transaction.date) ?? 1
            guard split > 0 else { continue }
            let quantity = abs(transaction.quantity) * split
            let cost = transaction.price / split
            let gain = (holding.quotePrice * quoteRate - cost * costRate) * quantity
            if gain.isFinite { gains[activity.id] = gain }
        }
        return gains
    }
}

struct HistoryPageContentID: Hashable {
    let ledger: UUID
    let basis: String
    let year: String?
    let forecast: Double?
    let gains: Int
    let dividendsByStock: Bool
    var ordersByStock = false
}

struct HistoryPreparedLedger {
    let contentID = UUID()
    private struct Period: Hashable {
        var basis: TaxYearBasis = .calendar
        var year: String?
    }

    private var pages: [Period: [HistoryCategory: HistoryActivityPage]] = [:]
    var realisedTotal = RealisedProfitSummary()
    var realisedByTaxYear: [TaxYearBasis: [(label: String, summary: RealisedProfitSummary)]] = [:]
    var matchedDisposals: [String: UKShareMatching.Disposal] = [:]
    var rowPresentations: [String: HistoryRowPresentation] = [:]
    var saleGains: [String: HistoryRowGain] = [:]
    var yearLabels: [TaxYearBasis: [String]] = [:]

    func page(category: HistoryCategory, basis: TaxYearBasis, year: String?) -> HistoryActivityPage {
        let period = year.map { Period(basis: basis, year: $0) } ?? Period()
        return pages[period]?[category] ?? HistoryActivityPage()
    }

    static func build(
        ledger: PortfolioActivityLedger, accountIDs: Set<String>, locale: Locale, ticker: String? = nil
    ) throws -> Self {
        try Task.checkCancellation()
        let symbol = ticker?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let activities = ledger.transactions.compactMap { transaction -> PortfolioActivity? in
            guard accountIDs.contains(transaction.accountKey),
                  symbol == nil || transaction.ticker.uppercased() == symbol else { return nil }
            let activity = PortfolioActivity(
                transaction: transaction,
                securityName: ledger.securityNames[transaction.ticker.uppercased()] ?? transaction.ticker
            )
            return activity.kind.isCashTransfer ? nil : activity
        }
        // Keep the calculator's existing whole-history inputs and algorithms.
        // The year filters apply to its results, never to acquisition lots.
        let transactions = activities.map(\.transaction)
        var result = Self()
        for activity in activities {
            try Task.checkCancellation()
            result.rowPresentations[activity.id] = HistoryRowPresentation(activity)
        }
        let sales = RealisedProfitCalculator.sales(transactions: transactions)
        let salesByID = sales.reduce(into: [String: RealisedSale]()) { result, sale in
            if let id = sale.transactionID { result[id] = sale }
        }
        result.realisedTotal = RealisedProfitCalculator.summarize(sales: sales)
        for sale in sales {
            guard let id = sale.transactionID, let gain = HistoryRowGain(sale.outcome) else { continue }
            result.saleGains[id] = gain
        }
        for basis in TaxYearBasis.allCases {
            try Task.checkCancellation()
            result.yearLabels[basis] = Array(Set(activities.compactMap { basis.label(for: $0.transaction.date) })).sorted(by: >)
            result.realisedByTaxYear[basis] = RealisedProfitCalculator
                .summarize(transactions: transactions, basis: basis)
                .filter { $0.summary.saleCount > 0 }
        }
        let splits = try? StockSplitCatalog.bundled.get()
        let tickers = Set(transactions.filter { $0.action.uppercased() == "SELL" }.map { $0.ticker.uppercased() })
        for ticker in tickers {
            try Task.checkCancellation()
            for disposal in UKShareMatching.disposals(ticker: ticker, transactions: transactions, splits: splits)
            where !disposal.isFullyFromPool {
                result.matchedDisposals[disposal.sourceID] = disposal
            }
        }

        let titles = Dictionary(uniqueKeysWithValues: Set(activities.map { $0.transaction.date }).map {
            ($0, dateGroupTitle($0, locale: locale))
        })
        result.pages[Period()] = makePages(activities, titles: titles, sales: salesByID)
        for basis in TaxYearBasis.allCases {
            let groups = Dictionary(grouping: activities) { basis.label(for: $0.transaction.date) }
            for (year, entries) in groups {
                try Task.checkCancellation()
                guard let year else { continue }
                result.pages[Period(basis: basis, year: year)] = makePages(entries, titles: titles, sales: salesByID)
            }
        }
        return result
    }

    private static func makePages(
        _ activities: [PortfolioActivity], titles: [String: String], sales: [String: RealisedSale]
    ) -> [HistoryCategory: HistoryActivityPage] {
        let sorted = activities.sorted {
            if $0.transaction.date == $1.transaction.date { return $0.id > $1.id }
            return $0.transaction.date > $1.transaction.date
        }
        return Dictionary(uniqueKeysWithValues: HistoryCategory.allCases.map { category in
            let filtered = sorted.filter { category.includes($0.kind) }
            let grouped = Dictionary(grouping: filtered) { $0.transaction.date }
            let groups = grouped.keys.sorted(by: >).map {
                ActivityDateGroup(id: $0, title: titles[$0] ?? $0, activities: grouped[$0] ?? [])
            }
            return (category, HistoryActivityPage(
                activities: filtered, groups: groups,
                // Sum in the original ledger order, as the previous display did.
                totalUSD: activities.filter { category.includes($0.kind) }.reduce(0) { $0 + $1.amountUSD },
                dividendBreakdown: category == .dividends ? HistoryDividendBreakdown.build(filtered) : .init(),
                ordersBreakdown: category == .orders
                    ? HistoryOrdersBreakdown.build(filtered, sales: sales, dateTitles: titles) : .init()
            ))
        })
    }

    static func dateGroupTitle(_ text: String, locale: Locale) -> String {
        let values = text.split(separator: "-").compactMap { Int($0) }
        guard values.count == 3,
              let date = Calendar.current.date(from: DateComponents(year: values[0], month: values[1], day: values[2]))
        else { return text }
        if Calendar.current.isDateInToday(date) { return L10n.text("Today") }
        if Calendar.current.isDateInYesterday(date) { return L10n.text("Yesterday") }
        return date.formatted(.dateTime.month(.wide).day().year().locale(locale))
    }
}

struct HistoryFeeCharge {
    let holding: Holding
    let rate: Double
    let annual: Double
    let isVerified: Bool

    static func build(holdings: [Holding]) -> [Self] {
        guard let catalog = try? FundFeeCatalog.bundled.get() else { return [] }
        return holdings.compactMap { holding in
            guard let fee = catalog.fee(brokerSymbol: holding.ticker) else { return nil }
            return Self(holding: holding, rate: fee.rate,
                        annual: holding.marketValue * fee.rate, isVerified: fee.isVerified)
        }.sorted { $0.annual > $1.annual }
    }
}
