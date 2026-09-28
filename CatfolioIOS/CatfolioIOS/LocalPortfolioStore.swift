import Foundation
import CryptoKit

enum LocalMarketQuoteKey {
    static func make(ticker: String, currency: String) -> String {
        "\(ticker.uppercased())|\(currency.uppercased())"
    }
}

/// Only reports imported broker Results. Completeness of the broker's entire
/// history cannot be inferred merely from having a Result for every local row.
struct LocalBrokerResultSummary {
    var totals: [String: Decimal] = [:]
    var saleCount = 0
    var missingCount = 0

    init(transactions: [LocalTransactionRecord]) {
        for transaction in transactions {
            let action = transaction.action.trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased().replacingOccurrences(of: "-", with: "_").replacingOccurrences(of: " ", with: "_")
            guard ["SELL", "SELL_SHORT"].contains(action) else { continue }
            saleCount += 1
            let currency = transaction.realisedProfitLossCurrency?
                .trimmingCharacters(in: .whitespacesAndNewlines).uppercased() ?? ""
            guard let value = transaction.realisedProfitLoss, value.isFinite,
                  currency.count == 3, currency.utf8.allSatisfy({ (65...90).contains($0) }),
                  let decimal = Decimal(string: String(value), locale: Locale(identifier: "en_US_POSIX")) else {
                missingCount += 1
                continue
            }
            totals[currency, default: 0] += decimal
        }
    }

    /// The results added up in USD, each converted from the currency the
    /// broker reported it in. Nil when there is nothing to add, or when a
    /// currency has no rate — an incomplete total would read as a small one.
    func usdTotal() -> Double? {
        guard !totals.isEmpty else { return nil }
        var total = 0.0
        for (currency, amount) in totals {
            guard let converted = try? LocalPortfolioEngine.usd(
                NSDecimalNumber(decimal: amount).doubleValue, currency: currency) else { return nil }
            total += converted
        }
        return total.isFinite ? total : nil
    }
}

#if DEBUG
enum FoundationRegressionChecks {
    static var emptyFixture: LocalPortfolioDocument {
        let transaction = LocalTransactionRecord(date: "2026-01-02", action: "SELL", ticker: "TEST", quantity: 1,
            price: 100, currency: "USD", source: "CSV", accountID: "closed", accountName: "已清仓测试账户",
            tradeID: "test-sale", realisedProfitLoss: 2.5, realisedProfitLossCurrency: "GBP")
        var transactions = [transaction]
        if LaunchArguments.contains("--verify-partial-results") {
            transactions.append(LocalTransactionRecord(date: "2026-01-02", action: "SELL", ticker: "MISSING",
                quantity: 1, price: 200, currency: "USD", source: "CSV", accountID: "closed",
                accountName: "已清仓测试账户", tradeID: "test-missing"))
        }
        return LocalPortfolioDocument(source: "CSV", updatedAt: Date(), positions: [], snapshots: [], transactions: transactions)
    }
    static func run() throws -> String {
        var passed: [String] = []
        func check(_ condition: Bool, _ name: String) throws {
            guard condition else { throw LocalPortfolioError.invalidCSV("REGRESSION FAILED: \(name)") }
            passed.append("PASS: \(name)")
        }
        let doc = emptyFixture
        try check(doc.accounts.count == 1 && doc.accounts[0].positionCount == 0, "closed account remains visible")
        try check(doc.scoped(to: [doc.accounts[0].id]).transactions?.count == 1, "closed account history scope")
        let presentation = try LocalPortfolioEngine.presentation(for: doc)
        try check(presentation.2.isEmpty, "zero positions presentation succeeds")
        let csv = """
        Action,Time,Ticker,No. of shares,Price / share,Currency (Price / share),Result,Currency (Result)
        Market buy,2026-01-01 10:00:00,TEST,1,100,USD,,
        Market buy,2026-01-01 10:00:00,TEST,1,100,USD,,
        Market sell,2026-01-02 10:00:00,TEST,2,110,USD,12.34,GBP
        """
        let parsed = try LocalCSVImporter.parse(Data(csv.utf8))
        let repeated = try LocalCSVImporter.parse(Data(csv.utf8))
        try check(parsed.0.isEmpty && parsed.1.count == 3, "fully closed CSV accepted")
        try check(Set(parsed.1.map(\.id)).count == 3, "identical fills remain separate")
        try check(parsed.1.map(\.id) == repeated.1.map(\.id), "reimport IDs are stable")
        try check(parsed.1.last?.realisedProfitLoss == 12.34 && parsed.1.last?.realisedProfitLossCurrency == "GBP", "CSV Result and currency retained")
        try check(parsed.1.allSatisfy { $0.executedAt != nil }, "execution times retained")
        try check(LocalPortfolioEngine.usdRate(for: "UNKNOWN") == nil, "unknown currency never assumes parity")
        let pound = try LocalPortfolioEngine.usd(1, currency: "GBP")
        let pence = try LocalPortfolioEngine.usd(100, currency: "GBX")
        try check(abs(pound - pence) < 1e-9, "GBP and GBX use one FX source")
        try check(DisplayFormat.money(.nan) == "—", "unavailable money does not display zero")
        func sale(_ result: Double?, _ currency: String?) -> LocalTransactionRecord {
            LocalTransactionRecord(date: "2026-01-02", action: "SELL", ticker: "TEST", quantity: 1,
                price: 100, currency: "USD", source: "CSV", accountID: nil, accountName: nil, realisedProfitLoss: result,
                realisedProfitLossCurrency: currency)
        }
        let partial = LocalBrokerResultSummary(transactions: [sale(2.5, "GBP"), sale(nil, nil)])
        try check(partial.missingCount == 1 && partial.saleCount == 2 && partial.totals["GBP"] == Decimal(string: "2.5"), "partial Results never include proceeds or estimates")
        let multiple = LocalBrokerResultSummary(transactions: [sale(0, "GBP"), sale(-1.25, " gbp "), sale(3, "USD")])
        try check(multiple.missingCount == 0 && multiple.totals["GBP"] == Decimal(string: "-1.25") && multiple.totals["USD"] == 3, "zero negative and mixed currency Results stay in native currency")
        let missing = LocalBrokerResultSummary(transactions: [sale(2.5, nil), sale(.nan, "GBP")])
        try check(missing.missingCount == 2 && missing.totals.isEmpty, "missing currency and invalid Results remain unavailable")
        try check(LocalBrokerResultSummary(transactions: []).saleCount == 0, "no sales is distinct from zero profit")
        return passed.joined(separator: "\n")
    }
}
#endif

/// Trading 212's London suffix identifies the exchange, not whether a price is
/// expressed in pounds or pence. Keep this aligned with the desktop importer,
/// which has verified these instruments against the broker's position values.
enum InstrumentCurrencyRules {
    /// Listing currency, not fund base currency. London uses distinct tickers
    /// for GBP/GBX and USD order books, so the `.L` suffix alone is ambiguous.
    private static let londonPriceCurrencies: [String: String] = [
        "VUAG": "GBP", "VUSA": "GBP", "VHVG": "GBP", "VEUA": "GBP", "XUSE": "GBP",
        "XS2D": "USD", "XT2D": "USD", "XSPD": "USD",
        "EQQU": "USD", "VUAA": "USD", "VUSD": "USD", "VHVE": "USD", "VWCG": "USD",
        "XSPS": "GBX", "EQQQ": "GBX",
    ]

    static func knownPriceCurrency(for ticker: String) -> String? {
        var normalized = ticker.uppercased()
        if normalized.hasSuffix(".L") { normalized.removeLast(2) }
        return londonPriceCurrencies[normalized]
    }

    /// Best-effort quote currency for persisted broker fills created before
    /// Catfolio separated account currency from instrument price currency.
    /// The broker activity report replaces this inference with its exact
    /// `Currency (Price / share)` as soon as that report is available.
    static func inferredPriceCurrency(for ticker: String) -> String? {
        let normalized = ticker.uppercased()
        if let known = knownPriceCurrency(for: normalized) { return known }
        if normalized.hasSuffix(".L") { return "GBX" }
        if normalized.hasSuffix(".DE") || normalized.hasSuffix(".AS")
            || normalized.hasSuffix(".PA") || normalized.hasSuffix(".MI") {
            return "EUR"
        }
        if normalized.hasSuffix(".HK") { return "HKD" }
        if normalized.hasSuffix(".TO") { return "CAD" }
        if !normalized.contains(".") { return "USD" }
        return nil
    }

    static func marketDataSymbol(for ticker: String) -> String? {
        let normalized = ticker.uppercased()
        guard !normalized.contains("."), londonPriceCurrencies[normalized] != nil else { return nil }
        return "\(normalized).L"
    }

    static func marketPriceScale(symbol: String, targetCurrency: String) -> Double {
        guard symbol.uppercased().hasSuffix(".L"),
              let listingCurrency = knownPriceCurrency(for: symbol) else { return 1 }
        switch (listingCurrency, targetCurrency.uppercased()) {
        case ("GBX", "GBP"): return 0.01
        case ("GBP", "GBX"): return 100
        default: return 1
        }
    }

    /// Normalize explicit provider units before bars enter the shared caches.
    /// Yahoo's case-sensitive `GBp` means pence, whereas `GBP` means pounds.
    static func providerPriceScale(symbol: String, sourceCurrency: String?) -> Double? {
        guard symbol.uppercased().hasSuffix(".L"),
              let target = knownPriceCurrency(for: symbol) else { return 1 }
        guard let sourceCurrency else { return nil }
        let source = sourceCurrency == "GBp" ? "GBX" : sourceCurrency.uppercased()
        if source == target { return 1 }
        switch (source, target) {
        case ("GBX", "GBP"): return 0.01
        case ("GBP", "GBX"): return 100
        default: return nil
        }
    }
}

struct ObservedMarketQuote: Sendable {
    let price: Double
    let observedAt: Date
}

struct LocalPositionRecord: Codable, Equatable {
    var publicDisclosure: PublicAccountDisclosure? = nil
    var quoteObservedAt: Date? = nil
    let ticker: String
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
    let ticker: String
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

enum AccountConnectorContext {
    case create
    case manage(PortfolioAccount)

    var isCreating: Bool {
        if case .create = self { return true }
        return false
    }

    var account: PortfolioAccount? {
        if case let .manage(account) = self { return account }
        return nil
    }
}

enum AccountNaming {
    static let generatedNicknames = [
        "橘子", "蓝莓", "水獭", "熊猫", "柚子", "樱桃", "松鼠", "海豚",
    ]

    static func providerName(for source: String) -> String {
        switch source {
        case "IBKR Flex": "IBKR"
        default: source
        }
    }

