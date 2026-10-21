import Foundation
import CryptoKit

/// Personal API credentials belong to this device's owner. Commercial app
/// secrets must never be bundled in the iOS application.
struct SnapTradeCredentials: Codable, Equatable {
    let clientID: String
    let consumerKey: String

    init(clientID: String, consumerKey: String) throws {
        let clientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let consumerKey = consumerKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientID.isEmpty, !consumerKey.isEmpty,
              clientID.count <= 4096, consumerKey.count <= 4096 else {
            throw SnapTradeError.credentials
        }
        self.clientID = clientID
        self.consumerKey = consumerKey
    }

    static func key(accountID: String?) -> String { "snaptrade.\(accountID ?? "pending").credentials" }

    func save(accountID: String?) throws {
        try KeychainStore.set(String(decoding: JSONEncoder().encode(self), as: UTF8.self), for: Self.key(accountID: accountID))
    }

    static func load(accountID: String?) -> Self? {
        guard let value = KeychainStore.string(for: key(accountID: accountID)) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: Data(value.utf8))
    }
}

enum SnapTradeError: LocalizedError {
    case credentials, network, malformed, accountUnavailable, syncing, disconnected, expired, duplicate, wrongAccount
    case http(Int)
    case rejected(status: Int, step: SnapTradeRequestStep, code: String?)
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .credentials: L10n.text("请填写 SnapTrade 个人 API 的 Client ID 和 Consumer Key。")
        case .network: L10n.text("无法连接 SnapTrade，请检查网络后重试。现有持仓已保留。")
        case .malformed: L10n.text("SnapTrade 返回的数据不完整，现有持仓已保留。")
        case .accountUnavailable: L10n.text("SnapTrade 尚未提供此账户的持仓，请检查授权。")
        case .syncing: L10n.text("SnapTrade 正在完成首次同步，请稍后重新读取。")
        case .disconnected: L10n.text("SnapTrade 券商连接已失效，请重新授权后读取。")
        case .expired: L10n.text("预览已过期，请重新读取持仓。")
        case .duplicate: L10n.text("此 SnapTrade 账户已存在，请在原账户中同步。")
        case .wrongAccount: L10n.text("请选择当前账户，其他账户请通过新建账户导入。")
        case .http(401), .http(403): L10n.text("SnapTrade 认证失败，请检查个人 API 凭证及权限。")
        case let .rejected(status, step, code):
            [L10n.text("SnapTrade 拒绝了「\(step.title)」请求（HTTP \(status)）。"),
             status == 401 && code == "1076"
                ? L10n.text("请求签名校验失败。现有数据已保留。")
                : status == 401
                ? L10n.text("认证信息未通过校验，请检查已保存的个人 API 凭证和设备时间。现有数据已保留。")
                : L10n.text("此请求未获准访问，请检查个人 API 凭证是否有效，以及该项数据的访问权限。现有数据已保留。"),
             code.map { L10n.text("SnapTrade 错误码：\($0)") }]
                .compactMap { $0 }.joined(separator: "\n")
        case .http(429): L10n.text("SnapTrade 请求过于频繁，请稍后重试。")
        case .http: L10n.text("SnapTrade 暂时无法读取，请稍后重试。现有持仓已保留。")
        case let .unsupported(symbol): L10n.text("\(symbol) 的资产类型、市场或成本数据暂不支持，未更新此账户。")
        }
    }
}

/// Fixed operation labels can be shown in an error without exposing account
/// IDs, signed URLs, credentials or provider response text.
enum SnapTradeRequestStep: Equatable {
    case accounts, account, connection, positions, activities, portal

    var title: String {
        switch self {
        case .accounts: L10n.text("读取账户列表")
        case .account: L10n.text("读取账户详情")
        case .connection: L10n.text("检查券商连接")
        case .positions: L10n.text("读取持仓")
        case .activities: L10n.text("读取交易历史")
        case .portal: L10n.text("生成授权链接")
        }
    }

    static func providerCode(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        // Only SnapTrade's four-digit error codes are safe to surface. Never
        // display the free-form detail/message, which can echo request data.
        let value = object["code"] ?? object["error_code"]
        let code: String
        if let string = value as? String { code = string }
        else if let number = value as? NSNumber { code = number.stringValue }
        else { return nil }
        guard code.count == 4, code.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return code
    }
}

