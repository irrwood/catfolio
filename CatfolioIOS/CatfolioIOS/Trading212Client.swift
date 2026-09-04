import Foundation
import CryptoKit

enum Trading212Environment: String, CaseIterable, Identifiable {
    case live
    case demo

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .live: "正式账户"
        case .demo: "模拟账户"
        }
    }

    fileprivate var baseURL: URL {
        switch self {
        case .live: URL(string: "https://live.trading212.com/api/v0")!
        case .demo: URL(string: "https://demo.trading212.com/api/v0")!
        }
    }
}

struct Trading212Credentials: Equatable {
    let apiKey: String
    let apiSecret: String

    init(apiKey: String, apiSecret: String) throws {
        let apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiSecret = apiSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty, apiKey.count <= 512, !apiKey.contains(":") else {
            throw Trading212Error.invalidAPIKey
        }
        guard !apiSecret.isEmpty, apiSecret.count <= 512 else {
            throw Trading212Error.invalidAPISecret
        }
        self.apiKey = apiKey
        self.apiSecret = apiSecret
    }
}

struct Trading212AccountCredentials: Equatable {
    let slot: Int
    let credentials: Trading212Credentials

    var label: String { "账户 \(slot)" }
}

struct Trading212Position: Decodable, Identifiable, Equatable {
    let accountSlot: Int
    let accountCurrency: String?
    let rawTicker: String
    let ticker: String
    let name: String
    let currency: String
    let quantity: Double
    let averagePricePaid: Double?
    let currentPrice: Double?
    let ppl: Double?
    let fxPpl: Double?
    let createdAt: String?

    var id: String { "\(accountSlot):\(rawTicker)" }

    private enum CodingKeys: String, CodingKey {
        case instrument
        case ticker
        case quantity
        case averagePricePaid
        case averagePrice
        case currentPrice
        case ppl
        case fxPpl
        case walletImpact
        case createdAt
        case initialFillDate
        case currency
        case currencyCode
    }

    private struct Instrument: Decodable {
        let ticker: String?
        let name: String?
        let shortName: String?
        let currencyCode: String?
        let currency: String?
    }

    /// Trading 212 moved position P&L from the legacy top-level `ppl` /
    /// `fxPpl` fields into `walletImpact`. Decode both response shapes so an
    /// API rollout does not silently turn the holding metrics into “暂无”.
    private struct WalletImpact: Decodable {
        let currency: String?
        let fxImpact: Double?
        let unrealizedProfitLoss: Double?

        private enum CodingKeys: String, CodingKey {
            case currency
            case fxImpact
            case unrealizedProfitLoss
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            currency = try values.decodeIfPresent(String.self, forKey: .currency)
            fxImpact = try values.decodeLossyDoubleIfPresent(forKey: .fxImpact)
            unrealizedProfitLoss = try values.decodeLossyDoubleIfPresent(forKey: .unrealizedProfitLoss)
        }
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let instrument = try values.decodeIfPresent(Instrument.self, forKey: .instrument)
        let flatTicker = try values.decodeIfPresent(String.self, forKey: .ticker)
        let flatCurrencyCode = try values.decodeIfPresent(String.self, forKey: .currencyCode)
        let flatCurrency = try values.decodeIfPresent(String.self, forKey: .currency)
        let walletImpact = try values.decodeIfPresent(WalletImpact.self, forKey: .walletImpact)
        let rawTicker = instrument?.ticker ?? flatTicker ?? ""
        self.accountSlot = 0
        accountCurrency = walletImpact?.currency?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        self.rawTicker = rawTicker
        ticker = Self.catfolioTicker(rawTicker)
        name = instrument?.name ?? instrument?.shortName ?? ticker
        currency = Self.currency(
            instrument?.currencyCode ?? instrument?.currency ?? flatCurrencyCode ?? flatCurrency,
            rawTicker: rawTicker
        )
        quantity = try values.decodeLossyDoubleIfPresent(forKey: .quantity) ?? 0
        let currentAveragePrice = try values.decodeLossyDoubleIfPresent(forKey: .averagePricePaid)
        let legacyAveragePrice = try values.decodeLossyDoubleIfPresent(forKey: .averagePrice)
        averagePricePaid = currentAveragePrice ?? legacyAveragePrice
        currentPrice = try values.decodeLossyDoubleIfPresent(forKey: .currentPrice)
        ppl = try values.decodeLossyDoubleIfPresent(forKey: .ppl)
            ?? walletImpact?.unrealizedProfitLoss
        fxPpl = try values.decodeLossyDoubleIfPresent(forKey: .fxPpl)
            ?? walletImpact?.fxImpact
        let currentCreatedAt = try values.decodeIfPresent(String.self, forKey: .createdAt)
        let legacyCreatedAt = try values.decodeIfPresent(String.self, forKey: .initialFillDate)
        createdAt = currentCreatedAt ?? legacyCreatedAt
    }

    private init(accountSlot: Int, accountCurrency: String?, position: Trading212Position) {
        self.accountSlot = accountSlot
        self.accountCurrency = accountCurrency
        rawTicker = position.rawTicker
        ticker = position.ticker
        name = position.name
        currency = position.currency
        quantity = position.quantity
        averagePricePaid = position.averagePricePaid
        currentPrice = position.currentPrice
        ppl = position.ppl
        fxPpl = position.fxPpl
        createdAt = position.createdAt
    }

    fileprivate func assigned(to slot: Int, accountCurrency: String?) -> Trading212Position {
        Trading212Position(
            accountSlot: slot,
            accountCurrency: self.accountCurrency ?? accountCurrency,
            position: self
        )
    }

    static func catfolioTicker(_ value: String) -> String {
        var ticker = value
        var marketSuffix: String?
        if ticker.hasSuffix("_US_EQ") {
            ticker.removeLast("_US_EQ".count)
            marketSuffix = "US"
        } else if ticker.hasSuffix("_EQ") {
            ticker.removeLast("_EQ".count)
            if let marker = ticker.last, marker.isLowercase {
                switch marker {
                case "l": marketSuffix = "L"
                case "d": marketSuffix = "DE"
                case "a": marketSuffix = "AS"
                case "p": marketSuffix = "PA"
                case "i": marketSuffix = "MI"
                case "s": marketSuffix = "SW"
                default: break
                }
                if marketSuffix != nil { ticker.removeLast() }
            }
        }

        ticker = ticker.uppercased()
        let aliases = ["FB": "META", "BRK_B": "BRK.B"]
        ticker = aliases[ticker] ?? ticker
        switch marketSuffix {
        case "L": return "\(ticker).L"
        case "DE": return "\(ticker).DE"
        case "AS": return "\(ticker).AS"
        case "PA": return "\(ticker).PA"
        case "MI": return "\(ticker).MI"
        case "SW": return "\(ticker).SW"
        default: return ticker
        }
    }