    static func displayName(provider: String, nickname rawNickname: String) -> String {
        let nickname = rawNickname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !nickname.isEmpty else { return provider }
        let prefix = "\(provider) · "
        return nickname.hasPrefix(prefix) ? nickname : prefix + nickname
    }

    static func nickname(from displayName: String, provider: String) -> String {
        let prefix = "\(provider) · "
        return displayName.hasPrefix(prefix) ? String(displayName.dropFirst(prefix.count)) : displayName
    }
}

struct PortfolioAccount: Identifiable, Equatable, Codable {
    let id: String
    let accountID: String?
    let source: String
    let name: String
    let baseCurrency: String
    let positionCount: Int
    let transactionCount: Int
    let manualTransactionCount: Int
    let hasCSVImport: Bool
    let marketValueUSD: Double
    /// The broker product the person chose when connecting this account,
    /// stored as a `Trading212AccountType` raw value.
    ///
    /// Trading 212 reports an account number and a currency, never whether the
    /// account is an ISA, so the choice cannot be derived and has to survive
    /// every sync, merge and reset of the positions around it.
    var accountTypeOverride: String? = nil

    /// Registered but never synced.
    ///
    /// Derived rather than stored: an account only reaches `knownAccounts`
    /// with no positions and no transactions when it was created ahead of its
    /// first sync, and the flag clears itself the moment anything lands.
    /// SnapTrade accounts are created only after a confirmed complete preview,
    /// so an empty SnapTrade account has already synced successfully.
    var awaitsFirstSync: Bool {
        !["SnapTrade", "Robinhood"].contains(source) && positionCount == 0 && transactionCount == 0
    }

    var brokerName: String {
        switch source {
        case "IBKR Flex": "IBKR"
        case "CSV": "CSV"
        case "公开披露": name
        default: source
        }
    }

    var accountType: String {
        if let chosen = chosenAccountType { return chosen.displayName }
        return switch source {
        case "Trading 212":
            // The credential slot an account was added under used to decide
            // this, which labelled a second Invest account as an ISA. The slot
            // is a local key index, so an account with no chosen type says so
            // rather than guessing.
            "未设置"
        case "IBKR Flex": "Individual"
        case "Moomoo": "Individual"
        case "CSV": "手动账户"
        case "假数据": "演示账户"
        case "公开披露": "投资账户"
        default: "投资账户"
        }
    }

    var chosenAccountType: Trading212AccountType? {
        accountTypeOverride.flatMap(Trading212AccountType.init(rawValue:))
    }

    var displayName: String {
        if source == "IBKR Flex", name.hasPrefix("IBKR · ••••") {
            return "IBKR · Individual"
        }
        return name
    }

    var localizedDisplayName: String { L10n.accountName(displayName) }

    var syncedSourceTitle: String {
        switch source {
        case "Trading 212": "Trading 212 API / 同步数据"
        case "IBKR Flex": "IBKR Flex / 同步数据"
        case "Moomoo": "Moomoo API / 同步数据"
        case "CSV": "CSV 导入"
        case "假数据": "本机演示数据"
        default: "本机数据"
        }
    }
}

struct HoldingDetailAccountOption: Identifiable, Equatable {
    let id: String
    let displayName: String
    let marketValue: Double
    let currency: String
    let marketValueUSD: Double
    /// Existing engine P&L converted to the card's quote currency. Public
    /// disclosures without a cost basis leave this unknown, never zero.
    var unrealized: Double? = nil

    static func unrealizedPercent(marketValue: Double, unrealized: Double?) -> Double? {
        guard marketValue.isFinite, let unrealized, unrealized.isFinite else { return nil }
        let cost = marketValue - unrealized
        guard cost > 0 else { return nil }
        let percent = unrealized / cost * 100
        return percent.isFinite ? percent : nil
    }
}

struct HoldingDetailAccountContext: Equatable {
    let ticker: String
    let document: LocalPortfolioDocument
    let options: [HoldingDetailAccountOption]

    var allAccountKeys: Set<String> {
        Set(options.map(\.id))
    }

    func holding(for accountKeys: Set<String>) -> Holding? {
        let effectiveKeys = accountKeys.intersection(allAccountKeys)
        guard !effectiveKeys.isEmpty,
              let presentation = try? LocalPortfolioEngine.presentation(
                for: document.scoped(to: effectiveKeys)
              ) else { return nil }
        return presentation.2.first {
            $0.ticker.caseInsensitiveCompare(ticker) == .orderedSame
        }
    }

    func document(for accountKeys: Set<String>) -> LocalPortfolioDocument {
        document.scoped(to: accountKeys.intersection(allAccountKeys))
    }
}

struct LocalPortfolioDocument: Codable, Equatable {
    var schemaVersion = 1
    var source: String
    var updatedAt: Date
    var marketDataUpdatedAt: Date? = nil
    var positions: [LocalPositionRecord]
    var snapshots: [LocalPortfolioSnapshotRecord]
    var transactions: [LocalTransactionRecord]? = nil
    var knownAccounts: [PortfolioAccount]? = nil
    /// Set by the generators that invent a portfolio — demo mode, the
    /// public-investor simulation. Nothing marked this way may leave the
    /// device.
    ///
    /// A flag rather than an inspection of `source`: the demo document calls
    /// itself "假数据（Trading 212 + Moomoo + IBKR）", which a check for
    /// "demo" or "fake" sails straight past. Provenance is something a
    /// producer states, not something a reader guesses.
    var isSynthetic: Bool? = nil

    static let empty = LocalPortfolioDocument(
        source: "local",
        updatedAt: .distantPast,
        positions: [],
        snapshots: []
    )
}

extension LocalPortfolioDocument {
    var isPublicDisclosure: Bool { source == PublicInvestorAccountAdapter.source || positions.contains { $0.publicDisclosure != nil } }