struct SnapTradeAccount: Decodable, Identifiable, Equatable {
    let id: String
    let brokerage_authorization: String
    let name: String?
    let number: String
    let institution_name: String
    let sync_status: SyncStatus
    let balance: Balance

    struct SyncStatus: Decodable, Equatable {
        let holdings: Holdings
        let transactions: Transactions?
        struct Transactions: Decodable, Equatable {
            let initial_sync_completed: Bool
        }
        struct Holdings: Decodable, Equatable {
            let initial_sync_completed: Bool
            let holdings_unavailable: Bool?
        }
    }
    struct Balance: Decodable, Equatable {
        let total: Total?
        struct Total: Decodable, Equatable { let currency: String? }
    }
    var displayName: String { "\(institution_name) · \(name ?? "") · ••••\(number.suffix(4))" }

    func validate() throws {
        guard UUID(uuidString: id) != nil, UUID(uuidString: brokerage_authorization) != nil else { throw SnapTradeError.malformed }
        guard sync_status.holdings.holdings_unavailable != true else { throw SnapTradeError.accountUnavailable }
        guard sync_status.holdings.initial_sync_completed else { throw SnapTradeError.syncing }
        guard let currency = balance.total?.currency, !currency.isEmpty else { throw SnapTradeError.malformed }
    }
}

struct SnapTradeSnapshot {
    let account: SnapTradeAccount
    let positions: [LocalPositionRecord]
    let asOf: Date
    let fetchedAt: Date
    var transactions: [LocalTransactionRecord] = []
    var skippedActivities: Int = 0

    var warnings: [String] {
        skippedActivities == 0 ? [] : [L10n.text("部分买卖记录的证券类型或市场暂不支持，未导入这些记录。")]
    }

    func validate(context: AccountConnectorContext, existing: [PortfolioAccount], now: Date = Date()) throws {
        guard now.timeIntervalSince(fetchedAt) < 900 else { throw SnapTradeError.expired }
        if let current = context.account {
            guard current.source == "SnapTrade", current.accountID == account.id else { throw SnapTradeError.wrongAccount }
        } else if existing.contains(where: { $0.source == "SnapTrade" && $0.accountID == account.id }) {
            throw SnapTradeError.duplicate
        }
    }

    func portfolioAccount(name: String) -> PortfolioAccount {
        PortfolioAccount(id: "SnapTrade|\(account.id)", accountID: account.id, source: "SnapTrade", name: name,
                         baseCurrency: account.balance.total?.currency ?? "", positionCount: positions.count,
                         transactionCount: transactions.count, manualTransactionCount: 0, hasCSVImport: false, marketValueUSD: 0)
    }
}

struct SnapTradeDecimal: Decodable {
    let value: Double
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self), let number = Double(string) { value = number }
        else { value = try container.decode(Double.self) }
        guard value.isFinite else { throw SnapTradeError.malformed }
    }
}

struct SnapTradePositions: Decodable {
    private let results: [Position]
    private let data_freshness: Freshness
    private struct Freshness: Decodable { let as_of: String }
    private struct Position: Decodable {
        let instrument: Instrument
        let units: SnapTradeDecimal?
        let price: SnapTradeDecimal?
        let cost_basis: SnapTradeDecimal?
        let currency: String?
        struct Instrument: Decodable {
            let kind: String
            let symbol: String?
            let raw_symbol: String?
            let description: String?
            let exchange: String?
        }
    }

