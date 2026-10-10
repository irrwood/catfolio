import Foundation
import CryptoKit

struct ObservedMarketQuote: Sendable {
    let price: Double
    let observedAt: Date
}

struct LocalPositionRecord: Codable, Equatable {
    var publicDisclosure: PublicAccountDisclosure? = nil
    var quoteObservedAt: Date? = nil
    var ticker: String
    let name: String
    let shares: Double
    let averageCost: Double
    let currency: String
    let quotePrice: Double
    let quoteCurrency: String
    let source: String
    let openedDate: String?
    let accountID: String?
    let accountName: String?
    let accountCurrency: String?
    let brokerPnl: Double?
    let brokerPnlCurrency: String?
    let brokerFxPnl: Double?
    let brokerFxPnlCurrency: String?
    let fxPnl: Double?
    let fxPnlCurrency: String?
    let fxPnlStatus: String?
    let fxPnlSource: String?

    init(
        ticker: String,
        name: String,
        shares: Double,
        averageCost: Double,
        currency: String,
        quotePrice: Double,
        quoteCurrency: String,
        source: String,
        openedDate: String?,
        accountID: String? = nil,
        accountName: String? = nil,
        accountCurrency: String? = nil,
        brokerPnl: Double? = nil,
        brokerPnlCurrency: String? = nil,
        brokerFxPnl: Double? = nil,
        brokerFxPnlCurrency: String? = nil,
        fxPnl: Double? = nil,
        fxPnlCurrency: String? = nil,
        fxPnlStatus: String? = nil,
        fxPnlSource: String? = nil,
        quoteObservedAt: Date? = nil
    ) {
        self.ticker = ticker
        self.name = name
        self.shares = shares
        self.averageCost = averageCost
        self.currency = currency
        self.quotePrice = quotePrice
        self.quoteCurrency = quoteCurrency
        self.source = source
        self.openedDate = openedDate
        self.accountID = accountID
        self.accountName = accountName
        self.accountCurrency = accountCurrency
        self.brokerPnl = brokerPnl
        self.brokerPnlCurrency = brokerPnlCurrency
        self.brokerFxPnl = brokerFxPnl
        self.brokerFxPnlCurrency = brokerFxPnlCurrency
        self.fxPnl = fxPnl
        self.fxPnlCurrency = fxPnlCurrency
        self.fxPnlStatus = fxPnlStatus
        self.fxPnlSource = fxPnlSource
        self.quoteObservedAt = quoteObservedAt
    }

    var accountKey: String {
        let identifier = accountID.flatMap { $0.isEmpty ? nil : $0 } ?? "default"
        return "\(source)|\(identifier)"
    }

    var resolvedAccountName: String {
        if let accountName, !accountName.isEmpty { return accountName }
        return source
    }

    func renamedAccount(to name: String) -> LocalPositionRecord {
        LocalPositionRecord(
            ticker: ticker,
            name: self.name,
            shares: shares,
            averageCost: averageCost,
            currency: currency,
            quotePrice: quotePrice,
            quoteCurrency: quoteCurrency,
            source: source,
            openedDate: openedDate,
            accountID: accountID,
            accountName: name,
            accountCurrency: accountCurrency,
            brokerPnl: brokerPnl,
            brokerPnlCurrency: brokerPnlCurrency,
            brokerFxPnl: brokerFxPnl,
            brokerFxPnlCurrency: brokerFxPnlCurrency,
            fxPnl: fxPnl,
            fxPnlCurrency: fxPnlCurrency,
            fxPnlStatus: fxPnlStatus,
            fxPnlSource: fxPnlSource,
            quoteObservedAt: quoteObservedAt
        )
    }

    func withQuotePrice(_ price: Double, observedAt: Date? = nil) -> LocalPositionRecord {
        LocalPositionRecord(
            ticker: ticker,
            name: name,
            shares: shares,
            averageCost: averageCost,
            currency: currency,
            quotePrice: price,
            quoteCurrency: quoteCurrency,
            source: source,
            openedDate: openedDate,
            accountID: accountID,
            accountName: accountName,
            accountCurrency: accountCurrency,
            brokerPnl: brokerPnl,
            brokerPnlCurrency: brokerPnlCurrency,
            brokerFxPnl: brokerFxPnl,
            brokerFxPnlCurrency: brokerFxPnlCurrency,
            fxPnl: fxPnl,
            fxPnlCurrency: fxPnlCurrency,
            fxPnlStatus: fxPnlStatus,
            fxPnlSource: fxPnlSource,
            quoteObservedAt: observedAt ?? quoteObservedAt
        )
    }