    var accounts: [PortfolioAccount] {
        let grouped = Dictionary(grouping: positions, by: \.accountKey)
        let history = Dictionary(grouping: transactions ?? [], by: \.accountKey)
        let saved = Dictionary((knownAccounts ?? []).map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        return Set(grouped.keys).union(history.keys).union(saved.keys)
            .map { key in
                let accountPositions = grouped[key] ?? []
                let firstPosition = accountPositions.first
                // `history` already groups every transaction by account. Re-scanning
                // the whole ledger for each account made this O(accounts x ledger).
                let accountTransactions = history[key] ?? []
                let transaction = accountTransactions.first
                let fallbackCurrency = firstPosition?.source == "Trading 212" ? "GBP" : (firstPosition?.currency ?? "USD")
                return PortfolioAccount(
                    id: key,
                    accountID: firstPosition?.accountID ?? saved[key]?.accountID ?? transaction?.accountID,
                    source: firstPosition?.source ?? saved[key]?.source ?? transaction?.source ?? "本机",
                    name: firstPosition?.resolvedAccountName ?? saved[key]?.name ?? transaction?.accountName ?? "本机账户",
                    baseCurrency: firstPosition?.accountCurrency ?? saved[key]?.baseCurrency ?? transaction?.realisedProfitLossCurrency ?? fallbackCurrency,
                    positionCount: accountPositions.count,
                    transactionCount: accountTransactions.count,
                    manualTransactionCount: accountTransactions.filter {
                        $0.entryMethod == "manual"
                    }.count,
                    hasCSVImport: firstPosition?.source == "CSV" || accountTransactions.contains {
                        $0.entryMethod == "csv"
                    },
                    marketValueUSD: (try? LocalPortfolioEngine.totals(for: accountPositions).marketValue) ?? 0,
                    // Positions carry the account's name and currency; only the
                    // chosen broker product lives in the saved account list.
                    accountTypeOverride: saved[key]?.accountTypeOverride
                )
            }
            .sorted {
                if $0.source == $1.source { return $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                return $0.source.localizedStandardCompare($1.source) == .orderedAscending
            }
    }

    func scoped(to selectedAccountKeys: Set<String>) -> LocalPortfolioDocument {
        scoped(to: selectedAccountKeys, availableAccounts: accounts)
    }

    /// Reuse an account index already prepared for this document. Building
    /// `accounts` groups the complete transaction history, so callers that
    /// also need the account list should do that work only once.
    func scoped(to selectedAccountKeys: Set<String>, availableAccounts: [PortfolioAccount]) -> LocalPortfolioDocument {
        let availableKeys = Set(availableAccounts.map(\.id))
        let effectiveKeys = selectedAccountKeys.intersection(availableKeys)
        let selectedPositions = positions.filter { effectiveKeys.contains($0.accountKey) }
        let selectedTransactions = transactions?.filter { effectiveKeys.contains($0.accountKey) }
        let isAllAccounts = effectiveKeys == availableKeys
        let selectedSnapshots = snapshots.compactMap { snapshot -> LocalPortfolioSnapshotRecord? in
            guard let accountTotals = snapshot.accountTotals else {
                // A legacy aggregate snapshot cannot be assigned to the
                // current account set once more than one account exists. If
                // retained, adding an account looks like a sell followed by a
                // buy and inflates cash-flow-matched portfolio value.
                return isAllAccounts && availableKeys.count == 1 ? snapshot : nil
            }
            let totals = effectiveKeys.compactMap { accountTotals[$0] }
            guard !totals.isEmpty else { return nil }
            return LocalPortfolioSnapshotRecord(
                date: snapshot.date,
                marketValueUSD: totals.reduce(0) { $0 + $1.marketValueUSD },
                costUSD: totals.reduce(0) { $0 + $1.costUSD },
                accountTotals: Dictionary(uniqueKeysWithValues: effectiveKeys.compactMap { key in
                    accountTotals[key].map { (key, $0) }
                })
            )
        }
        let selectedSources = Set(selectedPositions.map(\.source)).sorted()
        return LocalPortfolioDocument(
            schemaVersion: schemaVersion,
            source: isPublicDisclosure ? PublicInvestorAccountAdapter.source : selectedSources.joined(separator: " + "),
            updatedAt: updatedAt,
            marketDataUpdatedAt: marketDataUpdatedAt,
            positions: selectedPositions,
            snapshots: selectedSnapshots,
            transactions: selectedTransactions,
            knownAccounts: availableAccounts.filter { effectiveKeys.contains($0.id) },
            isSynthetic: isSynthetic
        )
    }
}

enum FakePortfolioGenerator {
    // Types used only by the retired generator below. Its entry point is
    // compile-time unavailable; the active path never receives user data.
    private struct Identity {
        let ticker: String
        let name: String
    }

    private struct AccountIdentity {
        let id: String
        let name: String

        var key: String { "假数据|\(id)" }
    }

    private struct DemoSpec {
        let ticker: String
        let name: String
        let currency: String
        let averageCost: Double
        let quotePrice: Double
        let weight: Double
        let account: Int
        let openedDaysAgo: Int
    }

    private struct DemoAccountSpec {
        let id: String
        let name: String
        let source: String
        let baseCurrency: String
    }

    private static let demoAccounts: [Int: DemoAccountSpec] = [
        1: DemoAccountSpec(
            id: "demo-moomoo-7842",
            name: "Moomoo · 美股账户",
            source: "Moomoo",
            baseCurrency: "USD"
        ),
        2: DemoAccountSpec(
            id: "demo-ibkr-U9483721",
            name: "IBKR · 全球账户",
            source: "IBKR Flex",
            baseCurrency: "GBP"
        ),
        3: DemoAccountSpec(
            id: "demo-212-ISA-5198",
            name: "Trading 212 · ISA",
            source: "Trading 212",
            baseCurrency: "GBP"
        ),
    ]

    /// Strong-privacy demo data. None of these positions, weights, prices,
    /// dates, accounts, or return paths are derived from the user's portfolio.
    private static let privateDemoSpecs = [
        // Moomoo · 美股账户
        DemoSpec(ticker: "ADBE", name: "Adobe Inc.", currency: "USD", averageCost: 365.40, quotePrice: 421.75, weight: 0.044, account: 1, openedDaysAgo: 1_040),
        DemoSpec(ticker: "AMD", name: "Advanced Micro Devices, Inc.", currency: "USD", averageCost: 138.70, quotePrice: 174.35, weight: 0.040, account: 1, openedDaysAgo: 845),
        DemoSpec(ticker: "ORCL", name: "Oracle Corporation", currency: "USD", averageCost: 186.30, quotePrice: 248.15, weight: 0.042, account: 1, openedDaysAgo: 720),
        DemoSpec(ticker: "UBER", name: "Uber Technologies, Inc.", currency: "USD", averageCost: 72.65, quotePrice: 92.40, weight: 0.035, account: 1, openedDaysAgo: 655),
        DemoSpec(ticker: "KO", name: "The Coca-Cola Company", currency: "USD", averageCost: 61.20, quotePrice: 70.15, weight: 0.030, account: 1, openedDaysAgo: 590),
        DemoSpec(ticker: "VOO", name: "Vanguard S&P 500 ETF", currency: "USD", averageCost: 529.80, quotePrice: 642.30, weight: 0.055, account: 1, openedDaysAgo: 540),
        DemoSpec(ticker: "0388.HK", name: "Hong Kong Exchanges and Clearing Limited", currency: "HKD", averageCost: 378.60, quotePrice: 456.20, weight: 0.034, account: 1, openedDaysAgo: 235),
        DemoSpec(ticker: "D05.SI", name: "DBS Group Holdings Ltd", currency: "SGD", averageCost: 47.15, quotePrice: 54.30, weight: 0.030, account: 1, openedDaysAgo: 145),

        // IBKR · 全球账户
        DemoSpec(ticker: "COST", name: "Costco Wholesale Corporation", currency: "USD", averageCost: 774.25, quotePrice: 985.60, weight: 0.050, account: 2, openedDaysAgo: 910),
        DemoSpec(ticker: "AMD", name: "Advanced Micro Devices, Inc.", currency: "USD", averageCost: 141.10, quotePrice: 174.35, weight: 0.045, account: 2, openedDaysAgo: 760),
        DemoSpec(ticker: "XOM", name: "Exxon Mobil Corporation", currency: "USD", averageCost: 103.45, quotePrice: 116.20, weight: 0.050, account: 2, openedDaysAgo: 790),
        DemoSpec(ticker: "ORCL", name: "Oracle Corporation", currency: "USD", averageCost: 191.80, quotePrice: 248.15, weight: 0.045, account: 2, openedDaysAgo: 610),
        DemoSpec(ticker: "VOO", name: "Vanguard S&P 500 ETF", currency: "USD", averageCost: 536.20, quotePrice: 642.30, weight: 0.060, account: 2, openedDaysAgo: 500),
        DemoSpec(ticker: "VUAG.L", name: "Vanguard S&P 500 UCITS ETF", currency: "GBP", averageCost: 88.95, quotePrice: 105.40, weight: 0.050, account: 2, openedDaysAgo: 470),
        DemoSpec(ticker: "ASML.AS", name: "ASML Holding N.V.", currency: "EUR", averageCost: 850.20, quotePrice: 1_040.80, weight: 0.040, account: 2, openedDaysAgo: 285),
        DemoSpec(ticker: "SAP.DE", name: "SAP SE", currency: "EUR", averageCost: 221.30, quotePrice: 272.45, weight: 0.040, account: 2, openedDaysAgo: 330),

        // Trading 212 · ISA
        DemoSpec(ticker: "ADBE", name: "Adobe Inc.", currency: "USD", averageCost: 372.80, quotePrice: 421.75, weight: 0.040, account: 3, openedDaysAgo: 820),
        DemoSpec(ticker: "COST", name: "Costco Wholesale Corporation", currency: "USD", averageCost: 801.40, quotePrice: 985.60, weight: 0.045, account: 3, openedDaysAgo: 690),
        DemoSpec(ticker: "AMD", name: "Advanced Micro Devices, Inc.", currency: "USD", averageCost: 145.60, quotePrice: 174.35, weight: 0.040, account: 3, openedDaysAgo: 620),
        DemoSpec(ticker: "KO", name: "The Coca-Cola Company", currency: "USD", averageCost: 62.75, quotePrice: 70.15, weight: 0.030, account: 3, openedDaysAgo: 510),
        DemoSpec(ticker: "VOO", name: "Vanguard S&P 500 ETF", currency: "USD", averageCost: 548.60, quotePrice: 642.30, weight: 0.055, account: 3, openedDaysAgo: 430),
        DemoSpec(ticker: "EQQQ.L", name: "Invesco EQQQ Nasdaq-100 UCITS ETF", currency: "GBX", averageCost: 35_640, quotePrice: 41_280, weight: 0.035, account: 3, openedDaysAgo: 425),
        DemoSpec(ticker: "AZN.L", name: "AstraZeneca PLC", currency: "GBX", averageCost: 10_860, quotePrice: 12_420, weight: 0.035, account: 3, openedDaysAgo: 380),
        DemoSpec(ticker: "ASML.AS", name: "ASML Holding N.V.", currency: "EUR", averageCost: 872.40, quotePrice: 1_040.80, weight: 0.030, account: 3, openedDaysAgo: 240),
    ]

    static func make() -> LocalPortfolioDocument {
        let targetMarketValueUSD = 93_742.65
        let calendar = Calendar(identifier: .gregorian)
        let now = Date()
        let positions = privateDemoSpecs.map { spec -> LocalPositionRecord in
            let rate = LocalPortfolioEngine.usdRate(for: spec.currency) ?? 1
            let shares = targetMarketValueUSD * spec.weight / (spec.quotePrice * rate)
            let opened = calendar.date(byAdding: .day, value: -spec.openedDaysAgo, to: now) ?? now
            let account = demoAccounts[spec.account] ?? demoAccounts[1]!
            return LocalPositionRecord(
                ticker: spec.ticker,
                name: spec.name,
                shares: shares,
                averageCost: spec.averageCost,
                currency: spec.currency,
                quotePrice: spec.quotePrice,
                quoteCurrency: spec.currency,
                source: account.source,
                openedDate: DayDateCodec.string(from: opened),
                accountID: account.id,
                accountName: account.name,
                accountCurrency: account.baseCurrency,
                brokerPnl: nil,
                brokerPnlCurrency: nil,
                brokerFxPnl: nil,
                brokerFxPnlCurrency: nil,
                fxPnl: nil,
                fxPnlCurrency: nil,
                fxPnlStatus: "demo_not_applicable",
                fxPnlSource: "private_synthetic_demo"
            )
        }

        let dividendTickers = Set([
            "COST", "XOM", "KO", "VOO", "VUAG.L", "EQQQ.L",
            "AZN.L", "SAP.DE", "0388.HK", "D05.SI",
        ])
        func demoDate(daysAgo: Int) -> String {
            let date = calendar.date(byAdding: .day, value: -daysAgo, to: now) ?? now
            return DayDateCodec.string(from: date)
        }

        var transactions = zip(privateDemoSpecs, positions).flatMap { spec, position -> [LocalTransactionRecord] in
            let account = demoAccounts[spec.account] ?? demoAccounts[1]!
            var rows = [
                LocalTransactionRecord(
                    date: demoDate(daysAgo: spec.openedDaysAgo),
                    action: "BUY",
                    ticker: position.ticker,
                    quantity: position.shares * 0.72,
                    price: position.averageCost * 0.90,
                    currency: position.currency,
                    source: position.source,
                    accountID: position.accountID,
                    accountName: position.accountName,
                    tradeID: "demo-\(spec.account)-\(position.ticker)-buy-1",
                    entryMethod: "demo"
                ),
                LocalTransactionRecord(
                    date: demoDate(daysAgo: max(60, spec.openedDaysAgo / 2)),
                    action: "BUY",
                    ticker: position.ticker,
                    quantity: position.shares * 0.46,
                    price: position.averageCost * 1.15,
                    currency: position.currency,
                    source: position.source,
                    accountID: position.accountID,
                    accountName: position.accountName,
                    tradeID: "demo-\(spec.account)-\(position.ticker)-buy-2",
                    entryMethod: "demo"
                ),
                LocalTransactionRecord(
                    date: demoDate(daysAgo: max(16, spec.openedDaysAgo / 7)),
                    action: "SELL",
                    ticker: position.ticker,
                    quantity: position.shares * 0.18,
                    price: position.quotePrice * 0.94,
                    currency: position.currency,
                    source: position.source,
                    accountID: position.accountID,
                    accountName: position.accountName,
                    tradeID: "demo-\(spec.account)-\(position.ticker)-sell-1",
                    entryMethod: "demo"
                ),
            ]

            if dividendTickers.contains(position.ticker) {
                rows.append(LocalTransactionRecord(
                    date: demoDate(daysAgo: max(12, min(82, spec.openedDaysAgo / 5))),
                    action: "DIVIDEND",
                    ticker: position.ticker,
                    quantity: 1,
                    price: max(7.20, targetMarketValueUSD * spec.weight * 0.0042),
                    currency: account.baseCurrency,
                    source: position.source,
                    accountID: position.accountID,
                    accountName: position.accountName,
                    tradeID: "demo-\(spec.account)-\(position.ticker)-dividend-1",
                    entryMethod: "demo"
                ))
            }
            return rows
        }

        for slot in demoAccounts.keys.sorted() {
            guard let account = demoAccounts[slot] else { continue }
            let interestAmount: Double = switch slot {
            case 1: 27.16
            case 2: 31.84
            default: 18.42
            }
            transactions.append(LocalTransactionRecord(
                date: demoDate(daysAgo: 8 + slot * 3),
                action: "INTEREST",
                ticker: "CASH",
                quantity: 1,
                price: interestAmount,
                currency: account.baseCurrency,
                source: account.source,
                accountID: account.id,
                accountName: account.name,
                tradeID: "demo-\(slot)-cash-interest-1",
                entryMethod: "demo"
            ))
        }

        let accountPositions = Dictionary(grouping: positions, by: \.accountKey)
        let currentAccountTotals = accountPositions.compactMapValues { rows -> LocalAccountSnapshotTotals? in
            guard let totals = try? LocalPortfolioEngine.totals(for: rows) else { return nil }
            return LocalAccountSnapshotTotals(marketValueUSD: totals.marketValue, costUSD: totals.cost)
        }
        let currentTotals = (try? LocalPortfolioEngine.totals(for: positions))
            ?? LocalPortfolioEngine.Totals(cost: 78_410.20, marketValue: targetMarketValueUSD)
        let snapshots = (0..<24).map { index -> LocalPortfolioSnapshotRecord in
            let progress = 0.34 + 0.66 * Double(index) / 23
            let date = calendar.date(byAdding: .month, value: index - 23, to: now) ?? now
            if index == 23 {
                return LocalPortfolioSnapshotRecord(
                    date: DayDateCodec.string(from: date),
                    marketValueUSD: currentTotals.marketValue,
                    costUSD: currentTotals.cost,
                    accountTotals: currentAccountTotals
                )
            }
            let trend = 0.012 + 0.158 * pow(Double(index) / 23, 1.35)
            let wave = sin(Double(index) * 0.83) * 0.024 + cos(Double(index) * 0.37) * 0.011
            let accountTotals = currentAccountTotals.mapValues { totals in
                LocalAccountSnapshotTotals(
                    marketValueUSD: totals.costUSD * progress * (1 + trend + wave),
                    costUSD: totals.costUSD * progress
                )
            }
            return LocalPortfolioSnapshotRecord(
                date: DayDateCodec.string(from: date),
                marketValueUSD: accountTotals.values.reduce(0) { $0 + $1.marketValueUSD },
                costUSD: accountTotals.values.reduce(0) { $0 + $1.costUSD },
                accountTotals: accountTotals
            )
        }

        return LocalPortfolioDocument(
            schemaVersion: 4,
            source: "假数据（Trading 212 + Moomoo + IBKR）",
            updatedAt: calendar.date(byAdding: .minute, value: -37, to: now) ?? now,
            marketDataUpdatedAt: calendar.date(byAdding: .minute, value: -37, to: now) ?? now,
            positions: positions,
            snapshots: snapshots,
            transactions: transactions,
            isSynthetic: true
        )
    }

    private static let usdStocks = [
        Identity(ticker: "ADBE", name: "Adobe Inc."),
        Identity(ticker: "AMD", name: "Advanced Micro Devices, Inc."),
        Identity(ticker: "AMGN", name: "Amgen Inc."),
        Identity(ticker: "BKNG", name: "Booking Holdings Inc."),
        Identity(ticker: "CAT", name: "Caterpillar Inc."),
        Identity(ticker: "COST", name: "Costco Wholesale Corporation"),
        Identity(ticker: "CRM", name: "Salesforce, Inc."),
        Identity(ticker: "CSCO", name: "Cisco Systems, Inc."),
        Identity(ticker: "DIS", name: "The Walt Disney Company"),
        Identity(ticker: "GE", name: "GE Aerospace"),
        Identity(ticker: "HD", name: "The Home Depot, Inc."),
        Identity(ticker: "HON", name: "Honeywell International Inc."),
        Identity(ticker: "IBM", name: "International Business Machines Corporation"),
        Identity(ticker: "INTU", name: "Intuit Inc."),
        Identity(ticker: "ISRG", name: "Intuitive Surgical, Inc."),
        Identity(ticker: "KO", name: "The Coca-Cola Company"),
        Identity(ticker: "LIN", name: "Linde plc"),
        Identity(ticker: "LOW", name: "Lowe's Companies, Inc."),
        Identity(ticker: "MCD", name: "McDonald's Corporation"),
        Identity(ticker: "MU", name: "Micron Technology, Inc."),
        Identity(ticker: "NFLX", name: "Netflix, Inc."),
        Identity(ticker: "NKE", name: "NIKE, Inc."),
        Identity(ticker: "NOW", name: "ServiceNow, Inc."),
        Identity(ticker: "ORCL", name: "Oracle Corporation"),
        Identity(ticker: "PANW", name: "Palo Alto Networks, Inc."),
        Identity(ticker: "PEP", name: "PepsiCo, Inc."),
        Identity(ticker: "PFE", name: "Pfizer Inc."),
        Identity(ticker: "QCOM", name: "QUALCOMM Incorporated"),
        Identity(ticker: "SBUX", name: "Starbucks Corporation"),
        Identity(ticker: "TMO", name: "Thermo Fisher Scientific Inc."),
        Identity(ticker: "TXN", name: "Texas Instruments Incorporated"),
        Identity(ticker: "UBER", name: "Uber Technologies, Inc."),
        Identity(ticker: "UNH", name: "UnitedHealth Group Incorporated"),
        Identity(ticker: "UPS", name: "United Parcel Service, Inc."),
        Identity(ticker: "WMT", name: "Walmart Inc."),
        Identity(ticker: "XOM", name: "Exxon Mobil Corporation"),
    ]

    private static let usdFunds = [
        Identity(ticker: "SPY", name: "SPDR S&P 500 ETF Trust"),
        Identity(ticker: "VOO", name: "Vanguard S&P 500 ETF"),
        Identity(ticker: "IVV", name: "iShares Core S&P 500 ETF"),
    ]

    private static let londonStocks = [
        Identity(ticker: "AZN.L", name: "AstraZeneca PLC"),
        Identity(ticker: "BA.L", name: "BAE Systems plc"),
        Identity(ticker: "BARC.L", name: "Barclays PLC"),
        Identity(ticker: "CPG.L", name: "Compass Group PLC"),
        Identity(ticker: "DGE.L", name: "Diageo plc"),
        Identity(ticker: "GSK.L", name: "GSK plc"),
        Identity(ticker: "HSBA.L", name: "HSBC Holdings plc"),
        Identity(ticker: "LSEG.L", name: "London Stock Exchange Group plc"),
        Identity(ticker: "NG.L", name: "National Grid plc"),
        Identity(ticker: "REL.L", name: "RELX PLC"),
        Identity(ticker: "RIO.L", name: "Rio Tinto plc"),
        Identity(ticker: "SHEL.L", name: "Shell plc"),
        Identity(ticker: "ULVR.L", name: "Unilever PLC"),
        Identity(ticker: "VOD.L", name: "Vodafone Group Plc"),
    ]

    private static let londonFunds = [
        Identity(ticker: "VUAG.L", name: "Vanguard S&P 500 UCITS ETF"),
        Identity(ticker: "VUSA.L", name: "Vanguard S&P 500 UCITS ETF"),
    ]

    private static let londonPenceFunds = [
        Identity(ticker: "EQQQ.L", name: "Invesco EQQQ Nasdaq-100 UCITS ETF"),
    ]

    private static let euroStocks = [
        Identity(ticker: "AIR.PA", name: "Airbus SE"),
        Identity(ticker: "ALV.DE", name: "Allianz SE"),
        Identity(ticker: "ASML.AS", name: "ASML Holding N.V."),
        Identity(ticker: "BAS.DE", name: "BASF SE"),
        Identity(ticker: "BNP.PA", name: "BNP Paribas SA"),
        Identity(ticker: "DTE.DE", name: "Deutsche Telekom AG"),
        Identity(ticker: "MC.PA", name: "LVMH Moet Hennessy Louis Vuitton SE"),
        Identity(ticker: "OR.PA", name: "L'Oreal S.A."),
        Identity(ticker: "SAP.DE", name: "SAP SE"),
        Identity(ticker: "SIE.DE", name: "Siemens AG"),
    ]

    private static let hkdStocks = [
        Identity(ticker: "0388.HK", name: "Hong Kong Exchanges and Clearing Limited"),
        Identity(ticker: "0669.HK", name: "Techtronic Industries Company Limited"),
        Identity(ticker: "1299.HK", name: "AIA Group Limited"),
        Identity(ticker: "2318.HK", name: "Ping An Insurance Group Company of China, Ltd."),
        Identity(ticker: "2388.HK", name: "BOC Hong Kong (Holdings) Limited"),
    ]

    private static let regionalStocks: [String: [Identity]] = [
        "CAD": [
            Identity(ticker: "CNQ.TO", name: "Canadian Natural Resources Limited"),
            Identity(ticker: "RY.TO", name: "Royal Bank of Canada"),
            Identity(ticker: "SHOP.TO", name: "Shopify Inc."),
        ],
        "AUD": [
            Identity(ticker: "BHP.AX", name: "BHP Group Limited"),
            Identity(ticker: "CSL.AX", name: "CSL Limited"),
            Identity(ticker: "WES.AX", name: "Wesfarmers Limited"),
        ],
        "JPY": [
            Identity(ticker: "6758.T", name: "Sony Group Corporation"),
            Identity(ticker: "6861.T", name: "Keyence Corporation"),
            Identity(ticker: "7203.T", name: "Toyota Motor Corporation"),
        ],
        "SGD": [
            Identity(ticker: "C6L.SI", name: "Singapore Airlines Limited"),
            Identity(ticker: "D05.SI", name: "DBS Group Holdings Ltd"),
            Identity(ticker: "O39.SI", name: "Oversea-Chinese Banking Corporation Limited"),
        ],
    ]

    @available(*, unavailable, message: "Privacy-unsafe: use the independent make() demo instead")
    private static func makeObfuscatedLegacy(from source: LocalPortfolioDocument) -> LocalPortfolioDocument {
        guard !source.positions.isEmpty else { return source }

        let signature = source.positions
            .map { $0.ticker.uppercased() }
            .sorted()
            .joined(separator: "|")
        let valueFactor = factor("portfolio:\(signature)", low: 0.72, high: 1.48)
        let dateOffset = -Int(factor("date:\(signature)", low: 11, high: 44))

        let originalAccounts = Set(source.positions.map(\.accountKey)).sorted()
        let accounts = Dictionary(uniqueKeysWithValues: originalAccounts.enumerated().map { index, key in
            (key, AccountIdentity(id: "demo-\(index + 1)", name: "演示账户 \(index + 1)"))
        })
        let identities = identityMap(for: source.positions)

        let positions = source.positions.map { position -> LocalPositionRecord in
            let originalTicker = position.ticker.uppercased()
            let identity = identities[originalTicker]
                ?? Identity(ticker: "CF\(identities.count + 1)", name: "Catfolio Sample Holding")
            let priceFactor = factor("price:\(originalTicker)", low: 0.74, high: 1.34)
            let shareFactor = valueFactor / priceFactor
            let account = accounts[position.accountKey]
            return LocalPositionRecord(
                ticker: identity.ticker,
                name: identity.name,
                shares: position.shares * shareFactor,
                averageCost: position.averageCost * priceFactor,
                currency: position.currency,
                quotePrice: position.quotePrice * priceFactor,
                quoteCurrency: position.quoteCurrency,
                source: "假数据",
                openedDate: shifted(position.openedDate, by: dateOffset),
                accountID: account?.id ?? "demo-1",
                accountName: account?.name ?? "演示账户 1",
                accountCurrency: position.accountCurrency,
                brokerPnl: position.brokerPnl.map { $0 * valueFactor },
                brokerPnlCurrency: position.brokerPnlCurrency,
                brokerFxPnl: position.brokerFxPnl.map { $0 * valueFactor },
                brokerFxPnlCurrency: position.brokerFxPnlCurrency,
                fxPnl: position.fxPnl.map { $0 * valueFactor },
                fxPnlCurrency: position.fxPnlCurrency,
                fxPnlStatus: position.fxPnlStatus,
                fxPnlSource: position.fxPnl == nil ? nil : "generated_fake_data"
            )
        }

        let snapshots = source.snapshots.map { snapshot in
            let accountTotals = snapshot.accountTotals.map { totals in
                Dictionary(uniqueKeysWithValues: totals.compactMap { key, value in
                    accounts[key].map { account in
                        (account.key, LocalAccountSnapshotTotals(
                            marketValueUSD: value.marketValueUSD * valueFactor,
                            costUSD: value.costUSD * valueFactor
                        ))
                    }
                })
            }
            return LocalPortfolioSnapshotRecord(
                date: shifted(snapshot.date, by: dateOffset) ?? snapshot.date,
                marketValueUSD: snapshot.marketValueUSD * valueFactor,
                costUSD: snapshot.costUSD * valueFactor,
                accountTotals: accountTotals
            )
        }

        let transactions = source.transactions?.compactMap { transaction -> LocalTransactionRecord? in
            let originalTicker = transaction.ticker.uppercased()
            guard let identity = identities[originalTicker] else { return nil }
            let priceFactor = factor("price:\(originalTicker)", low: 0.74, high: 1.34)
            let shareFactor = valueFactor / priceFactor
            let account = accounts[transaction.accountKey]
            return LocalTransactionRecord(
                date: shifted(transaction.date, by: dateOffset) ?? transaction.date,
                action: transaction.action,
                ticker: identity.ticker,
                quantity: transaction.quantity * shareFactor,
                price: transaction.price * priceFactor,
                currency: transaction.currency,
                source: "假数据",
                accountID: account?.id ?? "demo-1",
                accountName: account?.name ?? "演示账户 1",
                tradeID: nil,
                brokerFXRate: transaction.brokerFXRate.map {
                    $0 * factor("fx:\(originalTicker)", low: 0.985, high: 1.015)
                },
                entryMethod: transaction.entryMethod,
                realisedProfitLoss: transaction.realisedProfitLoss.map { $0 * valueFactor },
                realisedProfitLossCurrency: transaction.realisedProfitLossCurrency
            )
        }

        return LocalPortfolioDocument(
            schemaVersion: source.schemaVersion,
            source: "假数据（本机脱敏）",
            updatedAt: Calendar(identifier: .gregorian).date(
                byAdding: .day,
                value: dateOffset,
                to: source.updatedAt
            ) ?? source.updatedAt,
            marketDataUpdatedAt: source.marketDataUpdatedAt.flatMap {
                Calendar(identifier: .gregorian).date(
                    byAdding: .day,
                    value: dateOffset,
                    to: $0
                )
            },
            positions: positions,
            snapshots: snapshots,
            transactions: transactions,
            isSynthetic: true
        )
    }

    private static func identityMap(for positions: [LocalPositionRecord]) -> [String: Identity] {
        var result: [String: Identity] = [:]
        var used = Set<String>()
        let uniquePositions = Dictionary(grouping: positions, by: { $0.ticker.uppercased() })
            .compactMap { _, values in values.first }
            .sorted { $0.ticker.uppercased() < $1.ticker.uppercased() }

        for (index, position) in uniquePositions.enumerated() {
            let original = position.ticker.uppercased()
            let pool = identityPool(for: position)
            let start = Int(stableHash("identity:\(original)") % UInt64(max(1, pool.count)))
            let identity = (0..<pool.count)
                .map { pool[(start + $0) % pool.count] }
                .first { !used.contains($0.ticker) && $0.ticker.uppercased() != original }
                ?? Identity(ticker: "CF\(index + 1)", name: "Catfolio Sample Holding \(index + 1)")
            result[original] = identity
            used.insert(identity.ticker)
        }
        return result
    }

    private static func identityPool(for position: LocalPositionRecord) -> [Identity] {
        let currency = position.currency.uppercased()
        let name = position.name.uppercased()
        let isFund = name.contains("ETF") || name.contains("UCITS") || name.contains("FUND")
        if currency == "GBP" { return isFund ? londonFunds : londonStocks }
        if currency == "GBX" { return isFund ? londonPenceFunds : londonStocks }
        if currency == "EUR" { return euroStocks }
        if currency == "HKD" { return hkdStocks }
        if let regional = regionalStocks[currency] { return regional }
        return isFund ? usdFunds : usdStocks
    }

    private static func stableHash(_ value: String) -> UInt64 {
        value.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { hash, byte in
            (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }
    }

    private static func factor(_ key: String, low: Double, high: Double) -> Double {
        let unit = Double(stableHash(key) % 1_000_000) / 999_999
        return low + (high - low) * unit
    }

    private static func shifted(_ value: String?, by days: Int) -> String? {
        guard let value, let date = DayDateCodec.date(from: value) else { return value }
        let shifted = Calendar(identifier: .gregorian).date(byAdding: .day, value: days, to: date) ?? date
        return DayDateCodec.string(from: shifted)
    }
}

enum LocalPortfolioError: LocalizedError {
    case noPortfolio
    case invalidCSV(String)
    case unsupportedCurrency(String)
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .noPortfolio:
            L10n.text("手机中还没有组合数据，请先直连券商或导入 CSV")
        case let .invalidCSV(message):
            L10n.text("CSV 无法导入：\(message)")
        case let .unsupportedCurrency(currency):
            L10n.text("暂不支持 \(currency) 换算为 USD")
        case .writeFailed:
            L10n.text("无法保存到 iPhone 本地存储")
        }
    }
}

actor LocalPortfolioStore {
    static let shared = LocalPortfolioStore()

    private let fileURL: URL
    private(set) var recoveryNotice: String?

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    init(fileManager: FileManager = .default) {
        let root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        fileURL = root.appendingPathComponent("Catfolio", isDirectory: true)
            .appendingPathComponent("portfolio.json", isDirectory: false)
    }

    func load() throws -> LocalPortfolioDocument {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return .empty }
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let document: LocalPortfolioDocument
        do {
            document = try decoder.decode(LocalPortfolioDocument.self, from: data)
        } catch is DecodingError {
            let backup = try archivePortfolio(reason: "corrupt")
            recoveryNotice = L10n.text("组合文件无法读取，已备份为 \(backup.lastPathComponent)。请重新导入组合；原始数据保留在本机备份中。")
            return .empty
        }
        let migrated = try migrateKnownInstrumentCurrencies(in: document)
        if migrated != document { try save(migrated) }
        return migrated
    }