    func snapshot(account: SnapTradeAccount, now: Date = Date()) throws -> SnapTradeSnapshot {
        try account.validate()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: data_freshness.as_of) ?? ISO8601DateFormatter().date(from: data_freshness.as_of)
        guard let date, date <= now.addingTimeInterval(300) else { throw SnapTradeError.malformed }
        var seen = Set<String>()
        let positions = try results.compactMap { row -> LocalPositionRecord? in
            guard let units = row.units?.value else { throw SnapTradeError.malformed }
            if units == 0 { return nil }
            let instrument = row.instrument
            let label = instrument.symbol ?? instrument.kind
            guard units > 0, ["stock", "adr", "etf", "cef", "mutualfund"].contains(instrument.kind),
                  let raw = instrument.raw_symbol, !raw.isEmpty,
                  let exchange = instrument.exchange,
                  let average = row.cost_basis?.value, average >= 0,
                  let price = row.price?.value, price >= 0,
                  let rawCurrency = row.currency, !rawCurrency.isEmpty,
                  (units * price).isFinite, (units * average).isFinite else { throw SnapTradeError.unsupported(label) }
            let currency = rawCurrency == "GBp" ? "GBX" : rawCurrency.uppercased()
            // Use exchange-qualified quote symbols; never turn a foreign
            // listing into the US security with the same raw ticker.
            let symbol = try SnapTradeSecurity.ticker(raw: raw, exchange: exchange)
            guard seen.insert(symbol).inserted else { throw SnapTradeError.malformed }
            // Validate valuation support before allowing any account write.
            _ = try LocalPortfolioEngine.usd(1, currency: currency)
            return LocalPositionRecord(ticker: symbol, name: instrument.description ?? raw,
                shares: units, averageCost: average, currency: currency,
                quotePrice: price, quoteCurrency: currency, source: "SnapTrade", openedDate: nil,
                accountID: account.id, accountName: account.displayName,
                accountCurrency: account.balance.total?.currency, fxPnlStatus: "unavailable",
                quoteObservedAt: date)
        }
        return SnapTradeSnapshot(account: account, positions: positions, asOf: date, fetchedAt: now)
    }
}

