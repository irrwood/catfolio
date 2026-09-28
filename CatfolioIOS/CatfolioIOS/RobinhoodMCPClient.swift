import Foundation
import CryptoKit
import Security

/// A device-local, read-only client for Robinhood's official Streamable HTTP MCP.
/// No token, account payload or quote is sent to Catfolio's backend.
actor RobinhoodMCPClient {
    static let shared = RobinhoodMCPClient()
    static let endpoint = URL(string: "https://agent.robinhood.com/mcp/trading")!
    static let redirectURI = "http://localhost:60356/callback"
    static let credentialKey = "catfolio.robinhood.oauth.v1"
    static let pendingKey = "catfolio.robinhood.oauth.pending.v1"
    static let readTools: Set<String> = [
        "get_accounts", "get_portfolio", "get_equity_positions", "get_equity_quotes",
        "get_equity_price_book", "get_option_chains", "get_option_instruments",
        "get_option_quotes", "get_option_positions"
    ]

    struct Credential: Codable {
        let clientID: String
        let accessToken: String
        let refreshToken: String?
        let expiresAt: Date
    }
    struct Pending: Codable {
        let clientID: String
        let verifier: String
        let state: String
        let createdAt: Date
    }
    struct Quote: Equatable {
        let symbol: String
        let price: Double
        let observedAt: Date
    }
    enum Failure: Error, LocalizedError {
        case message(String)
        var errorDescription: String? {
            switch self { case .message(let value): return L10n.label(value) }
        }
    }

    private let session: URLSession
    private var generation = 0
    private var sessionID: String?
    private var tools: [String: [String: Any]] = [:]
    private var refreshTask: Task<Credential, Error>?
    private var initializing: Task<Void, Error>?
    private var retryAt = Date.distantPast

    init(session: URLSession? = nil) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        self.session = session ?? URLSession(configuration: configuration)
    }

    func isConnected() -> Bool { Self.load(Credential.self, key: Self.credentialKey) != nil }
    func connectionGeneration() -> Int { generation }

    func disconnect() throws {
        generation += 1
        refreshTask?.cancel()
        initializing?.cancel()
        refreshTask = nil
        initializing = nil
        sessionID = nil
        tools = [:]
        retryAt = .distantPast
        try KeychainStore.set("", for: Self.credentialKey)
        try KeychainStore.set("", for: Self.pendingKey)
    }

    func beginAuthorization() async throws -> URL {
        let epoch = generation
        let data = try await send(URL(string: "https://agent.robinhood.com/oauth/trading/register")!, json: [
            "client_name": "Catfolio iOS", "redirect_uris": [Self.redirectURI],
            "token_endpoint_auth_method": "none", "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"]
        ])
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let clientID = object["client_id"] as? String, !clientID.isEmpty else {
            throw Failure.message("Robinhood 客户端注册失败")
        }
        let pending = Pending(clientID: clientID, verifier: try Self.random(), state: try Self.random(), createdAt: Date())
        guard epoch == generation else { throw CancellationError() }
        try Self.save(pending, key: Self.pendingKey)
        var url = URLComponents(string: "https://robinhood.com/oauth")!
        url.queryItems = [
            .init(name: "client_id", value: clientID), .init(name: "redirect_uri", value: Self.redirectURI),
            .init(name: "response_type", value: "code"), .init(name: "state", value: pending.state),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "code_challenge", value: Self.challenge(pending.verifier)),
            .init(name: "scope", value: "internal"), .init(name: "resource", value: Self.endpoint.absoluteString)
        ]
        return url.url!
    }

    func finishAuthorization(callback: String) async throws {
        guard let pending = Self.load(Pending.self, key: Self.pendingKey) else {
            throw Failure.message("请先生成 Robinhood 登录链接")
        }
        let code = try Self.authorizationCode(callback, pending: pending, now: Date())
        let epoch = generation
        let credential = try await exchange([
            "grant_type": "authorization_code", "client_id": pending.clientID, "code": code,
            "redirect_uri": Self.redirectURI, "code_verifier": pending.verifier,
            "resource": Self.endpoint.absoluteString
        ], clientID: pending.clientID, previousRefresh: nil)
        guard epoch == generation else { throw CancellationError() }
        generation += 1
        refreshTask?.cancel()
        initializing?.cancel()
        refreshTask = nil
        initializing = nil
        retryAt = .distantPast
        try Self.save(credential, key: Self.credentialKey)
        try KeychainStore.set("", for: Self.pendingKey)
        sessionID = nil
        tools = [:]
    }

    static func authorizationCode(_ callback: String, pending: Pending, now: Date) throws -> String {
        guard now.timeIntervalSince(pending.createdAt) >= 0,
              now.timeIntervalSince(pending.createdAt) < 30 * 60,
              let url = URLComponents(string: callback.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "http", url.host == "localhost", url.port == 60356,
              url.path == "/callback", url.user == nil, url.password == nil, url.fragment == nil else {
            throw Failure.message("Robinhood 回调链接无效或已过期，请重新连接")
        }
        let items = url.queryItems ?? []
        guard items.filter({ $0.name == "state" }).count == 1,
              items.first(where: { $0.name == "state" })?.value == pending.state,
              !items.contains(where: { $0.name == "error" }),
              items.filter({ $0.name == "code" }).count == 1,
              let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            throw Failure.message("Robinhood 授权校验失败，请重新连接")
        }
        return code
    }

    /// Read tools are discovered after login; schema mismatches fail closed.
    func read(_ name: String, arguments: [String: Any] = [:]) async throws -> Any {
        guard Self.readTools.contains(name) else { throw Failure.message("Robinhood 仅允许读取数据") }
        let epoch = generation
        try await initialize()
        guard epoch == generation else { throw CancellationError() }
        guard let schema = tools[name] else { throw Failure.message("Robinhood 账户暂不支持此数据") }
        try Self.validate(arguments, schema: schema)
        if let symbols = arguments["symbols"] as? [String] {
            let limit = name == "get_equity_price_book" ? 4 : 20
            guard !symbols.isEmpty, symbols.count <= limit else {
                throw Failure.message("股票代码数量超出 Robinhood 单次查询限制")
            }
        }
        let envelope = try await rpc("tools/call", params: ["name": name, "arguments": arguments])
        guard epoch == generation else { throw CancellationError() }
        return try Self.toolPayload(envelope)
    }

    func availableTools() async throws -> [String] {
        try await initialize()
        return tools.keys.sorted()
    }

    /// Only fresh USD equity quotes can override the existing provider chain.
    /// Unknown response layouts are not guessed into portfolio prices.
    func quotes(symbols: [String], maxAge: TimeInterval = 120) async -> [String: Quote] {
        guard isConnected(), !symbols.isEmpty else { return [:] }
        let epoch = generation
        let unique = Array(Set(symbols.filter { Self.isUSSymbol($0) })).sorted()
        var result: [String: Quote] = [:]
        for start in stride(from: 0, to: unique.count, by: 20) {
            guard !Task.isCancelled, epoch == generation else { return [:] }
            let batch = Array(unique[start..<min(start + 20, unique.count)])
            do {
                let payload = try await read("get_equity_quotes", arguments: ["symbols": batch])
                for quote in Self.parseQuotes(payload, requested: Set(batch), now: Date(), maxAge: maxAge) {
                    result[quote.symbol] = quote
                }
            } catch { /* Existing providers handle unavailable/unsupported symbols. */ }
        }
        return epoch == generation ? result : [:]
    }

    static func isUSSymbol(_ symbol: String) -> Bool {
        symbol.range(of: "^[A-Z][A-Z0-9]{0,9}([.-][AB])?$", options: .regularExpression) != nil
    }

    static func parseQuotes(_ payload: Any, requested: Set<String>, now: Date, maxAge: TimeInterval = 120) -> [Quote] {
        let root = payload as? [String: Any]
        let rows = (payload as? [[String: Any]]) ?? (root?["results"] as? [[String: Any]])
            ?? (root?["quotes"] as? [[String: Any]]) ?? []
        return rows.compactMap { row in
            guard let symbol = row["symbol"] as? String, requested.contains(symbol),
                  let currency = row["currency"] as? String, currency.uppercased() == "USD",
                  let price = number(row["last_trade_price"]), price.isFinite, price > 0,
                  let stamp = row["updated_at"] as? String,
                  let date = isoDate(stamp), now.timeIntervalSince(date) >= -60,
                  now.timeIntervalSince(date) <= maxAge else { return nil }
            return Quote(symbol: symbol, price: price, observedAt: date)
        }
    }

    static func number(_ value: Any?) -> Double? {
        if let text = value as? String { return Double(text) }
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { return number.doubleValue }
        return nil
    }
    private static func isoDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    static func validate(_ arguments: [String: Any], schema: [String: Any]) throws {
        let properties = schema["properties"] as? [String: [String: Any]] ?? [:]
        let required = schema["required"] as? [String] ?? []
        guard required.allSatisfy({ arguments[$0] != nil }),
              arguments.keys.allSatisfy({ properties[$0] != nil }) else {
            throw Failure.message("Robinhood 数据接口已变化，暂时使用其他行情源")
        }
        for (key, value) in arguments {
            let property = properties[key] ?? [:]
            switch property["type"] as? String {
            case "string":
                guard let text = value as? String, !text.isEmpty else {
                    throw Failure.message("请填写 Robinhood 查询所需信息")
                }
            case "array":
                guard let values = value as? [String], !values.isEmpty,
                      values.allSatisfy({ !$0.isEmpty }),
                      values.count <= (property["maxItems"] as? Int ?? 100) else {
                    throw Failure.message("请检查 Robinhood 查询代码和数量")
                }
            default: break
            }
        }
    }

    static func toolPayload(_ envelope: [String: Any]) throws -> Any {
        guard let result = envelope["result"] as? [String: Any], result["isError"] as? Bool != true else {
            throw Failure.message("Robinhood 数据读取失败，请检查账户权限")
        }
        if let structured = result["structuredContent"] { return structured }
        let blocks = result["content"] as? [[String: Any]] ?? []
        for block in blocks where block["type"] as? String == "text" {
            if let text = block["text"] as? String, let data = text.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) { return json }
        }
        throw Failure.message("Robinhood 返回了无法识别的数据")
    }

    private func initialize() async throws {
        if !tools.isEmpty { return }
        if let initializing { return try await initializing.value }
        let epoch = generation
        let task = Task { try await self.initializeSession(epoch: epoch) }
        initializing = task
        defer { if epoch == generation { initializing = nil } }
        try await task.value
    }

    private func initializeSession(epoch: Int) async throws {
        _ = try await rpc("initialize", params: [
            "protocolVersion": "2025-03-26", "capabilities": [:],
            "clientInfo": ["name": "Catfolio iOS", "version": "1.0"]
        ])
        _ = try await rpc("notifications/initialized", params: [:], notification: true)
        var discovered: [String: [String: Any]] = [:]
        var cursor: String?
        var seen = Set<String>()
        repeat {
            let response = try await rpc("tools/list", params: cursor.map { ["cursor": $0] } ?? [:])
            guard let result = response["result"] as? [String: Any],
                  let list = result["tools"] as? [[String: Any]] else {
                throw Failure.message("Robinhood 工具列表无法读取")
            }
            for tool in list {
                if let name = tool["name"] as? String, Self.readTools.contains(name),
                   let schema = tool["inputSchema"] as? [String: Any] { discovered[name] = schema }
            }
            cursor = result["nextCursor"] as? String
            if let cursor, !seen.insert(cursor).inserted { throw Failure.message("Robinhood 工具列表无法读取") }
        } while cursor != nil && seen.count < 20
        guard epoch == generation else { throw CancellationError() }
        tools = discovered
    }

    private func credential() async throws -> Credential {
        guard let stored = Self.load(Credential.self, key: Self.credentialKey) else {
            throw Failure.message("请先连接 Robinhood")
        }
        if stored.expiresAt.timeIntervalSinceNow > 90 { return stored }
        if let refreshTask { return try await refreshTask.value }
        guard let refresh = stored.refreshToken else { throw Failure.message("Robinhood 授权已过期，请重新连接") }
        let epoch = generation
        let task = Task { try await self.exchange([
            "grant_type": "refresh_token", "refresh_token": refresh, "client_id": stored.clientID,
            "resource": Self.endpoint.absoluteString
        ], clientID: stored.clientID, previousRefresh: refresh) }
        refreshTask = task
        defer { if epoch == generation { refreshTask = nil } }
        let updated = try await task.value
        guard epoch == generation else { throw CancellationError() }
        try Self.save(updated, key: Self.credentialKey)
        return updated
    }

    private func exchange(_ parameters: [String: String], clientID: String, previousRefresh: String?) async throws -> Credential {
        var request = URLRequest(url: URL(string: "https://api.robinhood.com/oauth2/token/")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(Self.form(parameters).utf8)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = value["access_token"] as? String, !access.isEmpty,
              let expires = Self.number(value["expires_in"]), expires.isFinite, expires > 0 else {
            throw Failure.message("Robinhood 授权失败，请重新连接")
        }
        return Credential(clientID: clientID, accessToken: access,
            refreshToken: value["refresh_token"] as? String ?? previousRefresh,
            expiresAt: Date().addingTimeInterval(expires))
    }

    private func rpc(_ method: String, params: [String: Any], notification: Bool = false) async throws -> [String: Any] {
        guard Date() >= retryAt else { throw Failure.message("Robinhood 请求过于频繁，请稍后再试") }
        let epoch = generation
        let token = try await credential()
        guard epoch == generation else { throw CancellationError() }
        let id = UUID().uuidString
        var body: [String: Any] = ["jsonrpc": "2.0", "method": method, "params": params]
        if !notification { body["id"] = id }
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("2025-03-26", forHTTPHeaderField: "MCP-Protocol-Version")
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        let (data, response) = try await session.data(for: request)
        guard epoch == generation else { throw CancellationError() }
        guard let http = response as? HTTPURLResponse else { throw Failure.message("Robinhood 连接失败") }
        if http.statusCode == 429 {
            let delay = Double(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 60
            retryAt = Date().addingTimeInterval(min(3600, max(1, delay)))
        }
        guard (200..<300).contains(http.statusCode) else {
            if [401, 404].contains(http.statusCode) { sessionID = nil; tools = [:] }
            throw Failure.message("Robinhood 数据暂不可用，请稍后重试或重新连接")
        }
        if let newID = http.value(forHTTPHeaderField: "Mcp-Session-Id") { sessionID = newID }
        if notification { return [:] }
        return try Self.rpcResponse(data, id: id)
    }

    static func rpcResponse(_ data: Data, id: String) throws -> [String: Any] {
        var candidates = [data]
        if let text = String(data: data, encoding: .utf8) {
            let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            for event in normalized.components(separatedBy: "\n\n") {
                let value = event.components(separatedBy: "\n").filter { $0.hasPrefix("data:") }
                    .map { String($0.dropFirst(5)).trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
                if !value.isEmpty { candidates.append(Data(value.utf8)) }
            }
        }
        for candidate in candidates {
            if let value = try? JSONSerialization.jsonObject(with: candidate) as? [String: Any],
               value["id"] as? String == id, value["jsonrpc"] as? String == "2.0" {
                guard value["error"] == nil else { throw Failure.message("Robinhood 数据请求失败") }
                return value
            }
        }
        throw Failure.message("Robinhood 返回了无法识别的数据")
    }

    private func send(_ url: URL, json: [String: Any]) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: json)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw Failure.message("Robinhood 连接失败")
        }
        return data
    }

    static func challenge(_ verifier: String) -> String { base64(Data(SHA256.hash(data: Data(verifier.utf8)))) }
    private static func base64(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    private static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw Failure.message("无法创建安全的授权请求")
        }
        return base64(Data(bytes))
    }
    static func form(_ values: [String: String]) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return values.sorted { $0.key < $1.key }.map {
            "\($0.key.addingPercentEncoding(withAllowedCharacters: allowed)!)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)"
        }.joined(separator: "&")
    }
    private static func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let text = KeychainStore.string(for: key) else { return nil }
        return try? JSONDecoder().decode(type, from: Data(text.utf8))
    }
    private static func save<T: Encodable>(_ value: T, key: String) throws {
        try KeychainStore.set(String(decoding: JSONEncoder().encode(value), as: UTF8.self), for: key)
    }
}