    /// Move before resetting so a failed backup never destroys the original.
    @discardableResult
    func resetPortfolio() throws -> URL? {
        let backup = FileManager.default.fileExists(atPath: fileURL.path)
            ? try archivePortfolio(reason: "reset") : nil
        recoveryNotice = nil
        return backup
    }

    private func archivePortfolio(reason: String) throws -> URL {
        let backup = fileURL.deletingLastPathComponent()
            .appendingPathComponent("portfolio-\(reason)-\(UUID().uuidString).json")
        try FileManager.default.moveItem(at: fileURL, to: backup)
        return backup
    }

    func replace(
        positions: [LocalPositionRecord],
        source: String,
        transactions: [LocalTransactionRecord]? = nil,
        replacingAccountsOnly: Bool = false,
        syncedAccounts: [PortfolioAccount] = [],
        mergesTransactionHistory: Bool = false
    ) throws -> LocalPortfolioDocument {
        let previous = try load()
        let incomingAccountKeys = Set(positions.map(\.accountKey)).union(syncedAccounts.map(\.id)).union((transactions ?? []).map(\.accountKey))
        let positionAccountKeys = syncedAccounts.isEmpty ? incomingAccountKeys
            : Set(positions.map(\.accountKey)).union(syncedAccounts.map(\.id))
        guard !replacingAccountsOnly || !incomingAccountKeys.isEmpty else { throw LocalPortfolioError.noPortfolio }
        let combinedPositions = previous.positions.filter { position in
            replacingAccountsOnly
                ? !positionAccountKeys.contains(position.accountKey)
                : position.source != source
        } + positions.map { position in
            var observed = position
            if source != "CSV", source != "IBKR Flex", observed.quoteObservedAt == nil {
                observed.quoteObservedAt = Date()
            }
            return observed
        }
        let now = Date()
        let date = DayDateFormatter.shared.string(from: now)
        let totals = try LocalPortfolioEngine.totals(for: combinedPositions)
        let groupedAccounts = Dictionary(grouping: combinedPositions, by: \.accountKey)
        let accountTotals = try groupedAccounts.mapValues { accountPositions in
            let totals = try LocalPortfolioEngine.totals(for: accountPositions)
            return LocalAccountSnapshotTotals(
                marketValueUSD: totals.marketValue,
                costUSD: totals.cost
            )
        }
        let snapshot = LocalPortfolioSnapshotRecord(
            date: date,
            marketValueUSD: totals.marketValue,
            costUSD: totals.cost,
            accountTotals: accountTotals
        )
        var snapshots = previous.snapshots.filter { $0.date != date }
        snapshots.append(snapshot)
        snapshots.sort { $0.date < $1.date }
        if snapshots.count > 730 {
            snapshots.removeFirst(snapshots.count - 730)
        }
        let sources = Set(combinedPositions.map(\.source)).sorted()
        let combinedTransactions: [LocalTransactionRecord]
        if let transactions {
            let previousByID = Dictionary((previous.transactions ?? []).map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
            if mergesTransactionHistory {
                // Broker history can be partial or bounded. Absence from a
                // response is not evidence that a previously imported fill vanished.
                var merged = previousByID
                for row in transactions {
                    merged[row.id] = row.preservingBrokerResult(from: previousByID[row.id])
                }
                combinedTransactions = merged.values.sorted {
                    $0.date == $1.date ? $0.id < $1.id : $0.date < $1.date
                }
            } else {
                combinedTransactions = (previous.transactions ?? []).filter { transaction in
                    replacingAccountsOnly
                        ? !incomingAccountKeys.contains(transaction.accountKey)
                        : transaction.source != source
                } + transactions.map { $0.preservingBrokerResult(from: previousByID[$0.id]) }
            }
        } else {
            combinedTransactions = previous.transactions ?? []
        }
        let document = LocalPortfolioDocument(
            schemaVersion: 4,
            source: sources.joined(separator: " + "),
            updatedAt: now,
            marketDataUpdatedAt: combinedPositions.allSatisfy { $0.quoteObservedAt != nil }
                ? combinedPositions.compactMap(\.quoteObservedAt).min() : nil,
            positions: combinedPositions,
            snapshots: snapshots,
            transactions: combinedTransactions,
            knownAccounts: Array(Dictionary((previous.accounts + syncedAccounts).map { ($0.id, $0) }, uniquingKeysWith: { _, last in last }).values)
        )
        try save(document)
        return document
    }

    func updateMarketQuotes(
        _ prices: [String: ObservedMarketQuote],
        refreshedAt: Date = Date()
    ) throws -> LocalPortfolioDocument {
        guard !prices.isEmpty else { return try load() }
        var document = try load()
        var matchedQuote = false
        document.positions = document.positions.map { position in
            let key = LocalMarketQuoteKey.make(
                ticker: position.ticker,
                currency: position.quoteCurrency
            )
            guard let quote = prices[key], quote.price.isFinite, quote.price > 0,
                  quote.observedAt <= refreshedAt.addingTimeInterval(60),
                  quote.observedAt >= refreshedAt.addingTimeInterval(-7 * 86_400),
                  quote.observedAt > (position.quoteObservedAt
                    ?? (position.source == "CSV" ? nil : document.marketDataUpdatedAt)
                    ?? .distantPast) else { return position }
            matchedQuote = true
            return position.withQuotePrice(quote.price, observedAt: quote.observedAt)
        }
        guard matchedQuote else { return document }

        let totals = try LocalPortfolioEngine.totals(for: document.positions)
        let groupedAccounts = Dictionary(grouping: document.positions, by: \.accountKey)
        let accountTotals = try groupedAccounts.mapValues { positions in
            let values = try LocalPortfolioEngine.totals(for: positions)
            return LocalAccountSnapshotTotals(
                marketValueUSD: values.marketValue,
                costUSD: values.cost
            )
        }
        let date = DayDateFormatter.shared.string(from: refreshedAt)
        let snapshot = LocalPortfolioSnapshotRecord(
            date: date,
            marketValueUSD: totals.marketValue,
            costUSD: totals.cost,
            accountTotals: accountTotals
        )
        document.snapshots.removeAll { $0.date == date }
        document.snapshots.append(snapshot)
        document.snapshots.sort { $0.date < $1.date }
        if document.snapshots.count > 730 {
            document.snapshots.removeFirst(document.snapshots.count - 730)
        }
        document.updatedAt = refreshedAt
        // The aggregate timestamp must not claim that older holdings were refreshed.
        document.marketDataUpdatedAt = document.positions.allSatisfy { $0.quoteObservedAt != nil }
            ? document.positions.compactMap(\.quoteObservedAt).min() : nil
        try save(document)
        return document
    }

    func renameAccount(_ accountKey: String, to rawName: String) throws -> LocalPortfolioDocument {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw LocalPortfolioError.writeFailed }
        var document = try load()
        guard document.accounts.contains(where: { $0.id == accountKey }) else {
            return document
        }
        document.positions = document.positions.map {
            $0.accountKey == accountKey ? $0.renamedAccount(to: name) : $0
        }
        document.transactions = document.transactions?.map {
            $0.accountKey == accountKey ? $0.renamedAccount(to: name) : $0
        }
        document.knownAccounts = document.accounts.map { account in
            PortfolioAccount(id: account.id, accountID: account.accountID, source: account.source,
                name: account.id == accountKey ? name : account.name, baseCurrency: account.baseCurrency,
                positionCount: account.positionCount, transactionCount: account.transactionCount,
                manualTransactionCount: account.manualTransactionCount, hasCSVImport: account.hasCSVImport,
                marketValueUSD: account.marketValueUSD, accountTypeOverride: account.accountTypeOverride)
        }
        document.updatedAt = Date()
        try save(document)
        return document
    }