    func assignedAccount(id: String?, name: String, source: String? = nil) -> LocalPositionRecord {
        LocalPositionRecord(
            ticker: ticker,
            name: self.name,
            shares: shares,
            averageCost: averageCost,
            currency: currency,
            quotePrice: quotePrice,
            quoteCurrency: quoteCurrency,
            source: source ?? self.source,
            openedDate: openedDate,
            accountID: id,
            accountName: name,
            accountCurrency: accountCurrency,
            brokerPnl: brokerPnl,
            brokerPnlCurrency: brokerPnlCurrency,
            brokerFxPnl: brokerFxPnl,
            brokerFxPnlCurrency: brokerFxPnlCurrency,
            fxPnl: fxPnl,
            fxPnlCurrency: fxPnlCurrency,
            fxPnlStatus: fxPnlStatus,
            fxPnlSource: fxPnlSource,
            quoteObservedAt: quoteObservedAt
        )
    }

    func withFXResult(
        value: Double?,
        currency: String?,
        status: String?,
        source: String?
    ) -> LocalPositionRecord {
        LocalPositionRecord(
            ticker: ticker,
            name: name,
            shares: shares,
            averageCost: averageCost,
            currency: self.currency,
            quotePrice: quotePrice,
            quoteCurrency: quoteCurrency,
            source: self.source,
            openedDate: openedDate,
            accountID: accountID,
            accountName: accountName,
            accountCurrency: accountCurrency,
            brokerPnl: brokerPnl,
            brokerPnlCurrency: brokerPnlCurrency,
            brokerFxPnl: brokerFxPnl,
            brokerFxPnlCurrency: brokerFxPnlCurrency,
            fxPnl: value,
            fxPnlCurrency: currency,
            fxPnlStatus: status,
            fxPnlSource: source,
            quoteObservedAt: quoteObservedAt
        )
    }
}

struct LocalAccountSnapshotTotals: Codable, Equatable {
    let marketValueUSD: Double
    let costUSD: Double
}

struct LocalPortfolioSnapshotRecord: Codable, Equatable {
    let date: String
    let marketValueUSD: Double
    let costUSD: Double
    let accountTotals: [String: LocalAccountSnapshotTotals]?

    init(
        date: String,
        marketValueUSD: Double,
        costUSD: Double,
        accountTotals: [String: LocalAccountSnapshotTotals]? = nil
    ) {
        self.date = date
        self.marketValueUSD = marketValueUSD
        self.costUSD = costUSD
        self.accountTotals = accountTotals
    }
}

extension LocalTransactionRecord {
    var legacyTrading212ID: String? {
        guard source == "Trading 212", tradeID?.isEmpty == false else { return nil }
        return "\(accountKey)|" + [date, action.uppercased(), ticker.uppercased(), String(quantity), String(price)].joined(separator: "|")
    }
    /// Keep the broker's amount/currency pair through lightweight refreshes.
    func preservingBrokerResult(from previous: LocalTransactionRecord?) -> LocalTransactionRecord {
        var retained = self
        if entryMethod != "csv", let previous, previous.id == id, retained.cashPostings == nil {
            retained.cashPostings = previous.cashPostings
        }
        guard (realisedProfitLoss == nil || realisedProfitLossCurrency?.isEmpty != false),
              let previous, previous.id == id,
              let result = previous.realisedProfitLoss, result.isFinite,
              let resultCurrency = previous.realisedProfitLossCurrency, !resultCurrency.isEmpty else { return retained }
        return LocalTransactionRecord(date: date, action: action, ticker: ticker,
            quantity: quantity, price: price, currency: currency, source: source,
            accountID: accountID, accountName: accountName, tradeID: tradeID,
            brokerFXRate: brokerFXRate, entryMethod: entryMethod,
            realisedProfitLoss: result, realisedProfitLossCurrency: resultCurrency, executedAt: executedAt, cashPostings: retained.cashPostings)
    }
}

struct LocalTransactionRecord: Codable, Equatable, Identifiable {
    /// Signed account cash postings, net of charges. Nil means legacy or
    /// unverified settlement data and cannot fund an account-return ledger.
    var cashPostings: [DailyTimeWeightedReturn.Cash]? = nil
    let date: String
    var executedAt: String? = nil
    let action: String
    var ticker: String
    let quantity: Double
    let price: Double
    let currency: String
    let source: String
    let accountID: String?
    let accountName: String?
    let tradeID: String?
    let brokerFXRate: Double?
    let entryMethod: String?
    /// Broker-reported profit/loss for this closing transaction. This is kept
    /// separate from `quantity * price`, which is the gross sale proceeds.
    let realisedProfitLoss: Double?
    let realisedProfitLossCurrency: String?

