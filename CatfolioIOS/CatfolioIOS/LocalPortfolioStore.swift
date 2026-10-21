import Foundation
import CryptoKit

extension Notification.Name {
    static let localPortfolioDidChange = Notification.Name("Catfolio.localPortfolioDidChange")
}

enum LocalPortfolioSyncError: LocalizedError {
    case unsupportedDocument
    case accountConflict
    case cancelled

    var errorDescription: String? {
        switch self {
        case .unsupportedDocument:
            L10n.text("此组合不能同步，请更新 Catfolio 后重试。演示和公开披露数据不会上传。")
        case .accountConflict:
            L10n.text("这台设备的 Trading 212 账户与 iCloud 中的账户不一致，已停止合并，请先核对账户配置。")
        case .cancelled:
            L10n.text("iCloud 同步已停止。")
        }
    }
}

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
        // Verified Trading 212 euro listings whose legacy identifiers carry
        // no Yahoo exchange suffix. Treating every bare code as US silently
        // mislabelled their historical fill prices as dollars.
        if ["ANAE", "IBEE", "DHER"].contains(normalized) { return "EUR" }
        if normalized.hasSuffix(".L") { return "GBX" }
        if normalized.hasSuffix(".DE") || normalized.hasSuffix(".AS")
            || normalized.hasSuffix(".PA") || normalized.hasSuffix(".MI")
            || normalized.hasSuffix(".MC") || normalized.hasSuffix(".F") {
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
    private let readCredential: @Sendable (String) -> String?
    private var excludesCloudBackup = false
    private(set) var recoveryNotice: String?

    func csvImportJournal(accountKey: String) throws -> CSVImportJournal? {
        let url = csvJournalURL(accountKey)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let journal = try JSONDecoder().decode(CSVImportJournal.self, from: Data(contentsOf: url))
        if let undo = journal.undo {
            let state = CSVAccountState(document: try load(), key: accountKey)
            if state.fingerprint == undo.before.fingerprint && state.fingerprint != undo.afterFingerprint {
                // Receipt was saved, but the process stopped before the ledger.
                return .init(info: undo.previousInfo, undo: nil)
            }
        }
        return journal
    }

    /// Validate and commit without an actor suspension between the two.
    func commitCSVPreview(_ preview: CSVImportPreview, accountName: String?) throws -> (LocalPortfolioDocument, CSVImportResult) {
        guard preview.canCommit, let plan = preview.updatePlan else { throw CSVUpdateError.reviewRequired }
        let current = try load()
        let before = CSVAccountState(document: current, key: preview.accountKey)
        guard before.fingerprint == plan.baseline.fingerprint else { throw CSVUpdateError.accountChanged }
        let priorJournal = try csvImportJournal(accountKey: preview.accountKey)
        if let oldID = priorJournal?.info?.sourceAccountID, let newID = plan.sourceAccountID, oldID != newID {
            throw CSVUpdateError.wrongAccount
        }
        let name = before.account?.name ?? accountName ?? "CSV"
        let reference = plan.incoming.first
        let positions = preview.positions.map { position in
            let assigned = position.assignedAccount(id: reference?.accountID, name: name, source: reference?.source)
            guard let latest = before.positions.first(where: {
                $0.ticker == assigned.ticker && $0.quoteCurrency == assigned.quoteCurrency
            }), let observed = latest.quoteObservedAt,
                  observed > (assigned.quoteObservedAt ?? .distantPast) else { return assigned }
            return assigned.withQuotePrice(latest.quotePrice, observedAt: observed)
        }
        let transactions = preview.transactions.map {
            $0.assignedAccount(id: reference?.accountID, name: name, source: reference?.source)
        }
        let updated = Self.currentTickers(in: try replacingCSVAccount(in: current, key: preview.accountKey, positions: positions,
            transactions: transactions, account: before.account))
        let info = CSVImportInfo(importedAt: Date(), filename: plan.filename, format: plan.format,
            fileHash: plan.fileHash, sourceAccountID: plan.sourceAccountID ?? priorJournal?.info?.sourceAccountID,
            firstDate: transactions.map(\.date).min(), lastDate: transactions.map(\.date).max(),
            counts: preview.counts ?? CSVImportCounts())
        let undo = CSVImportUndo(id: UUID(), accountKey: preview.accountKey, before: before,
            afterFingerprint: CSVAccountState(document: updated, key: preview.accountKey).fingerprint,
            info: info, previousInfo: priorJournal?.info)
        let backup = try backupPortfolio(reason: "before-csv")
        // Write the receipt first. If saving the ledger fails, restore the old
        // receipt; a crash before the ledger save leaves an unusable undo token.
        let saved: LocalPortfolioDocument
        do {
            try writeCSVJournal(.init(info: info, undo: undo), key: preview.accountKey)
            saved = try save(updated)
        }
        catch {
            try? writeCSVJournal(priorJournal ?? .init(), key: preview.accountKey)
            throw error
        }
        var result = preview.result
        result = CSVImportResult(ok: true, holdingsCount: result.holdingsCount,
            transactionsCount: result.transactionsCount, backupCreated: backup != nil,
            warnings: result.warnings, holdings: result.holdings, skippedRowCount: result.skippedRowCount,
            importCounts: preview.counts, undoID: undo.id)
        return (saved, result)
    }

    /// Undo only this account. Another account may have changed meanwhile.
    /// Quote refreshes do not invalidate undo, but ledger edits do.
    func undoCSVImport(accountKey: String, id: UUID) throws -> LocalPortfolioDocument {
        guard let journal = try csvImportJournal(accountKey: accountKey),
              let undo = journal.undo, undo.id == id else { throw CSVUpdateError.undoUnavailable }
        let current = try load()
        guard CSVAccountState(document: current, key: accountKey).fingerprint == undo.afterFingerprint else {
            throw CSVUpdateError.undoUnavailable
        }
        let positions = undo.before.positions.map { previous in
            guard let latest = current.positions.first(where: {
                $0.accountKey == accountKey && $0.ticker == previous.ticker && $0.quoteCurrency == previous.quoteCurrency
            }), let observed = latest.quoteObservedAt,
                  observed > (previous.quoteObservedAt ?? .distantPast) else { return previous }
            return previous.withQuotePrice(latest.quotePrice, observedAt: observed)
        }
        let restored = try replacingCSVAccount(in: current, key: accountKey, positions: positions,
            transactions: undo.before.transactions, account: undo.before.account)
        _ = try backupPortfolio(reason: "before-csv-undo")
        do {
            try writeCSVJournal(.init(info: undo.previousInfo, undo: nil), key: accountKey)
            return try save(restored)
        }
        catch {
            try? writeCSVJournal(journal, key: accountKey)
            throw error
        }
    }

    private func csvJournalURL(_ key: String) -> URL {
        fileURL.deletingLastPathComponent().appendingPathComponent("csv-import-\(CSVTransactionMerger.digest(key)).json")
    }

    private func writeCSVJournal(_ journal: CSVImportJournal, key: String) throws {
        let url = csvJournalURL(key)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(journal).write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        // Receipts contain before/after account records; keep them local even
        // if the user independently enables encrypted CloudKit ledger sync.
        try excludeFileFromBackup(url)
    }

    private func replacingCSVAccount(in original: LocalPortfolioDocument, key: String,
                                     positions: [LocalPositionRecord], transactions: [LocalTransactionRecord],
                                     account: PortfolioAccount?) throws -> LocalPortfolioDocument {
        var document = original
        document.positions = original.positions.filter { $0.accountKey != key } + positions
        document.transactions = (original.transactions ?? []).filter { $0.accountKey != key } + transactions
        document.knownAccounts = (original.knownAccounts ?? []).filter { $0.id != key } + (account.map { [$0] } ?? [])
        document.source = Set(document.positions.map(\.source) + (document.transactions ?? []).map(\.source))
            .sorted().joined(separator: " + ")
        document.schemaVersion = max(document.schemaVersion, 4)
        document.updatedAt = Date()
        document.marketDataUpdatedAt = document.positions.allSatisfy { $0.quoteObservedAt != nil }
            ? document.positions.compactMap(\.quoteObservedAt).min() : nil
        let totals = try LocalPortfolioEngine.totals(for: document.positions)
        let accountTotals = try Dictionary(grouping: document.positions, by: \.accountKey).mapValues {
            let values = try LocalPortfolioEngine.totals(for: $0)
            return LocalAccountSnapshotTotals(marketValueUSD: values.marketValue, costUSD: values.cost)
        }
        let today = DayDateCodec.string(from: Date())
        document.snapshots.removeAll { $0.date == today }
        document.snapshots.append(.init(date: today, marketValueUSD: totals.marketValue,
            costUSD: totals.cost, accountTotals: accountTotals))
        document.snapshots.sort { $0.date < $1.date }
        document.syncMetadata = PortfolioDocumentMerge.normalized(original).syncMetadata
        document.syncMetadata?.positionsUpdatedAt[key] = document.updatedAt.timeIntervalSince1970
        return document
    }

    init(fileURL: URL, readCredential: @escaping @Sendable (String) -> String? = { KeychainStore.string(for: $0) }) {
        self.fileURL = fileURL
        self.readCredential = readCredential
    }

    init(fileManager: FileManager = .default) {
        readCredential = { KeychainStore.string(for: $0) }
        let root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        fileURL = root.appendingPathComponent("Catfolio", isDirectory: true)
            .appendingPathComponent("portfolio.json", isDirectory: false)
    }

    func load() throws -> LocalPortfolioDocument {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return .empty }
        if (try? fileURL.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup) == true {
            excludesCloudBackup = true
        }
        if excludesCloudBackup { try excludeFileFromBackup(fileURL) }
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
        if migrated != document { return try save(migrated) }
        return migrated
    }

    /// Runs inside this actor without suspension: a local import cannot land
    /// between reading the current document and committing the merged result.
    @discardableResult
    func mergeFromCloud(
        _ remote: LocalPortfolioDocument,
        canCommit: @Sendable () -> Bool = { true }
    ) throws -> LocalPortfolioDocument {
        let local = try load()
        try validateAccountBindings(local: local, remote: remote)
        guard let merged = PortfolioDocumentMerge.merge(local: local, remote: remote) else {
            throw LocalPortfolioSyncError.unsupportedDocument
        }
        guard canCommit() else { throw LocalPortfolioSyncError.cancelled }
        guard merged != local else { return local }
        if local.positions.isEmpty == false || local.transactions?.isEmpty == false {
            _ = try backupPortfolio(reason: "cloud-merge")
        }
        guard canCommit() else { throw LocalPortfolioSyncError.cancelled }
        return try save(merged, tracksLocalChanges: false)
    }

    /// Opt-in preparation only: bind device-local broker slots and exclude
    /// plaintext local portfolio files from automatic iCloud device backup.
    /// Record clocks stay untouched because this is not a portfolio edit.
    func prepareForCloudSync() throws -> LocalPortfolioDocument {
        try excludeFromCloudBackup()
        let original = try load()
        guard PortfolioDocumentMerge.isUploadable(original), (1...4).contains(original.schemaVersion) else {
            throw LocalPortfolioSyncError.unsupportedDocument
        }
        var document = PortfolioDocumentMerge.normalized(original)
        var bindings = document.syncMetadata?.accountBindings ?? [:]
        for account in document.accounts where isTrading212Slot(account.id) && bindings[account.id] == nil {
            bindings[account.id] = credentialBinding(for: account.id) ?? "local:\(UUID().uuidString)"
        }
        if !bindings.isEmpty { document.syncMetadata?.accountBindings = bindings }
        guard document != original else { return original }
        return try save(document, tracksLocalChanges: false)
    }

    func excludeFromCloudBackup() throws {
        excludesCloudBackup = true
        let directory = fileURL.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            where url == fileURL || (url.lastPathComponent.hasPrefix("portfolio-") && url.pathExtension == "json") {
            try excludeFileFromBackup(url)
        }
    }

    private func excludeFileFromBackup(_ original: URL) throws {
        var url = original
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }

    private func isTrading212Slot(_ accountKey: String) -> Bool {
        accountKey.hasPrefix("Trading 212|account-")
    }

    private func credentialBinding(for accountKey: String) -> String? {
        let slot = String(accountKey.dropFirst("Trading 212|".count))
        let connectionID = "trading212.\(slot)"
        let keys = [connectionID + ".api-key", connectionID + ".api-secret", connectionID + ".portfolio-binding"]
        let values = Dictionary(uniqueKeysWithValues: keys.compactMap { key in
            readCredential(key).map { (key, $0) }
        })
        // A synced connection carries its stable portfolio identity through
        // key rotations. The marker is accepted only for its exact key pair.
        if let binding = CloudCredentialPolicy.trading212PortfolioBinding(accountKey: accountKey, values: values) {
            return binding
        }
        guard let key = values[connectionID + ".api-key"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              let secret = values[connectionID + ".api-secret"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty, !secret.isEmpty,
              let data = try? JSONEncoder().encode([key, secret]) else { return nil }
        return "credential:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func validateAccountBindings(local: LocalPortfolioDocument, remote: LocalPortfolioDocument) throws {
        for (key, binding) in local.syncMetadata?.accountBindings ?? [:] {
            if let other = remote.syncMetadata?.accountBindings?[key], other != binding {
                // Tombstones retain account identity too: a new account in a
                // reused slot must never inherit the old account's history.
                throw LocalPortfolioSyncError.accountConflict
            }
        }
        let localKeys = Set(local.accounts.map(\.id))
        for account in remote.accounts where isTrading212Slot(account.id) {
            let remoteBinding = remote.syncMetadata?.accountBindings?[account.id]
            if localKeys.contains(account.id) {
                guard let localBinding = local.syncMetadata?.accountBindings?[account.id],
                      localBinding == remoteBinding else { throw LocalPortfolioSyncError.accountConflict }
            } else if let credential = credentialBinding(for: account.id), credential != remoteBinding {
                // Even before its first broker fetch, a configured slot must
                // not silently receive someone else's account data.
                throw LocalPortfolioSyncError.accountConflict
            }
        }
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

    /// Keep the original before committing deletion markers. A missing file
    /// would look like a new device and download the old portfolio again.
    @discardableResult
    func resetPortfolio() throws -> URL? {
        let previous = try load()
        guard !previous.positions.isEmpty || !(previous.transactions ?? []).isEmpty
                || !(previous.knownAccounts ?? []).isEmpty || previous.syncMetadata?.resetAt == nil else {
            return nil
        }
        let backup = try backupPortfolio(reason: "reset")
        var empty = LocalPortfolioDocument.empty
        empty.schemaVersion = max(4, previous.schemaVersion)
        empty.updatedAt = Date()
        empty.syncMetadata = previous.syncMetadata ?? LocalPortfolioSyncMetadata()
        empty.syncMetadata?.resetAt = empty.updatedAt.timeIntervalSince1970
        _ = try save(empty)
        recoveryNotice = nil
        return backup
    }

    /// Copies the portfolio as it stands, beside it, before an import replaces
    /// part of it. Nil when there is nothing saved yet to lose.
    func backupPortfolio(reason: String) throws -> URL? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let backup = fileURL.deletingLastPathComponent()
            .appendingPathComponent("portfolio-\(reason)-\(stamp)-\(UUID().uuidString.prefix(8)).json")
        do {
            try FileManager.default.copyItem(at: fileURL, to: backup)
            if excludesCloudBackup { try excludeFileFromBackup(backup) }
        } catch {
            throw LocalPortfolioError.writeFailed
        }
        if reason == "cloud-merge" {
            // copyItem may retain the source's creation date. Retention needs
            // the backup's creation time, rather than the portfolio's age.
            try? FileManager.default.setAttributes([.creationDate: Date()], ofItemAtPath: backup.path)
            pruneCloudMergeBackups(keepingNewest: backup)
        }
        return backup
    }

    /// Automatic foreground sync can run often. Limit only its disposable
    /// recovery copies; manual, import, reset and corruption archives remain.
    private func pruneCloudMergeBackups(keepingNewest newest: URL) {
        let directory = fileURL.deletingLastPathComponent()
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.creationDateKey, .isRegularFileKey]
        ) else { return }
        let older = files.filter { url in
            url != newest && url.lastPathComponent.hasPrefix("portfolio-cloud-merge-")
                && url.pathExtension == "json"
                && (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }.sorted { left, right in
            let leftDate = (try? left.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let rightDate = (try? right.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return leftDate == rightDate ? left.lastPathComponent > right.lastPathComponent : leftDate > rightDate
        }
        // Keep the just-created backup plus the four most recent older ones.
        for url in older.dropFirst(4) { try? FileManager.default.removeItem(at: url) }
    }

    /// One account's saved positions, for comparing an import against them.
    func positions(accountKey: String) throws -> [LocalPositionRecord] {
        try load().positions.filter { $0.accountKey == accountKey }
    }

    private func archivePortfolio(reason: String) throws -> URL {
        let backup = fileURL.deletingLastPathComponent()
            .appendingPathComponent("portfolio-\(reason)-\(UUID().uuidString).json")
        try FileManager.default.moveItem(at: fileURL, to: backup)
        if excludesCloudBackup { try excludeFileFromBackup(backup) }
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
            if source != "CSV", source != "IBKR Flex", source != ScreenshotImport.source,
               observed.quoteObservedAt == nil {
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
        var document = LocalPortfolioDocument(
            schemaVersion: 4,
            source: sources.joined(separator: " + "),
            updatedAt: now,
            marketDataUpdatedAt: combinedPositions.allSatisfy { $0.quoteObservedAt != nil }
                ? combinedPositions.compactMap(\.quoteObservedAt).min() : nil,
            positions: combinedPositions,
            snapshots: snapshots,
            transactions: combinedTransactions,
            knownAccounts: Array(Dictionary((previous.accounts + syncedAccounts).map { ($0.id, $0) }, uniquingKeysWith: { _, last in last }).values),
            syncMetadata: previous.syncMetadata
        )
        // A successful empty broker response is an authoritative empty
        // snapshot; registration alone deliberately does not set this clock.
        document.syncMetadata = PortfolioDocumentMerge.normalized(previous).syncMetadata
        for key in positionAccountKeys {
            document.syncMetadata?.positionsUpdatedAt[key] = now.timeIntervalSince1970
        }
        return try save(document)
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
        return try save(document)
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
        return try save(document)
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
        return try save(document)
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
        return try save(document)
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
        return try save(document)
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
            document = try save(document)
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
        return try save(document)
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
        return try save(document)
    }

    @discardableResult
    private func save(_ incoming: LocalPortfolioDocument, tracksLocalChanges: Bool = true) throws -> LocalPortfolioDocument {
        var document = Self.currentTickers(in: incoming)
        do {
            let previousData = FileManager.default.fileExists(atPath: fileURL.path)
                ? try Data(contentsOf: fileURL) : nil
            if tracksLocalChanges {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let previous = try previousData.map { try decoder.decode(LocalPortfolioDocument.self, from: $0) } ?? .empty
                document = PortfolioDocumentMerge.recordingChanges(from: previous, to: document)
            }
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(document)
            guard data != previousData else { return document }
            try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
            if excludesCloudBackup { try excludeFileFromBackup(fileURL) }
        } catch {
            throw LocalPortfolioError.writeFailed
        }
        NotificationCenter.default.post(name: .localPortfolioDidChange, object: self)
        return document
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