    /// Records the broker product the person chose for an account.
    ///
    /// Trading 212's API reports an account number and a currency only, so a
    /// type chosen on the connection screen is the single copy of that fact,
    /// and a later sync that omits it must not clear it.
    func setAccountTypeOverride(_ accountType: String, for accountKey: String) throws -> LocalPortfolioDocument {
        var document = try load()
        guard let target = document.accounts.first(where: { $0.id == accountKey }),
              target.accountTypeOverride != accountType else {
            return document
        }
        document.knownAccounts = document.accounts.map { account in
            PortfolioAccount(id: account.id, accountID: account.accountID, source: account.source,
                name: account.name, baseCurrency: account.baseCurrency,
                positionCount: account.positionCount, transactionCount: account.transactionCount,
                manualTransactionCount: account.manualTransactionCount, hasCSVImport: account.hasCSVImport,
                marketValueUSD: account.marketValueUSD,
                accountTypeOverride: account.id == accountKey ? accountType : account.accountTypeOverride)
        }
        document.updatedAt = Date()
        try save(document)
        return document
    }

    func appendHistoricalTransaction(_ transaction: LocalTransactionRecord) throws -> LocalPortfolioDocument {
        var document = try load()
        guard document.accounts.contains(where: { $0.id == transaction.accountKey }) else {
            throw LocalPortfolioError.noPortfolio
        }
        var transactions = document.transactions ?? []
        transactions.append(transaction)
        document.transactions = transactions
        document.updatedAt = Date()
        try save(document)
        return document
    }