    init(
        date: String,
        action: String,
        ticker: String,
        quantity: Double,
        price: Double,
        currency: String,
        source: String,
        accountID: String?,
        accountName: String?,
        tradeID: String? = nil,
        brokerFXRate: Double? = nil,
        entryMethod: String? = nil,
        realisedProfitLoss: Double? = nil,
        realisedProfitLossCurrency: String? = nil,
        executedAt: String? = nil,
        cashPostings: [DailyTimeWeightedReturn.Cash]? = nil
    ) {
        self.date = date
        self.executedAt = executedAt
        self.cashPostings = cashPostings
        self.action = action
        self.ticker = ticker
        self.quantity = quantity
        self.price = price
        self.currency = currency
        self.source = source
        self.accountID = accountID
        self.accountName = accountName
        self.tradeID = tradeID
        self.brokerFXRate = brokerFXRate
        self.entryMethod = entryMethod
        self.realisedProfitLoss = realisedProfitLoss
        self.realisedProfitLossCurrency = realisedProfitLossCurrency
    }

    var accountKey: String {
        let identifier = accountID.flatMap { $0.isEmpty ? nil : $0 } ?? "default"
        return "\(source)|\(identifier)"
    }

    /// Exact timestamps win over the date-only fallback. Untimed buys precede
    /// timed fills, untimed sells follow them. Equal times retain the legacy
    /// buy-first estimate: date-only CSVs were persisted at midnight too.
    static func orderedForLotMatching(_ rows: [Self]) -> [Self] {
        let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        let whole = Date.ISO8601FormatStyle()
        return rows.map { row -> (row: Self, time: TimeInterval, isBuy: Bool) in
            let isBuy = ["BUY", "BUY_BACK"].contains(row.action.trimmingCharacters(in: .whitespacesAndNewlines).uppercased())
            let time = row.executedAt.flatMap { text in
                (try? fractional.parse(text)) ?? (try? whole.parse(text))
            }?.timeIntervalSince1970
            return (row, time ?? (isBuy ? -.infinity : .infinity), isBuy)
        }.sorted {
            if $0.row.date != $1.row.date { return $0.row.date < $1.row.date }
            if $0.time != $1.time { return $0.time < $1.time }
            if $0.isBuy != $1.isBuy { return $0.isBuy }
            return $0.row.id < $1.row.id
        }.map(\.row)
    }

    /// Stable across decoding and broker refreshes, while matching the
    /// transaction merge/deduplication semantics used by the local store.
    var id: String {
        let fallbackParts = [
            executedAt ?? date,
            action.uppercased(),
            ticker.uppercased(),
            String(quantity),
            String(price),
        ] + (source == "Trading 212" ? [] : [currency.uppercased()])
        let recordID = tradeID.flatMap { $0.isEmpty ? nil : $0 }
            ?? fallbackParts.joined(separator: "|")
        return "\(accountKey)|\(recordID)"
    }

    func renamedAccount(to name: String) -> LocalTransactionRecord {
        LocalTransactionRecord(
            date: date,
            action: action,
            ticker: ticker,
            quantity: quantity,
            price: price,
            currency: currency,
            source: source,
            accountID: accountID,
            accountName: name,
            tradeID: tradeID,
            brokerFXRate: brokerFXRate,
            entryMethod: entryMethod,
            realisedProfitLoss: realisedProfitLoss,
            realisedProfitLossCurrency: realisedProfitLossCurrency,
            executedAt: executedAt,
            cashPostings: cashPostings
        )
    }

    func assignedAccount(id: String?, name: String, source: String? = nil) -> LocalTransactionRecord {
        LocalTransactionRecord(
            date: date,
            action: action,
            ticker: ticker,
            quantity: quantity,
            price: price,
            currency: currency,
            source: source ?? self.source,
            accountID: id,
            accountName: name,
            tradeID: tradeID,
            brokerFXRate: brokerFXRate,
            entryMethod: entryMethod,
            realisedProfitLoss: realisedProfitLoss,
            realisedProfitLossCurrency: realisedProfitLossCurrency,
            executedAt: executedAt,
            cashPostings: cashPostings
        )
    }
}
