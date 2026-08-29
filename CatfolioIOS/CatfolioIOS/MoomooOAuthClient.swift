import CryptoKit
import Foundation
import Network
import Security

struct MoomooAccount: Decodable, Identifiable, Equatable {
    let accountID: String
    let securityFirm: String
    let accountType: String
    let accountCardNumber: String

    var id: String { accountID }

    enum CodingKeys: String, CodingKey {
        case accountID = "account_id"
        case securityFirm = "security_firm"
        case accountType = "acc_type"
        case accountCardNumber = "account_card_number"
    }
}

struct MoomooPosition: Decodable, Identifiable, Equatable {
    let accountID: String
    let positionSide: String
    let code: String
    let stockName: String
    let quantity: String
    let currency: String
    let nominalPrice: String
    let costPrice: String
    let costPriceValid: Bool
    let marketValue: String

    var id: String { "\(accountID):\(positionSide):\(code)" }
    var quantityValue: Double { Self.number(quantity) ?? 0 }
    var nominalPriceValue: Double? { Self.number(nominalPrice) }
    var costPriceValue: Double? { costPriceValid ? Self.number(costPrice) : nil }
    var marketValueValue: Double? { Self.number(marketValue) }

    enum CodingKeys: String, CodingKey {
        case positionSide = "position_side"
        case code
        case stockName = "stock_name"
        case quantity = "qty"
        case currency
        case nominalPrice = "nominal_price"
        case costPrice = "cost_price"
        case costPriceValid = "cost_price_valid"
        case marketValue = "market_val"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        accountID = ""
        positionSide = try values.decodeIfPresent(String.self, forKey: .positionSide) ?? "NONE"
        code = try values.decode(String.self, forKey: .code)
        stockName = try values.decodeIfPresent(String.self, forKey: .stockName) ?? code
        quantity = try values.decodeIfPresent(String.self, forKey: .quantity) ?? "0"
        currency = try values.decodeIfPresent(String.self, forKey: .currency) ?? "USD"
        nominalPrice = try values.decodeIfPresent(String.self, forKey: .nominalPrice) ?? ""
        costPrice = try values.decodeIfPresent(String.self, forKey: .costPrice) ?? ""
        costPriceValid = try values.decodeIfPresent(Bool.self, forKey: .costPriceValid) ?? false
        marketValue = try values.decodeIfPresent(String.self, forKey: .marketValue) ?? ""
    }

    init(accountID: String, position: MoomooPosition) {
        self.accountID = accountID
        positionSide = position.positionSide
        code = position.code
        stockName = position.stockName
        quantity = position.quantity
        currency = position.currency
        nominalPrice = position.nominalPrice
        costPrice = position.costPrice
        costPriceValid = position.costPriceValid
        marketValue = position.marketValue
    }

    private static func number(_ value: String) -> Double? {
        Double(value.replacingOccurrences(of: ",", with: ""))
    }
}

struct MoomooSnapshot: Equatable {
    let accounts: [MoomooAccount]
    let positions: [MoomooPosition]

    func csvImportExport() throws -> MoomooCSVExport {
        var warnings: [String] = []
        var rows = ["Date,Action,Ticker,Quantity,Price,Currency,Name"]
        let date = DayDateFormatter.shared.string(from: Date())

        for position in positions {
            guard position.positionSide.uppercased() != "SHORT", position.quantityValue > 0 else {
                warnings.append("已跳过空头持仓 \(position.code)")
                continue
            }
            guard let costPrice = position.costPriceValue, costPrice > 0 else {
                warnings.append("\(position.code) 缺少有效成本价，已跳过")
                continue
            }
            let fields = [
                date,
                "BUY",
                Self.catfolioTicker(position.code),
                position.quantity,
                String(costPrice),
                position.currency.uppercased(),
                position.stockName,
            ]
            rows.append(fields.map(Self.csvField).joined(separator: ","))
        }

        guard rows.count > 1, let data = rows.joined(separator: "\n").data(using: .utf8) else {
            throw MoomooOpenAPIError.noImportablePositions(warnings)
        }
        return MoomooCSVExport(data: data, importedPositions: rows.count - 1, warnings: warnings)
    }