    func mergeTransactions(_ incoming: [LocalTransactionRecord]) throws -> LocalPortfolioDocument {
        guard !incoming.isEmpty else { return try load() }
        var document = try load()
        var transactionsByKey: [String: LocalTransactionRecord] = [:]

        let existing = document.transactions ?? []
        for transaction in existing {
            transactionsByKey[transaction.id] = transaction
        }
        for transaction in incoming {
            // v3 records had no fill ID. Replace their exact legacy fingerprint
            // as v4 IDs arrive, rather than counting old and new rows twice.
            if let legacyID = transaction.legacyTrading212ID,
               transactionsByKey[legacyID]?.tradeID == nil {
                transactionsByKey.removeValue(forKey: legacyID)
            }
            transactionsByKey[transaction.id] = transaction.preservingBrokerResult(from: transactionsByKey[transaction.id])
        }
        let merged = transactionsByKey.values.sorted {
            if $0.date == $1.date { return $0.id < $1.id }
            return $0.date < $1.date
        }
        let sortedExisting = existing.sorted {
            if $0.date == $1.date { return $0.id < $1.id }
            return $0.date < $1.date
        }
        guard merged != sortedExisting else { return document }
        document.transactions = merged
        document.updatedAt = Date()
        try save(document)
        return document
    }

    func deduplicateTransactions(for accountKey: String) throws -> (LocalPortfolioDocument, Int) {
        var document = try load()
        let transactions = document.transactions ?? []
        var seen = Set<String>()
        var removed = 0
        document.transactions = transactions.filter { transaction in
            guard transaction.accountKey == accountKey else { return true }
            guard seen.insert(transaction.id).inserted else {
                removed += 1
                return false
            }
            return true
        }
        if removed > 0 {
            document.updatedAt = Date()
            try save(document)
        }
        return (document, removed)
    }

    /// Creates an account that has nothing in it yet, so a broker connection
    /// can be saved and shown while its first report is still generating.
    func registerAccount(_ account: PortfolioAccount) throws -> LocalPortfolioDocument {
        var document = try load()
        var known = document.knownAccounts ?? []
        known.removeAll { $0.id == account.id }
        known.append(account)
        document.knownAccounts = known
        document.updatedAt = Date()
        try save(document)
        return document
    }

    func removeAccount(_ accountKey: String) throws -> LocalPortfolioDocument {
        var document = try load()
        guard document.accounts.contains(where: { $0.id == accountKey }) else {
            return document
        }
        document.positions.removeAll { $0.accountKey == accountKey }
        document.transactions?.removeAll { $0.accountKey == accountKey }
        document.knownAccounts?.removeAll { $0.id == accountKey }
        document.snapshots = document.snapshots.compactMap { snapshot in
            guard let accountTotals = snapshot.accountTotals else { return nil }
            var remainingTotals = accountTotals
            remainingTotals.removeValue(forKey: accountKey)
            guard !remainingTotals.isEmpty else { return nil }
            return LocalPortfolioSnapshotRecord(
                date: snapshot.date,
                marketValueUSD: remainingTotals.values.reduce(0) { $0 + $1.marketValueUSD },
                costUSD: remainingTotals.values.reduce(0) { $0 + $1.costUSD },
                accountTotals: remainingTotals
            )
        }
        document.source = Set(document.positions.map(\.source)).sorted().joined(separator: " + ")
        document.updatedAt = Date()
        try save(document)
        return document
    }

    private func save(_ document: LocalPortfolioDocument) throws {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(document)
            try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
        } catch {
            throw LocalPortfolioError.writeFailed
        }
    }

