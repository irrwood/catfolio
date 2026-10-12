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
        "SILG": "GBP",
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
        let migrated = Self.currentTickers(in: try migrateKnownInstrumentCurrencies(in: document))
        if migrated != document { try save(migrated) }
        return migrated
    }

    /// A listing renamed since the broker last reported it is kept under its
    /// current code, positions and trades alike, so a lot bought as IPOE and
    /// one bought as SOFI are one holding with one history and one quote.
    static func currentTickers(in document: LocalPortfolioDocument) -> LocalPortfolioDocument {
        var document = document
        for index in document.positions.indices {
            document.positions[index].ticker = TickerRenames.currentSymbol(for: document.positions[index].ticker)
        }
        if var transactions = document.transactions {
            for index in transactions.indices {
                transactions[index].ticker = TickerRenames.currentSymbol(for: transactions[index].ticker)
            }
            document.transactions = transactions
        }
        return document
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
        let document = Self.currentTickers(in: document)
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
        // A fill is priced in what its security is quoted in: the broker's
        // own quote currency where it is still held, and only a guess for
        // one sold since. The guess counts any unlisted London line as
        // pence, which made SILG.L's pound fills a hundredth of their cost.
        let heldCurrencies = Dictionary(positions.filter { $0.source == "Trading 212" }.map {
            ($0.ticker.uppercased(), $0.quoteCurrency.uppercased())
        }, uniquingKeysWith: { first, _ in first })
        let transactions = source.transactions?.map { transaction -> LocalTransactionRecord in
            guard transaction.source == "Trading 212",
                  ["BUY", "SELL"].contains(transaction.action.uppercased()),
                  let currency = heldCurrencies[transaction.ticker.uppercased()]
                      ?? InstrumentCurrencyRules.inferredPriceCurrency(for: transaction.ticker),
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