    private static func catfolioTicker(_ value: String) -> String {
        let parts = value.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return value.uppercased() }
        let market = parts[0].uppercased()
        var code = parts[1].uppercased()
        if market == "HK", code.count == 5, code.first == "0" {
            code.removeFirst()
        }
        let suffixes = [
            "US": "", "HK": ".HK", "SG": ".SI", "JP": ".T", "JA": ".T",
            "AU": ".AX", "CA": ".TO", "SH": ".SS", "SZ": ".SZ", "BMS": ".KL",
        ]
        guard let suffix = suffixes[market] else { return value.uppercased() }
        return code + suffix
    }

    private static func csvField(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") else { return value }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}

struct MoomooCSVExport {
    let data: Data
    let importedPositions: Int
    let warnings: [String]
}

struct MoomooTokenSet: Codable, Equatable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
    let scope: String

    var isUsable: Bool { expiresAt.timeIntervalSinceNow > 90 }
}

enum MoomooCredentialStore {
    private static let clientIDKey = "moomoo.oauth.client-id"
    private static let tokenSetKey = "moomoo.oauth.tokens"

    static var clientID: String? {
        KeychainStore.string(for: clientIDKey)
    }

    static var tokenSet: MoomooTokenSet? {
        guard let value = KeychainStore.string(for: tokenSetKey),
              let data = value.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(MoomooTokenSet.self, from: data)
    }

    static func save(clientID: String) throws {
        try KeychainStore.set(clientID, for: clientIDKey)
    }

    static func save(tokenSet: MoomooTokenSet) throws {
        let data = try JSONEncoder().encode(tokenSet)
        guard let value = String(data: data, encoding: .utf8) else {
            throw MoomooOpenAPIError.invalidResponse
        }
        try KeychainStore.set(value, for: tokenSetKey)
    }

    static func clearTokens() {
        try? KeychainStore.set("", for: tokenSetKey)
    }
}

enum MoomooOpenAPIError: LocalizedError {
    case invalidResponse
    case registrationFailed(String)
    case authorizationCancelled
    case authorizationFailed(String)
    case invalidState
    case tokenMissing
    case service(Int?, String)
    case noAccounts
    case noPositions
    case noImportablePositions([String])

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "Moomoo 返回了无法识别的数据"
        case let .registrationFailed(message):
            "无法注册 Moomoo OAuth 客户端：\(message)"
        case .authorizationCancelled:
            "已取消 Moomoo 登录"
        case let .authorizationFailed(message):
            "Moomoo 授权失败：\(message)"
        case .invalidState:
            "Moomoo OAuth state 校验失败，请重新登录"
        case .tokenMissing:
            "尚未登录 Moomoo"
        case let .service(code, message):
            code.map { "Moomoo \($0)：\(message)" } ?? "Moomoo：\(message)"
        case .noAccounts:
            "Moomoo 没有返回已授权的交易账户；请授予 trade:read 权限"
        case .noPositions:
            "已授权的 Moomoo 账户当前没有持仓"
        case let .noImportablePositions(warnings):
            warnings.isEmpty ? "Moomoo 没有可导入的多头持仓" : warnings.joined(separator: "；")
        }
    }
}