    /// Earlier iOS builds treated every `l_EQ` fallback as GBX. Repair those
    /// persisted Trading 212 positions and their cash-flow currencies in place.
    private func migrateKnownInstrumentCurrencies(
        in source: LocalPortfolioDocument
    ) throws -> LocalPortfolioDocument {
        var document = source
        let positions = source.positions.map { position -> LocalPositionRecord in
            guard position.source == "Trading 212",
                  let currency = InstrumentCurrencyRules.knownPriceCurrency(for: position.ticker),
                  position.currency != currency || position.quoteCurrency != currency else {
                return position
            }
            return LocalPositionRecord(
                ticker: position.ticker,
                name: position.name,
                shares: position.shares,
                averageCost: position.averageCost,
                currency: currency,
                quotePrice: position.quotePrice,
                quoteCurrency: currency,
                source: position.source,
                openedDate: position.openedDate,
                accountID: position.accountID,
                accountName: position.accountName,
                accountCurrency: position.accountCurrency,
                brokerPnl: position.brokerPnl,
                brokerPnlCurrency: position.brokerPnlCurrency,
                brokerFxPnl: position.brokerFxPnl,
                brokerFxPnlCurrency: position.brokerFxPnlCurrency,
                fxPnl: position.fxPnl,
                fxPnlCurrency: position.fxPnlCurrency,
                fxPnlStatus: position.fxPnlStatus,
                fxPnlSource: position.fxPnlSource,
                quoteObservedAt: position.quoteObservedAt
            )
        }
        let transactions = source.transactions?.map { transaction -> LocalTransactionRecord in
            guard transaction.source == "Trading 212",
                  ["BUY", "SELL"].contains(transaction.action.uppercased()),
                  let currency = InstrumentCurrencyRules.inferredPriceCurrency(for: transaction.ticker),
                  transaction.currency != currency else { return transaction }
            return LocalTransactionRecord(
                date: transaction.date,
                action: transaction.action,
                ticker: transaction.ticker,
                quantity: transaction.quantity,
                price: transaction.price,
                currency: currency,
                source: transaction.source,
                accountID: transaction.accountID,
                accountName: transaction.accountName,
                tradeID: transaction.tradeID,
                brokerFXRate: transaction.brokerFXRate,
                entryMethod: transaction.entryMethod,
                realisedProfitLoss: transaction.realisedProfitLoss,
                realisedProfitLossCurrency: transaction.realisedProfitLossCurrency,
                executedAt: transaction.executedAt,
                cashPostings: transaction.cashPostings
            )
        }
        guard positions != source.positions || transactions != source.transactions else { return source }

        document.schemaVersion = max(4, source.schemaVersion)
        document.positions = positions
        document.transactions = transactions

        // Replace only today's bad snapshot. Older snapshots are retained rather
        // than silently rewriting historical account composition.
        let today = DayDateCodec.string(from: Date())
        let totals = try LocalPortfolioEngine.totals(for: positions)
        let groupedAccounts = Dictionary(grouping: positions, by: \.accountKey)
        let accountTotals = try groupedAccounts.mapValues { accountPositions in
            let values = try LocalPortfolioEngine.totals(for: accountPositions)
            return LocalAccountSnapshotTotals(
                marketValueUSD: values.marketValue,
                costUSD: values.cost
            )
        }
        document.snapshots.removeAll { $0.date == today }
        document.snapshots.append(LocalPortfolioSnapshotRecord(
            date: today,
            marketValueUSD: totals.marketValue,
            costUSD: totals.cost,
            accountTotals: accountTotals
        ))
        document.snapshots.sort { $0.date < $1.date }
        return document
    }
}

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

enum LocalCSVImporter {
    private struct Transaction {
        let date: Date
        let action: String
        let ticker: String
        let quantity: Double
        let price: Double
        let currency: String
        let name: String
        let reference: String?
        let realisedProfitLoss: Double?
        let realisedProfitLossCurrency: String?
        let cashPostings: [DailyTimeWeightedReturn.Cash]?
    }

    static let aliases: [String: [String]] = [
        "total": ["total"],
        "totalCurrency": ["currency total"],
        "netCash": ["net cash amount"],
        "cashCurrency": ["cash currency"],
        "result": ["result", "realised profit loss", "realized profit loss"],
        "resultCurrency": ["currency result", "result currency"],
        "reference": ["id", "reference", "trade id"],
        "date": [
            "date", "trade date", "transaction date", "time", "date time", "datetime",
            "timestamp", "execution time", "executed at", "created at", "closing time",
            "fill time", "filled at",
            "日期", "时间", "交易日期", "交易时间", "成交时间", "日期时间",
        ],
        "action": [
            "action", "type", "transaction type", "side", "direction",
            "操作", "类型", "交易类型", "方向",
        ],
        "ticker": [
            "ticker", "symbol", "instrument", "stock", "isin", "code",
            "代码", "股票代码", "标的代码", "证券代码",
        ],
        "quantity": [
            "quantity", "qty", "shares", "units", "amount", "no of shares",
            "数量", "股数", "成交数量",
        ],
        "price": [
            "price", "price share", "price per share", "trade price", "unit price", "execution price",
            "fill price", "filled price",
            "价格", "每股价格", "成交价", "执行价格",
        ],
        "currency": [
            "currency price share", "price currency", "currency price", "currency", "ccy", "curr",
            "price currency", "货币", "币种", "价格币种",
        ],
        "name": [
            "name", "company", "description", "instrument name", "security name",
            "名称", "公司名称", "证券名称",
        ],
    ]

    static let requiredColumnKeys = ["date", "action", "ticker", "quantity", "price"]

