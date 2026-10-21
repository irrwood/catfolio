import Foundation
import CryptoKit

enum DirectBroker: String, Codable, CaseIterable, Sendable {
    case longbridge, alpaca
    var title: String { self == .longbridge ? "Longbridge" : "Alpaca" }
}

enum AlpacaEnvironment: String, Codable, CaseIterable, Identifiable, Sendable {
    case live, paper
    var id: String { rawValue }
    var title: String { L10n.text(self == .live ? "实盘" : "模拟盘") }
    var host: String { self == .live ? "api.alpaca.markets" : "paper-api.alpaca.markets" }
}

struct DirectBrokerCredentials: Codable, Equatable, Sendable {
    let broker: DirectBroker
    let key: String
    let secret: String
    let token: String
    let environment: AlpacaEnvironment

    init(broker: DirectBroker, key: String, secret: String, token: String = "",
         environment: AlpacaEnvironment = .live) {
        self.broker = broker
        self.key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        self.secret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        self.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        self.environment = broker == .alpaca ? environment : .live
    }
    var isComplete: Bool { !key.isEmpty && !secret.isEmpty && (broker != .longbridge || !token.isEmpty) }
    var longbridge: LongbridgeCredentials { .init(appKey: key, appSecret: secret, accessToken: token) }
    static func storageKey(broker: DirectBroker, accountID: String) -> String {
        let hash = SHA256.hash(data: Data(accountID.utf8)).map { String(format: "%02x", $0) }.joined()
        return "catfolio.account.\(broker.rawValue).\(hash).credentials"
    }
    func save(accountID: String) throws {
        guard isComplete else { throw DirectBrokerError.credentials }
        try KeychainStore.set(String(decoding: JSONEncoder().encode(self), as: UTF8.self),
                              for: Self.storageKey(broker: broker, accountID: accountID))
    }
    static func load(broker: DirectBroker, accountID: String?) -> Self? {
        if let accountID,
           let value = KeychainStore.string(for: storageKey(broker: broker, accountID: accountID)),
           let saved = try? JSONDecoder().decode(Self.self, from: Data(value.utf8)),
           saved.broker == broker, saved.isComplete { return saved }
        // A new Longbridge account can reuse the already configured quote credentials.
        if accountID == nil, broker == .longbridge, let saved = LongbridgeCredentials.stored {
            return .init(broker: broker, key: saved.appKey, secret: saved.appSecret, token: saved.accessToken)
        }
        return nil
    }
}

enum DirectBrokerError: LocalizedError {
    case credentials, incomplete, unsupported, expired, duplicate, wrongAccount, unauthorized, rateLimited
    case rejected(Int)
    var errorDescription: String? {
        switch self {
        case .credentials: L10n.text("请填写完整的券商 API 凭证。")
        case .incomplete: L10n.text("券商持仓、成本或行情不完整，现有持仓未更新。")
        case .unsupported: L10n.text("账户包含暂不支持的持仓类型或币种；目前支持股票和 ETF 多头持仓，现有持仓未更新。")
        case .expired: L10n.text("持仓预览已过期，请重新读取。")
        case .duplicate: L10n.text("此券商账户已添加，请从账户详情更新持仓。")
        case .wrongAccount: L10n.text("返回的券商账户与当前账户不匹配，现有持仓未更新。")
        case .unauthorized: L10n.text("券商授权失败，请检查凭证、有效期及账户权限；Alpaca 凭证需与所选实盘或模拟盘一致。")
        case .rateLimited: L10n.text("券商请求过于频繁，请稍后重试。")
        case .rejected(let code): L10n.text("券商服务暂不可用，错误代码") + " \(code)"
        }
    }
}

struct DirectBrokerSnapshot {
    let broker: DirectBroker
    let accountID: String
    let accountLabel: String
    let currency: String
    let positions: [LocalPositionRecord]
    let fetchedAt: Date

    var accountKey: String { "\(broker.title)|\(accountID)" }
    func validate(context: AccountConnectorContext, existing: [PortfolioAccount], now: Date = .now) throws {
        guard (-60..<900).contains(now.timeIntervalSince(fetchedAt)) else { throw DirectBrokerError.expired }
        if let current = context.account {
            guard current.source == broker.title, current.accountID == accountID,
                  existing.contains(where: { $0.id == current.id }) else { throw DirectBrokerError.wrongAccount }
        } else if existing.contains(where: { $0.source == broker.title && $0.accountID == accountID }) {
            throw DirectBrokerError.duplicate
        }
        guard positions.allSatisfy({ $0.source == broker.title && $0.accountID == accountID }) else {
            throw DirectBrokerError.wrongAccount
        }
    }
    func portfolioAccount(name: String) -> PortfolioAccount {
        .init(id: accountKey, accountID: accountID, source: broker.title, name: name,
              baseCurrency: currency, positionCount: positions.count, transactionCount: 0,
              manualTransactionCount: 0, hasCSVImport: false, marketValueUSD: 0)
    }
}

/// Only the documented read endpoints are exposed. Redirects cannot forward API headers.
struct DirectBrokerHTTP {
    typealias Request = (URLRequest) async throws -> (Data, URLResponse)
    let request: Request
    init(request: @escaping Request = { try await BrokerReadSession.shared.recordedData(for: $0) }) {
        self.request = request
    }
    func data(_ request: URLRequest) async throws -> Data {
        try Task.checkCancellation()
        let (data, response) = try await self.request(request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw DirectBrokerError.incomplete }
        switch http.statusCode {
        case 200: break
        case 401, 403: throw DirectBrokerError.unauthorized
        case 429: throw DirectBrokerError.rateLimited
        default: throw DirectBrokerError.rejected(http.statusCode)
        }
        guard http.value(forHTTPHeaderField: "Link")?.contains("rel=\"next\"") != true else {
            throw DirectBrokerError.incomplete
        }
        return data
    }
    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw DirectBrokerError.incomplete }
    }
    static func number(_ value: String) throws -> Double {
        guard let result = Double(value), result.isFinite else { throw DirectBrokerError.incomplete }
        return result
    }
}

private final class BrokerReadSession: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        return URLSession(configuration: configuration, delegate: BrokerReadSession(), delegateQueue: nil)
    }()
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