struct MoomooOpenAPIClient {
    static let redirectURI = "http://localhost:60355/callback"
    private static let baseURL = URL(string: "https://webapi.moomoo.com")!
    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.httpCookieStorage = nil
            self.session = URLSession(configuration: configuration)
        }
    }

    func registerPublicClient() async throws -> String {
        let payload: [String: Any] = [
            "redirect_uris": [Self.redirectURI],
            "token_endpoint_auth_method": "none",
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
            "client_name": "Catfolio iOS",
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        var request = request(path: "/oauth2/register", method: "POST")
        request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (responseData, http) = try await response(for: request)
        guard (200..<300).contains(http.statusCode),
              let registration = try? JSONDecoder().decode(MoomooRegistration.self, from: responseData),
              !registration.clientID.isEmpty else {
            throw MoomooOpenAPIError.registrationFailed(serviceMessage(from: responseData))
        }
        return registration.clientID
    }

    func authorizationURL(clientID: String, challenge: String, state: String) throws -> URL {
        var components = URLComponents(
            url: Self.baseURL.appendingPathComponent("oauth2/authorize/confirm"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "state", value: state),
        ]
        guard let url = components?.url else { throw MoomooOpenAPIError.invalidResponse }
        return url
    }

    func exchangeCode(_ code: String, clientID: String, verifier: String) async throws -> MoomooTokenSet {
        try await tokenRequest(parameters: [
            "grant_type": "authorization_code",
            "code": code,
            "client_id": clientID,
            "redirect_uri": Self.redirectURI,
            "code_verifier": verifier,
        ], existingRefreshToken: nil)
    }

    func validToken() async throws -> MoomooTokenSet {
        guard let tokenSet = MoomooCredentialStore.tokenSet else {
            throw MoomooOpenAPIError.tokenMissing
        }
        guard !tokenSet.isUsable else { return tokenSet }
        guard let clientID = MoomooCredentialStore.clientID else {
            throw MoomooOpenAPIError.tokenMissing
        }
        let refreshed = try await tokenRequest(parameters: [
            "grant_type": "refresh_token",
            "refresh_token": tokenSet.refreshToken,
            "client_id": clientID,
        ], existingRefreshToken: tokenSet.refreshToken)
        try MoomooCredentialStore.save(tokenSet: refreshed)
        return refreshed
    }

    func fetchSnapshot() async throws -> MoomooSnapshot {
        let token = try await validToken()
        let accounts: [MoomooAccount] = try await authorizedGet(
            path: "/api/v1.0/accounts/authorized_trd_accs",
            accessToken: token.accessToken,
            decode: { data in
                let envelope = try JSONDecoder().decode(MoomooAccountsEnvelope.self, from: data)
                try Self.validate(envelope.status, code: envelope.errorCode, message: envelope.errorMessage)
                return envelope.data?.accounts ?? []
            }
        )
        guard !accounts.isEmpty else { throw MoomooOpenAPIError.noAccounts }

        var allPositions: [MoomooPosition] = []
        for account in accounts {
            let encodedID = account.accountID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
                ?? account.accountID
            let positions: [MoomooPosition] = try await authorizedGet(
                path: "/api/v1.0/accounts/\(encodedID)/positions",
                accessToken: token.accessToken,
                decode: { data in
                    let envelope = try JSONDecoder().decode(MoomooPositionsEnvelope.self, from: data)
                    try Self.validate(envelope.status, code: envelope.errorCode, message: envelope.errorMessage)
                    return envelope.data ?? []
                }
            )
            allPositions.append(contentsOf: positions.map { MoomooPosition(accountID: account.accountID, position: $0) })
        }
        guard !allPositions.isEmpty else { throw MoomooOpenAPIError.noPositions }
        return MoomooSnapshot(accounts: accounts, positions: allPositions)
    }

    private func tokenRequest(parameters: [String: String], existingRefreshToken: String?) async throws -> MoomooTokenSet {
        var request = request(path: "/oauth2/token", method: "POST")
        request.httpBody = formEncoded(parameters)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let (data, http) = try await response(for: request)
        guard (200..<300).contains(http.statusCode),
              let response = try? JSONDecoder().decode(MoomooTokenResponse.self, from: data) else {
            throw MoomooOpenAPIError.authorizationFailed(serviceMessage(from: data))
        }
        guard let refreshToken = response.refreshToken ?? existingRefreshToken, !refreshToken.isEmpty else {
            throw MoomooOpenAPIError.invalidResponse
        }
        return MoomooTokenSet(
            accessToken: response.accessToken,
            refreshToken: refreshToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(response.expiresIn)),
            scope: response.scope
        )
    }

    private func authorizedGet<T>(
        path: String,
        accessToken: String,
        decode: (Data) throws -> T
    ) async throws -> T {
        var request = request(path: path, method: "GET")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, http) = try await response(for: request)
        guard (200..<300).contains(http.statusCode) else {
            throw MoomooOpenAPIError.service(http.statusCode, serviceMessage(from: data))
        }
        return try decode(data)
    }

    private func request(path: String, method: String) -> URLRequest {
        var request = URLRequest(url: Self.baseURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))))
        request.httpMethod = method
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("CatfolioIOS/1.0", forHTTPHeaderField: "User-Agent")
        return request
    }

    private func response(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MoomooOpenAPIError.invalidResponse }
        return (data, http)
    }

    private func formEncoded(_ values: [String: String]) -> Data? {
        var components = URLComponents()
        components.queryItems = values.sorted { $0.key < $1.key }.map(URLQueryItem.init)
        return components.percentEncodedQuery?.data(using: .utf8)
    }

    private func serviceMessage(from data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "请求失败"
        }
        return object["errmsg"] as? String
            ?? object["error_description"] as? String
            ?? object["error"] as? String
            ?? "请求失败"
    }

    private static func validate(_ status: String, code: Int?, message: String?) throws {
        guard status.caseInsensitiveCompare("ok") == .orderedSame else {
            throw MoomooOpenAPIError.service(code, message ?? "请求失败")
        }
    }
}

