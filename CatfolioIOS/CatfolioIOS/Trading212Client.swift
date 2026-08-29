import Foundation

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

    var label: String { slot == 1 ? "账户 1" : "账户 2" }
}

struct Trading212Position: Decodable, Identifiable, Equatable {
    let accountSlot: Int
    let rawTicker: String
    let ticker: String
    let name: String
    let currency: String
    let quantity: Double
    let averagePricePaid: Double?
    let currentPrice: Double?
    let createdAt: String?

    var id: String { "\(accountSlot):\(rawTicker)" }

    private enum CodingKeys: String, CodingKey {
        case instrument
        case ticker
        case quantity
        case averagePricePaid
        case averagePrice
        case currentPrice
        case createdAt
        case initialFillDate
    }

    private struct Instrument: Decodable {
        let ticker: String?
        let name: String?
        let shortName: String?
        let currencyCode: String?
        let currency: String?
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let instrument = try values.decodeIfPresent(Instrument.self, forKey: .instrument)
        let flatTicker = try values.decodeIfPresent(String.self, forKey: .ticker)
        let rawTicker = instrument?.ticker ?? flatTicker ?? ""
        self.accountSlot = 0
        self.rawTicker = rawTicker
        ticker = Self.catfolioTicker(rawTicker)
        name = instrument?.name ?? instrument?.shortName ?? ticker
        currency = Self.currency(
            instrument?.currencyCode ?? instrument?.currency,
            rawTicker: rawTicker
        )
        quantity = try values.decodeLossyDoubleIfPresent(forKey: .quantity) ?? 0
        let currentAveragePrice = try values.decodeLossyDoubleIfPresent(forKey: .averagePricePaid)
        let legacyAveragePrice = try values.decodeLossyDoubleIfPresent(forKey: .averagePrice)
        averagePricePaid = currentAveragePrice ?? legacyAveragePrice
        currentPrice = try values.decodeLossyDoubleIfPresent(forKey: .currentPrice)
        let currentCreatedAt = try values.decodeIfPresent(String.self, forKey: .createdAt)
        let legacyCreatedAt = try values.decodeIfPresent(String.self, forKey: .initialFillDate)
        createdAt = currentCreatedAt ?? legacyCreatedAt
    }

    private init(accountSlot: Int, position: Trading212Position) {
        self.accountSlot = accountSlot
        rawTicker = position.rawTicker
        ticker = position.ticker
        name = position.name
        currency = position.currency
        quantity = position.quantity
        averagePricePaid = position.averagePricePaid
        currentPrice = position.currentPrice
        createdAt = position.createdAt
    }

    fileprivate func assigned(to slot: Int) -> Trading212Position {
        Trading212Position(accountSlot: slot, position: self)
    }

    private static func catfolioTicker(_ value: String) -> String {
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
        default: return ticker
        }
    }

    private static func currency(_ value: String?, rawTicker: String) -> String {
        if rawTicker.hasSuffix("l_EQ") { return "GBX" }
        if rawTicker.hasSuffix("_US_EQ") { return "USD" }
        if rawTicker.hasSuffix("d_EQ") || rawTicker.hasSuffix("a_EQ") || rawTicker.hasSuffix("p_EQ") {
            return "EUR"
        }
        let result = value?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() ?? ""
        return result.isEmpty ? "USD" : result
    }
}

struct Trading212Snapshot: Equatable {
    let accountCount: Int
    let positions: [Trading212Position]

    func csvImportExport() throws -> Trading212CSVExport {
        var warnings: [String] = []
        var rows = ["Date,Action,Ticker,Quantity,Price,Currency,Name"]

        for position in positions {
            guard !position.ticker.isEmpty else {
                warnings.append("已跳过缺少代码的持仓")
                continue
            }
            guard position.quantity > 0 else {
                warnings.append("已跳过空头或空仓 \(position.rawTicker)")
                continue
            }
            guard let averagePrice = position.averagePricePaid, averagePrice > 0 else {
                warnings.append("\(position.rawTicker) 缺少平均成本，已跳过")
                continue
            }
            let fields = [
                Self.normalizedDate(position.createdAt),
                "BUY",
                position.ticker,
                String(position.quantity),
                String(averagePrice),
                position.currency,
                position.name,
            ]
            rows.append(fields.map(Self.csvField).joined(separator: ","))
        }

        guard rows.count > 1, let data = rows.joined(separator: "\n").data(using: .utf8) else {
            throw Trading212Error.noImportablePositions(warnings)
        }
        return Trading212CSVExport(data: data, importedPositions: rows.count - 1, warnings: warnings)
    }

    private static func normalizedDate(_ value: String?) -> String {
        guard let value else { return DayDateFormatter.shared.string(from: Date()) }
        let prefix = String(value.prefix(10))
        let parts = prefix.split(separator: "-")
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2 else {
            return DayDateFormatter.shared.string(from: Date())
        }
        return prefix
    }

    private static func csvField(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") else { return value }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}

struct Trading212CSVExport {
    let data: Data
    let importedPositions: Int
    let warnings: [String]
}

enum Trading212Error: LocalizedError {
    case invalidAPIKey
    case invalidAPISecret
    case incompleteSecondAccount
    case noAccounts
    case invalidResponse
    case authorizationFailed
    case accountFailed(Int, String)
    case http(Int, String)
    case noPositions
    case noImportablePositions([String])

    var errorDescription: String? {
        switch self {
        case .invalidAPIKey:
            "API Key 不能为空，且不能包含冒号"
        case .invalidAPISecret:
            "API Secret 不能为空"
        case .incompleteSecondAccount:
            "账户 2 的 API Key 与 API Secret 需要同时填写"
        case .noAccounts:
            "请至少填写账户 1 的 API Key 与 API Secret"
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
        case let .noImportablePositions(warnings):
            warnings.isEmpty ? "Trading 212 没有可导入的多头持仓" : warnings.joined(separator: "；")
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

    func fetchSnapshot(
        accounts: [Trading212AccountCredentials],
        environment: Trading212Environment
    ) async throws -> Trading212Snapshot {
        guard !accounts.isEmpty else { throw Trading212Error.noAccounts }
        var positions: [Trading212Position] = []
        for account in accounts {
            do {
                let accountPositions = try await fetchPositions(
                    credentials: account.credentials,
                    environment: environment
                )
                positions.append(contentsOf: accountPositions.map { $0.assigned(to: account.slot) })
            } catch {
                throw Trading212Error.accountFailed(account.slot, error.localizedDescription)
            }
        }
        guard !positions.isEmpty else { throw Trading212Error.noPositions }
        return Trading212Snapshot(accountCount: accounts.count, positions: positions)
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