    static func currency(_ value: String?, rawTicker: String) -> String {
        // Match the desktop importer before consulting the exchange suffix.
        // VUSA/VUAG and this verified set are quoted in whole GBP on Trading 212;
        // treating `l_EQ` as GBX makes their value exactly 100x too small.
        if let known = InstrumentCurrencyRules.knownPriceCurrency(for: catfolioTicker(rawTicker)) {
            return known
        }
        let reported = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !reported.isEmpty {
            // Trading 212 returns prices in the instrument currency. Some London
            // listings (including VUAG/VUSA) trade in pounds, while others trade
            // in pence, so the exchange suffix alone cannot determine the unit.
            if reported == "GBp" { return "GBX" }
            let normalized = reported.uppercased()
            if normalized == "GBX" { return "GBX" }
            return normalized
        }
        if rawTicker.hasSuffix("l_EQ") { return "GBX" }
        if rawTicker.hasSuffix("_US_EQ") { return "USD" }
        if rawTicker.hasSuffix("d_EQ") || rawTicker.hasSuffix("a_EQ")
            || rawTicker.hasSuffix("p_EQ") || rawTicker.hasSuffix("i_EQ") {
            return "EUR"
        }
        return "USD"
    }
}

struct Trading212Snapshot: Equatable {
    let accountCount: Int
    let positions: [Trading212Position]
    let transactions: [Trading212Transaction]
    let hasCompleteTransactionHistory: Bool
    let transactionHistoryStatus: String?
}

struct Trading212Transaction: Codable, Equatable, Sendable {
    let accountSlot: Int
    let date: String
    let executedAt: String?
    let action: String
    let ticker: String
    let quantity: Double
    let price: Double
    let currency: String
    let reference: String?
    /// Exact closed-position result reported by Trading 212's activity CSV.
    /// This is intentionally separate from the order total.
    let realisedProfitLoss: Double?
    let realisedProfitLossCurrency: String?

    init(
        accountSlot: Int,
        date: String,
        executedAt: String?,
        action: String,
        ticker: String,
        quantity: Double,
        price: Double,
        currency: String,
        reference: String? = nil,
        realisedProfitLoss: Double? = nil,
        realisedProfitLossCurrency: String? = nil
    ) {
        self.accountSlot = accountSlot
        self.date = date
        self.executedAt = executedAt
        self.action = action
        self.ticker = ticker
        self.quantity = quantity
        self.price = price
        self.currency = currency
        self.reference = reference
        self.realisedProfitLoss = realisedProfitLoss
        self.realisedProfitLossCurrency = realisedProfitLossCurrency
    }
}

private struct Trading212CachedOrder: Codable, Equatable, Sendable {
    let key: String
    let transaction: Trading212Transaction
}

private struct Trading212HistoryCheckpoint: Codable, Equatable, Sendable {
    var orders: [Trading212CachedOrder] = []
    var nextPagePath: String?
    var hasCompleteBaseline = false
    var refreshBoundaryKeys: Set<String> = []
    var resumeAfter: Date?
    var updatedAt = Date()
}

private actor Trading212HistorySyncStore {
    static let shared = Trading212HistorySyncStore()

    private var checkpoints: [String: Trading212HistoryCheckpoint] = [:]
    private var hasLoaded = false

    func checkpoint(for key: String) -> Trading212HistoryCheckpoint {
        loadIfNeeded()
        return checkpoints[key] ?? Trading212HistoryCheckpoint()
    }

    func save(_ checkpoint: Trading212HistoryCheckpoint, for key: String) {
        loadIfNeeded()
        checkpoints[key] = checkpoint
        persist()
    }

    private func loadIfNeeded() {
        guard !hasLoaded else { return }
        hasLoaded = true
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(
                [String: Trading212HistoryCheckpoint].self,
                from: data
              ) else { return }
        checkpoints = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(checkpoints) else { return }
        let folder = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: [.atomic, .completeFileProtection])
    }

    private var fileURL: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return root
            .appendingPathComponent("Catfolio", isDirectory: true)
            .appendingPathComponent("trading212-history-sync.json")
    }
}

private struct Trading212CachedDividend: Codable, Equatable, Sendable {
    let key: String
    let transaction: Trading212Transaction
}

private struct Trading212DividendCheckpoint: Codable, Equatable, Sendable {
    var dividends: [Trading212CachedDividend] = []
    var nextPagePath: String?
    var hasCompleteBaseline = false
    var refreshBoundaryKeys: Set<String> = []
    var resumeAfter: Date?
    var updatedAt = Date()
}

private actor Trading212DividendSyncStore {
    static let shared = Trading212DividendSyncStore()

    private var checkpoints: [String: Trading212DividendCheckpoint] = [:]
    private var hasLoaded = false

    func checkpoint(for key: String) -> Trading212DividendCheckpoint {
        loadIfNeeded()
        return checkpoints[key] ?? Trading212DividendCheckpoint()
    }

    func save(_ checkpoint: Trading212DividendCheckpoint, for key: String) {
        loadIfNeeded()
        checkpoints[key] = checkpoint
        persist()
    }

    private func loadIfNeeded() {
        guard !hasLoaded else { return }
        hasLoaded = true
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(
                [String: Trading212DividendCheckpoint].self,
                from: data
              ) else { return }
        checkpoints = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(checkpoints) else { return }
        let folder = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: [.atomic, .completeFileProtection])
    }

    private var fileURL: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return root
            .appendingPathComponent("Catfolio", isDirectory: true)
            .appendingPathComponent("trading212-dividend-sync.json")
    }
}

private struct Trading212CachedInterest: Codable, Equatable, Sendable {
    let key: String
    let transaction: Trading212Transaction
}

private struct Trading212ReportedOrder: Codable, Equatable, Sendable {
    let transaction: Trading212Transaction
}

private struct Trading212InterestCheckpoint: Codable, Equatable, Sendable {
    var interests: [Trading212CachedInterest] = []
    /// Orders from the broker-generated CSV carry the authoritative Result
    /// and Currency (Result) values that the lightweight orders endpoint omits.
    var reportedOrders: [Trading212ReportedOrder]?
    var pendingReportID: Int64?
    var nextCheckAfter: Date?
    var lastCompletedAt: Date?
    var currentPeriodStart: Date?
    var currentPeriodEnd: Date?
    var nextPeriodEnd: Date?
    var hasCompleteBaseline: Bool?
}

private actor Trading212InterestSyncStore {
    static let shared = Trading212InterestSyncStore()

    private var checkpoints: [String: Trading212InterestCheckpoint] = [:]
    private var hasLoaded = false

    func checkpoint(for key: String) -> Trading212InterestCheckpoint {
        loadIfNeeded()
        return checkpoints[key] ?? Trading212InterestCheckpoint()
    }

    func save(_ checkpoint: Trading212InterestCheckpoint, for key: String) {
        loadIfNeeded()
        checkpoints[key] = checkpoint
        persist()
    }

    private func loadIfNeeded() {
        guard !hasLoaded else { return }
        hasLoaded = true
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(
                [String: Trading212InterestCheckpoint].self,
                from: data
              ) else { return }
        checkpoints = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(checkpoints) else { return }
        let folder = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: [.atomic, .completeFileProtection])
    }

    private var fileURL: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return root
            .appendingPathComponent("Catfolio", isDirectory: true)
            .appendingPathComponent("trading212-interest-sync.json")
    }
}