/// Reject redirects so a signed request can never forward auth to another host.
private final class SnapTradeRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct SnapTradeClient {
    private let session: URLSession
    private static let defaultSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        return URLSession(configuration: config, delegate: SnapTradeRedirectPolicy(), delegateQueue: nil)
    }()
    init(session: URLSession? = nil) {
        self.session = session ?? Self.defaultSession
    }

    static func request(path: String, credentials: SnapTradeCredentials, body: [String: String]? = nil,
                        query: [URLQueryItem] = [], pathPrefix: String = "/api/v1",
                        now: Date = Date()) throws -> URLRequest {
        var components = URLComponents(string: "https://api.snaptrade.com" + pathPrefix + path)!
        let items = [URLQueryItem(name: "clientId", value: credentials.clientID),
                     URLQueryItem(name: "timestamp", value: String(Int(now.timeIntervalSince1970)))] + query
        // Match the official SDK's URLSearchParams encoding. URLComponents'
        // default leaves commas and '+' literal, which differs for BUY,SELL
        // and can change the query bytes checked by the signing gateway.
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789*-._")
        func encode(_ value: String) -> String {
            value.addingPercentEncoding(withAllowedCharacters: allowed)!.replacingOccurrences(of: "%20", with: "+")
        }
        components.percentEncodedQuery = items.map { encode($0.name) + "=" + encode($0.value ?? "") }.joined(separator: "&")
        let payload: [String: Any] = ["content": body as Any? ?? NSNull(), "path": pathPrefix + path,
                                      "query": components.percentEncodedQuery!]
        let canonical = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes])
        let signature = HMAC<SHA256>.authenticationCode(for: canonical, using: SymmetricKey(data: Data(credentials.consumerKey.utf8)))
        var request = URLRequest(url: components.url!)
        request.httpMethod = body == nil ? "GET" : "POST"
        request.httpBody = try body.map { try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys, .withoutEscapingSlashes]) }
        request.setValue(Data(signature).base64EncodedString(), forHTTPHeaderField: "Signature")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    private func fetch<T: Decodable>(_ type: T.Type, path: String, credentials: SnapTradeCredentials,
                                     step: SnapTradeRequestStep,
                                     body: [String: String]? = nil, query: [URLQueryItem] = [],
                                     pathPrefix: String = "/api/v1") async throws -> T {
        try Task.checkCancellation()
        let request = try Self.request(path: path, credentials: credentials, body: body, query: query, pathPrefix: pathPrefix)
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.recordedData(for: request) }
        catch { if Task.isCancelled { throw CancellationError() }; throw SnapTradeError.network }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw SnapTradeError.network }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw SnapTradeError.rejected(status: http.statusCode, step: step,
                code: SnapTradeRequestStep.providerCode(from: data))
        }
        guard (200..<300).contains(http.statusCode) else { throw SnapTradeError.http(http.statusCode) }
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw SnapTradeError.malformed }
    }

    func accounts(credentials: SnapTradeCredentials) async throws -> [SnapTradeAccount] {
        try await fetch([SnapTradeAccount].self, path: "/accounts", credentials: credentials, step: .accounts)
    }

    func portal(credentials: SnapTradeCredentials, reconnect: String? = nil) async throws -> URL {
        struct Portal: Decodable { let redirectURI: String }
        var body = ["connectionType": "read"]
        if let reconnect { body["reconnect"] = reconnect }
        let result = try await fetch(Portal.self, path: "/snapTrade/login", credentials: credentials, step: .portal, body: body)
        guard let url = URL(string: result.redirectURI), url.scheme == "https", url.host == "app.snaptrade.com",
              url.user == nil, url.password == nil else { throw SnapTradeError.malformed }
        return url
    }

    func snapshot(accountID: String, credentials: SnapTradeCredentials) async throws -> SnapTradeSnapshot {
        guard UUID(uuidString: accountID) != nil else { throw SnapTradeError.malformed }
        let account = try await fetch(SnapTradeAccount.self, path: "/accounts/\(accountID)", credentials: credentials, step: .account)
        guard account.id == accountID else { throw SnapTradeError.wrongAccount }
        try account.validate()
        guard account.sync_status.transactions?.initial_sync_completed != false else { throw SnapTradeError.syncing }
        struct Connection: Decodable { let disabled: Bool }
        let connection = try await fetch(Connection.self, path: "/authorizations/\(account.brokerage_authorization)", credentials: credentials, step: .connection)
        guard !connection.disabled else { throw SnapTradeError.disconnected }
        let positions = try await fetch(SnapTradePositions.self, path: "/accounts/\(accountID)/positions/all", credentials: credentials, step: .positions)
        var snapshot = try positions.snapshot(account: account)
        let history = try await activities(account: account, credentials: credentials)
        snapshot.transactions = history.transactions
        snapshot.skippedActivities = history.skipped
        return snapshot
    }

    func activities(account: SnapTradeAccount, credentials: SnapTradeCredentials) async throws -> SnapTradeActivityHistory {
        guard UUID(uuidString: account.id) != nil else { throw SnapTradeError.malformed }
        var history = SnapTradeActivityHistory()
        var offset = 0
        var expectedTotal: Int?
        var seen = Set<String>()
        var pathPrefix = ""
        while true {
            let query = [URLQueryItem(name: "type", value: "BUY,SELL"),
                URLQueryItem(name: "offset", value: String(offset)), URLQueryItem(name: "limit", value: "1000")]
            let page: SnapTradeActivityPage
            do {
                page = try await fetch(SnapTradeActivityPage.self, path: "/accounts/\(account.id)/activities",
                    credentials: credentials, step: .activities, query: query, pathPrefix: pathPrefix)
            } catch let error as SnapTradeError {
                // The preceding account reads use the legacy route. Allow that
                // same compatibility route once for an explicit signature
                // rejection of the canonical route; do not retry credentials,
                // permissions, rate limits or other failures. Keep later pages
                // on the same working route, with a fresh matching signature.
                guard case let .rejected(status, step, code) = error,
                      status == 401, step == .activities, code == "1076", pathPrefix.isEmpty else { throw error }
                pathPrefix = "/api/v1"
                page = try await fetch(SnapTradeActivityPage.self, path: "/accounts/\(account.id)/activities",
                    credentials: credentials, step: .activities, query: query, pathPrefix: pathPrefix)
            }
            let pagination = page.pagination
            guard pagination.offset == offset, (1...1000).contains(pagination.limit),
                  page.data.count <= pagination.limit, pagination.total >= offset,
                  page.data.count <= pagination.total - offset,
                  expectedTotal == nil || expectedTotal == pagination.total else { throw SnapTradeError.malformed }
            expectedTotal = pagination.total
            for activity in page.data {
                // Reject repeated pages/IDs rather than accepting a truncated history.
                guard !activity.id.isEmpty, seen.insert(activity.id).inserted else { throw SnapTradeError.malformed }
                if let row = try activity.transaction(account: account) { history.transactions.append(row) }
                else if activity.isTrade { history.skipped += 1 }
            }
            offset += page.data.count
            if offset == pagination.total { break }
            guard !page.data.isEmpty else { throw SnapTradeError.malformed }
        }
        history.transactions = LocalTransactionRecord.orderedForLotMatching(history.transactions)
        return history
    }
}