@MainActor
final class MoomooAuthorizationSession: ObservableObject {
    @Published var authorizationPage: MoomooAuthorizationPage?
    private var loopbackListener: MoomooLoopbackListener?

    func authorize() async throws -> MoomooTokenSet {
        let client = MoomooOpenAPIClient()
        let clientID: String
        if let savedClientID = MoomooCredentialStore.clientID {
            clientID = savedClientID
        } else {
            clientID = try await client.registerPublicClient()
            try MoomooCredentialStore.save(clientID: clientID)
        }

        let verifier = Self.randomURLSafeString(byteCount: 32)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
        let state = Self.randomURLSafeString(byteCount: 24)
        let authorizationURL = try client.authorizationURL(clientID: clientID, challenge: challenge, state: state)
        let listener = try MoomooLoopbackListener(port: 60355)
        loopbackListener = listener
        do {
            try await listener.start()
        } catch {
            loopbackListener = nil
            throw MoomooOpenAPIError.authorizationFailed("无法启动本机 OAuth 回调：\(error.localizedDescription)")
        }
        authorizationPage = MoomooAuthorizationPage(url: authorizationURL)
        let callbackURL: URL
        do {
            callbackURL = try await listener.waitForCallback()
        } catch {
            authorizationPage = nil
            loopbackListener = nil
            throw error
        }
        authorizationPage = nil
        loopbackListener = nil
        guard callbackURL.scheme == "http", callbackURL.host?.lowercased() == "localhost",
              callbackURL.port == 60355, callbackURL.path == "/callback" else {
            throw MoomooOpenAPIError.authorizationFailed("回调地址无效")
        }
        let items = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let value: (String) -> String? = { name in items.first(where: { $0.name == name })?.value }
        if let error = value("error") {
            throw MoomooOpenAPIError.authorizationFailed(value("error_description") ?? error)
        }
        guard value("state") == state else { throw MoomooOpenAPIError.invalidState }
        guard let code = value("code"), !code.isEmpty else { throw MoomooOpenAPIError.invalidResponse }
        let tokens = try await client.exchangeCode(code, clientID: clientID, verifier: verifier)
        try MoomooCredentialStore.save(tokenSet: tokens)
        return tokens
    }

    func cancel() {
        loopbackListener?.cancel(with: MoomooOpenAPIError.authorizationCancelled)
        loopbackListener = nil
        authorizationPage = nil
    }

    private static func randomURLSafeString(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncodedString()
    }
}

struct MoomooAuthorizationPage: Identifiable {
    let id = UUID()
    let url: URL
}