enum Trading212Error: LocalizedError {
    case invalidAPIKey
    case invalidAPISecret
    case noAccounts
    case invalidResponse
    case authorizationFailed
    case accountFailed(Int, String)
    case http(Int, String)
    case noPositions

    var errorDescription: String? {
        switch self {
        case .invalidAPIKey:
            "API Key 不能为空，且不能包含冒号"
        case .invalidAPISecret:
            "API Secret 不能为空"
        case .noAccounts:
            "请填写 Trading 212 账户的 API Key 与 API Secret"
        case .invalidResponse:
            "Trading 212 返回了无法识别的数据"
        case .authorizationFailed:
            "Trading 212 授权失败，请检查环境、API Key、Secret 与读取权限"
        case let .accountFailed(slot, message):
            "Trading 212 账户 \(slot)：\(message)"
        case let .http(code, message):
            "Trading 212 请求失败（HTTP \(code)）：\(message)"
        case .noPositions:
            "Trading 212 账户当前没有持仓"
        }
    }
}

struct Trading212Client {
    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            self.session = URLSession(configuration: configuration)
        }
    }

    func cachedTransactions(
        accounts: [Trading212AccountCredentials],
        environment: Trading212Environment
    ) async -> [Trading212Transaction] {
        var result: [Trading212Transaction] = []
        for account in accounts {
            let orderKey = Self.historyCheckpointKey(
                credentials: account.credentials,
                environment: environment,
                accountSlot: account.slot
            )
            let orders = await Trading212HistorySyncStore.shared.checkpoint(for: orderKey)
            let interestKey = Self.interestCheckpointKey(
                credentials: account.credentials,
                environment: environment,
                accountSlot: account.slot
            )
            let activityReport = await Trading212InterestSyncStore.shared.checkpoint(for: interestKey)
            result.append(contentsOf: Self.applyingBrokerReport(
                activityReport.reportedOrders?.map(\.transaction) ?? [],
                to: orders.orders.map(\.transaction)
            ))

            let dividendKey = Self.dividendCheckpointKey(
                credentials: account.credentials,
                environment: environment,
                accountSlot: account.slot
            )
            let dividends = await Trading212DividendSyncStore.shared.checkpoint(for: dividendKey)
            result.append(contentsOf: dividends.dividends.map(\.transaction))

            result.append(contentsOf: activityReport.interests.map(\.transaction))
        }
        return result
    }

    func fetchSnapshot(
        accounts: [Trading212AccountCredentials],
        environment: Trading212Environment
    ) async throws -> Trading212Snapshot {
        guard !accounts.isEmpty else { throw Trading212Error.noAccounts }
        var positions: [Trading212Position] = []
        var transactions: [Trading212Transaction] = []
        var hasCompleteTransactionHistory = true
        var historyStatuses: [String] = []
        for account in accounts {
            do {
                // Match the desktop pipeline: `fxPpl` is denominated in the
                // account currency, so resolve that currency independently of
                // the instrument quote currency. Trading 212 permissions can
                // expose either account/info or account/cash; when neither is
                // available the desktop importer uses GBP as its UK-account
                // compatibility fallback.
                let accountCurrency = (try? await fetchAccountCurrency(
                    credentials: account.credentials,
                    environment: environment
                )) ?? "GBP"
                let accountPositions = try await fetchPositions(
                    credentials: account.credentials,
                    environment: environment
                )
                positions.append(contentsOf: accountPositions.map {
                    $0.assigned(to: account.slot, accountCurrency: accountCurrency)
                })
                do {
                    async let orderHistoryRequest = fetchTransactionHistory(
                        credentials: account.credentials,
                        environment: environment,
                        accountSlot: account.slot
                    )
                    async let dividendHistoryRequest = fetchDividendHistory(
                        credentials: account.credentials,
                        environment: environment,
                        accountSlot: account.slot,
                        accountCurrency: accountCurrency
                    )
                    let orderHistory = try await orderHistoryRequest
                    let dividendHistory: HistoricalOrdersResult
                    do {
                        dividendHistory = try await dividendHistoryRequest
                    } catch {
                        // Missing dividend permission must not hide otherwise
                        // valid BUY/SELL history from the account.
                        dividendHistory = HistoricalOrdersResult(
                            transactions: [],
                            isComplete: true,
                            cachedCount: 0,
                            status: "分红记录读取失败：\(error.localizedDescription)"
                        )
                    }
                    let interestHistory: HistoricalOrdersResult
                    do {
                        interestHistory = try await fetchInterestHistory(
                            credentials: account.credentials,
                            environment: environment,
                            accountSlot: account.slot,
                            accountCurrency: accountCurrency,
                            oldestOrderDate: orderHistory.transactions.map(\.date).min(),
                            hasCompleteOrderHistory: orderHistory.isComplete
                        )
                    } catch {
                        // Exact sell results and interest are exposed through
                        // Trading 212's asynchronous activity export. A report
                        // failure must not hide the lightweight history.
                        interestHistory = HistoricalOrdersResult(
                            transactions: [],
                            isComplete: false,
                            cachedCount: 0,
                            status: "券商结算报表读取失败：\(error.localizedDescription)"
                        )
                    }
                    let activityKey = Self.interestCheckpointKey(
                        credentials: account.credentials,
                        environment: environment,
                        accountSlot: account.slot
                    )
                    let activityReport = await Trading212InterestSyncStore.shared.checkpoint(for: activityKey)
                    transactions.append(contentsOf: Self.applyingBrokerReport(
                        activityReport.reportedOrders?.map(\.transaction) ?? [],
                        to: orderHistory.transactions
                    ))
                    transactions.append(contentsOf: dividendHistory.transactions)
                    transactions.append(contentsOf: interestHistory.transactions)
                    let accountHistoryComplete = orderHistory.isComplete
                        && dividendHistory.isComplete
                        && interestHistory.isComplete
                    hasCompleteTransactionHistory = hasCompleteTransactionHistory && accountHistoryComplete
                    let messages = [
                        orderHistory.status,
                        dividendHistory.status,
                        interestHistory.status,
                    ].compactMap { $0 }
                    if !messages.isEmpty {
                        historyStatuses.append("\(account.label)\(messages.joined(separator: "；"))")
                    } else if !accountHistoryComplete {
                        historyStatuses.append(
                            "\(account.label)正在补齐成交、分红和利息历史"
                        )
                    }
                } catch {
                    hasCompleteTransactionHistory = false
                    historyStatuses.append("\(account.label)成交历史本次未能继续读取")
                }
            } catch {
                throw Trading212Error.accountFailed(account.slot, error.localizedDescription)
            }
        }
        guard !positions.isEmpty else { throw Trading212Error.noPositions }
        return Trading212Snapshot(
            accountCount: accounts.count,
            positions: positions,
            // Expose the persisted partial pages immediately. The store merges
            // these records until the baseline is complete, so users can see
            // SELL and DIVIDEND rows without waiting several minutes.
            transactions: transactions,
            hasCompleteTransactionHistory: hasCompleteTransactionHistory,
            transactionHistoryStatus: historyStatuses.isEmpty
                ? nil
                : historyStatuses.joined(separator: "；")
        )
    }

    private struct HistoricalOrdersResult {
        let transactions: [Trading212Transaction]
        let isComplete: Bool
        let cachedCount: Int
        let status: String?
    }

    private struct HistoricalOrdersPage: Decodable {
        let items: [HistoricalOrder]
        let nextPagePath: String?
    }

    private struct HistoricalOrder: Decodable {
        struct Fill: Decodable {
            let filledAt: String?
            let id: Int64?
            let price: Double?
            let quantity: Double?
        }

        struct Order: Decodable {
            let currency: String?
            let side: String?
            let status: String?
            let ticker: String?
        }

        let fill: Fill?
        let order: Order?
    }

    private struct HistoricalDividendsPage: Decodable {
        let items: [HistoricalDividend]
        let nextPagePath: String?
    }

    private struct HistoricalDividend: Decodable {
        struct Instrument: Decodable {
            let ticker: String?
        }

        let amount: Double?
        let currency: String?
        let grossAmountPerShare: Double?
        let instrument: Instrument?
        let paidOn: String?
        let quantity: Double?
        let reference: String?
        let ticker: String?
    }

    private struct InterestReportRequest: Encodable {
        struct IncludedData: Encodable {
            let includeDividends = false
            let includeInterest = true
            // The lightweight orders endpoint omits realised P/L. Trading
            // 212's CSV `Result` column is the broker source of truth.
            let includeOrders = true
            let includeTransactions = false
        }

        let dataIncluded = IncludedData()
        let timeFrom: String
        let timeTo: String
    }

    private struct EnqueuedInterestReport: Decodable {
        let reportId: Int64
    }

    private struct InterestReport: Decodable {
        let downloadLink: String?
        let reportId: Int64
        let status: String
    }

    /// Historical fills come from Trading 212's orders API. Current quantity,
    /// market value and average cost always come from the positions snapshot;
    /// completing this history is only needed for time-series reconstruction.
    private func fetchTransactionHistory(
        credentials: Trading212Credentials,
        environment: Trading212Environment,
        accountSlot: Int
    ) async throws -> HistoricalOrdersResult {
        return try await fetchHistoricalOrders(
            credentials: credentials,
            environment: environment,
            accountSlot: accountSlot
        )
    }

    private func fetchHistoricalOrders(
        credentials: Trading212Credentials,
        environment: Trading212Environment,
        accountSlot: Int
    ) async throws -> HistoricalOrdersResult {
        let checkpointKey = Self.historyCheckpointKey(
            credentials: credentials,
            environment: environment,
            accountSlot: accountSlot
        )
        var checkpoint = await Trading212HistorySyncStore.shared.checkpoint(for: checkpointKey)
        if let resumeAfter = checkpoint.resumeAfter, resumeAfter > Date() {
            return HistoricalOrdersResult(
                transactions: checkpoint.orders.map(\.transaction).sorted { $0.date < $1.date },
                isComplete: false,
                cachedCount: checkpoint.orders.count,
                status: "历史接口已达本轮限制，稍后再同步会继续"
            )
        }

        let initialURL = environment.baseURL
            .appendingPathComponent("equity/history/orders")
            .appending(queryItems: [URLQueryItem(name: "limit", value: "50")])
        let isContinuing = checkpoint.nextPagePath?.isEmpty == false
        if !isContinuing, checkpoint.hasCompleteBaseline {
            checkpoint.refreshBoundaryKeys = Set(checkpoint.orders.map(\.key))
        }
        let isRefreshingBaseline = !checkpoint.refreshBoundaryKeys.isEmpty
        var nextURL: URL
        if let path = checkpoint.nextPagePath,
           let resolved = URL(string: path, relativeTo: environment.baseURL)?.absoluteURL {
            nextURL = resolved
        } else {
            nextURL = initialURL
        }
        var ordersByKey = Dictionary(uniqueKeysWithValues: checkpoint.orders.map { ($0.key, $0) })
        var reachedExistingBaseline = false

        // The official limit is six history calls per minute. Persist after
        // every page so termination, background suspension and later launches
        // resume from the returned cursor instead of restarting at page one.
        for _ in 0..<6 {
            var request = URLRequest(url: nextURL)
            request.httpMethod = "GET"
            request.timeoutInterval = 30
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("CatfolioIOS/1.0", forHTTPHeaderField: "User-Agent")
            let token = Data("\(credentials.apiKey):\(credentials.apiSecret)".utf8).base64EncodedString()
            request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw Trading212Error.invalidResponse }
            if http.statusCode == 401 || http.statusCode == 403 { throw Trading212Error.authorizationFailed }
            guard (200..<300).contains(http.statusCode) else {
                throw Trading212Error.http(http.statusCode, Self.serviceMessage(from: data))
            }
            let page = try JSONDecoder().decode(HistoricalOrdersPage.self, from: data)
            for item in page.items {
                guard let fill = item.fill,
                      let order = item.order,
                      order.status?.uppercased() == "FILLED",
                      let filledAt = fill.filledAt,
                      let signedQuantity = fill.quantity, signedQuantity != 0,
                      let price = fill.price, price >= 0,
                      let rawTicker = order.ticker,
                      let side = order.side?.uppercased(),
                      ["BUY", "SELL"].contains(side),
                      side == "SELL" || price > 0 else { continue }
                // `order.currency` is the account/order currency, while
                // `fill.price` is quoted in the instrument currency. Never
                // multiply a USD share price as though it were GBP.
                let currency = Trading212Position.currency(nil, rawTicker: rawTicker)
                let transaction = Trading212Transaction(
                    accountSlot: accountSlot,
                    date: String(filledAt.prefix(10)),
                    executedAt: filledAt,
                    action: side,
                    ticker: Trading212Position.catfolioTicker(rawTicker),
                    // Trading 212 represents sell quantities as negative
                    // values. Direction comes from `order.side`; Catfolio's
                    // transaction model stores quantity as an absolute value.
                    quantity: abs(signedQuantity),
                    price: price,
                    currency: currency
                )
                let orderKey = Self.transactionKey(transaction, filledAt: filledAt)
                if isRefreshingBaseline, checkpoint.refreshBoundaryKeys.contains(orderKey) {
                    reachedExistingBaseline = true
                }
                ordersByKey[orderKey] = Trading212CachedOrder(key: orderKey, transaction: transaction)
            }

            checkpoint.orders = Array(ordersByKey.values)
            checkpoint.updatedAt = Date()
            if reachedExistingBaseline || page.nextPagePath?.isEmpty != false {
                checkpoint.nextPagePath = nil
                checkpoint.hasCompleteBaseline = true
                checkpoint.refreshBoundaryKeys = []
                checkpoint.resumeAfter = nil
                await Trading212HistorySyncStore.shared.save(checkpoint, for: checkpointKey)
                return HistoricalOrdersResult(
                    transactions: checkpoint.orders.map(\.transaction).sorted { $0.date < $1.date },
                    isComplete: true,
                    cachedCount: checkpoint.orders.count,
                    status: nil
                )
            }
            guard let path = page.nextPagePath,
                  let resolved = URL(string: path, relativeTo: environment.baseURL)?.absoluteURL else {
                checkpoint.nextPagePath = nil
                checkpoint.resumeAfter = nil
                await Trading212HistorySyncStore.shared.save(checkpoint, for: checkpointKey)
                return HistoricalOrdersResult(
                    transactions: checkpoint.orders.map(\.transaction).sorted { $0.date < $1.date },
                    isComplete: false,
                    cachedCount: checkpoint.orders.count,
                    status: "已缓存 \(checkpoint.orders.count) 笔成交，下次同步会继续"
                )
            }
            checkpoint.nextPagePath = path
            checkpoint.resumeAfter = nil
            await Trading212HistorySyncStore.shared.save(checkpoint, for: checkpointKey)
            nextURL = resolved
        }
        checkpoint.resumeAfter = Date().addingTimeInterval(61)
        await Trading212HistorySyncStore.shared.save(checkpoint, for: checkpointKey)
        return HistoricalOrdersResult(
            transactions: checkpoint.orders.map(\.transaction).sorted { $0.date < $1.date },
            isComplete: false,
            cachedCount: checkpoint.orders.count,
            status: "已缓存 \(checkpoint.orders.count) 笔成交，为避免 Trading 212 限流，稍后再继续"
        )
    }

    private func fetchDividendHistory(
        credentials: Trading212Credentials,
        environment: Trading212Environment,
        accountSlot: Int,
        accountCurrency: String
    ) async throws -> HistoricalOrdersResult {
        let checkpointKey = Self.dividendCheckpointKey(
            credentials: credentials,
            environment: environment,
            accountSlot: accountSlot
        )
        var checkpoint = await Trading212DividendSyncStore.shared.checkpoint(for: checkpointKey)
        if let resumeAfter = checkpoint.resumeAfter, resumeAfter > Date() {
            return HistoricalOrdersResult(
                transactions: checkpoint.dividends.map(\.transaction).sorted { $0.date < $1.date },
                isComplete: false,
                cachedCount: checkpoint.dividends.count,
                status: "分红历史稍后继续"
            )
        }

        let initialURL = environment.baseURL
            .appendingPathComponent("equity/history/dividends")
            .appending(queryItems: [URLQueryItem(name: "limit", value: "50")])
        let isContinuing = checkpoint.nextPagePath?.isEmpty == false
        if !isContinuing, checkpoint.hasCompleteBaseline {
            checkpoint.refreshBoundaryKeys = Set(checkpoint.dividends.map(\.key))
        }
        let isRefreshingBaseline = !checkpoint.refreshBoundaryKeys.isEmpty
        var nextURL: URL
        if let path = checkpoint.nextPagePath,
           let resolved = URL(string: path, relativeTo: environment.baseURL)?.absoluteURL {
            nextURL = resolved
        } else {
            nextURL = initialURL
        }
        var dividendsByKey = Dictionary(uniqueKeysWithValues: checkpoint.dividends.map { ($0.key, $0) })
        var reachedExistingBaseline = false

        for _ in 0..<6 {
            let (data, response) = try await authenticatedGET(
                url: nextURL,
                credentials: credentials
            )
            guard let http = response as? HTTPURLResponse else { throw Trading212Error.invalidResponse }
            if http.statusCode == 401 || http.statusCode == 403 { throw Trading212Error.authorizationFailed }
            guard (200..<300).contains(http.statusCode) else {
                throw Trading212Error.http(http.statusCode, Self.serviceMessage(from: data))
            }
            let page = try JSONDecoder().decode(HistoricalDividendsPage.self, from: data)
            for item in page.items {
                guard let paidOn = item.paidOn,
                      let amount = item.amount, amount != 0,
                      let rawTicker = item.instrument?.ticker ?? item.ticker,
                      !rawTicker.isEmpty else { continue }
                let quantity = max(abs(item.quantity ?? 0), 1)
                // `amount` is in the account currency while
                // `grossAmountPerShare` is in the instrument currency. Store
                // the exact paid account-currency amount in our quantity ×
                // price transaction model.
                let unitAmount = abs(amount) / quantity
                let reference = item.reference?.trimmingCharacters(in: .whitespacesAndNewlines)
                let transaction = Trading212Transaction(
                    accountSlot: accountSlot,
                    date: String(paidOn.prefix(10)),
                    executedAt: paidOn,
                    action: "DIVIDEND",
                    ticker: Trading212Position.catfolioTicker(rawTicker),
                    quantity: quantity,
                    price: unitAmount,
                    currency: item.currency?.uppercased() ?? accountCurrency
                )
                let key = (reference?.isEmpty == false)
                    ? reference!
                    : Self.transactionKey(transaction, filledAt: paidOn)
                if isRefreshingBaseline, checkpoint.refreshBoundaryKeys.contains(key) {
                    reachedExistingBaseline = true
                }
                dividendsByKey[key] = Trading212CachedDividend(key: key, transaction: transaction)
            }

            checkpoint.dividends = Array(dividendsByKey.values)
            checkpoint.updatedAt = Date()
            if reachedExistingBaseline || page.nextPagePath?.isEmpty != false {
                checkpoint.nextPagePath = nil
                checkpoint.hasCompleteBaseline = true
                checkpoint.refreshBoundaryKeys = []
                checkpoint.resumeAfter = nil
                await Trading212DividendSyncStore.shared.save(checkpoint, for: checkpointKey)
                return HistoricalOrdersResult(
                    transactions: checkpoint.dividends.map(\.transaction).sorted { $0.date < $1.date },
                    isComplete: true,
                    cachedCount: checkpoint.dividends.count,
                    status: nil
                )
            }
            guard let path = page.nextPagePath,
                  let resolved = URL(string: path, relativeTo: environment.baseURL)?.absoluteURL else {
                checkpoint.nextPagePath = nil
                await Trading212DividendSyncStore.shared.save(checkpoint, for: checkpointKey)
                return HistoricalOrdersResult(
                    transactions: checkpoint.dividends.map(\.transaction).sorted { $0.date < $1.date },
                    isComplete: false,
                    cachedCount: checkpoint.dividends.count,
                    status: "已缓存 \(checkpoint.dividends.count) 笔分红，稍后继续"
                )
            }
            checkpoint.nextPagePath = path
            checkpoint.resumeAfter = nil
            await Trading212DividendSyncStore.shared.save(checkpoint, for: checkpointKey)
            nextURL = resolved
        }
        checkpoint.resumeAfter = Date().addingTimeInterval(61)
        await Trading212DividendSyncStore.shared.save(checkpoint, for: checkpointKey)
        return HistoricalOrdersResult(
            transactions: checkpoint.dividends.map(\.transaction).sorted { $0.date < $1.date },
            isComplete: false,
            cachedCount: checkpoint.dividends.count,
            status: "已缓存 \(checkpoint.dividends.count) 笔分红，稍后继续"
        )
    }

    /// Trading 212 omits realised results and interest from its lightweight
    /// endpoints. The official activity export is the source of truth, so this
    /// persists request/check/download state and retrieves at most one
    /// broker-supported 365-day period per cycle.
    private func fetchInterestHistory(
        credentials: Trading212Credentials,
        environment: Trading212Environment,
        accountSlot: Int,
        accountCurrency: String,
        oldestOrderDate: String?,
        hasCompleteOrderHistory: Bool
    ) async throws -> HistoricalOrdersResult {
        let checkpointKey = Self.interestCheckpointKey(
            credentials: credentials,
            environment: environment,
            accountSlot: accountSlot
        )
        var checkpoint = await Trading212InterestSyncStore.shared.checkpoint(for: checkpointKey)
        let cached = {
            checkpoint.interests.map(\.transaction).sorted { $0.date < $1.date }
        }

        let hasCompleteBaseline = checkpoint.hasCompleteBaseline ?? false
        if hasCompleteBaseline,
           checkpoint.pendingReportID == nil,
           checkpoint.nextPeriodEnd == nil,
           let completedAt = checkpoint.lastCompletedAt,
           Date().timeIntervalSince(completedAt) < 24 * 60 * 60 {
            return HistoricalOrdersResult(
                transactions: cached(),
                isComplete: true,
                cachedCount: checkpoint.interests.count,
                status: nil
            )
        }
        if let retryAt = checkpoint.nextCheckAfter, retryAt > Date() {
            return HistoricalOrdersResult(
                transactions: cached(),
                isComplete: false,
                cachedCount: checkpoint.interests.count,
                status: checkpoint.pendingReportID == nil
                    ? "券商结算报表稍后重试"
                    : "券商结算报表生成中"
            )
        }

        if checkpoint.pendingReportID == nil {
            let now = Date()
            let oldest = oldestOrderDate.flatMap(DayDateCodec.date(from:))
                ?? Calendar(identifier: .gregorian).date(byAdding: .year, value: -1, to: now)!
            let periodEnd = hasCompleteBaseline ? now : (checkpoint.nextPeriodEnd ?? now)
            let proposedStart = Calendar(identifier: .gregorian).date(
                byAdding: .day,
                value: -364,
                to: periodEnd
            ) ?? oldest
            let periodStart = max(proposedStart, oldest)
            checkpoint.pendingReportID = try await requestInterestReport(
                credentials: credentials,
                environment: environment,
                periodStart: periodStart,
                periodEnd: periodEnd
            )
            checkpoint.currentPeriodStart = periodStart
            checkpoint.currentPeriodEnd = periodEnd
            checkpoint.nextCheckAfter = nil
            await Trading212InterestSyncStore.shared.save(checkpoint, for: checkpointKey)
            // A small first check catches the normal fast path without
            // repeatedly polling the one-request-per-minute reports endpoint.
            try await Task.sleep(for: .seconds(2))
        }

        guard let reportID = checkpoint.pendingReportID else {
            return HistoricalOrdersResult(
                transactions: cached(),
                isComplete: true,
                cachedCount: checkpoint.interests.count,
                status: nil
            )
        }
        let reports = try await listInterestReports(
            credentials: credentials,
            environment: environment
        )
        guard let report = reports.first(where: { $0.reportId == reportID }) else {
            checkpoint.nextCheckAfter = Date().addingTimeInterval(61)
            await Trading212InterestSyncStore.shared.save(checkpoint, for: checkpointKey)
            return HistoricalOrdersResult(
                transactions: cached(),
                isComplete: false,
                cachedCount: checkpoint.interests.count,
                status: "券商结算报表生成中"
            )
        }

        switch report.status.lowercased() {
        case "finished":
            guard let link = report.downloadLink,
                  let url = URL(string: link), url.scheme?.lowercased() == "https" else {
                throw Trading212Error.invalidResponse
            }
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                throw Trading212Error.invalidResponse
            }
            let parsed = try Self.parseActivityReport(
                data,
                accountSlot: accountSlot,
                fallbackCurrency: accountCurrency
            )
            let merged = Dictionary(
                (checkpoint.interests + parsed.interests).map { ($0.key, $0) },
                uniquingKeysWith: { _, newest in newest }
            )
            checkpoint.interests = Array(merged.values)
            let reportedOrders = Dictionary(
                ((checkpoint.reportedOrders ?? []) + parsed.orders).map {
                    (Self.reportedOrderKey($0.transaction), $0)
                },
                uniquingKeysWith: { _, newest in newest }
            )
            checkpoint.reportedOrders = Array(reportedOrders.values)

            let oldest = oldestOrderDate.flatMap(DayDateCodec.date(from:))
            let periodStart = checkpoint.currentPeriodStart
            if hasCompleteBaseline || (
                hasCompleteOrderHistory
                    && (oldest == nil || periodStart == nil || periodStart! <= oldest!)
            ) {
                checkpoint.hasCompleteBaseline = true
                checkpoint.nextPeriodEnd = nil
            } else {
                checkpoint.hasCompleteBaseline = false
                checkpoint.nextPeriodEnd = periodStart!.addingTimeInterval(-1)
            }
            checkpoint.pendingReportID = nil
            checkpoint.nextCheckAfter = nil
            checkpoint.lastCompletedAt = Date()
            checkpoint.currentPeriodStart = nil
            checkpoint.currentPeriodEnd = nil
            await Trading212InterestSyncStore.shared.save(checkpoint, for: checkpointKey)
            let isComplete = checkpoint.hasCompleteBaseline == true
            return HistoricalOrdersResult(
                transactions: checkpoint.interests.map(\.transaction).sorted { $0.date < $1.date },
                isComplete: isComplete,
                cachedCount: checkpoint.interests.count,
                status: isComplete ? nil : "已同步部分券商结算结果，稍后继续补齐"
            )
        case "failed", "canceled":
            checkpoint.pendingReportID = nil
            checkpoint.nextCheckAfter = Date().addingTimeInterval(5 * 60)
            await Trading212InterestSyncStore.shared.save(checkpoint, for: checkpointKey)
            return HistoricalOrdersResult(
                transactions: cached(),
                isComplete: false,
                cachedCount: checkpoint.interests.count,
                status: "券商结算报表生成失败，稍后重试"
            )
        default:
            checkpoint.nextCheckAfter = Date().addingTimeInterval(61)
            await Trading212InterestSyncStore.shared.save(checkpoint, for: checkpointKey)
            return HistoricalOrdersResult(
                transactions: cached(),
                isComplete: false,
                cachedCount: checkpoint.interests.count,
                status: "券商结算报表生成中"
            )
        }
    }

    private func requestInterestReport(
        credentials: Trading212Credentials,
        environment: Trading212Environment,
        periodStart: Date,
        periodEnd: Date
    ) async throws -> Int64 {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let body = InterestReportRequest(
            timeFrom: formatter.string(from: periodStart),
            timeTo: formatter.string(from: periodEnd)
        )
        let url = environment.baseURL.appendingPathComponent("equity/history/exports")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpBody = try JSONEncoder().encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("CatfolioIOS/1.0", forHTTPHeaderField: "User-Agent")
        let token = Data("\(credentials.apiKey):\(credentials.apiSecret)".utf8).base64EncodedString()
        request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Trading212Error.invalidResponse }
        if http.statusCode == 401 || http.statusCode == 403 { throw Trading212Error.authorizationFailed }
        guard (200..<300).contains(http.statusCode) else {
            throw Trading212Error.http(http.statusCode, Self.serviceMessage(from: data))
        }
        return try JSONDecoder().decode(EnqueuedInterestReport.self, from: data).reportId
    }

    private func listInterestReports(
        credentials: Trading212Credentials,
        environment: Trading212Environment
    ) async throws -> [InterestReport] {
        let url = environment.baseURL.appendingPathComponent("equity/history/exports")
        let (data, response) = try await authenticatedGET(url: url, credentials: credentials)
        guard let http = response as? HTTPURLResponse else { throw Trading212Error.invalidResponse }
        if http.statusCode == 401 || http.statusCode == 403 { throw Trading212Error.authorizationFailed }
        guard (200..<300).contains(http.statusCode) else {
            throw Trading212Error.http(http.statusCode, Self.serviceMessage(from: data))
        }
        return try JSONDecoder().decode([InterestReport].self, from: data)
    }

    private struct ParsedActivityReport {
        let interests: [Trading212CachedInterest]
        let orders: [Trading212ReportedOrder]
    }

    private static func parseActivityReport(
        _ data: Data,
        accountSlot: Int,
        fallbackCurrency: String
    ) throws -> ParsedActivityReport {
        guard let text = LocalCSVImporter.decodedText(from: data) else {
            throw Trading212Error.invalidResponse
        }
        let records = LocalCSVImporter.parseRecords(text)
        guard let headerOffset = records.prefix(25).firstIndex(where: { row in
            let headers = row.map(reportHeader)
            return headers.contains("action") && (headers.contains("time") || headers.contains("date"))
        }) else { throw Trading212Error.invalidResponse }
        let headers = records[headerOffset].map(reportHeader)

        func index(_ names: [String]) -> Int? {
            names.compactMap { headers.firstIndex(of: $0) }.first
        }
        guard let actionIndex = index(["action", "type"]),
              let dateIndex = index(["time", "date", "date time", "datetime"]) else {
            throw Trading212Error.invalidResponse
        }
        let totalIndex = index(["total", "amount"])
        let totalCurrencyIndex = index(["currency total", "currency amount", "currency"])
        let tickerIndex = index(["ticker", "symbol"])
        let quantityIndex = index(["no of shares", "quantity", "qty"])
        let priceIndex = index(["price share", "price per share", "price"])
        let priceCurrencyIndex = index(["currency price share", "currency price per share"])
        let resultIndex = index(["result", "realised profit loss", "realized profit loss"])
        let resultCurrencyIndex = index(["currency result"])
        let referenceIndex = index(["id", "reference"])
        var interests: [Trading212CachedInterest] = []
        var orders: [Trading212ReportedOrder] = []

        for row in records.dropFirst(headerOffset + 1) {
            func field(_ position: Int?) -> String {
                guard let position, row.indices.contains(position) else { return "" }
                return row[position].trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let action = field(actionIndex).lowercased()
            let dateText = field(dateIndex)
            guard let date = LocalCSVImporter.parsedDate(dateText) else { continue }
            let reference = field(referenceIndex)
            if action.contains("interest") {
                guard let amount = LocalCSVImporter.numericValue(field(totalIndex)), amount != 0 else {
                    continue
                }
                let currency = field(totalCurrencyIndex).uppercased()
                let transaction = Trading212Transaction(
                    accountSlot: accountSlot,
                    date: DayDateCodec.string(from: date),
                    executedAt: dateText,
                    action: "INTEREST",
                    ticker: "CASH",
                    quantity: 1,
                    price: amount,
                    currency: currency.isEmpty ? fallbackCurrency : currency,
                    reference: reference.isEmpty ? nil : reference
                )
                let key = reference.isEmpty
                    ? transactionKey(transaction, filledAt: dateText)
                    : reference
                interests.append(Trading212CachedInterest(key: key, transaction: transaction))
                continue
            }

            let side: String
            if action.contains("sell") {
                side = "SELL"
            } else if action.contains("buy") {
                side = "BUY"
            } else {
                continue
            }
            guard let quantity = LocalCSVImporter.numericValue(field(quantityIndex)), quantity != 0,
                  let price = LocalCSVImporter.numericValue(field(priceIndex)), price > 0 else {
                continue
            }
            let rawTicker = field(tickerIndex)
            guard !rawTicker.isEmpty else { continue }
            let priceCurrency = field(priceCurrencyIndex).uppercased()
            let realised = side == "SELL"
                ? LocalCSVImporter.numericValue(field(resultIndex))
                : nil
            let resultCurrency = field(resultCurrencyIndex).uppercased()
            orders.append(Trading212ReportedOrder(transaction: Trading212Transaction(
                accountSlot: accountSlot,
                date: DayDateCodec.string(from: date),
                executedAt: dateText,
                action: side,
                ticker: Trading212Position.catfolioTicker(rawTicker),
                quantity: abs(quantity),
                price: price,
                currency: priceCurrency.isEmpty
                    ? Trading212Position.currency(nil, rawTicker: rawTicker)
                    : priceCurrency,
                reference: reference.isEmpty ? nil : reference,
                realisedProfitLoss: realised,
                realisedProfitLossCurrency: realised == nil
                    ? nil
                    : (resultCurrency.isEmpty ? fallbackCurrency : resultCurrency)
            )))
        }
        return ParsedActivityReport(interests: interests, orders: orders)
    }

    /// Enrich lightweight order fills with the report's native price currency
    /// and exact broker Result. A report row is consumed at most once so two
    /// equal fills on the same day do not share one realised value.
    private static func applyingBrokerReport(
        _ reported: [Trading212Transaction],
        to orders: [Trading212Transaction]
    ) -> [Trading212Transaction] {
        var unmatched = reported
        return orders.map { order in
            guard order.action == "BUY" || order.action == "SELL" else { return order }
            let candidates = unmatched.indices.filter { index in
                let report = unmatched[index]
                return report.accountSlot == order.accountSlot
                    && report.date == order.date
                    && report.action == order.action
                    && comparableTicker(report.ticker) == comparableTicker(order.ticker)
            }
            guard let match = candidates.min(by: { left, right in
                reportDistance(unmatched[left], order) < reportDistance(unmatched[right], order)
            }) else { return order }
            let report = unmatched[match]
            let quantityTolerance = max(0.000_01, abs(order.quantity) * 0.000_1)
            let priceTolerance = max(0.02, abs(order.price) * 0.000_1)
            guard abs(report.quantity - order.quantity) <= quantityTolerance,
                  abs(report.price - order.price) <= priceTolerance else { return order }
            unmatched.remove(at: match)
            return Trading212Transaction(
                accountSlot: order.accountSlot,
                date: order.date,
                executedAt: order.executedAt,
                action: order.action,
                ticker: order.ticker,
                quantity: order.quantity,
                price: order.price,
                currency: report.currency,
                reference: order.reference,
                realisedProfitLoss: report.realisedProfitLoss,
                realisedProfitLossCurrency: report.realisedProfitLossCurrency
            )
        }
    }

    private static func reportDistance(
        _ report: Trading212Transaction,
        _ order: Trading212Transaction
    ) -> Double {
        abs(report.quantity - order.quantity) / max(abs(order.quantity), 0.000_001)
            + abs(report.price - order.price) / max(abs(order.price), 0.000_001)
    }

    private static func comparableTicker(_ value: String) -> String {
        let uppercased = value.uppercased()
        for suffix in [".L", ".DE", ".AS", ".PA", ".MI", ".SW"] where uppercased.hasSuffix(suffix) {
            return String(uppercased.dropLast(suffix.count))
        }
        return uppercased
    }

    private static func reportedOrderKey(_ transaction: Trading212Transaction) -> String {
        [
            String(transaction.accountSlot),
            transaction.reference ?? "",
            transaction.date,
            transaction.action,
            comparableTicker(transaction.ticker),
            String(format: "%.8f", transaction.quantity),
            String(format: "%.8f", transaction.price),
        ].joined(separator: "|")
    }

    private static func reportHeader(_ value: String) -> String {
        let folded = value
            .replacingOccurrences(of: "\u{feff}", with: "")
            .replacingOccurrences(of: "\u{00a0}", with: " ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
        return folded.unicodeScalars.map { scalar -> String in
            CharacterSet.alphanumerics.contains(scalar) ? String(scalar) : " "
        }.joined().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private func authenticatedGET(
        url: URL,
        credentials: Trading212Credentials
    ) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("CatfolioIOS/1.0", forHTTPHeaderField: "User-Agent")
        let token = Data("\(credentials.apiKey):\(credentials.apiSecret)".utf8).base64EncodedString()
        request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        return try await session.data(for: request)
    }

    private static func historyCheckpointKey(
        credentials: Trading212Credentials,
        environment: Trading212Environment,
        accountSlot: Int
    ) -> String {
        // v3 invalidates checkpoints that mislabeled fill prices with the
        // account currency instead of the instrument's quote currency.
        let source = "v3:\(environment.rawValue):\(accountSlot):\(credentials.apiKey)"
        let digest = SHA256.hash(data: Data(source.utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private static func dividendCheckpointKey(
        credentials: Trading212Credentials,
        environment: Trading212Environment,
        accountSlot: Int
    ) -> String {
        let source = "v1:\(environment.rawValue):\(accountSlot):\(credentials.apiKey)"
        let digest = SHA256.hash(data: Data(source.utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private static func interestCheckpointKey(
        credentials: Trading212Credentials,
        environment: Trading212Environment,
        accountSlot: Int
    ) -> String {
        let source = "v1:\(environment.rawValue):\(accountSlot):\(credentials.apiKey)"
        let digest = SHA256.hash(data: Data(source.utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private static func transactionKey(_ transaction: Trading212Transaction, filledAt: String) -> String {
        let canonicalTime = String(
            filledAt.replacingOccurrences(of: " ", with: "T").prefix(19)
        )
        return [
            canonicalTime,
            transaction.action,
            transaction.ticker,
            String(transaction.quantity),
            String(transaction.price),
            transaction.currency,
        ].joined(separator: "|")
    }

    private func fetchPositions(
        credentials: Trading212Credentials,
        environment: Trading212Environment
    ) async throws -> [Trading212Position] {
        do {
            return try await requestPositions(
                path: "equity/positions",
                credentials: credentials,
                environment: environment
            )
        } catch let Trading212Error.http(code, _) where code == 404 {
            return try await requestPositions(
                path: "equity/portfolio",
                credentials: credentials,
                environment: environment
            )
        }
    }

    private struct AccountCurrencyPayload: Decodable {
        let currencyCode: String?
    }

    private func fetchAccountCurrency(
        credentials: Trading212Credentials,
        environment: Trading212Environment
    ) async throws -> String? {
        var lastError: Error?
        for path in ["equity/account/info", "equity/account/cash"] {
            do {
                if let currency = try await requestAccountCurrency(
                    path: path,
                    credentials: credentials,
                    environment: environment
                ) {
                    return currency
                }
            } catch {
                lastError = error
            }
        }
        if let lastError { throw lastError }
        return nil
    }

    private func requestAccountCurrency(
        path: String,
        credentials: Trading212Credentials,
        environment: Trading212Environment
    ) async throws -> String? {
        let url = environment.baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("CatfolioIOS/1.0", forHTTPHeaderField: "User-Agent")
        let token = Data("\(credentials.apiKey):\(credentials.apiSecret)".utf8).base64EncodedString()
        request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Trading212Error.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw Trading212Error.http(http.statusCode, Self.serviceMessage(from: data))
        }
        return try JSONDecoder().decode(AccountCurrencyPayload.self, from: data).currencyCode?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
    }

    private func requestPositions(
        path: String,
        credentials: Trading212Credentials,
        environment: Trading212Environment
    ) async throws -> [Trading212Position] {
        let url = environment.baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("CatfolioIOS/1.0", forHTTPHeaderField: "User-Agent")
        let token = Data("\(credentials.apiKey):\(credentials.apiSecret)".utf8).base64EncodedString()
        request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Trading212Error.invalidResponse }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw Trading212Error.authorizationFailed
        }
        guard (200..<300).contains(http.statusCode) else {
            throw Trading212Error.http(http.statusCode, Self.serviceMessage(from: data))
        }
        do {
            return try JSONDecoder().decode([Trading212Position].self, from: data)
        } catch {
            throw Trading212Error.invalidResponse
        }
    }

    private static func serviceMessage(from data: Data) -> String {
        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "服务暂时不可用"
        }
        return payload["message"] as? String
            ?? payload["error"] as? String
            ?? payload["code"] as? String
            ?? "服务暂时不可用"
    }
}

private extension KeyedDecodingContainer {
    func decodeLossyDoubleIfPresent(forKey key: Key) throws -> Double? {
        if let value = try? decodeIfPresent(Double.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(Int.self, forKey: key) { return Double(value) }
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return Double(value.replacingOccurrences(of: ",", with: ""))
        }
        return nil
    }
}