    static func decodedText(from data: Data) -> String? {
        if data.starts(with: [0xFF, 0xFE]) {
            return String(data: data, encoding: .utf16LittleEndian)
        }
        if data.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16BigEndian)
        }
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .windowsCP1252)
            ?? String(data: data, encoding: .isoLatin1)
    }

    static func columns(in header: [String]) -> [String: Int] {
        let normalized = header.map(normalizeHeader)
        var result: [String: Int] = [:]
        for (key, choices) in aliases {
            // Prefer exact column names. "Result" must never resolve to
            // "Currency (Result)" just because that column occurs first.
            if let exact = choices.compactMap({ normalized.firstIndex(of: normalizeHeader($0)) }).first {
                result[key] = exact
                continue
            }
            for choice in choices {
                let alias = normalizeHeader(choice)
                if let index = normalized.firstIndex(where: { headerMatches($0, alias: alias) }) {
                    result[key] = index
                    break
                }
            }
        }
        return result
    }

    static func headerRowIndex(in records: [[String]]) -> Int? {
        records.prefix(25).enumerated()
            .filter { !$0.element.isEmpty && !isSeparatorDirective($0.element) }
            .max { lhs, rhs in
                columns(in: lhs.element).count < columns(in: rhs.element).count
            }?
            .offset
    }

    static func missingRequiredColumns(in header: [String]) -> [String] {
        let resolved = columns(in: header)
        if resolved["total"] != nil || resolved["netCash"] != nil {
            return ["date", "action"].filter { resolved[$0] == nil }
        }
        return requiredColumnKeys.filter { resolved[$0] == nil }
    }

    static func parse(
        _ data: Data,
        splitCatalog: StockSplitCatalog? = try? StockSplitCatalog.bundled.get()
    ) throws -> ([LocalPositionRecord], [LocalTransactionRecord], CSVImportResult) {
        guard var text = decodedText(from: data) else {
            throw LocalPortfolioError.invalidCSV(L10n.text("文件编码无法识别，请使用 UTF-8 或 UTF-16"))
        }
        text = text.replacingOccurrences(of: "\u{feff}", with: "")
        let records = parseRecords(text)
        guard !records.isEmpty else { throw LocalPortfolioError.invalidCSV(L10n.text("文件为空")) }
        guard let headerIndex = headerRowIndex(in: records) else {
            throw LocalPortfolioError.invalidCSV(L10n.text("没有找到可识别的表头"))
        }
        let header = records[headerIndex]
        // One import is assigned to one selected account. Refuse combined
        // statements instead of silently netting different accounts' trades.
        if let accountColumn = header.firstIndex(where: {
            ["account", "account id", "account number", "账户", "账户编号"].contains(normalizeHeader($0))
        }) {
            let accounts = Set(records.dropFirst(headerIndex + 1).compactMap { row -> String? in
                guard row.indices.contains(accountColumn) else { return nil }
                let value = row[accountColumn].trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty ? nil : value
            })
            guard accounts.count <= 1 else {
                throw LocalPortfolioError.invalidCSV(L10n.text("CSV 包含多个账户，请按账户拆分后分别导入。"))
            }
        }
        let columns = columns(in: header)
        let missing = missingRequiredColumns(in: header)
        guard missing.isEmpty else {
            throw LocalPortfolioError.invalidCSV(L10n.text("缺少列：\(missing.joined(separator: L10n.listSeparator))"))
        }

        var transactions: [Transaction] = []
        var warnings: [String] = []
        var ledgerIncomplete = false
        var rowOccurrences: [String: Int] = [:]
        for (offset, row) in records.dropFirst(headerIndex + 1).enumerated() {
            do {
                func field(_ name: String) -> String {
                    guard let index = columns[name], row.indices.contains(index) else { return "" }
                    return row[index].trimmingCharacters(in: .whitespacesAndNewlines)
                }
                guard !field("action").isEmpty else { continue }
                let action = normalizedAction(field("action")) ?? "UNSUPPORTED: \(field("action"))"
                let isTrade = action == "BUY" || action == "SELL"
                let rawTicker = field("ticker")
                let ticker = rawTicker.isEmpty && !isTrade ? "CASH" : Trading212Position.catfolioTicker(rawTicker)
                guard !ticker.isEmpty else { throw LocalPortfolioError.invalidCSV(L10n.text("交易缺少股票代码")) }
                let quantity = isTrade ? abs(try number(field("quantity"))) : 1
                let price = isTrade ? try number(field("price")) : (numericValue(field("total")) ?? numericValue(field("netCash")) ?? numericValue(field("price")) ?? 0)
                var postings: [DailyTimeWeightedReturn.Cash]? = nil
                let locale = Locale(identifier: "en_US_POSIX")
                if let net = Decimal(string: field("netCash").replacingOccurrences(of: ",", with: ""), locale: locale), !field("cashCurrency").isEmpty {
                    postings = [.init(currency: field("cashCurrency").uppercased(), amount: net)]
                } else if let total = Decimal(string: field("total").replacingOccurrences(of: ",", with: ""), locale: locale), !field("totalCurrency").isEmpty {
                    // Total semantics vary across broker exports. Fee-bearing
                    // rows need an explicit signed net cash amount; do not guess
                    // whether a fee column was already included in Total.
                    let hasCharges = header.enumerated().contains { index, name in
                        let key = name.lowercased()
                        let currencyLabel = key.hasPrefix("currency (") || key.hasPrefix("currency currency ") || key.hasSuffix(" currency")
                        guard !currencyLabel, key.contains("fee") || key.contains("tax") || key.contains("commission"),
                              row.indices.contains(index), !row[index].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
                        guard let amount = numericValue(row[index]), amount.isFinite else { return true }
                        return amount != 0
                    }
                    if !hasCharges {
                        let magnitude = total < 0 ? -total : total
                        let debit = ["BUY", "WITHDRAWAL", "FEE", "TAX"].contains(action)
                        postings = [.init(currency: field("totalCurrency").uppercased(), amount: debit ? -magnitude : magnitude)]
                    }
                }
                let reportedCurrency = field("currency")
                let currency = Trading212Position.currency(
                    reportedCurrency.isEmpty ? nil : reportedCurrency,
                    rawTicker: rawTicker
                )
                let result = action == "SELL" ? numericValue(field("result")) : nil
                let resultCurrency = field("resultCurrency").uppercased()
                let canonical = [field("date"), action, ticker, String(quantity), String(price), currency].joined(separator: "|")
                let digest = SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
                rowOccurrences[digest, default: 0] += 1
                if result != nil && resultCurrency.isEmpty {
                    warnings.append(L10n.text("第 \(headerIndex + offset + 2) 行：Result 缺少币种，不计入券商已实现盈亏。"))
                }
                transactions.append(Transaction(
                    date: try date(field("date")),
                    action: action,
                    ticker: ticker,
                    quantity: quantity,
                    price: price,
                    currency: currency.isEmpty ? "USD" : currency,
                    name: field("name"),
                    reference: field("reference").isEmpty ? "csv-\(digest)-\(rowOccurrences[digest]!)" : field("reference"),
                    realisedProfitLoss: result,
                    realisedProfitLossCurrency: resultCurrency.isEmpty ? nil : resultCurrency,
                    cashPostings: postings
                ))
            } catch {
                ledgerIncomplete = true
                warnings.append(L10n.text("第 \(headerIndex + offset + 2) 行：\(error.localizedDescription)"))
            }
        }
        guard !transactions.isEmpty else { throw LocalPortfolioError.invalidCSV(L10n.text("没有有效交易")) }

        struct PositionState {
            var shares = 0.0
            var average = 0.0
            var currency = "USD"
            var name = ""
            var openedDate: Date?
        }
        var states: [String: PositionState] = [:]
        for transaction in transactions.sorted(by: { $0.date < $1.date }) {
            guard transaction.action == "BUY" || transaction.action == "SELL" else { continue }
            let key = "\(transaction.ticker)|\(transaction.currency)"
            let adjustment = splitCatalog.map { $0.adjustment(ticker: transaction.ticker,
                    from: DayDateCodec.string(from: transaction.date)) } ?? 1
            guard let factor = adjustment, factor.isFinite, factor > 0 else {
                throw LocalPortfolioError.invalidCSV(transaction.ticker)
            }
            let quantity = transaction.quantity * factor
            let price = transaction.price / factor
            var state = states[key] ?? PositionState()
            state.currency = transaction.currency
            if !transaction.name.isEmpty { state.name = transaction.name }
            if transaction.action == "BUY" {
                if state.shares <= 0.001 {
                    state.openedDate = transaction.date
                }
                let newShares = state.shares + quantity
                if newShares > 0 {
                    state.average = (state.average * state.shares + price * quantity) / newShares
                }
                state.shares = newShares
            } else {
                guard quantity <= state.shares + max(1e-8, state.shares * 1e-8) else {
                    throw LocalPortfolioError.invalidCSV(L10n.text("\(transaction.ticker) 卖出数量超过可重建持仓，请补齐历史或拆股记录。"))
                }
                state.shares = max(0, state.shares - quantity)
                if state.shares <= 0.001 {
                    state.openedDate = nil
                }
            }
            states[key] = state
        }
        let positions = states.compactMap { key, state -> LocalPositionRecord? in
            let ticker = String(key.split(separator: "|", maxSplits: 1)[0])
            guard state.shares > 0.001 else { return nil }
            return LocalPositionRecord(
                ticker: ticker,
                name: state.name,
                shares: state.shares,
                averageCost: state.average,
                currency: state.currency,
                quotePrice: state.average,
                quoteCurrency: state.currency,
                source: "CSV",
                openedDate: state.openedDate.map { DayDateFormatter.shared.string(from: $0) }
            )
        }.sorted { $0.ticker < $1.ticker }
        let imported = positions.map {
            CSVImportedHolding(ticker: $0.ticker, name: $0.name, shares: $0.shares, averageCost: $0.averageCost, currency: $0.currency)
        }
        let storedTransactions = transactions.map {
            LocalTransactionRecord(
                date: DayDateCodec.string(from: $0.date),
                action: $0.action,
                ticker: $0.ticker,
                quantity: $0.quantity,
                price: $0.price,
                currency: $0.currency,
                source: "CSV",
                accountID: nil,
                accountName: "CSV",
                tradeID: $0.reference,
                entryMethod: "csv",
                realisedProfitLoss: $0.realisedProfitLoss,
                realisedProfitLossCurrency: $0.realisedProfitLossCurrency,
                executedAt: ISO8601DateFormatter().string(from: $0.date),
                cashPostings: ledgerIncomplete ? nil : $0.cashPostings
            )
        }
        return (positions, storedTransactions, CSVImportResult(
            ok: true,
            holdingsCount: positions.count,
            transactionsCount: transactions.count,
            backupCreated: false,
            warnings: warnings,
            holdings: imported
        ))
    }

    private static func number(_ value: String) throws -> Double {
        guard let number = numericValue(value) else {
            throw LocalPortfolioError.invalidCSV(L10n.text("无效数字 \(value)"))
        }
        return number
    }

    private static func date(_ value: String) throws -> Date {
        guard let parsed = parsedDate(value) else {
            throw LocalPortfolioError.invalidCSV(L10n.text("无效日期 \(value)"))
        }
        return parsed
    }

    static func parsedDate(_ value: String) -> Date? {
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }

        for options: ISO8601DateFormatter.Options in [
            [.withInternetDateTime, .withFractionalSeconds],
            [.withInternetDateTime],
        ] {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = options
            if let date = formatter.date(from: cleaned) { return date }
        }

        let formats = [
            "yyyy-MM-dd HH:mm:ss.SSSSSS", "yyyy-MM-dd HH:mm:ss.SSS", "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd HH:mm", "yyyy-MM-dd, HH:mm:ss", "yyyy/MM/dd HH:mm:ss",
            "MM/dd/yyyy HH:mm:ss", "dd/MM/yyyy HH:mm:ss", "dd-MM-yyyy HH:mm:ss",
            "yyyy-MM-dd", "MM/dd/yyyy", "dd/MM/yyyy", "yyyy/MM/dd", "dd-MM-yyyy",
        ]
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.isLenient = false
            formatter.dateFormat = format
            if let date = formatter.date(from: cleaned) { return date }
        }
        return nil
    }

    static func numericValue(_ value: String) -> Double? {
        var cleaned = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\u{00a0}", with: "")
            .replacingOccurrences(of: " ", with: "")
        let negative = cleaned.hasPrefix("(") && cleaned.hasSuffix(")")
        if negative { cleaned = String(cleaned.dropFirst().dropLast()) }
        cleaned = String(cleaned.filter { $0.isNumber || "+-.,eE".contains($0) })

        if let comma = cleaned.lastIndex(of: ","), let dot = cleaned.lastIndex(of: ".") {
            if comma > dot {
                cleaned = cleaned.replacingOccurrences(of: ".", with: "")
                cleaned = cleaned.replacingOccurrences(of: ",", with: ".")
            } else {
                cleaned = cleaned.replacingOccurrences(of: ",", with: "")
            }
        } else if let comma = cleaned.lastIndex(of: ",") {
            let fractionalDigits = cleaned.distance(from: cleaned.index(after: comma), to: cleaned.endIndex)
            if fractionalDigits == 3 && cleaned.filter({ $0 == "," }).count == 1 {
                cleaned.remove(at: comma)
            } else {
                cleaned = cleaned.replacingOccurrences(of: ",", with: ".")
            }
        }
        guard let number = Double(cleaned) else { return nil }
        return negative ? -number : number
    }

    static func normalizedAction(_ value: String) -> String? {
        let action = normalizeHeader(value)
        if action == "deposit" || action == "入金" { return "DEPOSIT" }
        if action == "withdrawal" || action == "withdraw" || action == "出金" { return "WITHDRAWAL" }
        if action.contains("interest") { return "INTEREST" }
        if action == "fee" { return "FEE" }
        if action == "tax" { return "TAX" }
        if action.contains("buy") || action.contains("买入") { return "BUY" }
        if action.contains("sell") || action.contains("卖出") { return "SELL" }
        if action.contains("dividend") || action.contains("股息") || action.contains("红利") {
            return "DIVIDEND"
        }
        return nil
    }

    /// RFC 4180-style records shared by the manual importer and broker CSV
    /// downloads. Keeping the parser local means downloaded statements never
    /// need to leave the iPhone for conversion.
    static func parseRecords(_ text: String, maximumRecords: Int? = nil) -> [[String]] {
        let delimiter = detectedDelimiter(in: text)
        var records: [[String]] = []
        var record: [String] = []
        var field = ""
        var insideQuotes = false
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "\"" {
                let next = text.index(after: index)
                if insideQuotes, next < text.endIndex, text[next] == "\"" {
                    field.append("\"")
                    index = next
                } else {
                    insideQuotes.toggle()
                }
            } else if character == delimiter, !insideQuotes {
                record.append(field)
                field = ""
            } else if (character == "\n" || character == "\r" || character == "\r\n"), !insideQuotes {
                if character == "\n" || !record.isEmpty || !field.isEmpty {
                    record.append(field)
                    if record.contains(where: { !$0.isEmpty }) { records.append(record) }
                    record = []
                    field = ""
                    if let maximumRecords, records.count >= maximumRecords { break }
                }
            } else {
                field.append(character)
            }
            index = text.index(after: index)
        }
        record.append(field)
        if record.contains(where: { !$0.isEmpty }) { records.append(record) }
        if let first = records.first, isSeparatorDirective(first) {
            records.removeFirst()
        }
        return records
    }

    private static func normalizeHeader(_ value: String) -> String {
        let folded = value
            .replacingOccurrences(of: "\u{feff}", with: "")
            .replacingOccurrences(of: "\u{00a0}", with: " ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
        let scalars = folded.unicodeScalars.map { scalar -> String in
            CharacterSet.alphanumerics.contains(scalar) ? String(scalar) : " "
        }.joined()
        return scalars.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private static func headerMatches(_ value: String, alias: String) -> Bool {
        value == alias || value.hasPrefix("\(alias) ") || value.hasSuffix(" \(alias)")
    }

    private static func isSeparatorDirective(_ row: [String]) -> Bool {
        row.joined().trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("sep=")
    }

    private static func detectedDelimiter(in text: String) -> Character {
        let candidates: [Character] = [",", ";", "\t"]
        let lines = String(text.prefix(65_536))
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .prefix(12)

        if let directive = lines.first?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           directive.hasPrefix("sep="), let separator = directive.last, candidates.contains(separator) {
            return separator
        }

        return candidates.max { lhs, rhs in
            lines.map { delimiterCount(in: String($0), delimiter: lhs) }.max() ?? 0
                < lines.map { delimiterCount(in: String($0), delimiter: rhs) }.max() ?? 0
        } ?? ","
    }

    private static func delimiterCount(in line: String, delimiter: Character) -> Int {
        var insideQuotes = false
        var count = 0
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            if character == "\"" {
                let next = line.index(after: index)
                if insideQuotes, next < line.endIndex, line[next] == "\"" {
                    index = next
                } else {
                    insideQuotes.toggle()
                }
            } else if character == delimiter, !insideQuotes {
                count += 1
            }
            index = line.index(after: index)
        }
        return count
    }
}