private final class MoomooLoopbackListener: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.catfolio.ios.moomoo-oauth")
    private let lock = NSLock()
    private var readyContinuation: CheckedContinuation<Void, Error>?
    private var callbackContinuation: CheckedContinuation<URL, Error>?
    private var pendingCallback: Result<URL, Error>?
    private var hasFinished = false

    init(port: UInt16) throws {
        guard let port = NWEndpoint.Port(rawValue: port) else {
            throw MoomooOpenAPIError.authorizationFailed("本机回调端口无效")
        }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
        listener = try NWListener(using: parameters)
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            readyContinuation = continuation
            lock.unlock()
            listener.stateUpdateHandler = { [weak self] state in
                self?.handle(state: state)
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.receiveRequest(from: connection, buffer: Data())
            }
            listener.start(queue: queue)
        }
    }

    func waitForCallback() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let pendingCallback {
                self.pendingCallback = nil
                lock.unlock()
                continuation.resume(with: pendingCallback)
            } else {
                callbackContinuation = continuation
                lock.unlock()
            }
        }
    }

    func cancel(with error: Error) {
        finish(.failure(error))
    }

    private func handle(state: NWListener.State) {
        switch state {
        case .ready:
            resumeReady(.success(()))
        case let .failed(error):
            resumeReady(.failure(error))
            finish(.failure(MoomooOpenAPIError.authorizationFailed(error.localizedDescription)))
        case let .waiting(error):
            resumeReady(.failure(error))
            finish(.failure(MoomooOpenAPIError.authorizationFailed("本机回调端口不可用：\(error.localizedDescription)")))
        case .cancelled:
            resumeReady(.failure(MoomooOpenAPIError.authorizationCancelled))
        default:
            break
        }
    }

    private func receiveRequest(from connection: NWConnection, buffer: Data) {
        connection.start(queue: queue)
        receiveMore(from: connection, buffer: buffer)
    }

    private func receiveMore(from connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8_192) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var accumulated = buffer
            if let data { accumulated.append(data) }
            if accumulated.count > 16_384 {
                self.sendResponse(to: connection, status: "413 Payload Too Large", message: "请求过大")
                return
            }
            if accumulated.range(of: Data("\r\n\r\n".utf8)) != nil || isComplete {
                self.handleRequest(accumulated, from: connection)
            } else if let error {
                self.sendResponse(to: connection, status: "400 Bad Request", message: error.localizedDescription)
            } else {
                self.receiveMore(from: connection, buffer: accumulated)
            }
        }
    }

    private func handleRequest(_ data: Data, from connection: NWConnection) {
        guard let requestText = String(data: data, encoding: .utf8),
              let firstLine = requestText.components(separatedBy: "\r\n").first,
              firstLine.hasPrefix("GET "),
              let target = firstLine.split(separator: " ").dropFirst().first,
              let callbackURL = URL(string: String(target), relativeTo: URL(string: "http://localhost:60355"))?.absoluteURL,
              callbackURL.path == "/callback" else {
            sendResponse(to: connection, status: "404 Not Found", message: "无效回调")
            return
        }
        sendResponse(to: connection, status: "200 OK", message: "Moomoo 授权完成，可以返回 Catfolio。")
        finish(.success(callbackURL))
    }

    private func sendResponse(to connection: NWConnection, status: String, message: String) {
        let body = "<!doctype html><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width\"><title>Catfolio</title><body style=\"font:17px -apple-system;padding:40px;line-height:1.5\"><h2>Catfolio</h2><p>\(message)</p></body>"
        let bodyData = Data(body.utf8)
        let headers = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(bodyData.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n"
        var response = Data(headers.utf8)
        response.append(bodyData)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func resumeReady(_ result: Result<Void, Error>) {
        lock.lock()
        let continuation = readyContinuation
        readyContinuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }

    private func finish(_ result: Result<URL, Error>) {
        lock.lock()
        guard !hasFinished else {
            lock.unlock()
            return
        }
        hasFinished = true
        let continuation = callbackContinuation
        callbackContinuation = nil
        if continuation == nil { pendingCallback = result }
        lock.unlock()
        listener.cancel()
        continuation?.resume(with: result)
    }
}

private struct MoomooRegistration: Decodable {
    let clientID: String

    enum CodingKeys: String, CodingKey {
        case clientID = "client_id"
    }
}

private struct MoomooTokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int
    let scope: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case scope
    }
}

private struct MoomooAccountsEnvelope: Decodable {
    let status: String
    let data: MoomooAccountsData?
    let errorCode: Int?
    let errorMessage: String?

    enum CodingKeys: String, CodingKey {
        case status = "s"
        case data = "d"
        case errorCode = "errcode"
        case errorMessage = "errmsg"
    }
}

private struct MoomooAccountsData: Decodable {
    let accounts: [MoomooAccount]
}

private struct MoomooPositionsEnvelope: Decodable {
    let status: String
    let data: [MoomooPosition]?
    let errorCode: Int?
    let errorMessage: String?

    enum CodingKeys: String, CodingKey {
        case status = "s"
        case data = "d"
        case errorCode = "errcode"
        case errorMessage = "errmsg"
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
