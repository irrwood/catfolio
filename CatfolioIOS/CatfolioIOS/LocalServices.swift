import Foundation
import FoundationModels
import OSLog

enum LocalServiceKeys {
    static let fmp = "catfolio.fmp.api-key"
    static let massive = "catfolio.massive.api-key"
    static let deepSeek = "catfolio.deepseek.api-key"
}

enum LocalServiceError: LocalizedError {
    case missingMarketKey
    case missingMassiveKey
    case missingAIKey
    case missingCodexConnection
    case appleModelUnavailable(String)
    case noAvailableAIProvider(String)
    case invalidResponse
    case remote(String)
    case noMarketData
    case noHistoricalPrices
    case noSupportedETF

    var errorDescription: String? {
        switch self {
        case .missingMarketKey:
            L10n.text("成交量分析需要行情数据。请在设置中填写 Financial Modeling Prep API Key。")
        case .missingMassiveKey:
            L10n.text("请先在设置中填写 Massive API Key。")
        case .missingAIKey:
            L10n.text("DeepSeek 模式需要 API Key。请在设置中填写，Key 只保存在此 iPhone。")
        case .missingCodexConnection:
            L10n.text("请先在设置中连接 ChatGPT Codex。")
        case let .appleModelUnavailable(reason):
            L10n.text("Apple 本地模型暂不可用：\(reason)")
        case let .noAvailableAIProvider(reason):
            L10n.text("当前没有可用的 AI 模型：\(reason)")
        case .invalidResponse:
            L10n.text("第三方服务返回了无法识别的数据")
        case let .remote(message):
            message
        case .noMarketData:
            L10n.text("没有读取到这只证券的历史成交量")
        case .noHistoricalPrices:
            L10n.text("无法读取历史价格，请检查行情 API 设置与网络后重试")
        case .noSupportedETF:
            L10n.text("当前组合中的 ETF 暂无可用持仓快照")
        }
    }
}

enum AIProviderPreference: String, CaseIterable, Identifiable {
    case automatic
    case apple
    case codex
    case deepSeek

    static let storageKey = "catfolio.ai.provider"

    var id: String { rawValue }

    static var current: AIProviderPreference {
        guard let raw = UserDefaults.standard.string(forKey: storageKey),
              let value = AIProviderPreference(rawValue: raw) else { return .automatic }
        return value
    }

    var title: String {
        switch self {
        case .automatic: L10n.text("自动")
        case .apple: L10n.text("Apple 本地")
        case .codex: "Codex"
        case .deepSeek: "DeepSeek"
        }
    }

    var detail: String {
        switch self {
        case .automatic:
            L10n.text("优先使用 Apple 本地模型；不可用时依次使用已连接的 Codex 和 DeepSeek。")
        case .apple:
            L10n.text("组合摘要只在设备上处理，可离线使用；需要 Apple Intelligence 已开启且模型就绪。")
        case .codex:
            L10n.text("在此 iPhone 上登录 ChatGPT，直接使用你的 Codex 订阅进行分析。")
        case .deepSeek:
            L10n.text("组合摘要会直接发送给 DeepSeek，需要 API Key 和网络连接。")
        }
    }
}

struct CodexLoginSession: Codable, Sendable {
    let loginID: String
    let verificationURL: URL
    let userCode: String
    let deviceAuthID: String
    let intervalSeconds: UInt64
    let createdAt: Date
}

struct CodexConnectionStatus: Sendable {
    let available: Bool
    let connected: Bool
    let pending: Bool
    let email: String?
    let plan: String?
    let error: String?
}

struct CodexOAuthClient: Sendable {
    static let connectedStorageKey = "catfolio.codex.connected"
    static let accountEmailStorageKey = "catfolio.codex.account-email"
    static let accountPlanStorageKey = "catfolio.codex.account-plan"
    private static let credentialsKey = "catfolio.codex.oauth-credentials"
    private static let pendingLoginKey = "catfolio.codex.pending-login"
    private static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    private static let authBaseURL = URL(string: "https://auth.openai.com")!
    private static let codexResponsesURL = URL(string: "https://chatgpt.com/backend-api/codex/responses")!
    private static let model = "gpt-5.4"

    static var cachedConnected: Bool {
        KeychainStore.string(for: credentialsKey) != nil
    }

    func startLogin() async throws -> CodexLoginSession {
        let requestBody = try JSONEncoder().encode(DeviceCodeRequest(clientID: Self.clientID))
        let (data, response) = try await send(
            url: Self.authBaseURL.appendingPathComponent("api/accounts/deviceauth/usercode"),
            method: "POST",
            body: requestBody,
            contentType: "application/json"
        )
        try Self.requireSuccess(response, data: data, fallback: L10n.text("无法开始 ChatGPT 登录"))
        let deviceCode = try JSONDecoder().decode(DeviceCodeResponse.self, from: data)
        let session = CodexLoginSession(
            loginID: UUID().uuidString,
            verificationURL: Self.authBaseURL.appendingPathComponent("codex/device"),
            userCode: deviceCode.userCode,
            deviceAuthID: deviceCode.deviceAuthID,
            intervalSeconds: max(deviceCode.interval, 2),
            createdAt: Date()
        )
        try Self.save(session, key: Self.pendingLoginKey)
        return session
    }

    func pendingLoginSession() throws -> CodexLoginSession? {
        try Self.load(CodexLoginSession.self, key: Self.pendingLoginKey)
    }

    func status(loginID: String? = nil) async throws -> CodexConnectionStatus {
        if let credentials = try Self.load(CodexCredentials.self, key: Self.credentialsKey) {
            let status = Self.connectedStatus(credentials)
            Self.cache(status)
            return status
        }

        guard let pending = try Self.load(CodexLoginSession.self, key: Self.pendingLoginKey) else {
            let status = Self.disconnectedStatus
            Self.cache(status)
            return status
        }
        guard let loginID, loginID == pending.loginID else {
            return CodexConnectionStatus(
                available: true,
                connected: false,
                pending: true,
                email: nil,
                plan: nil,
                error: nil
            )
        }
        guard Date().timeIntervalSince(pending.createdAt) < 15 * 60 else {
            try? KeychainStore.set("", for: Self.pendingLoginKey)
            throw LocalServiceError.remote(L10n.text("登录已超时，请重新开始"))
        }

        let pollBody = try JSONEncoder().encode(DeviceTokenPollRequest(
            deviceAuthID: pending.deviceAuthID,
            userCode: pending.userCode
        ))
        let (pollData, pollResponse) = try await send(
            url: Self.authBaseURL.appendingPathComponent("api/accounts/deviceauth/token"),
            method: "POST",
            body: pollBody,
            contentType: "application/json"
        )
        if pollResponse.statusCode == 403 || pollResponse.statusCode == 404 {
            return CodexConnectionStatus(
                available: true,
                connected: false,
                pending: true,
                email: nil,
                plan: nil,
                error: nil
            )
        }
        try Self.requireSuccess(pollResponse, data: pollData, fallback: L10n.text("ChatGPT 授权失败"))
        let authorization = try JSONDecoder().decode(DeviceAuthorizationResponse.self, from: pollData)
        let credentials = try await exchange(authorization)
        try Self.save(credentials, key: Self.credentialsKey)
        try? KeychainStore.set("", for: Self.pendingLoginKey)
        let status = Self.connectedStatus(credentials)
        Self.cache(status)
        return status
    }

    func logout() async throws {
        if let credentials = try Self.load(CodexCredentials.self, key: Self.credentialsKey),
           let body = try? JSONEncoder().encode(RevokeRequest(
               token: credentials.refreshToken,
               tokenTypeHint: "refresh_token",
               clientID: Self.clientID
           )) {
            _ = try? await send(
                url: Self.authBaseURL.appendingPathComponent("oauth/revoke"),
                method: "POST",
                body: body,
                contentType: "application/json"
            )
        }
        try KeychainStore.set("", for: Self.credentialsKey)
        try KeychainStore.set("", for: Self.pendingLoginKey)
        Self.cache(Self.disconnectedStatus)
    }

    func complete(prompt: String, webSearch: Bool = false) async throws -> String {
        try await completion(prompt: prompt, webSearch: webSearch).text
    }

    /// - Returns: the answer, and whether the model was actually allowed to
    ///   search. Callers that tell the reader "this used live search" need to
    ///   know the difference, and the fallback below means asking is not the
    ///   same as getting it.
    func completion(prompt: String, webSearch: Bool = false) async throws -> (text: String, searched: Bool) {
        guard var credentials = try Self.load(CodexCredentials.self, key: Self.credentialsKey) else {
            Self.cache(Self.disconnectedStatus)
            throw LocalServiceError.missingCodexConnection
        }
        if credentials.expiresAt.timeIntervalSinceNow < 5 * 60 {
            credentials = try await refresh(credentials)
        }
        do {
            let text = try await run(prompt: prompt, credentials: credentials, webSearch: webSearch)
            return (text, webSearch)
        } catch let error where Self.isTransientNetworkError(error) {
            try await Task.sleep(for: .milliseconds(700))
            let text = try await run(prompt: prompt, credentials: credentials, webSearch: webSearch)
            return (text, webSearch)
        } catch where webSearch {
            // `web_search` is a hosted tool on the Responses API, so asking for
            // it costs no client-side loop — but this endpoint is the ChatGPT
            // Codex backend rather than the documented API, and whether it
            // honours the tool is not something the client can know in advance.
            // One rejected request is the whole price of finding out; the answer
            // is then produced without it and says so.
            let text = try await run(prompt: prompt, credentials: credentials, webSearch: false)
            return (text, false)
        }
    }

    private func run(
        prompt: String,
        credentials: CodexCredentials,
        webSearch: Bool
    ) async throws -> String {
        do {
            return try await requestCompletion(
                prompt: prompt, credentials: credentials, webSearch: webSearch
            )
        } catch CodexRequestError.unauthorized {
            let refreshed = try await refresh(credentials, force: true)
            return try await requestCompletion(
                prompt: prompt, credentials: refreshed, webSearch: webSearch
            )
        }
    }

    static func isTransientNetworkError(_ error: Error) -> Bool {
        guard let code = (error as? URLError)?.code else { return false }
        return [
            .networkConnectionLost,
            .notConnectedToInternet,
            .timedOut,
            .cannotConnectToHost,
            .dnsLookupFailed,
            .internationalRoamingOff,
            .dataNotAllowed,
        ].contains(code)
    }

    private func exchange(_ authorization: DeviceAuthorizationResponse) async throws -> CodexCredentials {
        let body = Self.formBody([
            "grant_type": "authorization_code",
            "code": authorization.authorizationCode,
            "redirect_uri": Self.authBaseURL.appendingPathComponent("deviceauth/callback").absoluteString,
            "client_id": Self.clientID,
            "code_verifier": authorization.codeVerifier,
        ])
        let (data, response) = try await send(
            url: Self.authBaseURL.appendingPathComponent("oauth/token"),
            method: "POST",
            body: Data(body.utf8),
            contentType: "application/x-www-form-urlencoded"
        )
        try Self.requireSuccess(response, data: data, fallback: L10n.text("ChatGPT 令牌交换失败"))
        let tokens = try JSONDecoder().decode(TokenResponse.self, from: data)
        return try Self.credentials(from: tokens)
    }

    private func refresh(_ credentials: CodexCredentials, force: Bool = false) async throws -> CodexCredentials {
        if !force, credentials.expiresAt.timeIntervalSinceNow >= 5 * 60 { return credentials }
        let body = try JSONEncoder().encode(RefreshRequest(
            clientID: Self.clientID,
            grantType: "refresh_token",
            refreshToken: credentials.refreshToken
        ))
        let (data, response) = try await send(
            url: Self.authBaseURL.appendingPathComponent("oauth/token"),
            method: "POST",
            body: body,
            contentType: "application/json"
        )
        guard (200..<300).contains(response.statusCode) else {
            if response.statusCode == 400 || response.statusCode == 401 {
                try? KeychainStore.set("", for: Self.credentialsKey)
                Self.cache(Self.disconnectedStatus)
                throw LocalServiceError.remote(L10n.text("ChatGPT 登录已失效，请重新登录"))
            }
            try Self.requireSuccess(response, data: data, fallback: L10n.text("ChatGPT 登录刷新失败"))
            throw LocalServiceError.invalidResponse
        }
        let refreshed = try JSONDecoder().decode(RefreshTokenResponse.self, from: data)
        let merged = TokenResponse(
            idToken: refreshed.idToken ?? credentials.idToken,
            accessToken: refreshed.accessToken ?? credentials.accessToken,
            refreshToken: refreshed.refreshToken ?? credentials.refreshToken
        )
        let updated = try Self.credentials(from: merged)
        try Self.save(updated, key: Self.credentialsKey)
        Self.cache(Self.connectedStatus(updated))
        return updated
    }

    private func requestCompletion(
        prompt: String,
        credentials: CodexCredentials,
        webSearch: Bool = false
    ) async throws -> String {
        var body: [String: Any] = [
            "model": Self.model,
            "instructions": "你是 Catfolio 的投资组合分析助手。用简洁、可验证的语言回答；明确区分数据与推断，不承诺收益。" + L10n.responseLanguageInstruction,
            "input": [[
                "type": "message",
                "role": "user",
                "content": [["type": "input_text", "text": prompt]],
            ]],
            "tools": [],
            "tool_choice": "none",
            "parallel_tool_calls": false,
            "store": false,
            "stream": true,
            "include": [],
        ]
        if webSearch {
            body["tools"] = [["type": "web_search"]]
            body["tool_choice"] = "auto"
        }
        let encoded = try JSONSerialization.data(withJSONObject: body)
        var request = URLRequest(url: Self.codexResponsesURL)
        request.httpMethod = "POST"
        request.httpBody = encoded
        request.timeoutInterval = 130
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(credentials.accountID, forHTTPHeaderField: "chatgpt-account-id")
        request.setValue("catfolio_ios", forHTTPHeaderField: "originator")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let (data, response) = try await Self.session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LocalServiceError.invalidResponse }
        if http.statusCode == 401 { throw CodexRequestError.unauthorized }
        try Self.requireSuccess(http, data: data, fallback: L10n.text("Codex 分析请求失败"))
        // A requested tool is not proof that the server actually searched.
        if webSearch, !Self.containsCompletedWebSearch(data) {
            throw LocalServiceError.invalidResponse
        }
        return try Self.parseCompletion(data)
    }

    private func send(
        url: URL,
        method: String,
        body: Data,
        contentType: String
    ) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 30
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("catfolio_ios", forHTTPHeaderField: "originator")
        let (data, response) = try await Self.session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LocalServiceError.invalidResponse }
        return (data, http)
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = true
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    private static var disconnectedStatus: CodexConnectionStatus {
        CodexConnectionStatus(
            available: true,
            connected: false,
            pending: false,
            email: nil,
            plan: nil,
            error: nil
        )
    }

    private static func connectedStatus(_ credentials: CodexCredentials) -> CodexConnectionStatus {
        CodexConnectionStatus(
            available: true,
            connected: true,
            pending: false,
            email: credentials.email,
            plan: credentials.plan,
            error: nil
        )
    }

    private static func credentials(from tokens: TokenResponse) throws -> CodexCredentials {
        let idClaims = try jwtClaims(tokens.idToken)
        let accessClaims = try? jwtClaims(tokens.accessToken)
        guard let accountID = idClaims.accountID ?? accessClaims?.accountID, !accountID.isEmpty else {
            throw LocalServiceError.remote(L10n.text("无法识别 ChatGPT 账户"))
        }
        return CodexCredentials(
            idToken: tokens.idToken,
            accessToken: tokens.accessToken,
            refreshToken: tokens.refreshToken,
            accountID: accountID,
            email: idClaims.email ?? accessClaims?.email,
            plan: idClaims.plan ?? accessClaims?.plan,
            expiresAt: accessClaims?.expiration ?? idClaims.expiration ?? Date().addingTimeInterval(45 * 60)
        )
    }

    private static func jwtClaims(_ token: String) throws -> JWTClaims {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { throw LocalServiceError.invalidResponse }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LocalServiceError.invalidResponse
        }
        let auth = root["https://api.openai.com/auth"] as? [String: Any]
        let profile = root["https://api.openai.com/profile"] as? [String: Any]
        return JWTClaims(
            accountID: auth?["chatgpt_account_id"] as? String,
            email: (root["email"] as? String) ?? (profile?["email"] as? String),
            plan: auth?["chatgpt_plan_type"] as? String,
            expiration: (root["exp"] as? TimeInterval).map(Date.init(timeIntervalSince1970:))
        )
    }

    static func containsCompletedWebSearch(_ data: Data) -> Bool {
        guard let stream = String(data: data, encoding: .utf8) else { return false }
        return stream.split(whereSeparator: \.isNewline).contains { line in
            guard line.hasPrefix("data:"),
                  let bytes = String(line.dropFirst(5)).data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { return false }
            if event["type"] as? String == "response.web_search_call.completed" { return true }
            let response = event["response"] as? [String: Any]
            let items = response?["output"] as? [[String: Any]] ?? [event["item"] as? [String: Any] ?? [:]]
            return items.contains { $0["type"] as? String == "web_search_call" && $0["status"] as? String == "completed" }
        }
    }

    private static func parseCompletion(_ data: Data) throws -> String {
        guard let stream = String(data: data, encoding: .utf8) else {
            throw LocalServiceError.invalidResponse
        }
        var output = ""
        for line in stream.split(whereSeparator: \.isNewline) {
            let raw = String(line)
            guard raw.hasPrefix("data:") else { continue }
            let payload = raw.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard payload != "[DONE]", let eventData = payload.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: eventData) as? [String: Any]
            else { continue }
            if event["type"] as? String == "response.output_text.delta",
               let delta = event["delta"] as? String {
                output += delta
            }
        }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LocalServiceError.invalidResponse }
        return trimmed
    }

    private static func requireSuccess(
        _ response: HTTPURLResponse,
        data: Data,
        fallback: String
    ) throws {
        guard (200..<300).contains(response.statusCode) else {
            let message = errorMessage(data) ?? "\(fallback)（\(response.statusCode)）"
            throw LocalServiceError.remote(message)
        }
    }

    private static func errorMessage(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let detail = object["detail"] as? String { return detail }
        if let message = object["message"] as? String { return message }
        if let error = object["error"] as? [String: Any] {
            return (error["message"] as? String) ?? (error["code"] as? String)
        }
        return object["error"] as? String
    }

    private static func formBody(_ values: [String: String]) -> String {
        var components = URLComponents()
        components.queryItems = values.sorted(by: { $0.key < $1.key }).map {
            URLQueryItem(name: $0.key, value: $0.value)
        }
        return components.percentEncodedQuery ?? ""
    }

    private static func save<Value: Encodable>(_ value: Value, key: String) throws {
        let data = try JSONEncoder().encode(value)
        guard let encoded = String(data: data, encoding: .utf8) else {
            throw LocalServiceError.invalidResponse
        }
        try KeychainStore.set(encoded, for: key)
    }

    private static func load<Value: Decodable>(_ type: Value.Type, key: String) throws -> Value? {
        guard let encoded = KeychainStore.string(for: key), let data = encoded.data(using: .utf8) else {
            return nil
        }
        return try JSONDecoder().decode(type, from: data)
    }

    private static func cache(_ status: CodexConnectionStatus) {
        let defaults = UserDefaults.standard
        defaults.set(status.connected, forKey: connectedStorageKey)
        defaults.set(status.email, forKey: accountEmailStorageKey)
        defaults.set(status.plan, forKey: accountPlanStorageKey)
    }

    private struct DeviceCodeRequest: Encodable {
        let clientID: String
        enum CodingKeys: String, CodingKey { case clientID = "client_id" }
    }

    private struct DeviceCodeResponse: Decodable {
        let deviceAuthID: String
        let userCode: String
        let interval: UInt64

        enum CodingKeys: String, CodingKey {
            case deviceAuthID = "device_auth_id"
            case userCode = "user_code"
            case legacyUserCode = "usercode"
            case interval
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            deviceAuthID = try values.decode(String.self, forKey: .deviceAuthID)
            userCode = try values.decodeIfPresent(String.self, forKey: .userCode)
                ?? values.decode(String.self, forKey: .legacyUserCode)
            let rawInterval = try values.decode(String.self, forKey: .interval)
            interval = UInt64(rawInterval.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 5
        }
    }

    private struct DeviceTokenPollRequest: Encodable {
        let deviceAuthID: String
        let userCode: String
        enum CodingKeys: String, CodingKey {
            case deviceAuthID = "device_auth_id"
            case userCode = "user_code"
        }
    }

    private struct DeviceAuthorizationResponse: Decodable {
        let authorizationCode: String
        let codeVerifier: String
        enum CodingKeys: String, CodingKey {
            case authorizationCode = "authorization_code"
            case codeVerifier = "code_verifier"
        }
    }

    private struct TokenResponse: Codable {
        let idToken: String
        let accessToken: String
        let refreshToken: String
        enum CodingKeys: String, CodingKey {
            case idToken = "id_token"
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
        }
    }

    private struct RefreshRequest: Encodable {
        let clientID: String
        let grantType: String
        let refreshToken: String
        enum CodingKeys: String, CodingKey {
            case clientID = "client_id"
            case grantType = "grant_type"
            case refreshToken = "refresh_token"
        }
    }

    private struct RevokeRequest: Encodable {
        let token: String
        let tokenTypeHint: String
        let clientID: String
        enum CodingKeys: String, CodingKey {
            case token
            case tokenTypeHint = "token_type_hint"
            case clientID = "client_id"
        }
    }

    private struct RefreshTokenResponse: Decodable {
        let idToken: String?
        let accessToken: String?
        let refreshToken: String?
        enum CodingKeys: String, CodingKey {
            case idToken = "id_token"
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
        }
    }

    private struct CodexCredentials: Codable {
        let idToken: String
        let accessToken: String
        let refreshToken: String
        let accountID: String
        let email: String?
        let plan: String?
        let expiresAt: Date
    }

    private struct JWTClaims {
        let accountID: String?
        let email: String?
        let plan: String?
        let expiration: Date?
    }

    private enum CodexRequestError: Error { case unauthorized }
}

enum AppleFoundationModelStatus: Equatable {
    case available
    case requiresNewerOS
    case deviceNotEligible
    case appleIntelligenceNotEnabled
    case modelNotReady
    case unknown

    var isAvailable: Bool { self == .available }

    var message: String {
        switch self {
        case .available: L10n.text("Apple 本地模型已就绪")
        case .requiresNewerOS: L10n.text("需要 iOS 26 或更高版本")
        case .deviceNotEligible: L10n.text("这台设备不支持 Apple Intelligence")
        case .appleIntelligenceNotEnabled: L10n.text("请先在系统设置中开启 Apple Intelligence")
        case .modelNotReady: L10n.text("Apple 模型仍在下载或暂未就绪")
        case .unknown: L10n.text("Apple 模型当前不可用")
        }
    }
}

private actor LocalHistoricalPriceCache {
    struct Hit: Sendable {
        let values: [String: Double]
        let isFresh: Bool
    }

    private struct Entry: Codable {
        var fetchedAt: Date
        var values: [String: Double]
        var requestedFrom: String?
        var requestedTo: String?
    }

    static let shared = LocalHistoricalPriceCache()

    private var entries: [String: Entry] = [:]
    private var hasLoaded = false

    func lookup(symbol: String, from: String, to: String) -> Hit? {
        loadIfNeeded()
        guard let entry = entries[symbol] else { return nil }
        let filtered = entry.values.filter { $0.key >= from && $0.key <= to }
        guard !filtered.isEmpty else { return nil }
        return Hit(
            values: filtered,
            isFresh: Date().timeIntervalSince(entry.fetchedAt) < 12 * 60 * 60
                && entry.requestedFrom.map { $0 <= from } == true
                && entry.requestedTo.map { $0 >= to } == true
        )
    }

    func save(symbol: String, values: [String: Double], requestedFrom: String, requestedTo: String) {
        guard !values.isEmpty else { return }
        loadIfNeeded()
        var merged = entries[symbol]?.values ?? [:]
        merged.merge(values) { _, new in new }
        let previous = entries[symbol]
        entries[symbol] = Entry(
            fetchedAt: Date(),
            values: merged,
            requestedFrom: min(previous?.requestedFrom ?? requestedFrom, requestedFrom),
            requestedTo: max(previous?.requestedTo ?? requestedTo, requestedTo)
        )
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }

    private func loadIfNeeded() {
        guard !hasLoaded else { return }
        hasLoaded = true
        guard let data = try? Data(contentsOf: cacheURL),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) else { return }
        entries = decoded
    }

    private var cacheURL: URL {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return root.appendingPathComponent("catfolio-market-history-units-v2.json")
    }
}

private struct MarketIntradayBar: Codable, Sendable {
    let timestamp: Date
    let close: Double
}

/// Minute bars change continuously and have a very different refresh cadence
/// from end-of-day history. Keep them in their own cache so opening a chart
/// repeatedly does not spend another vendor request, while daily history can
/// retain its longer cache lifetime.
private actor LocalIntradayPriceCache {
    struct Hit: Sendable {
        let bars: [MarketIntradayBar]
        let isFresh: Bool
    }

    private struct Entry: Codable {
        let fetchedAt: Date
        let bars: [MarketIntradayBar]
    }

    static let shared = LocalIntradayPriceCache()

    private var entries: [String: Entry] = [:]
    private var hasLoaded = false

    func lookup(symbol: String) -> Hit? {
        loadIfNeeded()
        guard let entry = entries[symbol.uppercased()], entry.bars.count > 1 else { return nil }
        return Hit(
            bars: entry.bars,
            isFresh: Date().timeIntervalSince(entry.fetchedAt) < 5 * 60
        )
    }

    func save(symbol: String, bars: [MarketIntradayBar]) {
        guard bars.count > 1 else { return }
        loadIfNeeded()
        entries[symbol.uppercased()] = Entry(fetchedAt: Date(), bars: bars)
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }

    private func loadIfNeeded() {
        guard !hasLoaded else { return }
        hasLoaded = true
        guard let data = try? Data(contentsOf: cacheURL),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) else { return }
        entries = decoded
    }

    private var cacheURL: URL {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return root.appendingPathComponent("catfolio-intraday-history-units-v2.json")
    }
}

private struct MarketDailyBar: Codable, Sendable {
    let date: String
    let close: Double
    let high: Double
    let low: Double
    let volume: Double
}

struct PortfolioAttentionDailyBar: Sendable {
    let date: String
    let close: Double
    let high: Double
    let low: Double
    let volume: Double
}

/// Each current holding's value by day; see `LocalMarketDataClient.holdingValueHistory`.
struct HoldingValueHistory: Sendable {
    struct Row: Sendable {
        let dateText: String
        let cost: Double
        /// USD by upper-cased ticker.
        let values: [String: Double]
        /// What the holdings open on this day cost, USD by upper-cased ticker.
        var costs: [String: Double] = [:]

        /// A holding's gain on this day: its value less what it cost.
        func gain(_ ticker: String) -> Double {
            guard let value = values[ticker] else { return 0 }
            return value - (costs[ticker] ?? value)
        }

        var date: Date { DayDateCodec.date(from: dateText) ?? .distantPast }
        var total: Double { values.values.reduce(0, +) }
    }

    let rows: [Row]
    /// What each holding cost, USD by upper-cased ticker.
    let costs: [String: Double]
    let names: [String: String]

    /// Each holding's gain on the latest day: its value then less its cost.
    var gains: [String: Double] {
        guard let last = rows.last else { return [:] }
        var result: [String: Double] = [:]
        for (ticker, value) in last.values {
            result[ticker] = value - (last.costs[ticker] ?? costs[ticker] ?? value)
        }
        return result
    }
}

private struct CurrentOpenBackcastPosition {
    let position: LocalPositionRecord
    let startDate: String
}

/// Daily OHLCV changes at most once per trading day, so keep it across app
/// launches instead of spending one vendor request every time a detail opens.
private actor LocalVolumeBarCache {
    struct Hit: Sendable {
        let bars: [MarketDailyBar]
        let isFresh: Bool
    }

    private struct Entry: Codable {
        let fetchedAt: Date
        let bars: [MarketDailyBar]
    }

    static let shared = LocalVolumeBarCache()

    private var entries: [String: Entry] = [:]
    private var hasLoaded = false

    func lookup(symbol: String) -> Hit? {
        loadIfNeeded()
        guard let entry = entries[symbol.uppercased()], !entry.bars.isEmpty else { return nil }
        return Hit(
            bars: entry.bars,
            isFresh: Date().timeIntervalSince(entry.fetchedAt) < 24 * 60 * 60
        )
    }

    func save(symbol: String, bars: [MarketDailyBar]) {
        guard !bars.isEmpty else { return }
        loadIfNeeded()
        entries[symbol.uppercased()] = Entry(fetchedAt: Date(), bars: bars)
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }

    private func loadIfNeeded() {
        guard !hasLoaded else { return }
        hasLoaded = true
        guard let data = try? Data(contentsOf: cacheURL),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) else { return }
        entries = decoded
    }

    private var cacheURL: URL {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return root.appendingPathComponent("catfolio-volume-bars-units-v2.json")
    }
}

private enum LocalRequestSessions {
    static let ephemeral = URLSession(configuration: .ephemeral)
    static let waiting: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForResource = 60
        return URLSession(configuration: configuration)
    }()
}

struct LocalMarketDataClient {
    private static let yahooSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.urlCache = URLCache(
            memoryCapacity: 24 * 1_024 * 1_024,
            diskCapacity: 120 * 1_024 * 1_024
        )
        return URLSession(configuration: configuration)
    }()

    private struct YahooChartResponse: Decodable {
        struct Chart: Decodable {
            let result: [Result]?
            let error: YahooError?
        }

        struct Result: Decodable {
            struct Meta: Decodable { let currency: String? }
            let meta: Meta?
            let timestamp: [Int]?
            let indicators: Indicators
        }

        struct Indicators: Decodable {
            let quote: [Quote]?
            let adjclose: [AdjustedClose]?
        }

        struct Quote: Decodable {
            let close: [Double?]?
            let high: [Double?]?
            let low: [Double?]?
            let volume: [Double?]?
        }

        struct AdjustedClose: Decodable {
            let adjclose: [Double?]?
        }

        struct YahooError: Decodable {
            let code: String?
            let description: String?
        }

        let chart: Chart
    }

    private struct MassiveAggregatesResponse: Decodable {
        struct Aggregate: Decodable {
            let close: Double
            let high: Double
            let low: Double
            let timestamp: Int64
            let volume: Double

            enum CodingKeys: String, CodingKey {
                case close = "c"
                case high = "h"
                case low = "l"
                case timestamp = "t"
                case volume = "v"
            }
        }

        let status: String?
        let results: [Aggregate]?
        let error: String?
        let message: String?
    }

    func portfolioChart(
        document: LocalPortfolioDocument,
        cachedOnly: Bool = false
    ) async throws -> PortfolioChartResponse {
        if document.isPublicDisclosure, let current = document.snapshots.last {
            let rows = document.snapshots.map { ChartPoint(dateText: $0.date, marketValue: $0.marketValueUSD, cost: $0.costUSD) }
            return PortfolioChartResponse(positionCount: document.positions.count,
                positionHistory: PositionHistory(available: rows.count > 1, rows: rows),
                currentPoint: ChartPoint(dateText: current.date, marketValue: current.marketValueUSD, cost: current.costUSD),
                warning: nil)
        }
        if document.isSynthetic == true { return try LocalPortfolioEngine.presentation(for: document).1 }
        do {
            let account = try await accountTimeWeightedSeries(document: document,
                to: DayDateCodec.string(from: Date()), cachedOnly: cachedOnly, includeBenchmarks: false)
            guard let ledger = account.ledger else { throw LocalServiceError.noHistoricalPrices }
            return .accountHistory(ledger: ledger, nav: account.portfolio, positionCount: document.positions.count)
        } catch {
            if cachedOnly { throw error }
            return .unavailableAccountHistory(positionCount: document.positions.count,
                reason: error.localizedDescription.replacingOccurrences(of: "TWR：", with: "账户历史："))
        }
    }

    /// The home chart's history, kept apart by holding: each current
    /// holding's shares at each day's close from the day it was first bought,
    /// by the same method as `currentOpenPositionsHistory`, so the holdings of
    /// a day add up to the home chart's value for it. Values are USD, keyed by
    /// upper-cased ticker with accounts added together; `cost` is the same
    /// net-deposit line the home chart draws.
    func holdingValueHistory(
        document: LocalPortfolioDocument,
        cachedOnly: Bool = false
    ) async throws -> HoldingValueHistory {
        guard !document.positions.isEmpty else { throw LocalPortfolioError.noPortfolio }
        let end = DayDateCodec.string(from: Date())
        var earliestBuyDates: [String: String] = [:]
        for transaction in document.transactions ?? [] where transaction.action.uppercased() == "BUY" {
            let key = "\(transaction.accountKey)|\(transaction.ticker.uppercased())"
            earliestBuyDates[key] = min(earliestBuyDates[key] ?? transaction.date, transaction.date)
        }
        let dated = document.positions.compactMap { position -> CurrentOpenBackcastPosition? in
            let key = "\(position.accountKey)|\(position.ticker.uppercased())"
            guard let startDate = position.openedDate ?? earliestBuyDates[key],
                  DayDateCodec.date(from: startDate) != nil else { return nil }
            return CurrentOpenBackcastPosition(position: position, startDate: startDate)
        }
        guard let start = dated.map(\.startDate).min() else { return HoldingValueHistory(rows: [], costs: [:], names: [:]) }

        let symbols = dated.map { Self.yahooSymbol(ticker: $0.position.ticker, currency: $0.position.quoteCurrency) }.uniqued()
        let histories = await historicalCloses(symbols: symbols, from: start, to: end, cachedOnly: cachedOnly)
        var scales: [String: Double] = [:]
        for item in dated {
            let symbol = Self.yahooSymbol(ticker: item.position.ticker, currency: item.position.quoteCurrency)
            guard let latest = histories[symbol]?.max(by: { $0.key < $1.key })?.value else { continue }
            scales[symbol] = Self.priceScale(ticker: item.position.ticker, currency: item.position.quoteCurrency,
                                             referencePrice: item.position.quotePrice, marketPrice: latest)
        }

        var lastClose: [String: Double] = [:]
        var rows: [HoldingValueHistory.Row] = []
        for date in histories.values.flatMap(\.keys).sorted().uniqued() where date >= start {
            var values: [String: Double] = [:]
            var costs: [String: Double] = [:]
            var cost = 0.0
            for item in dated where date >= item.startDate {
                let position = item.position
                let positionCost = try LocalPortfolioEngine.usd(position.shares * position.averageCost, currency: position.currency)
                cost += positionCost
                costs[position.ticker.uppercased(), default: 0] += positionCost
                let symbol = Self.yahooSymbol(ticker: position.ticker, currency: position.quoteCurrency)
                if let close = histories[symbol]?[date] { lastClose[symbol] = close }
                let value = try lastClose[symbol].map {
                    try LocalPortfolioEngine.usd(position.shares * $0 * (scales[symbol] ?? 1), currency: position.quoteCurrency)
                } ?? positionCost
                values[position.ticker.uppercased(), default: 0] += value
            }
            if !values.isEmpty { rows.append(.init(dateText: date, cost: cost, values: values, costs: costs)) }
        }
        var costs: [String: Double] = [:]
        var names: [String: String] = [:]
        for item in dated {
            let key = item.position.ticker.uppercased()
            costs[key, default: 0] += try LocalPortfolioEngine.usd(item.position.shares * item.position.averageCost,
                                                                   currency: item.position.currency)
            names[key] = names[key] ?? item.position.name
        }
        return HoldingValueHistory(rows: rows, costs: costs, names: names)
    }

    /// Today's share counts held through the whole window, priced at each
    /// day's close. Unlike `holdingValueHistory`, nothing enters on its
    /// purchase date, so a buy never reads as a rise: the total's fall from a
    /// high splits exactly into each holding's own fall, which is what the
    /// underwater analysis draws. A holding with no close yet — listed later
    /// than the window starts — sits at its first close until it trades.
    func fixedShareHistory(
        document: LocalPortfolioDocument,
        years: Int = 5,
        cachedOnly: Bool = false
    ) async throws -> HoldingValueHistory {
        let positions = document.positions.filter { $0.shares > 0 }
        guard !positions.isEmpty else { throw LocalPortfolioError.noPortfolio }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let endDate = Date()
        let startDate = calendar.date(byAdding: .year, value: -years, to: endDate) ?? endDate
        let symbols = positions.map { Self.yahooSymbol(ticker: $0.ticker, currency: $0.quoteCurrency) }.uniqued()
        let histories = await historicalCloses(symbols: symbols, from: DayDateCodec.string(from: startDate),
                                               to: DayDateCodec.string(from: endDate), cachedOnly: cachedOnly)
        var scales: [String: Double] = [:]
        var lastClose: [String: Double] = [:]
        for position in positions {
            let symbol = Self.yahooSymbol(ticker: position.ticker, currency: position.quoteCurrency)
            guard let history = histories[symbol], let latest = history.max(by: { $0.key < $1.key })?.value else { continue }
            scales[symbol] = Self.priceScale(ticker: position.ticker, currency: position.quoteCurrency,
                                             referencePrice: position.quotePrice, marketPrice: latest)
            lastClose[symbol] = history.min(by: { $0.key < $1.key })?.value
        }
        var rows: [HoldingValueHistory.Row] = []
        for date in histories.values.flatMap(\.keys).sorted().uniqued() {
            var values: [String: Double] = [:]
            for position in positions {
                let symbol = Self.yahooSymbol(ticker: position.ticker, currency: position.quoteCurrency)
                if let close = histories[symbol]?[date] { lastClose[symbol] = close }
                guard let close = lastClose[symbol] else { continue }
                values[position.ticker.uppercased(), default: 0] += try LocalPortfolioEngine.usd(
                    position.shares * close * (scales[symbol] ?? 1), currency: position.quoteCurrency)
            }
            if !values.isEmpty { rows.append(.init(dateText: date, cost: 0, values: values)) }
        }
        var names: [String: String] = [:]
        for position in positions { names[position.ticker.uppercased()] = names[position.ticker.uppercased()] ?? position.name }
        return HoldingValueHistory(rows: rows, costs: [:], names: names)
    }

    /// Refreshes the quote carried by every locally stored position. The
    /// result is keyed by ticker and quote currency so multiple broker
    /// accounts for the same instrument share one market request while still
    /// preserving their independent quantities and costs.
    func latestQuotes(for positions: [LocalPositionRecord]) async -> [String: Double] {
        guard !positions.isEmpty else { return [:] }
        let symbols = positions.map {
            Self.yahooSymbol(ticker: $0.ticker, currency: $0.quoteCurrency)
        }.uniqued()
        let rawPrices = await withTaskGroup(of: (String, Double?).self) { group in
            var iterator = symbols.makeIterator()
            let concurrencyLimit = min(8, symbols.count)
            for _ in 0..<concurrencyLimit {
                guard let symbol = iterator.next() else { break }
                group.addTask { (symbol, await latestRawPrice(for: symbol)) }
            }

            var result: [String: Double] = [:]
            while let (symbol, price) = await group.next() {
                if let price, price.isFinite, price > 0 {
                    result[symbol] = price
                }
                if let next = iterator.next() {
                    group.addTask { (next, await latestRawPrice(for: next)) }
                }
            }
            return result
        }

        return positions.reduce(into: [String: Double]()) { result, position in
            let symbol = Self.yahooSymbol(
                ticker: position.ticker,
                currency: position.quoteCurrency
            )
            guard let rawPrice = rawPrices[symbol] else { return }
            let adjusted = rawPrice * Self.priceScale(
                ticker: position.ticker, currency: position.quoteCurrency,
                referencePrice: position.quotePrice,
                marketPrice: rawPrice
            )
            guard adjusted.isFinite, adjusted > 0 else { return }
            result[LocalMarketQuoteKey.make(
                ticker: position.ticker,
                currency: position.quoteCurrency
            )] = adjusted
        }
    }

    private func latestRawPrice(for symbol: String) async -> Double? {
        if let bars = try? await intradayBars(symbol: symbol),
           let price = bars.last?.close,
           price.isFinite,
           price > 0 {
            return price
        }

        let endDate = Date()
        let startDate = Calendar(identifier: .gregorian).date(
            byAdding: .day,
            value: -14,
            to: endDate
        ) ?? endDate
        let history = try? await historicalCloses(
            symbol: symbol,
            from: DayDateCodec.string(from: startDate),
            to: DayDateCodec.string(from: endDate)
        )
        return history?.max(by: { $0.key < $1.key })?.value
    }

    /// Mirrors the desktop/Web chart rule: backcast the currently open broker
    /// positions from their initial fill date using cached daily market prices.
    /// The latest point is calibrated separately from the live broker snapshot.
    private func currentOpenPositionsHistory(
        document: LocalPortfolioDocument,
        end: String,
        cachedOnly: Bool = false
    ) async throws -> (rows: [ChartPoint], warnings: [String]) {
        var earliestBuyDates: [String: String] = [:]
        for transaction in document.transactions ?? [] where transaction.action.uppercased() == "BUY" {
            let key = "\(transaction.accountKey)|\(transaction.ticker.uppercased())"
            earliestBuyDates[key] = min(earliestBuyDates[key] ?? transaction.date, transaction.date)
        }
        let datedPositions = document.positions.compactMap { position -> CurrentOpenBackcastPosition? in
            let key = "\(position.accountKey)|\(position.ticker.uppercased())"
            let startDate = position.openedDate ?? earliestBuyDates[key]
            guard let startDate, DayDateCodec.date(from: startDate) != nil else { return nil }
            return CurrentOpenBackcastPosition(position: position, startDate: startDate)
        }
        guard let start = datedPositions.map(\.startDate).min() else {
            return ([], ["持仓缺少首次建仓日期，当前只能显示最新值。"])
        }

        let symbols = datedPositions.map {
            Self.yahooSymbol(ticker: $0.position.ticker, currency: $0.position.quoteCurrency)
        }.uniqued()
        let histories = await historicalCloses(
            symbols: symbols,
            from: start,
            to: end,
            cachedOnly: cachedOnly
        )
        if cachedOnly, histories.count != symbols.count {
            throw LocalServiceError.noHistoricalPrices
        }
        let dates = histories.values.flatMap(\.keys).sorted().uniqued()
        guard !dates.isEmpty else {
            return ([], ["暂未读取到当前持仓的历史行情，当前只能显示最新值。"])
        }

        var scales: [String: Double] = [:]
        for item in datedPositions {
            let position = item.position
            let symbol = Self.yahooSymbol(ticker: position.ticker, currency: position.quoteCurrency)
            guard let latest = histories[symbol]?.max(by: { $0.key < $1.key })?.value else { continue }
            scales[symbol] = Self.priceScale(
                ticker: position.ticker, currency: position.quoteCurrency,
                referencePrice: position.quotePrice,
                marketPrice: latest
            )
        }

        var lastClose: [String: Double] = [:]
        var rows: [ChartPoint] = []
        for date in dates where date >= start {
            var marketValue = 0.0
            var cost = 0.0
            var activePositions = 0
            for item in datedPositions {
                guard date >= item.startDate else { continue }
                let position = item.position
                activePositions += 1
                let positionCost = try LocalPortfolioEngine.usd(
                    position.shares * position.averageCost,
                    currency: position.currency
                )
                cost += positionCost

                let symbol = Self.yahooSymbol(ticker: position.ticker, currency: position.quoteCurrency)
                if let close = histories[symbol]?[date] {
                    lastClose[symbol] = close
                }
                if let close = lastClose[symbol] {
                    marketValue += try LocalPortfolioEngine.usd(
                        position.shares * close * (scales[symbol] ?? 1),
                        currency: position.quoteCurrency
                    )
                } else {
                    marketValue += positionCost
                }
            }
            if activePositions > 0 {
                rows.append(ChartPoint(dateText: date, marketValue: marketValue, cost: cost))
            }
        }

        var warnings: [String] = []
        let missingSymbols = symbols.filter { histories[$0]?.isEmpty != false }
        if !missingSymbols.isEmpty {
            let preview = missingSymbols.prefix(6).joined(separator: "、")
            let remainder = missingSymbols.count > 6 ? " 等 \(missingSymbols.count) 个标的" : ""
            warnings.append("\(preview)\(remainder)缺少历史行情，市值暂按成本估算。")
        }
        let missingDateCount = document.positions.count - datedPositions.count
        if missingDateCount > 0 {
            warnings.append("\(missingDateCount) 个持仓缺少首次建仓日期，只计入最新值。")
        }
        return (rows, warnings)
    }

    /// Reads the latest two cached daily closes for every holding in one bounded
    /// batch. This powers the heatmap without issuing a separate volume-profile
    /// request for every tile.
    func dailyChanges(for holdings: [Holding]) async -> [String: Double] {
        guard !holdings.isEmpty else { return [:] }

        let endDate = Date.now
        let startDate = Calendar(identifier: .gregorian).date(
            byAdding: .day,
            value: -14,
            to: endDate
        ) ?? endDate
        let start = DayDateCodec.string(from: startDate)
        let end = DayDateCodec.string(from: endDate)
        let symbols = holdings.map {
            Self.yahooSymbol(ticker: $0.ticker, currency: $0.quoteCurrency ?? "USD")
        }.uniqued()
        let histories = await historicalCloses(symbols: symbols, from: start, to: end)

        return holdings.reduce(into: [String: Double]()) { result, holding in
            let symbol = Self.yahooSymbol(
                ticker: holding.ticker,
                currency: holding.quoteCurrency ?? "USD"
            )
            guard let change = Self.latestDailyChange(in: histories[symbol]) else { return }
            result[holding.ticker.uppercased()] = change
        }
    }

    /// Fetches changes for a bounded list of ETF constituents without creating
    /// synthetic portfolio holdings. Callers keep this list small so enabling
    /// look-through does not fan out across an entire index.
    func dailyChanges(tickers: [String]) async -> [String: Double] {
        let tickers = tickers
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
            .filter { !$0.isEmpty && $0 != "ETF 其他" }
            .uniqued()
        guard !tickers.isEmpty else { return [:] }

        let endDate = Date.now
        let startDate = Calendar(identifier: .gregorian).date(
            byAdding: .day,
            value: -14,
            to: endDate
        ) ?? endDate
        let start = DayDateCodec.string(from: startDate)
        let end = DayDateCodec.string(from: endDate)
        let symbolByTicker = Dictionary(uniqueKeysWithValues: tickers.map {
            ($0, Self.yahooSymbol(ticker: $0, currency: "USD"))
        })
        let histories = await historicalCloses(
            symbols: Array(Set(symbolByTicker.values)),
            from: start,
            to: end
        )

        return symbolByTicker.reduce(into: [String: Double]()) { result, entry in
            guard let change = Self.latestDailyChange(in: histories[entry.value]) else { return }
            result[entry.key] = change
        }
    }

    func dailyChange(ticker: String, currency: String = "USD") async -> Double? {
        let endDate = Date.now
        let startDate = Calendar(identifier: .gregorian).date(
            byAdding: .day,
            value: -14,
            to: endDate
        ) ?? endDate
        let start = DayDateCodec.string(from: startDate)
        let end = DayDateCodec.string(from: endDate)
        let symbol = Self.yahooSymbol(ticker: ticker, currency: currency)
        let histories = await historicalCloses(symbols: [symbol], from: start, to: end)
        return Self.latestDailyChange(in: histories[symbol])
    }

    /// Returns one year of daily OHLCV for Catfolio's deterministic attention
    /// engine. The engine, rather than the language model, calculates every
    /// market signal from these bars.
    func portfolioAttentionBars(
        ticker: String,
        currency: String,
        referencePrice: Double
    ) async throws -> [PortfolioAttentionDailyBar] {
        let endDate = Date.now
        let startDate = Calendar(identifier: .gregorian).date(
            byAdding: .day,
            value: -400,
            to: endDate
        ) ?? endDate
        let start = DayDateCodec.string(from: startDate)
        let end = DayDateCodec.string(from: endDate)
        let symbol = Self.yahooSymbol(ticker: ticker, currency: currency)
        let cached = await LocalVolumeBarCache.shared.lookup(symbol: symbol)
        var bars: [MarketDailyBar]?
        var latestError: Error?

        if let cached, cached.isFresh {
            bars = cached.bars
        }
        if bars == nil,
           Self.supportsMassiveStockSymbol(symbol),
           let key = KeychainStore.string(for: LocalServiceKeys.massive), !key.isEmpty {
            do {
                let fetched = try await massiveHistoricalBars(symbol: symbol, from: start, to: end, key: key)
                await LocalVolumeBarCache.shared.save(symbol: symbol, bars: fetched)
                bars = fetched
            } catch {
                latestError = error
            }
        }
        if bars == nil {
            do {
                let fetched = try await yahooHistoricalBars(symbol: symbol, from: start, to: end)
                await LocalVolumeBarCache.shared.save(symbol: symbol, bars: fetched)
                bars = fetched
            } catch {
                latestError = error
            }
        }
        if bars == nil,
           let key = KeychainStore.string(for: LocalServiceKeys.fmp), !key.isEmpty {
            do {
                let fetched = try await fmpHistoricalBars(ticker: ticker, from: start, to: end, key: key)
                await LocalVolumeBarCache.shared.save(symbol: symbol, bars: fetched)
                bars = fetched
            } catch {
                latestError = error
            }
        }
        if bars == nil { bars = cached?.bars }
        guard let bars, !bars.isEmpty else {
            throw latestError ?? LocalServiceError.noHistoricalPrices
        }
        let ordered = bars.sorted { $0.date < $1.date }
        let scale = Self.priceScale(ticker: ticker, currency: currency, referencePrice: referencePrice, marketPrice: ordered.last?.close)
        return ordered.map {
            PortfolioAttentionDailyBar(
                date: $0.date,
                close: $0.close * scale,
                high: $0.high * scale,
                low: $0.low * scale,
                volume: $0.volume
            )
        }
    }

    private static func latestDailyChange(in history: [String: Double]?) -> Double? {
        guard let closes = history?.sorted(by: { $0.key < $1.key }),
              closes.count > 1 else { return nil }
        let latest = closes[closes.count - 1].value
        let previous = closes[closes.count - 2].value
        guard latest.isFinite, previous.isFinite, latest > 0, previous > 0 else { return nil }
        return (latest / previous - 1) * 100
    }

    func volumeProfile(
        ticker: String,
        currency: String,
        referencePrice: Double? = nil,
        forceRefresh: Bool = false
    ) async throws -> VolumeProfile {
        let end = DayDateFormatter.shared.string(from: Date())
        let start = DayDateFormatter.shared.string(
            from: Calendar.current.date(byAdding: .day, value: -370, to: Date()) ?? Date()
        )
        let marketSymbol = Self.yahooSymbol(ticker: ticker, currency: currency)
        let cached = await LocalVolumeBarCache.shared.lookup(symbol: marketSymbol)
        if !forceRefresh, let cached, cached.isFresh {
            return try Self.makeVolumeProfile(
                bars: cached.bars,
                ticker: ticker,
                currency: currency,
                referencePrice: referencePrice,
                fallbackDate: end
            )
        }

        var latestError: Error?
        if Self.supportsMassiveStockSymbol(marketSymbol),
           let key = KeychainStore.string(for: LocalServiceKeys.massive), !key.isEmpty {
            do {
                let bars = try await massiveHistoricalBars(symbol: marketSymbol, from: start, to: end, key: key)
                await LocalVolumeBarCache.shared.save(symbol: marketSymbol, bars: bars)
                return try Self.makeVolumeProfile(
                    bars: bars,
                    ticker: ticker,
                    currency: currency,
                    referencePrice: referencePrice,
                    fallbackDate: end
                )
            } catch {
                latestError = error
            }
        }

        do {
            let bars = try await yahooHistoricalBars(symbol: marketSymbol, from: start, to: end)
            await LocalVolumeBarCache.shared.save(symbol: marketSymbol, bars: bars)
            return try Self.makeVolumeProfile(
                bars: bars,
                ticker: ticker,
                currency: currency,
                referencePrice: referencePrice,
                fallbackDate: end
            )
        } catch {
            latestError = error
        }

        if let key = KeychainStore.string(for: LocalServiceKeys.fmp), !key.isEmpty {
            do {
                let bars = try await fmpHistoricalBars(ticker: ticker, from: start, to: end, key: key)
                await LocalVolumeBarCache.shared.save(symbol: marketSymbol, bars: bars)
                return try Self.makeVolumeProfile(
                    bars: bars,
                    ticker: ticker,
                    currency: currency,
                    referencePrice: referencePrice,
                    fallbackDate: end
                )
            } catch {
                latestError = error
            }
        }

        if let cached {
            return try Self.makeVolumeProfile(
                bars: cached.bars,
                ticker: ticker,
                currency: currency,
                referencePrice: referencePrice,
                fallbackDate: end
            )
        }
        throw latestError ?? LocalServiceError.noMarketData
    }

    func securityPriceHistory(
        ticker: String,
        currency: String,
        referencePrice: Double? = nil,
        document: LocalPortfolioDocument,
        forceRefresh: Bool = false
    ) async throws -> SecurityPriceHistory {
        let normalizedTicker = ticker.uppercased()
        let transactions = (document.transactions ?? []).filter {
            $0.ticker.uppercased() == normalizedTicker
                && SecurityTrade.canonicalAction($0.action) != nil
        }
        let matchingPositions = document.positions
            .filter { $0.ticker.uppercased() == normalizedTicker }
        // MAX means the security's available market history, not the user's
        // holding period. Providers naturally begin at the IPO/listing date.
        // The early sentinel covers Yahoo's oldest daily series; Massive/FMP
        // return the portion covered by the user's plan.
        let start = "1900-01-01"
        let end = DayDateCodec.string(from: Date())
        let symbol = Self.yahooSymbol(ticker: ticker, currency: currency)
        async let dailyCloses = historicalCloses(symbol: symbol, from: start, to: end, forceRefresh: forceRefresh)
        async let latestIntradayBars = intradayBars(symbol: symbol, forceRefresh: forceRefresh)
        let closes = try await dailyCloses
        let intradayBars = (try? await latestIntradayBars) ?? []
        guard !closes.isEmpty else { throw LocalServiceError.noHistoricalPrices }

        let latestMarketClose = closes.max(by: { $0.key < $1.key })?.value
        let scale = Self.priceScale(ticker: ticker, currency: currency, referencePrice: referencePrice, marketPrice: latestMarketClose)
        // referencePrice is only a unit-normalization hint, not a timestamped
        // quote. SecurityPriceHistory merges the dated minute observation.
        let points = closes
            .compactMap { dateText, value -> SecurityPricePoint? in
                let adjusted = value * scale
                guard adjusted.isFinite, adjusted > 0 else { return nil }
                return SecurityPricePoint(dateText: dateText, close: adjusted)
            }
            .sorted { $0.dateText < $1.dateText }
        guard points.count > 1 else { throw LocalServiceError.noHistoricalPrices }
        let intradayPoints = intradayBars.compactMap { bar -> SecurityPricePoint? in
            let adjusted = bar.close * scale
            guard adjusted.isFinite, adjusted > 0 else { return nil }
            return SecurityPricePoint(
                dateText: String(Int(bar.timestamp.timeIntervalSince1970)),
                close: adjusted,
                timestamp: bar.timestamp
            )
        }

        let groupedTrades = Dictionary(grouping: transactions) {
            "\($0.date)|\(SecurityTrade.canonicalAction($0.action) ?? $0.action.uppercased())"
        }
        var trades = groupedTrades.values.compactMap { rows -> SecurityTrade? in
            guard let first = rows.first else { return nil }
            return SecurityTrade(
                dateText: first.date,
                action: SecurityTrade.canonicalAction(first.action) ?? first.action.uppercased(),
                quantity: rows.reduce(0) { $0 + abs($1.quantity) },
                tradeCount: rows.count,
                accountKeys: Set(rows.map(\.accountKey))
            )
        }
        // Trading 212 can provide the API position snapshot before its paged
        // order history has finished syncing. The broker-supplied openedDate
        // still gives us a trustworthy first-entry marker; later buys and all
        // sells appear once the complete transaction history is available.
        if trades.isEmpty {
            let inferredBuys = Dictionary(grouping: matchingPositions.compactMap { position -> (String, Double, String)? in
                guard let date = position.openedDate else { return nil }
                return (date, position.shares, position.accountKey)
            }, by: { $0.0 })
            trades = inferredBuys.map { date, rows in
                SecurityTrade(
                    dateText: date,
                    action: "BUY",
                    quantity: rows.reduce(0) { $0 + abs($1.1) },
                    tradeCount: rows.count,
                    accountKeys: Set(rows.map(\.2))
                )
            }
        }
        trades.sort {
            $0.dateText == $1.dateText ? $0.action < $1.action : $0.dateText < $1.dateText
        }

        return SecurityPriceHistory(
            ticker: ticker,
            currency: currency,
            points: points,
            intradayPoints: intradayPoints,
            trades: trades
        )
    }

    private func intradayBars(symbol: String, forceRefresh: Bool = false) async throws -> [MarketIntradayBar] {
        let cached = await LocalIntradayPriceCache.shared.lookup(symbol: symbol)
        if !forceRefresh, let cached, cached.isFresh { return cached.bars }

        var latestError: Error?
        if Self.supportsMassiveStockSymbol(symbol),
           let key = KeychainStore.string(for: LocalServiceKeys.massive), !key.isEmpty {
            do {
                let bars = try await massiveIntradayBars(symbol: symbol, key: key)
                await LocalIntradayPriceCache.shared.save(symbol: symbol, bars: bars)
                return bars
            } catch {
                latestError = error
            }
        }

        do {
            let bars = try await yahooIntradayBars(symbol: symbol)
            await LocalIntradayPriceCache.shared.save(symbol: symbol, bars: bars)
            return bars
        } catch {
            latestError = error
        }

        if let cached { return cached.bars }
        throw latestError ?? LocalServiceError.noMarketData
    }

    private func massiveIntradayBars(symbol: String, key: String) async throws -> [MarketIntradayBar] {
        let endDate = Date()
        let startDate = Calendar(identifier: .gregorian).date(
            byAdding: .day,
            value: -7,
            to: endDate
        ) ?? endDate
        let start = DayDateCodec.string(from: startDate)
        let end = DayDateCodec.string(from: endDate)
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))
        let encodedSymbol = symbol.addingPercentEncoding(withAllowedCharacters: allowed) ?? symbol
        var components = URLComponents(
            string: "https://api.massive.com/v2/aggs/ticker/\(encodedSymbol)/range/5/minute/\(start)/\(end)"
        )!
        components.queryItems = [
            URLQueryItem(name: "adjusted", value: "true"),
            URLQueryItem(name: "sort", value: "asc"),
            URLQueryItem(name: "limit", value: "50000"),
        ]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 12
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await LocalRequestSessions.ephemeral.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LocalServiceError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw LocalServiceError.remote(Self.message(from: data, fallback: "Massive 日内行情请求失败（\(http.statusCode)）"))
        }
        let payload = try JSONDecoder().decode(MassiveAggregatesResponse.self, from: data)
        if let error = payload.error ?? payload.message, !error.isEmpty {
            throw LocalServiceError.remote(error)
        }
        guard payload.status?.uppercased() == "OK", let aggregates = payload.results else {
            throw LocalServiceError.noMarketData
        }
        let bars = aggregates.compactMap { aggregate -> MarketIntradayBar? in
            guard aggregate.close.isFinite, aggregate.close > 0 else { return nil }
            return MarketIntradayBar(
                timestamp: Date(timeIntervalSince1970: TimeInterval(aggregate.timestamp) / 1_000),
                close: aggregate.close
            )
        }
        return try Self.latestMarketSession(from: bars, symbol: symbol)
    }

    private func yahooIntradayBars(symbol: String) async throws -> [MarketIntradayBar] {
        let endDate = Date()
        let startDate = Calendar(identifier: .gregorian).date(
            byAdding: .day,
            value: -7,
            to: endDate
        ) ?? endDate
        let escapedSymbol = symbol.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? symbol
        var components = URLComponents(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(escapedSymbol)")!
        components.queryItems = [
            URLQueryItem(name: "period1", value: String(Int(startDate.timeIntervalSince1970))),
            URLQueryItem(name: "period2", value: String(Int(endDate.timeIntervalSince1970) + 60)),
            URLQueryItem(name: "interval", value: "5m"),
            URLQueryItem(name: "events", value: "history"),
            URLQueryItem(name: "includePrePost", value: "false"),
        ]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 9
        request.setValue("Mozilla/5.0 Catfolio-iOS", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await Self.yahooSession.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LocalServiceError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw LocalServiceError.remote("Yahoo 日内行情请求失败（\(http.statusCode)）")
        }
        let payload = try JSONDecoder().decode(YahooChartResponse.self, from: data)
        if let error = payload.chart.error {
            throw LocalServiceError.remote(error.description ?? error.code ?? "Yahoo 日内行情读取失败")
        }
        guard let result = payload.chart.result?.first,
              let timestamps = result.timestamp,
              let closes = result.indicators.quote?.first?.close else {
            throw LocalServiceError.noMarketData
        }
        guard let unitScale = InstrumentCurrencyRules.providerPriceScale(symbol: symbol, sourceCurrency: result.meta?.currency) else {
            throw LocalServiceError.remote("行情报价币种无法确认：\(symbol)")
        }
        var bars: [MarketIntradayBar] = []
        bars.reserveCapacity(timestamps.count)
        for (index, timestamp) in timestamps.enumerated() where index < closes.count {
            guard let close = closes[index], close.isFinite, close > 0 else { continue }
            bars.append(MarketIntradayBar(
                timestamp: Date(timeIntervalSince1970: TimeInterval(timestamp)),
                close: close * unitScale
            ))
        }
        return try Self.latestMarketSession(from: bars, symbol: symbol)
    }

    private static func latestMarketSession(
        from bars: [MarketIntradayBar],
        symbol: String
    ) throws -> [MarketIntradayBar] {
        let sorted = bars.sorted { $0.timestamp < $1.timestamp }
        let grouped = Dictionary(grouping: sorted) {
            sessionKey(for: $0.timestamp, symbol: symbol)
        }
        guard let latestKey = grouped.keys.max(),
              let latest = grouped[latestKey], latest.count > 1 else {
            throw LocalServiceError.noMarketData
        }
        // Massive includes pre-market and after-hours aggregates, whereas the
        // Yahoo fallback is requested with includePrePost=false. Normalize U.S.
        // listings to the regular session so the same 1D range is shown no
        // matter which provider answered.
        guard supportsMassiveStockSymbol(symbol) else { return latest }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = marketTimeZone(for: symbol)
        let regularSession = latest.filter { bar in
            let values = calendar.dateComponents([.hour, .minute], from: bar.timestamp)
            let minute = (values.hour ?? 0) * 60 + (values.minute ?? 0)
            return minute >= 9 * 60 + 30 && minute <= 16 * 60
        }
        return regularSession.count > 1 ? regularSession : latest
    }

    private static func sessionKey(for date: Date, symbol: String) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = marketTimeZone(for: symbol)
        let values = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", values.year ?? 0, values.month ?? 0, values.day ?? 0)
    }

    private static func marketTimeZone(for symbol: String) -> TimeZone {
        if symbol.hasSuffix(".L") { return TimeZone(identifier: "Europe/London")! }
        if symbol.hasSuffix(".HK") { return TimeZone(identifier: "Asia/Hong_Kong")! }
        if symbol.hasSuffix(".T") { return TimeZone(identifier: "Asia/Tokyo")! }
        if symbol.hasSuffix(".DE") { return TimeZone(identifier: "Europe/Berlin")! }
        return TimeZone(identifier: "America/New_York")!
    }

    /// A direct Massive probe for Settings; it intentionally bypasses local
    /// caches and the other providers so an invalid key cannot appear valid.
    func testMassiveConnection(apiKey: String? = nil) async throws -> Int {
        let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? KeychainStore.string(for: LocalServiceKeys.massive)
            ?? ""
        guard !key.isEmpty else {
            throw LocalServiceError.missingMassiveKey
        }
        let end = DayDateFormatter.shared.string(from: Date())
        let start = DayDateFormatter.shared.string(
            from: Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
        )
        return try await massiveHistoricalBars(symbol: "AAPL", from: start, to: end, key: key).count
    }

    /// Settings uses this direct probe so the "test FMP" button cannot pass
    /// merely because the Yahoo fallback or a local cache happened to work.
    func testFMPConnection(apiKey: String? = nil) async throws -> Int {
        let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? KeychainStore.string(for: LocalServiceKeys.fmp)
            ?? ""
        guard !key.isEmpty else {
            throw LocalServiceError.missingMarketKey
        }
        let end = DayDateFormatter.shared.string(from: Date())
        let start = DayDateFormatter.shared.string(
            from: Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
        )
        return try await fmpHistoricalBars(ticker: "AAPL", from: start, to: end, key: key).count
    }

    private func fmpHistoricalBars(
        ticker: String,
        from start: String,
        to end: String,
        key: String
    ) async throws -> [MarketDailyBar] {
        // This endpoint has no currency metadata. Do not use it for London
        // listings where pounds and pence cannot be distinguished safely.
        guard !ticker.uppercased().hasSuffix(".L"), InstrumentCurrencyRules.marketDataSymbol(for: ticker) == nil else {
            throw LocalServiceError.remote("FMP 无法确认伦敦标的报价币种")
        }
        var components = URLComponents(string: "https://financialmodelingprep.com/stable/historical-price-eod/full")!
        components.queryItems = [
            URLQueryItem(name: "symbol", value: ticker),
            URLQueryItem(name: "from", value: start),
            URLQueryItem(name: "to", value: end),
            URLQueryItem(name: "apikey", value: key),
        ]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 25
        try await FMPRequestLimiter.shared.waitForTurn()
        let (data, response) = try await LocalRequestSessions.waiting.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LocalServiceError.invalidResponse }
        if http.statusCode == 429 {
            await FMPRequestLimiter.shared.backOff(retryAfter: http.value(forHTTPHeaderField: "Retry-After"))
            let wait = await FMPRequestLimiter.shared.secondsUntilFreeSlot
            throw FMPFailure.rateLimited(retryAfterSeconds: Int(wait.rounded(.up)))
        }
        guard (200..<300).contains(http.statusCode) else {
            throw LocalServiceError.remote(Self.message(from: data, fallback: "行情请求失败（\(http.statusCode)）"))
        }
        let bars: [MarketDailyBar]
        do {
            bars = try JSONDecoder().decode([MarketDailyBar].self, from: data)
        } catch {
            throw LocalServiceError.remote(Self.message(from: data, fallback: "FMP 返回格式无法识别"))
        }
        guard !bars.isEmpty else { throw LocalServiceError.noMarketData }
        return bars
    }

    private func massiveHistoricalBars(
        symbol: String,
        from start: String,
        to end: String,
        key: String
    ) async throws -> [MarketDailyBar] {
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))
        let encodedSymbol = symbol.addingPercentEncoding(withAllowedCharacters: allowed) ?? symbol
        var components = URLComponents(
            string: "https://api.massive.com/v2/aggs/ticker/\(encodedSymbol)/range/1/day/\(start)/\(end)"
        )!
        components.queryItems = [
            URLQueryItem(name: "adjusted", value: "true"),
            URLQueryItem(name: "sort", value: "asc"),
            URLQueryItem(name: "limit", value: "50000"),
        ]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 20
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await LocalRequestSessions.ephemeral.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LocalServiceError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw LocalServiceError.remote(Self.message(from: data, fallback: "Massive 行情请求失败（\(http.statusCode)）"))
        }
        let payload: MassiveAggregatesResponse
        do {
            payload = try JSONDecoder().decode(MassiveAggregatesResponse.self, from: data)
        } catch {
            throw LocalServiceError.remote("Massive 返回格式无法识别")
        }
        if let error = payload.error ?? payload.message, !error.isEmpty {
            throw LocalServiceError.remote(error)
        }
        guard payload.status?.uppercased() == "OK", let aggregates = payload.results, !aggregates.isEmpty else {
            throw LocalServiceError.noMarketData
        }
        let bars = aggregates.compactMap { aggregate -> MarketDailyBar? in
            guard aggregate.close > 0, aggregate.high > 0, aggregate.low > 0 else { return nil }
            return MarketDailyBar(
                date: DayDateCodec.string(
                    from: Date(timeIntervalSince1970: TimeInterval(aggregate.timestamp) / 1_000)
                ),
                close: aggregate.close,
                high: aggregate.high,
                low: aggregate.low,
                volume: aggregate.volume
            )
        }
        guard !bars.isEmpty else { throw LocalServiceError.noMarketData }
        return bars
    }

    private func yahooHistoricalBars(
        symbol: String,
        from start: String,
        to end: String
    ) async throws -> [MarketDailyBar] {
        guard let fromDate = DayDateCodec.date(from: start),
              let toDate = DayDateCodec.date(from: end) else {
            throw LocalServiceError.invalidResponse
        }
        let period1 = Int(fromDate.timeIntervalSince1970)
        let period2Date = Calendar(identifier: .gregorian).date(byAdding: .day, value: 1, to: toDate) ?? toDate
        let period2 = Int(period2Date.timeIntervalSince1970)
        let escapedSymbol = symbol.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? symbol
        var components = URLComponents(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(escapedSymbol)")!
        components.queryItems = [
            URLQueryItem(name: "period1", value: String(period1)),
            URLQueryItem(name: "period2", value: String(period2)),
            URLQueryItem(name: "interval", value: "1d"),
            URLQueryItem(name: "events", value: "history"),
        ]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 9
        request.setValue("Mozilla/5.0 Catfolio-iOS", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await Self.yahooSession.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LocalServiceError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw LocalServiceError.remote("Yahoo 成交量请求失败（\(http.statusCode)）")
        }
        let payload = try JSONDecoder().decode(YahooChartResponse.self, from: data)
        if let error = payload.chart.error {
            throw LocalServiceError.remote(error.description ?? error.code ?? "Yahoo 成交量读取失败")
        }
        guard let result = payload.chart.result?.first,
              let timestamps = result.timestamp,
              let quote = result.indicators.quote?.first,
              let closes = quote.close,
              let highs = quote.high,
              let lows = quote.low,
              let volumes = quote.volume else {
            throw LocalServiceError.noMarketData
        }
        guard let unitScale = InstrumentCurrencyRules.providerPriceScale(symbol: symbol, sourceCurrency: result.meta?.currency) else {
            throw LocalServiceError.remote("行情报价币种无法确认：\(symbol)")
        }
        var bars: [MarketDailyBar] = []
        for index in timestamps.indices {
            guard index < closes.count, index < highs.count, index < lows.count, index < volumes.count,
                  let close = closes[index], let high = highs[index], let low = lows[index], let volume = volumes[index],
                  close > 0, high > 0, low > 0 else { continue }
            bars.append(MarketDailyBar(
                date: DayDateCodec.string(from: Date(timeIntervalSince1970: TimeInterval(timestamps[index]))),
                close: close * unitScale,
                high: high * unitScale,
                low: low * unitScale,
                volume: volume
            ))
        }
        guard !bars.isEmpty else { throw LocalServiceError.noMarketData }
        return bars
    }

    private static func makeVolumeProfile(
        bars: [MarketDailyBar],
        ticker: String,
        currency: String,
        referencePrice: Double?,
        fallbackDate: String
    ) throws -> VolumeProfile {
        let annualSessions = Array(bars.sorted { $0.date > $1.date }.prefix(252))
        let sessions = Array(annualSessions.prefix(160))
        let scale = Self.priceScale(
            ticker: ticker, currency: currency,
            referencePrice: referencePrice,
            marketPrice: annualSessions.first?.close
        )
        let todayChangePercent: Double? = {
            guard annualSessions.count > 1, annualSessions[1].close > 0 else { return nil }
            return (annualSessions[0].close / annualSessions[1].close - 1) * 100
        }()
        let minimum = sessions.map { $0.low * scale }.min() ?? 0
        let maximum = sessions.map { $0.high * scale }.max() ?? 0
        guard maximum > minimum else { throw LocalServiceError.noMarketData }
        let binCount = 36
        let width = (maximum - minimum) / Double(binCount)
        var bins = Array(repeating: 0.0, count: binCount)
        for bar in sessions where bar.volume > 0 {
            let typical = (bar.high + bar.low + bar.close) / 3 * scale
            let index = min(binCount - 1, max(0, Int((typical - minimum) / width)))
            bins[index] += bar.volume
        }
        guard let pocIndex = bins.indices.max(by: { bins[$0] < bins[$1] }), bins[pocIndex] > 0 else {
            throw LocalServiceError.noMarketData
        }
        let target = bins.reduce(0, +) * 0.70
        var lowIndex = pocIndex
        var highIndex = pocIndex
        var covered = bins[pocIndex]
        while covered < target, lowIndex > 0 || highIndex < binCount - 1 {
            let lower = lowIndex > 0 ? bins[lowIndex - 1] : -1
            let upper = highIndex < binCount - 1 ? bins[highIndex + 1] : -1
            if upper >= lower {
                highIndex += 1
                covered += bins[highIndex]
            } else {
                lowIndex -= 1
                covered += bins[lowIndex]
            }
        }
        func midpoint(_ index: Int) -> Double { minimum + (Double(index) + 0.5) * width }
        return VolumeProfile(
            ticker: ticker,
            currency: currency,
            available: true,
            valueAreaHigh: midpoint(highIndex),
            pointOfControl: midpoint(pocIndex),
            valueAreaLow: midpoint(lowIndex),
            sessions: sessions.count,
            valueAreaPercent: 70,
            asOf: sessions.map(\.date).max() ?? fallbackDate,
            fiftyTwoWeekHigh: annualSessions.map { $0.high * scale }.max(),
            fiftyTwoWeekLow: annualSessions.map { $0.low * scale }.min(),
            // The oldest close in the same 252-session window is the period
            // start used by the 52-week performance segment.
            fiftyTwoWeekStartPrice: annualSessions.last.map { $0.close * scale },
            todayChangePercent: todayChangePercent,
            bins: bins.indices.map { index in
                VolumeProfileBin(
                    priceLow: minimum + Double(index) * width,
                    priceHigh: minimum + Double(index + 1) * width,
                    volume: bins[index]
                )
            }
        )
    }

    func comparison(document: LocalPortfolioDocument) async throws -> ComparisonResponse {
        guard !document.positions.isEmpty || !(document.transactions ?? []).isEmpty else { throw LocalPortfolioError.noPortfolio }
        let end = DayDateCodec.string(from: Date())
        // All three modes share the same private, on-device account ledger.
        let benchmarkSymbols = ComparisonBenchmarkCatalog.symbols
        var dates: [String] = []
        var portfolio: [Double?] = []
        var series = Dictionary(uniqueKeysWithValues: benchmarkSymbols.map { ($0, [Double?]()) })
        var portfolioReturnSeries: [Double?] = []
        var benchmarkReturnSeries = Dictionary(
            uniqueKeysWithValues: benchmarkSymbols.map { ($0, [Double?]()) }
        )
        var mwrPortfolioSeries: [Double?] = []
        var mwrBenchmarkSeries = Dictionary(
            uniqueKeysWithValues: benchmarkSymbols.map { ($0, [Double?]()) }
        )
        var returns = Dictionary(uniqueKeysWithValues: benchmarkSymbols.map { ($0, Optional<Double>.none) })
        var comparisonWarnings: [String] = []
        var cashFlowPortfolioReturn: Double?

        var twr: (dates: [String], portfolio: [Double?], benchmarks: [String: [Double?]], ledger: AccountMWRLedger?) = ([], [], [:], nil)
        do {
            twr = try await accountTimeWeightedSeries(document: document, to: end)
            guard let ledger = twr.ledger, let mirrored = ledger.cashFlowComparison() else {
                throw DailyTimeWeightedReturn.Failure(message: "缺少完整入金和出金金额。")
            }
            dates = ledger.dates
            portfolio = mirrored.portfolio
            series = mirrored.benchmarks
            portfolioReturnSeries = mirrored.portfolioReturns
            benchmarkReturnSeries = mirrored.benchmarkReturns
            cashFlowPortfolioReturn = mirrored.portfolioReturns.last ?? nil
            for symbol in benchmarkSymbols { returns[symbol] = mirrored.benchmarkReturns[symbol]?.last ?? nil }
            comparisonWarnings.append("现金流镜像：组合与基准使用相同日期、相同金额的真实外部资金流。曲线为剩余资产（含现金）＋累计取出金额，单位 USD；百分比为累计盈亏÷累计入金。基准按同日可用收盘总收益价格模拟，不含额外交易费用，非实际日内成交。现金余额尚未与券商核对。")
            let unavailable = benchmarkSymbols.filter { (mirrored.benchmarks[$0]?.last ?? nil) == nil }
            if !unavailable.isEmpty {
                comparisonWarnings.append("现金流镜像：\(unavailable.joined(separator: "、")) 缺少可用行情或无法支付同额出金，最新结果不可用。")
            }
            let mwr = twr.ledger?.returns()
            mwrPortfolioSeries = mwr?.portfolio ?? []
            mwrBenchmarkSeries = mwr?.benchmarks ?? [:]
            comparisonWarnings.append("每日 TWR 基于资金流水重建；入金按日初、出金按日末处理，股息按到账日计入。期末现金尚未与券商余额核对。")
            comparisonWarnings.append("MWR：按实际入出金日期和含现金的账户净值计算所选期间收益，非年化；股息按到账日计入，现金余额尚未与券商核对。基准按同日收盘价模拟资金进出。")
        } catch {
            let reason = error.localizedDescription
            comparisonWarnings.append(reason.hasPrefix("TWR：") ? reason : "TWR：\(reason)")
            comparisonWarnings.append("MWR：" + reason.replacingOccurrences(of: "TWR：", with: ""))
            comparisonWarnings.append("现金流镜像：" + reason.replacingOccurrences(of: "TWR：", with: ""))
        }
        return ComparisonResponse(
            available: !dates.isEmpty || !twr.dates.isEmpty,
            dates: dates,
            portfolio: portfolio,
            benchmarks: series,
            cashFlowPortfolioReturns: portfolioReturnSeries,
            cashFlowBenchmarkReturns: benchmarkReturnSeries,
            mwrPortfolio: mwrPortfolioSeries,
            mwrBenchmarks: mwrBenchmarkSeries,
            twrDates: twr.dates,
            twrPortfolio: twr.portfolio,
            twrBenchmarks: twr.benchmarks,
            warnings: comparisonWarnings.isEmpty ? nil : comparisonWarnings,
            summary: ComparisonSummary(
                portfolioReturn: cashFlowPortfolioReturn,
                benchmarkReturn: returns["SPY"] ?? nil,
                benchmarkReturns: returns
            ),
            mwrLedger: twr.ledger
        )
    }

    /// All private ledger data stays on-device. Only public symbols/dates are
    /// sent to the market provider. Core is not a runtime dependency.
    private func accountTimeWeightedSeries(
        document: LocalPortfolioDocument, to end: String, cachedOnly: Bool = false, includeBenchmarks: Bool = true
    ) async throws -> (dates: [String], portfolio: [Double?], benchmarks: [String: [Double?]], ledger: AccountMWRLedger?) {
        typealias T = DailyTimeWeightedReturn
        let records = document.transactions ?? []
        guard document.isSynthetic != true, !document.isPublicDisclosure,
              let start = records.map(\.date).min(), start <= end else {
            throw T.Failure(message: "TWR：需要完整账户资金流水。")
        }
        var events: [T.Event] = []
        var currencies = Set<String>()
        var symbols = Set<String>()
        for row in records {
            let action = row.action.uppercased()
            guard ["BUY", "SELL", "DEPOSIT", "WITHDRAWAL", "DIVIDEND", "INTEREST", "FEE", "TAX"].contains(action) else {
                throw T.Failure(message: "TWR：暂不能处理流水类型 \(row.action)，请补全换汇或公司行动分录。")
            }
            guard let cash = row.cashPostings, !cash.isEmpty else {
                throw T.Failure(message: "TWR：\(row.date) \(row.ticker) 缺少净现金金额及币种，请导入完整资金流水。")
            }
            let trade = action == "BUY" || action == "SELL"
            guard row.quantity.isFinite, !trade || row.quantity > 0 else {
                throw T.Failure(message: "TWR：交易数量无效。")
            }
            let debit = ["BUY", "WITHDRAWAL", "FEE", "TAX"].contains(action)
            guard cash.allSatisfy({ !$0.amount.isNaN && (debit ? $0.amount <= 0 : $0.amount >= 0) }) else {
                throw T.Failure(message: "TWR：净现金金额方向与流水类型不符。")
            }
            let symbol = trade ? Self.yahooSymbol(ticker: row.ticker, currency: row.currency) : nil
            if let symbol { symbols.insert(symbol) }
            currencies.formUnion(cash.map(\.currency))
            events.append(T.Event(id: row.id, date: row.date, account: row.accountKey,
                symbol: symbol, quantity: trade ? Decimal(row.quantity) * (action == "BUY" ? 1 : -1) : 0,
                cash: cash, external: action == "DEPOSIT" || action == "WITHDRAWAL"))
        }
        var prices: [String: LedgerPriceHistory] = [:]
        var splits: [T.Split] = []
        for symbol in symbols.sorted() {
            try Task.checkCancellation()
            let history = try await ledgerPriceHistory(symbol: symbol, from: start, to: end, cachedOnly: cachedOnly)
            prices[symbol] = history
            currencies.insert(history.currency)
            splits += history.splits
        }
        var fx: [String: [String: Double]] = [:]
        for currency in currencies where currency != "USD" {
            let normalized = currency == "GBX" ? "GBP" : currency
            let fxStart = DayDateCodec.string(from: DayDateCodec.date(from: start)!.addingTimeInterval(-7 * 86400))
            let history = try await historicalCloses(symbol: "\(normalized)USD=X", from: fxStart, to: end, cachedOnly: cachedOnly)
            fx[currency] = history.mapValues { currency == "GBX" ? $0 / 100 : $0 }
        }
        guard var date = DayDateCodec.date(from: start), let last = DayDateCodec.date(from: end) else {
            throw T.Failure(message: "TWR：日期无效。")
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var days: [T.Day] = []
        var lastQuotes: [String: (date: Date, quote: T.Quote)] = [:]
        var lastRates: [String: (date: Date, rate: Decimal)] = [:]
        for (symbol, history) in prices {
            if let key = history.closes.keys.filter({ $0 < start }).max(), let close = history.closes[key], let prior = DayDateCodec.date(from: key) {
                lastQuotes[symbol] = (prior, T.Quote(price: Decimal(close), currency: history.currency))
            }
        }
        for (currency, history) in fx {
            if let key = history.keys.filter({ $0 < start }).max(), let rate = history[key], let prior = DayDateCodec.date(from: key) {
                lastRates[currency] = (prior, Decimal(rate))
            }
        }
        while date <= last {
            let key = DayDateCodec.string(from: date)
            // A pre-split close cannot value post-split quantities. Require a
            // fresh quote on the new basis even within the short carry window.
            for split in splits where split.date == key { lastQuotes.removeValue(forKey: split.symbol) }
            for (symbol, history) in prices {
                if let close = history.closes[key] {
                    lastQuotes[symbol] = (date, T.Quote(price: Decimal(close), currency: history.currency))
                }
            }
            for (currency, history) in fx {
                if let rate = history[key], rate.isFinite, rate > 0 { lastRates[currency] = (date, Decimal(rate)) }
            }
            // Carry an already observed close across short market closures;
            // never backfill from a future quote or flatten long missing spans.
            let maxAge: TimeInterval = 4 * 86_400
            let quotes = lastQuotes.filter { date.timeIntervalSince($0.value.date) <= maxAge }.mapValues(\.quote)
            let rates = lastRates.filter { date.timeIntervalSince($0.value.date) <= maxAge }.mapValues(\.rate)
            days.append(T.Day(date: key, quotes: quotes, usdRates: rates))
            date = calendar.date(byAdding: .day, value: 1, to: date)!
        }
        let result = try T.calculate(events: events, days: days, splits: splits)
        var expected: [String: [String: Decimal]] = [:]
        for position in document.positions {
            let symbol = Self.yahooSymbol(ticker: position.ticker, currency: position.quoteCurrency)
            expected[position.accountKey, default: [:]][symbol, default: 0] += Decimal(position.shares)
        }
        for account in Set(expected.keys).union(result.holdings.keys) {
            for symbol in Set(expected[account]?.keys.map { $0 } ?? []).union(result.holdings[account]?.keys.map { $0 } ?? []) {
                let difference = (expected[account]?[symbol] ?? 0) - (result.holdings[account]?[symbol] ?? 0)
                guard abs(NSDecimalNumber(decimal: difference).doubleValue) < 0.000001 else {
                    throw T.Failure(message: "TWR：\(symbol) 重建持仓与当前账户不符，请核查流水、拆股和证券转账。")
                }
            }
        }
        // An explicit baseline preserves the first funded day's return when
        // the chart rebases the selected range to its first point.
        let baseline = calendar.date(byAdding: .day, value: -1, to: DayDateCodec.date(from: result.points[0].date)!)!
        let dates = [DayDateCodec.string(from: baseline)] + result.points.map(\.date)
        let benchmarkSymbols = includeBenchmarks ? ComparisonBenchmarkCatalog.symbols : []
        let benchmarks = await historicalCloses(symbols: benchmarkSymbols, from: dates[0], to: end, cachedOnly: cachedOnly)
        var series: [String: [Double?]] = [:]
        for symbol in benchmarkSymbols {
            let closes = Self.closes(onOrBefore: dates, in: benchmarks[symbol] ?? [:])
            // No different starting line for a benchmark missing the baseline.
            if let first = closes.first, let base = first, base > 0 {
                series[symbol] = closes.map { $0.map { $0 / base } }
            }
        }
        let flows = [0.0] + result.points.map { NSDecimalNumber(decimal: $0.inflow - $0.outflow).doubleValue }
        var benchmarkValues: [String: [Double?]] = [:]
        for symbol in benchmarkSymbols {
            let history = benchmarks[symbol] ?? [:]
            var quoteDate = history.keys.filter { $0 <= dates[0] }.max()
            let aligned: [Double?] = dates.map { date in
                if history[date] != nil { quoteDate = date }
                guard let quoteDate, let quoted = DayDateCodec.date(from: quoteDate), let day = DayDateCodec.date(from: date),
                      day.timeIntervalSince(quoted) <= 4 * 86400 else { return nil }
                return history[quoteDate]
            }
            benchmarkValues[symbol] = AccountMWRLedger.mirror(cashFlows: flows, prices: aligned)
        }
        let ledger = AccountMWRLedger(dates: dates, cashFlows: flows,
            values: [0] + result.points.map { NSDecimalNumber(decimal: $0.value).doubleValue },
            benchmarkValues: benchmarkValues,
            inflows: [0] + result.points.map { NSDecimalNumber(decimal: $0.inflow).doubleValue },
            outflows: [0] + result.points.map { NSDecimalNumber(decimal: $0.outflow).doubleValue })
        return (dates, [1] + result.points.map { NSDecimalNumber(decimal: $0.nav).doubleValue }, series, ledger)
    }

    private struct LedgerPriceHistory: Codable {
        var currency: String
        var closes: [String: Double]
        var splits: [DailyTimeWeightedReturn.Split]
        var fetchedAt: Date
    }

    /// Yahoo quote.close is split-adjusted. Undo subsequent splits to get the
    /// contemporaneous price used with actual historical share quantities.
    private func ledgerPriceHistory(symbol: String, from: String, to: String, cachedOnly: Bool = false) async throws -> LedgerPriceHistory {
        let cacheKey = Data("ledger-v1|\(symbol)|\(from)|\(to)".utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
        let cacheURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(cacheKey + ".json")
        let cached = (try? Data(contentsOf: cacheURL)).flatMap { try? JSONDecoder().decode(LedgerPriceHistory.self, from: $0) }
        if cachedOnly {
            guard let cached else { throw LocalServiceError.noHistoricalPrices }
            return cached
        }
        if let cached, Date().timeIntervalSince(cached.fetchedAt) < 12 * 3600 { return cached }
        guard let start = DayDateCodec.date(from: from), let end = DayDateCodec.date(from: to) else { throw LocalServiceError.invalidResponse }
        var url = URLComponents(string: "https://query1.finance.yahoo.com/v8/finance/chart/")!
        url.path += symbol
        url.queryItems = [URLQueryItem(name: "period1", value: String(Int(start.timeIntervalSince1970 - 7 * 86400))),
            URLQueryItem(name: "period2", value: String(Int(end.timeIntervalSince1970 + 86400))),
            URLQueryItem(name: "interval", value: "1d"), URLQueryItem(name: "events", value: "splits")]
        var request = URLRequest(url: url.url!)
        request.timeoutInterval = 15
        request.setValue("Mozilla/5.0 Catfolio-iOS", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await Self.yahooSession.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let chart = root["chart"] as? [String: Any],
                  let result = (chart["result"] as? [[String: Any]])?.first,
                  let meta = result["meta"] as? [String: Any], let currency = meta["currency"] as? String,
                  let timezone = meta["exchangeTimezoneName"] as? String, let zone = TimeZone(identifier: timezone),
                  let timestamps = result["timestamp"] as? [Double],
                  let indicators = result["indicators"] as? [String: Any],
                  let quote = (indicators["quote"] as? [[String: Any]])?.first,
                  let closes = quote["close"] as? [Any] else { throw LocalServiceError.invalidResponse }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = zone
            formatter.dateFormat = "yyyy-MM-dd"
            func day(_ timestamp: Double) -> String { formatter.string(from: Date(timeIntervalSince1970: timestamp)) }
            let eventMap = result["events"] as? [String: Any]
            let rawSplits = eventMap?["splits"] as? [String: [String: Any]] ?? [:]
            var splits: [DailyTimeWeightedReturn.Split] = []
            for event in rawSplits.values {
                guard let timestamp = event["date"] as? Double, let numerator = event["numerator"] as? Double,
                      let denominator = event["denominator"] as? Double, numerator > 0, denominator > 0 else { throw LocalServiceError.invalidResponse }
                splits.append(.init(date: day(timestamp), symbol: symbol, factor: Decimal(numerator / denominator)))
            }
            var values: [String: Double] = [:]
            for (index, timestamp) in timestamps.enumerated() where closes.indices.contains(index) {
                guard let close = closes[index] as? Double, close.isFinite, close > 0 else { continue }
                let date = day(timestamp)
                let factor = splits.filter { $0.date > date }.reduce(1.0) { $0 * NSDecimalNumber(decimal: $1.factor).doubleValue }
                values[date] = close * factor
            }
            guard !values.isEmpty else { throw LocalServiceError.noHistoricalPrices }
            let history = LedgerPriceHistory(currency: currency == "GBp" ? "GBX" : currency.uppercased(), closes: values,
                splits: splits.filter { $0.date >= from && $0.date <= to }, fetchedAt: Date())
            try? JSONEncoder().encode(history).write(to: cacheURL, options: .atomic)
            return history
        } catch {
            if let cached { return cached }
            throw error
        }
    }

    private static func currentWeightModelSeries(
        document: LocalPortfolioDocument,
        positionHistories: [String: [String: Double]],
        benchmarkHistories: [String: [String: Double]]
    ) throws -> (dates: [String], portfolio: [Double?], benchmarks: [String: [Double?]]) {
        var marketValues: [String: Double] = [:]
        for position in document.positions {
            let symbol = yahooSymbol(ticker: position.ticker, currency: position.quoteCurrency)
            let value = try LocalPortfolioEngine.usd(
                position.shares * position.quotePrice,
                currency: position.quoteCurrency
            )
            marketValues[symbol, default: 0] += value
        }
        let available = marketValues.filter { positionHistories[$0.key]?.count ?? 0 > 1 }
        let totalValue = available.values.reduce(0, +)
        guard totalValue > 0, !available.isEmpty else { return ([], [], [:]) }
        let weights = available.mapValues { $0 / totalValue }

        // Do not intersect every holding's trading dates. A recently listed or
        // sparsely covered holding would otherwise truncate the whole TWR chart
        // (SOHO.L, for example, reduced a one-year chart to a few weeks).
        // A shared market calendar keeps every series aligned; individual
        // holdings are forward-filled only from an already observed close.
        let benchmarkDates = Set(benchmarkHistories.values.flatMap(\.keys))
        let positionDates = Set(positionHistories.values.flatMap(\.keys))
        let dates = (benchmarkDates.isEmpty ? positionDates : benchmarkDates).sorted()
        guard !dates.isEmpty else { return ([], [], [:]) }

        let alignedPositionCloses = Dictionary(uniqueKeysWithValues: weights.keys.map { symbol in
            (symbol, Self.closes(onOrBefore: dates, in: positionHistories[symbol] ?? [:]))
        })

        var portfolioNAV = 1.0
        var portfolio: [Double?] = [portfolioNAV]
        if dates.count > 1 {
            for index in 1..<dates.count {
                var dailyReturn = 0.0
                var coveredWeight = 0.0
                for (symbol, weight) in weights {
                    guard let closes = alignedPositionCloses[symbol],
                          let previous = closes[index - 1], previous > 0,
                          let current = closes[index], current > 0 else { continue }
                    dailyReturn += (current / previous - 1) * weight
                    coveredWeight += weight
                }
                // Do not let a tiny surviving slice of the portfolio dictate
                // the whole day's return when the historical cache is sparse.
                if coveredWeight >= 0.95 {
                    dailyReturn /= coveredWeight
                } else {
                    dailyReturn = 0
                }
                portfolioNAV *= 1 + dailyReturn
                portfolio.append(portfolioNAV)
            }
        }

        var benchmarks: [String: [Double?]] = [:]
        for symbol in ComparisonBenchmarkCatalog.symbols {
            let history = benchmarkHistories[symbol] ?? [:]
            let closes = Self.closes(onOrBefore: dates, in: history)
            guard let base = closes.compactMap({ $0 }).first, base > 0 else {
                benchmarks[symbol] = dates.map { _ in nil }
                continue
            }
            benchmarks[symbol] = closes.map { $0.map { $0 / base } }
        }
        return (dates, portfolio, benchmarks)
    }

    func historicalCloses(
        symbols: [String],
        from: String,
        to: String,
        dividendAdjusted: Bool = true,
        cachedOnly: Bool = false
    ) async -> [String: [String: Double]] {
        await withTaskGroup(of: (String, [String: Double]?).self) { group in
            // A large broker CSV can contain hundreds of symbols. Sending all
            // Yahoo requests at once is both slower on iPhone and commonly
            // triggers 429 responses, which previously erased the whole chart.
            var iterator = symbols.makeIterator()
            let concurrencyLimit = min(8, symbols.count)
            for _ in 0..<concurrencyLimit {
                guard let symbol = iterator.next() else { break }
                group.addTask {
                    (symbol, try? await historicalCloses(
                        symbol: symbol,
                        from: from,
                        to: to,
                        dividendAdjusted: dividendAdjusted,
                        cachedOnly: cachedOnly
                    ))
                }
            }

            var result: [String: [String: Double]] = [:]
            while let (symbol, history) = await group.next() {
                if let history, !history.isEmpty {
                    result[symbol] = history
                }
                if let nextSymbol = iterator.next() {
                    group.addTask {
                        (nextSymbol, try? await historicalCloses(
                            symbol: nextSymbol,
                            from: from,
                            to: to,
                            dividendAdjusted: dividendAdjusted,
                            cachedOnly: cachedOnly
                        ))
                    }
                }
            }
            return result
        }
    }

    private func historicalCloses(
        symbol: String,
        from: String,
        to: String,
        dividendAdjusted: Bool = true,
        cachedOnly: Bool = false,
        forceRefresh: Bool = false
    ) async throws -> [String: Double] {
        let cacheSymbol = dividendAdjusted ? symbol : symbol + "#split-only"
        let cached = await LocalHistoricalPriceCache.shared.lookup(symbol: cacheSymbol, from: from, to: to)
        if cachedOnly {
            guard let cached, cached.values.count > 1 else {
                throw LocalServiceError.noHistoricalPrices
            }
            return cached.values
        }
        if !forceRefresh, let cached, cached.isFresh, cached.values.count > 1 {
            return cached.values
        }
        var latestError: Error?
        do {
            let yahoo = try await yahooHistoricalCloses(symbol: symbol, from: from, to: to, dividendAdjusted: dividendAdjusted)
            if !yahoo.isEmpty {
                await LocalHistoricalPriceCache.shared.save(
                    symbol: cacheSymbol,
                    values: yahoo,
                    requestedFrom: from,
                    requestedTo: to
                )
                return yahoo
            }
        } catch {
            latestError = error
        }

        if !dividendAdjusted {
            if let cached, cached.values.count > 1 { return cached.values }
            throw latestError ?? LocalServiceError.noHistoricalPrices
        }

        if Self.supportsMassiveStockSymbol(symbol),
           let key = KeychainStore.string(for: LocalServiceKeys.massive), !key.isEmpty {
            do {
                let bars = try await massiveHistoricalBars(symbol: symbol, from: from, to: to, key: key)
                let massive = Dictionary(uniqueKeysWithValues: bars.map { ($0.date, $0.close) })
                await LocalHistoricalPriceCache.shared.save(
                    symbol: cacheSymbol,
                    values: massive,
                    requestedFrom: from,
                    requestedTo: to
                )
                return massive
            } catch {
                latestError = error
            }
        }

        if KeychainStore.string(for: LocalServiceKeys.fmp)?.isEmpty == false {
            do {
                let fmp = try await fmpHistoricalCloses(symbol: symbol, from: from, to: to)
                await LocalHistoricalPriceCache.shared.save(
                    symbol: cacheSymbol,
                    values: fmp,
                    requestedFrom: from,
                    requestedTo: to
                )
                return fmp
            } catch {
                latestError = error
            }
        }

        if let cached { return cached.values }
        throw latestError ?? LocalServiceError.noHistoricalPrices
    }

    private func yahooHistoricalCloses(symbol: String, from: String, to: String, dividendAdjusted: Bool = true) async throws -> [String: Double] {
        guard let fromDate = DayDateCodec.date(from: from),
              let toDate = DayDateCodec.date(from: to) else {
            throw LocalServiceError.invalidResponse
        }
        let period1 = Int(fromDate.timeIntervalSince1970)
        let period2Date = Calendar(identifier: .gregorian).date(byAdding: .day, value: 1, to: toDate) ?? toDate
        let period2 = Int(period2Date.timeIntervalSince1970)
        let escapedSymbol = symbol.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? symbol
        var components = URLComponents(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(escapedSymbol)")!
        components.queryItems = [
            URLQueryItem(name: "period1", value: String(period1)),
            URLQueryItem(name: "period2", value: String(period2)),
            URLQueryItem(name: "interval", value: "1d"),
            URLQueryItem(name: "events", value: "history"),
        ]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 9
        request.setValue("Mozilla/5.0 Catfolio-iOS", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await Self.yahooSession.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LocalServiceError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw LocalServiceError.remote("Yahoo 历史行情请求失败（\(http.statusCode)）")
        }
        let payload: YahooChartResponse
        do {
            payload = try JSONDecoder().decode(YahooChartResponse.self, from: data)
        } catch {
            throw LocalServiceError.remote("Yahoo 历史行情返回格式无法识别")
        }
        if let error = payload.chart.error {
            throw LocalServiceError.remote(error.description ?? error.code ?? "Yahoo 历史行情读取失败")
        }
        guard let result = payload.chart.result?.first,
              let timestamps = result.timestamp else {
            throw LocalServiceError.noMarketData
        }
        let adjusted = result.indicators.adjclose?.first?.adjclose ?? []
        let raw = result.indicators.quote?.first?.close ?? []
        let closes = dividendAdjusted && adjusted.contains(where: { $0 != nil }) ? adjusted : raw
        guard let unitScale = InstrumentCurrencyRules.providerPriceScale(symbol: symbol, sourceCurrency: result.meta?.currency) else {
            throw LocalServiceError.remote("行情报价币种无法确认：\(symbol)")
        }
        var values: [String: Double] = [:]
        for (index, timestamp) in timestamps.enumerated() where index < closes.count {
            guard let close = closes[index], close > 0 else { continue }
            let date = DayDateCodec.string(from: Date(timeIntervalSince1970: TimeInterval(timestamp)))
            values[date] = close * unitScale
        }
        guard !values.isEmpty else { throw LocalServiceError.noMarketData }
        return values
    }

    private func fmpHistoricalCloses(symbol: String, from: String, to: String) async throws -> [String: Double] {
        guard !symbol.uppercased().hasSuffix(".L"), InstrumentCurrencyRules.marketDataSymbol(for: symbol) == nil else {
            throw LocalServiceError.remote("FMP 无法确认伦敦标的报价币种")
        }
        guard let key = KeychainStore.string(for: LocalServiceKeys.fmp), !key.isEmpty else {
            throw LocalServiceError.missingMarketKey
        }
        var components = URLComponents(string: "https://financialmodelingprep.com/stable/historical-price-eod/full")!
        components.queryItems = [
            URLQueryItem(name: "symbol", value: symbol),
            URLQueryItem(name: "from", value: from),
            URLQueryItem(name: "to", value: to),
            URLQueryItem(name: "apikey", value: key),
        ]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 25
        try await FMPRequestLimiter.shared.waitForTurn()
        let (data, response) = try await LocalRequestSessions.ephemeral.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LocalServiceError.invalidResponse }
        if http.statusCode == 429 {
            await FMPRequestLimiter.shared.backOff(retryAfter: http.value(forHTTPHeaderField: "Retry-After"))
            let wait = await FMPRequestLimiter.shared.secondsUntilFreeSlot
            throw FMPFailure.rateLimited(retryAfterSeconds: Int(wait.rounded(.up)))
        }
        guard (200..<300).contains(http.statusCode) else {
            throw LocalServiceError.remote(Self.message(from: data, fallback: "行情请求失败（\(http.statusCode)）"))
        }
        guard let bars = try? JSONDecoder().decode([MarketDailyBar].self, from: data) else {
            throw LocalServiceError.remote(Self.message(from: data, fallback: "FMP 返回格式无法识别"))
        }
        return Dictionary(uniqueKeysWithValues: bars.map { ($0.date, $0.close) })
    }

    static func yahooSymbol(ticker: String, currency: String) -> String {
        let normalized = ticker.uppercased()
        let overrides = [
            "BRK.B": "BRK-B",
            "ENR": "ENR.DE",
            "RWE": "RWE.DE",
            "VUAG": "VUAG.L",
            "VUSA": "VUSA.L",
            "BARC": "BARC.L",
        ]
        if let override = overrides[normalized] { return override }
        if let londonSymbol = InstrumentCurrencyRules.marketDataSymbol(for: normalized) {
            return londonSymbol
        }
        if ["GBP", "GBX"].contains(currency.uppercased()), !normalized.contains(".") {
            return "\(normalized).L"
        }
        return normalized
    }

    /// Massive's stocks aggregates cover U.S. listings. Exchange-suffixed
    /// Yahoo symbols such as VUSA.L and RWE.DE must stay on the existing
    /// Yahoo/FMP route instead of spending a request that cannot return data.
    private static func supportsMassiveStockSymbol(_ symbol: String) -> Bool {
        !symbol.contains(".") && !symbol.contains("=") && !symbol.contains("^")
    }

    private static func close(onOrBefore date: String, in history: [String: Double]) -> Double? {
        if let exact = history[date] { return exact }
        return history.keys.filter { $0 <= date }.max().flatMap { history[$0] }
    }

    /// Aligns a sorted date axis in one pass. Chart preparation calls this for
    /// every holding; repeatedly scanning an entire price dictionary for every
    /// point made the returns tab unnecessarily expensive on iPhone.
    private static func closes(
        onOrBefore dates: [String],
        in history: [String: Double]
    ) -> [Double?] {
        let sortedHistory = history.sorted { $0.key < $1.key }
        var historyIndex = 0
        var lastClose: Double?
        var result: [Double?] = []
        result.reserveCapacity(dates.count)
        for date in dates {
            while historyIndex < sortedHistory.count,
                  sortedHistory[historyIndex].key <= date {
                lastClose = sortedHistory[historyIndex].value
                historyIndex += 1
            }
            result.append(lastClose)
        }
        return result
    }

    private static func close(
        onOrAfter date: String,
        in history: [String: Double],
        maximumDayGap: Int = 7
    ) -> Double? {
        if let exact = history[date] { return exact }
        guard let nextDate = history.keys.filter({ $0 >= date }).min(),
              let requested = DayDateCodec.date(from: date),
              let matched = DayDateCodec.date(from: nextDate),
              let dayGap = Calendar(identifier: .gregorian).dateComponents(
                [.day],
                from: requested,
                to: matched
              ).day,
              dayGap <= maximumDayGap else { return nil }
        return history[nextDate]
    }

    static func priceScale(ticker: String, currency: String, referencePrice: Double?, marketPrice: Double?) -> Double {
        let symbol = yahooSymbol(ticker: ticker, currency: currency)
        // A London suffix alone does not identify pounds vs pence. Only the
        // verified listing currency can authorize a 100x unit conversion.
        let scale = InstrumentCurrencyRules.marketPriceScale(symbol: symbol, targetCurrency: currency)
        if let referencePrice, let marketPrice,
           referencePrice.isFinite, marketPrice.isFinite,
           referencePrice > 0, marketPrice > 0 {
            let ratio = marketPrice * scale / referencePrice
            if ratio < 0.25 || ratio > 4 {
                Logger(subsystem: "com.catfolio.ios", category: "PriceUnits")
                    .warning("Price cross-check failed for \(symbol, privacy: .public); retaining declared currency scale \(scale)")
            }
        }
        return scale
    }

    private static func message(from data: Data, fallback: String) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return fallback }
        return object["Error Message"] as? String
            ?? object["error"] as? String
            ?? object["message"] as? String
            ?? fallback
    }
}

/// Reconstructs the currency component of open-position P/L independently for
/// every broker account. Rates are expressed as USD per currency unit; the
/// calculator derives instrument-to-account rates so a GBP account holding a
/// USD stock retains its GBP economic perspective before the result is finally
/// translated to Catfolio's USD storage currency.
struct LocalFXImpactCalculator {
    private struct Lot {
        var quantity: Double
        let date: String
        let currency: String
        let brokerFXRateToAccount: Double?
    }

    private let marketData = LocalMarketDataClient()

    func enrich(
        positions: [LocalPositionRecord],
        transactions: [LocalTransactionRecord]
    ) async -> [LocalPositionRecord] {
        let candidates = positions.filter {
            $0.fxPnl == nil && $0.accountCurrency != nil
        }
        guard !candidates.isEmpty else { return positions }

        let today = DayDateCodec.string(from: Date())
        let transactionStart = transactions.map(\.date).min()
        let positionStart = candidates.compactMap(\.openedDate).min()
        let start = min(transactionStart ?? positionStart ?? today, positionStart ?? transactionStart ?? today)
        let currencies = Set(candidates.flatMap { position in
            [position.currency, position.quoteCurrency, position.accountCurrency ?? ""]
        }.filter { !$0.isEmpty }.map(Self.marketCurrency))
        let symbols = currencies
            .filter { $0 != "USD" }
            .map(Self.yahooFXSymbol)
            .sorted()
        let histories = await marketData.historicalCloses(symbols: symbols, from: start, to: today)

        let transactionsByPosition = Dictionary(grouping: transactions) {
            "\($0.accountKey)|\($0.ticker.uppercased())"
        }
        return positions.map { position in
            if position.fxPnl != nil { return position }
            guard let accountCurrency = position.accountCurrency?.uppercased(),
                  !accountCurrency.isEmpty else {
                return position.withFXResult(
                    value: nil, currency: nil, status: "unavailable",
                    source: "missing_account_currency"
                )
            }

            if Self.marketCurrency(position.quoteCurrency) == Self.marketCurrency(accountCurrency) {
                return position.withFXResult(
                    value: 0, currency: "USD", status: "not_applicable",
                    source: "same_currency"
                )
            }

            let key = "\(position.accountKey)|\(position.ticker.uppercased())"
            let matchingTransactions = transactionsByPosition[key] ?? []
            var (lots, complete) = Self.remainingLots(from: matchingTransactions)
            let tolerance = max(0.0001, abs(position.shares) * 0.001)
            let reconstructedQuantity = lots.reduce(0) { $0 + $1.quantity }
            var status = "reconstructed"
            var source = "historical_daily_fx_fifo"

            if !complete || abs(reconstructedQuantity - position.shares) > tolerance {
                guard let openedDate = position.openedDate else {
                    return position.withFXResult(
                        value: nil, currency: nil, status: "unavailable",
                        source: matchingTransactions.isEmpty
                            ? "missing_trade_history"
                            : "incomplete_trade_history"
                    )
                }
                lots = [Lot(
                    quantity: position.shares,
                    date: openedDate,
                    currency: position.currency,
                    brokerFXRateToAccount: nil
                )]
                status = "estimated"
                source = "opened_date_daily_fx"
            }

            guard let currentInstrumentUSD = Self.usdPerUnit(
                currency: position.quoteCurrency,
                onOrBefore: today,
                histories: histories
            ), let currentAccountUSD = Self.usdPerUnit(
                currency: accountCurrency,
                onOrBefore: today,
                histories: histories
            ), currentAccountUSD > 0 else {
                return position.withFXResult(
                    value: nil, currency: nil, status: "unavailable",
                    source: "missing_current_fx_rate"
                )
            }

            var impactInAccountCurrency = 0.0
            var usedBrokerRate = false
            var usedMarketRate = false
            for lot in lots where lot.quantity > 0 {
                guard Self.marketCurrency(lot.currency) == Self.marketCurrency(position.quoteCurrency) else {
                    return position.withFXResult(
                        value: nil, currency: nil, status: "unavailable",
                        source: "trade_currency_mismatch"
                    )
                }
                let currentInstrumentToAccount = currentInstrumentUSD / currentAccountUSD
                let historicalInstrumentToAccount: Double
                if let brokerRate = lot.brokerFXRateToAccount,
                   brokerRate.isFinite, brokerRate > 0 {
                    // IBKR defines FX Rate to Base as base-currency units per
                    // asset-currency unit, which is exactly the ratio needed here.
                    historicalInstrumentToAccount = brokerRate
                    usedBrokerRate = true
                } else {
                    guard let historicalInstrumentUSD = Self.usdPerUnit(
                        currency: lot.currency,
                        onOrBefore: lot.date,
                        histories: histories
                    ), let historicalAccountUSD = Self.usdPerUnit(
                        currency: accountCurrency,
                        onOrBefore: lot.date,
                        histories: histories
                    ), historicalAccountUSD > 0 else {
                        return position.withFXResult(
                            value: nil, currency: nil, status: "unavailable",
                            source: "missing_historical_fx_rate"
                        )
                    }
                    historicalInstrumentToAccount = historicalInstrumentUSD / historicalAccountUSD
                    usedMarketRate = true
                }
                impactInAccountCurrency += lot.quantity * position.quotePrice
                    * (currentInstrumentToAccount - historicalInstrumentToAccount)
            }
            let impactUSD = impactInAccountCurrency * currentAccountUSD
            guard impactUSD.isFinite else {
                return position.withFXResult(
                    value: nil, currency: nil, status: "unavailable",
                    source: "invalid_fx_result"
                )
            }
            if status == "reconstructed", usedBrokerRate {
                source = usedMarketRate ? "broker_and_daily_fx_fifo" : "broker_trade_fx_fifo"
            }
            return position.withFXResult(
                value: impactUSD,
                currency: "USD",
                status: status,
                source: source
            )
        }
    }

    private static func remainingLots(
        from transactions: [LocalTransactionRecord]
    ) -> (lots: [Lot], complete: Bool) {
        var lots: [Lot] = []
        var complete = true
        for transaction in transactions.sorted(by: {
            if $0.date == $1.date { return ($0.tradeID ?? "") < ($1.tradeID ?? "") }
            return $0.date < $1.date
        }) {
            let quantity = abs(transaction.quantity)
            guard quantity > 0 else { continue }
            switch transaction.action.uppercased() {
            case "BUY":
                lots.append(Lot(
                    quantity: quantity,
                    date: transaction.date,
                    currency: transaction.currency,
                    brokerFXRateToAccount: transaction.brokerFXRate
                ))
            case "SELL":
                var remaining = quantity
                while remaining > 0.0000001, !lots.isEmpty {
                    let consumed = min(remaining, lots[0].quantity)
                    lots[0].quantity -= consumed
                    remaining -= consumed
                    if lots[0].quantity <= 0.0000001 { lots.removeFirst() }
                }
                if remaining > 0.0000001 { complete = false }
            default:
                continue
            }
        }
        return (lots, complete)
    }

    private static func marketCurrency(_ currency: String) -> String {
        currency.uppercased() == "GBX" ? "GBP" : currency.uppercased()
    }

    private static func yahooFXSymbol(_ currency: String) -> String {
        "\(currency.uppercased())USD=X"
    }

    private static func usdPerUnit(
        currency: String,
        onOrBefore date: String,
        histories: [String: [String: Double]]
    ) -> Double? {
        let original = currency.uppercased()
        let normalized = marketCurrency(original)
        if normalized == "USD" { return original == "GBX" ? 0.01 : 1 }
        let symbol = yahooFXSymbol(normalized)
        guard let value = histories[symbol]?
            .filter({ $0.key <= date })
            .max(by: { $0.key < $1.key })?
            .value,
              value.isFinite, value > 0 else { return nil }
        return original == "GBX" ? value / 100 : value
    }
}

private struct LocalPortfolioAttentionEngine {
    private struct Candidate {
        let holding: Holding
        let return60D: Double?
        let volumeMultiple: Double?
        let distanceHigh: Double?
        let distanceLow: Double?
        let ma200Position: Double?
        let ma200Cross: String?
        let contribution: Double?
        var signals: [PortfolioAttentionSignal]
    }

    func scan(document: LocalPortfolioDocument) async throws -> PortfolioAttentionReport {
        let holdings = try LocalPortfolioEngine.presentation(for: document).2
        guard !holdings.isEmpty else { throw LocalPortfolioError.noPortfolio }
        let histories = await histories(for: holdings)
        var candidates = holdings.map { holding in
            candidate(holding: holding, bars: histories[holding.ticker.uppercased()] ?? [])
        }
        let totalAbsoluteContribution = candidates.reduce(0) { partial, row in
            partial + abs(row.contribution ?? 0)
        }
        for index in candidates.indices {
            guard totalAbsoluteContribution > 0,
                  let contribution = candidates[index].contribution else { continue }
            let share = abs(contribution) / totalAbsoluteContribution
            if share >= 0.40, abs(contribution) >= 0.20 {
                candidates[index].signals.append(PortfolioAttentionSignal(
                    kind: "portfolio_contribution",
                    label: "占今日组合波动 \(Int((share * 100).rounded()))%",
                    direction: contribution >= 0 ? "positive" : "negative",
                    value: share
                ))
            }
        }
        let selected = candidates.compactMap { row -> PortfolioAttentionHolding? in
            guard !row.signals.isEmpty else { return nil }
            let level: PortfolioAttentionLevel = row.signals.count >= 2 ? .high : .medium
            return PortfolioAttentionHolding(
                ticker: row.holding.ticker,
                name: row.holding.shortName,
                attention: level,
                weight: row.holding.weight,
                portfolioContributionPercent: row.contribution,
                return60DPercent: row.return60D,
                volumeMultiple: row.volumeMultiple,
                distanceFrom52WHighPercent: row.distanceHigh,
                distanceFrom52WLowPercent: row.distanceLow,
                ma200PositionPercent: row.ma200Position,
                signals: row.signals,
                fundamentals: nil,
                thesis: fallbackThesis(for: row),
                sources: []
            )
        }.sorted {
            let lhs = $0.attention == .high ? 2 : 1
            let rhs = $1.attention == .high ? 2 : 1
            if lhs != rhs { return lhs > rhs }
            if $0.signals.count != $1.signals.count { return $0.signals.count > $1.signals.count }
            return abs($0.portfolioContributionPercent ?? 0) > abs($1.portfolioContributionPercent ?? 0)
        }
        let missingHistory = candidates.filter { histories[$0.holding.ticker.uppercased()]?.count ?? 0 < 40 }.count
        let warnings = missingHistory > 0 ? ["\(missingHistory) 只持仓历史行情不足，未由 AI 补全缺失指标。"] : []
        return PortfolioAttentionReport(
            generatedAt: Date(),
            holdingsCount: holdings.count,
            noMaterialChangeCount: holdings.count - selected.count,
            attentionRows: selected,
            warnings: warnings
        )
    }

    private func histories(for holdings: [Holding]) async -> [String: [PortfolioAttentionDailyBar]] {
        await withTaskGroup(of: (String, [PortfolioAttentionDailyBar]?).self) { group in
            for holding in holdings {
                let ticker = holding.ticker
                let currency = holding.quoteCurrency ?? "USD"
                let price = holding.quotePrice
                group.addTask {
                    let bars = try? await LocalMarketDataClient().portfolioAttentionBars(
                        ticker: ticker,
                        currency: currency,
                        referencePrice: price
                    )
                    return (ticker.uppercased(), bars)
                }
            }
            var result: [String: [PortfolioAttentionDailyBar]] = [:]
            for await (ticker, bars) in group {
                if let bars { result[ticker] = bars }
            }
            return result
        }
    }

    private func candidate(holding: Holding, bars: [PortfolioAttentionDailyBar]) -> Candidate {
        let ordered = bars.sorted { $0.date < $1.date }
        let latest = ordered.last
        let cutoff = Calendar(identifier: .gregorian).date(byAdding: .day, value: -60, to: Date()) ?? Date()
        let past = ordered.last { bar in
            guard let day = DayDateCodec.date(from: bar.date) else { return false }
            return day <= cutoff
        }
        let return60D = past.flatMap { $0.close > 0 ? (holding.quotePrice / $0.close - 1) * 100 : nil }
        let previousVolumes = ordered.dropLast().suffix(30).map(\.volume).filter { $0 > 0 }
        let averageVolume = previousVolumes.isEmpty ? nil : previousVolumes.reduce(0, +) / Double(previousVolumes.count)
        let volumeMultiple: Double? = averageVolume.flatMap { average -> Double? in
            guard average > 0, let latest, latest.volume > 0 else { return nil }
            return latest.volume / average
        }
        let annual = ordered.suffix(252)
        let high = annual.map(\.high).max()
        let low = annual.map(\.low).min()
        let distanceHigh = high.flatMap { $0 > 0 ? ($0 - holding.quotePrice) / $0 * 100 : nil }
        let distanceLow = low.flatMap { $0 > 0 ? (holding.quotePrice - $0) / $0 * 100 : nil }
        let closes = ordered.map(\.close)
        let ma200 = closes.count >= 200 ? closes.suffix(200).reduce(0, +) / 200 : nil
        let ma200Position = ma200.flatMap { $0 > 0 ? (holding.quotePrice / $0 - 1) * 100 : nil }
        var cross: String?
        if closes.count >= 201, let ma200 {
            let previousMA = closes.dropLast().suffix(200).reduce(0, +) / 200
            let wasAbove = closes[closes.count - 2] >= previousMA
            let isAbove = holding.quotePrice >= ma200
            if wasAbove != isAbove { cross = isAbove ? "above" : "below" }
        }

        var signals: [PortfolioAttentionSignal] = []
        if let value = return60D, abs(value) >= 10 {
            signals.append(.init(kind: "price_60d", label: "60D \(Self.signedPercent(value))", direction: value >= 0 ? "positive" : "negative", value: value))
        }
        if let value = volumeMultiple, value >= 2 {
            signals.append(.init(kind: "volume_spike", label: "成交量 \(String(format: "%.1f", value))×", direction: "neutral", value: value))
        }
        if let value = distanceHigh, (-3...3).contains(value) {
            signals.append(.init(kind: "near_52w_high", label: "距 52 周高点 \(String(format: "%.1f", abs(value)))%", direction: "positive", value: value))
        } else if let value = distanceLow, (-3...3).contains(value) {
            signals.append(.init(kind: "near_52w_low", label: "距 52 周低点 \(String(format: "%.1f", abs(value)))%", direction: "negative", value: value))
        }
        if let value = holding.todayChangePercent, abs(value) >= 5 {
            signals.append(.init(kind: "today_move", label: "今日 \(Self.signedPercent(value))", direction: value >= 0 ? "positive" : "negative", value: value))
        }
        if let cross {
            signals.append(.init(kind: "ma_200_cross", label: cross == "above" ? "突破 200D 均线" : "跌破 200D 均线", direction: cross == "above" ? "positive" : "negative", value: ma200Position ?? 0))
        }
        let contribution = holding.todayChangePercent.map { holding.weight * $0 }
        return Candidate(
            holding: holding,
            return60D: return60D,
            volumeMultiple: volumeMultiple,
            distanceHigh: distanceHigh,
            distanceLow: distanceLow,
            ma200Position: ma200Position,
            ma200Cross: cross,
            contribution: contribution,
            signals: signals
        )
    }

    private func fallbackThesis(for row: Candidate) -> PortfolioAttentionThesis {
        let positive = row.signals.filter { $0.direction == "positive" }.count
        let negative = row.signals.filter { $0.direction == "negative" }.count
        let stance: PortfolioThesisStance = positive > negative ? .strengthening : (negative > positive ? .weakening : .maintaining)
        return PortfolioAttentionThesis(
            stance: stance,
            confidence: .none,
            whatChanged: row.signals.map(\.label).joined(separator: "、"),
            whyItMatters: "这一变化值得核对，但在可靠公司来源确认前，不应视为基本面结论。",
            supportingEvidence: row.signals.map(\.label),
            counterEvidence: ["信号可能来自市场或板块波动，而非公司级催化剂。"],
            risks: ["公司级催化剂尚未验证"],
            watchNext: ["公司公告与业绩", "成交量是否持续", "200 日均线"],
            riskFlags: []
        )
    }

    private static func signedPercent(_ value: Double) -> String {
        String(format: "%@%.1f%%", value >= 0 ? "+" : "", value)
    }
}

private struct PortfolioEventResearchClient {
    private struct Response: Decodable {
        struct News: Decodable {
            let title: String
            let publisher: String?
            let link: URL
            let providerPublishTime: Int?
        }
        let news: [News]?
    }

    func recentSources(ticker: String, name: String) async -> [PortfolioAttentionSource] {
        let research = SecurityDebateResearch()
        async let google = research.googleNews(ticker: ticker, name: name)
        async let yahoo = research.yahooNews(ticker: ticker, name: name)
        return await SecurityDebateResearch.deduplicated(google + yahoo)
    }
}

private struct AttentionThesisEnvelope: Decodable {
    let theses: [AttentionThesisCandidate]
}

private struct AttentionThesisCandidate: Decodable {
    let ticker: String
    let stance: String
    let whatChanged: String
    let whyItMatters: String
    let supportingEvidence: [String]
    let counterEvidence: [String]
    let risks: [String]
    let watchNext: [String]
    let riskFlags: [String]
    let companySpecificCatalyst: Bool
    let catalystConfirmed: Bool
    let catalystIsRecent: Bool
    let evidenceSourceIDs: [String]
    let severeUnresolvedRisk: Bool

    enum CodingKeys: String, CodingKey {
        case ticker, stance, risks
        case whatChanged = "what_changed"
        case whyItMatters = "why_it_matters"
        case supportingEvidence = "supporting_evidence"
        case counterEvidence = "counter_evidence"
        case watchNext = "watch_next"
        case riskFlags = "risk_flags"
        case companySpecificCatalyst = "company_specific_catalyst"
        case catalystConfirmed = "catalyst_confirmed"
        case catalystIsRecent = "catalyst_is_recent"
        case evidenceSourceIDs = "evidence_source_ids"
        case severeUnresolvedRisk = "severe_unresolved_risk"
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

struct LocalAIClient {
    static var appleModelStatus: AppleFoundationModelStatus {
        guard #available(iOS 26.0, *) else { return .requiresNewerOS }
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(.deviceNotEligible):
            return .deviceNotEligible
        case .unavailable(.appleIntelligenceNotEnabled):
            return .appleIntelligenceNotEnabled
        case .unavailable(.modelNotReady):
            return .modelNotReady
        @unknown default:
            return .unknown
        }
    }

    func testDeepSeekConnection(apiKey: String? = nil) async throws {
        let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? KeychainStore.string(for: LocalServiceKeys.deepSeek)
            ?? ""
        guard !key.isEmpty else { throw LocalServiceError.missingAIKey }

        var request = URLRequest(url: URL(string: "https://api.deepseek.com/models")!)
        request.timeoutInterval = 20
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await LocalRequestSessions.ephemeral.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LocalServiceError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let detail = ((object?["error"] as? [String: Any])?["message"] as? String)
                ?? "DeepSeek 请求失败（\(http.statusCode)）"
            throw LocalServiceError.remote(detail)
        }
    }

    func briefing(document: LocalPortfolioDocument) async throws -> String {
        try await complete(
            question: L10n.text("请生成一段简洁的中文组合简报，指出集中度、盈亏和最值得关注的风险。"),
            document: document
        )
    }

    func answer(
        _ question: String,
        document: LocalPortfolioDocument,
        additionalContext: String? = nil
    ) async throws -> String {
        try await complete(question: question, document: document, additionalContext: additionalContext)
    }

    func portfolioAttention(document: LocalPortfolioDocument) async throws -> PortfolioAttentionReport {
        var report = try await LocalPortfolioAttentionEngine().scan(document: document)
        guard !report.attentionRows.isEmpty else { return report }

        let research = await withTaskGroup(of: (String, [PortfolioAttentionSource], PortfolioFundamentalSnapshot?).self) { group in
            for row in report.attentionRows {
                group.addTask {
                    async let news = PortfolioEventResearchClient().recentSources(ticker: row.ticker, name: row.name)
                    async let financials = try? CompanyFinancialsClient.shared.load(ticker: row.ticker)
                    var sources = await news
                    let data = await financials
                    if let data, let cik = data.cik,
                       let url = URL(string: "https://data.sec.gov/api/xbrl/companyfacts/CIK\(String(format: "%010d", cik)).json") {
                        sources.append(PortfolioAttentionSource(
                            id: "\(row.ticker.lowercased())-sec-facts",
                            title: "\(data.entityName) SEC Company Facts",
                            publisher: "SEC",
                            url: url,
                            publishedAt: nil,
                            tier: "primary"
                        ))
                    }
                    return (row.ticker, sources, data.map(Self.fundamentalSnapshot))
                }
            }
            var result: [String: ([PortfolioAttentionSource], PortfolioFundamentalSnapshot?)] = [:]
            for await (ticker, sources, fundamentals) in group { result[ticker] = (sources, fundamentals) }
            return result
        }
        for index in report.attentionRows.indices {
            let item = research[report.attentionRows[index].ticker]
            report.attentionRows[index].sources = item?.0 ?? []
            report.attentionRows[index].fundamentals = item?.1
        }

        let researchedRows = Array(report.attentionRows.prefix(6))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let evidenceData = try? encoder.encode(researchedRows),
              let evidence = String(data: evidenceData, encoding: .utf8) else { return report }
        let prompt = """
        你是 Catfolio Portfolio Attention Engine 的 thesis 阶段。以下市场指标已由代码计算，不得重算、改写或虚构数字。只能使用附带的新闻标题和来源元数据，不得虚构文章内容。若没有清晰、已确认的公司级事件，company_specific_catalyst 和 catalyst_confirmed 必须为 false。

        对每只持仓输出：发生了什么、为什么重要、投资逻辑增强/维持/减弱、支持证据、最强反方证据、风险和下一步关注。risk_flags 只允许 legal_regulatory、governance、dilution、liquidity、leadership。不输出 Buy/Sell、目标价、仓位或交易建议。

        证据：
        \(evidence)

        只输出 JSON：
        {"theses":[{"ticker":"NVDA","stance":"strengthening|maintaining|weakening","what_changed":"...","why_it_matters":"...","supporting_evidence":["..."],"counter_evidence":["..."],"risks":["..."],"watch_next":["..."],"risk_flags":[],"company_specific_catalyst":false,"catalyst_confirmed":false,"catalyst_is_recent":false,"evidence_source_ids":[],"severe_unresolved_risk":false}]}
        """
        guard let raw = try? await complete(question: prompt, document: document),
              let data = Self.cleanJSON(raw).data(using: .utf8),
              let envelope = try? JSONDecoder().decode(AttentionThesisEnvelope.self, from: data) else {
            return report
        }
        let candidates = Dictionary(uniqueKeysWithValues: envelope.theses.map { ($0.ticker.uppercased(), $0) })
        let allowedRiskFlags = Set(["legal_regulatory", "governance", "dilution", "liquidity", "leadership"])
        for index in report.attentionRows.indices {
            let row = report.attentionRows[index]
            guard let candidate = candidates[row.ticker.uppercased()] else { continue }
            let sourceIndex = Dictionary(uniqueKeysWithValues: row.sources.map { ($0.id, $0) })
            let cited = candidate.evidenceSourceIDs.compactMap { sourceIndex[$0] }
            let recencyCutoff = Calendar(identifier: .gregorian).date(
                byAdding: .day,
                value: -90,
                to: Date()
            ) ?? Date.distantPast
            let hasRecentReliableSource = cited.contains {
                ($0.tier == "primary" || $0.tier == "wire")
                    && ($0.publishedAt.map { $0 >= recencyCutoff } ?? false)
            }
            let confidence: PortfolioAttentionLevel
            if candidate.companySpecificCatalyst,
               candidate.catalystConfirmed,
               candidate.catalystIsRecent,
               hasRecentReliableSource,
               !candidate.counterEvidence.isEmpty,
               !candidate.severeUnresolvedRisk {
                confidence = .high
            } else if candidate.companySpecificCatalyst || candidate.catalystConfirmed || !cited.isEmpty {
                confidence = .medium
            } else {
                confidence = .none
            }
            report.attentionRows[index].thesis = PortfolioAttentionThesis(
                stance: PortfolioThesisStance(rawValue: candidate.stance) ?? row.thesis.stance,
                confidence: confidence,
                whatChanged: candidate.whatChanged,
                whyItMatters: candidate.whyItMatters,
                supportingEvidence: candidate.supportingEvidence,
                counterEvidence: candidate.counterEvidence,
                risks: candidate.risks,
                watchNext: candidate.watchNext,
                riskFlags: candidate.riskFlags.filter(allowedRiskFlags.contains)
            )
        }
        return report
    }

    private static func fundamentalSnapshot(_ data: CompanyFinancialsData) -> PortfolioFundamentalSnapshot {
        let income = data.income.filter { $0.kind == .quarterly }.sorted { $0.periodEnd > $1.periodEnd }
        let latestIncome = income.first
        let comparableIncome = latestIncome.flatMap { latest in
            income.first { $0.fiscalYear == latest.fiscalYear - 1 && $0.fiscalPeriod == latest.fiscalPeriod }
        }
        let cashFlow = data.cashFlow.filter { $0.kind == .quarterly }.sorted { $0.periodEnd > $1.periodEnd }
        let latestCash = cashFlow.first
        let comparableCash = latestCash.flatMap { latest in
            cashFlow.first { $0.fiscalYear == latest.fiscalYear - 1 && $0.fiscalPeriod == latest.fiscalPeriod }
        }
        func growth(_ current: Double?, _ previous: Double?) -> Double? {
            guard let current, let previous, previous != 0 else { return nil }
            return (current / previous - 1) * 100
        }
        return PortfolioFundamentalSnapshot(
            source: data.source,
            latestPeriod: latestIncome?.periodEnd ?? latestCash?.periodEnd,
            revenueGrowthYoY: growth(latestIncome?.revenue, comparableIncome?.revenue),
            operatingIncomeGrowthYoY: growth(latestIncome?.operatingIncome, comparableIncome?.operatingIncome),
            freeCashFlowGrowthYoY: growth(latestCash?.freeCashFlow, comparableCash?.freeCashFlow)
        )
    }

    private func complete(
        question: String,
        document: LocalPortfolioDocument,
        additionalContext: String? = nil
    ) async throws -> String {
        guard !document.positions.isEmpty else { throw LocalPortfolioError.noPortfolio }
        var context = try portfolioContext(document: document)
        if let additionalContext, !additionalContext.isEmpty {
            context += "\n\n上一次 Portfolio Attention 的结果：\n\(additionalContext)\n追问必须沿用上述信号、thesis 和 confidence，不要重算指标。"
        }

        return try await researchAnswer(question, context: context)
    }

    /// Public research only. Unlike portfolio chat this does not load or send
    /// account balances, credentials, or the user's holdings.
    func researchAnswer(_ question: String, context: String, structured: Bool = false) async throws -> String {
        switch AIProviderPreference.current {
        case .apple:
            if #available(iOS 26.0, *) {
                return try await completeWithApple(question: question, context: context, structured: structured)
            }
            throw LocalServiceError.appleModelUnavailable(Self.appleModelStatus.message)
        case .deepSeek:
            return try await completeWithDeepSeek(question: question, context: context, structured: structured)
        case .codex:
            return try await completeWithCodex(question: question, context: context)
        case .automatic:
            var appleFailure = Self.appleModelStatus.message
            if #available(iOS 26.0, *), Self.appleModelStatus.isAvailable {
                do {
                    return try await completeWithApple(question: question, context: context, structured: structured)
                } catch {
                    appleFailure = error.localizedDescription
                }
            }
            var codexFailure = L10n.text("Codex 尚未连接")
            if CodexOAuthClient.cachedConnected {
                do {
                    return try await completeWithCodex(question: question, context: context)
                } catch {
                    codexFailure = error.localizedDescription
                }
            }
            do {
                return try await completeWithDeepSeek(question: question, context: context, structured: structured)
            } catch {
                throw LocalServiceError.noAvailableAIProvider(
                    "Apple：\(appleFailure)；Codex：\(codexFailure)；DeepSeek：\(error.localizedDescription)"
                )
            }
        }
    }

    /// Research where the model is also allowed to look things up itself.
    ///
    /// Only one of the three providers can: Apple's on-device model has no
    /// network at all, DeepSeek's API is chat completions with no hosted tool,
    /// and Codex reaches an endpoint that may or may not honour `web_search`.
    /// So Codex is preferred for this one job when it is connected, rather than
    /// following the usual Apple-first order — the sources gathered locally are
    /// the floor, and live search is the part only it can add.
    ///
    /// - Returns: the answer, and whether search actually happened.
    /// Daily notes need evidence before accepting any answer. Skip an ungrounded
    /// completion when native search is unavailable; the caller supplies articles next.
    func researchAnswerWithNativeSearch(_ question: String) async throws -> (text: String, searched: Bool) {
        let preference = AIProviderPreference.current
        guard (preference == .codex || preference == .automatic), CodexOAuthClient.cachedConnected else {
            throw LocalServiceError.missingCodexConnection
        }
        return try await CodexOAuthClient().completion(prompt: question, webSearch: true)
    }

    func researchAnswerAllowingSearch(
        _ question: String,
        context: String
    ) async throws -> (text: String, searched: Bool) {
        let preference = AIProviderPreference.current
        let codexEligible = (preference == .codex || preference == .automatic)
            && CodexOAuthClient.cachedConnected
        if codexEligible {
            let prompt = context.isEmpty ? question : "\(context)\n\n问题：\(question)"
            do {
                return try await CodexOAuthClient().completion(prompt: prompt, webSearch: true)
            } catch where preference == .automatic {
                // Fall through to the ordinary ladder rather than failing the
                // whole request because one provider is having a bad day.
            }
        }
        return (try await researchAnswer(question, context: context, structured: true), false)
    }

    private func portfolioContext(document: LocalPortfolioDocument) throws -> String {
        let presentation = try LocalPortfolioEngine.presentation(for: document)
        if document.isPublicDisclosure {
            let rows = presentation.2.map { holding in
                "\(holding.ticker): 市值 \(holding.displayedMarketValue)，持股 \(DisplayFormat.shares(holding.shares))，模拟成本 \(DisplayFormat.money(holding.shares * holding.averageCost))，浮动盈亏 \(DisplayFormat.money(holding.unrealized))"
            }.joined(separator: "\n")
            return "模拟账户：\(document.accounts.map(\.name).joined(separator: ", "))。账本根据历史披露重建；13F 在申报日收盘价调整股数，佩洛西按披露上限及对应日期收盘价计算。以下成本与盈亏来自模拟交易和行情，可以用于分析该模拟组合，但不是人物真实账户收益。不包含未确定合约的期权及未匹配证券。\n\(rows)"
        }
        let top = presentation.2.prefix(15).map {
            "\($0.ticker): 市值 \(DisplayFormat.money($0.marketValue))，权重 \(String(format: "%.1f", $0.weight * 100))%，未实现收益 \(String(format: "%.1f", $0.unrealizedPercent))%"
        }.joined(separator: "\n")
        return """
        组合市值：\(DisplayFormat.money(presentation.0.summary.marketValue))
        组合成本：\(DisplayFormat.money(presentation.0.summary.totalCost))
        持仓数：\(presentation.0.summary.openPositions)
        主要持仓：
        \(top)
        """
    }

    @available(iOS 26.0, *)
    private func completeWithApple(question: String, context: String, structured: Bool = false) async throws -> String {
        let model = SystemLanguageModel.default
        guard model.availability == .available else {
            throw LocalServiceError.appleModelUnavailable(Self.appleModelStatus.message)
        }
        let responseLocale = Locale(identifier: ContentLanguage.current)
        guard model.supportsLocale(responseLocale) else {
            throw LocalServiceError.appleModelUnavailable(L10n.text("当前系统模型暂不支持所选语言"))
        }

        let session = LanguageModelSession(
            model: model,
            instructions: structured ? "严格按当前请求提供的 JSON schema 输出单个 JSON 对象，不附加解释或 Markdown。仅使用提供的证据，证据不足时遵循请求中的空结果规则，不要编造内容。若请求是筛选条件解析，不支持的条件放入 unsupported，不可忽略。" : """
            你是 Catfolio 的投资组合分析助手。只根据用户设备提供的组合摘要回答，使用简洁语言；不要虚构实时新闻、行情或组合中未提供的数据。金融数字由 Catfolio 计算，你只负责解释，不要重新推算或改写。回答末尾简短说明这不是投资建议。
            \(L10n.responseLanguageInstruction)
            """
        )
        let response: LanguageModelSession.Response<String>
        do {
            response = try await session.respond(
                to: "\(context)\n\n问题：\(question)",
                options: GenerationOptions(temperature: 0.2, maximumResponseTokens: 1_800)
            )
        } catch let error as LanguageModelSession.GenerationError {
            throw LocalServiceError.appleModelUnavailable(Self.appleGenerationErrorMessage(error))
        } catch {
            throw LocalServiceError.appleModelUnavailable(
                error.localizedDescription.isEmpty ? L10n.text("生成请求失败，请稍后再试") : error.localizedDescription
            )
        }
        let content = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { throw LocalServiceError.invalidResponse }
        return content
    }

    @available(iOS 26.0, *)
    private static func appleGenerationErrorMessage(
        _ error: LanguageModelSession.GenerationError
    ) -> String {
        switch error {
        case .exceededContextWindowSize:
            L10n.text("组合摘要超过本地模型的上下文长度")
        case .assetsUnavailable:
            L10n.text("模型资源暂不可用，请等待系统完成下载后重试")
        case .guardrailViolation:
            L10n.text("请求被 Apple Intelligence 的安全规则拦截")
        case .unsupportedGuide:
            L10n.text("当前系统模型不支持此输出格式")
        case .unsupportedLanguageOrLocale:
            L10n.text("当前系统模型暂不支持所用语言")
        case .decodingFailure:
            L10n.text("本地模型返回内容无法解析")
        case .rateLimited:
            L10n.text("本地模型请求过于频繁，请稍后再试")
        case .concurrentRequests:
            L10n.text("本地模型正在处理另一个请求")
        case .refusal:
            L10n.text("本地模型拒绝回答此问题")
        @unknown default:
            L10n.text("本地模型生成失败，请稍后再试")
        }
    }

    private func completeWithDeepSeek(question: String, context: String, structured: Bool = false) async throws -> String {
        guard let key = KeychainStore.string(for: LocalServiceKeys.deepSeek), !key.isEmpty else {
            throw LocalServiceError.missingAIKey
        }
        let payload: [String: Any] = [
            "model": "deepseek-chat",
            "temperature": 0.2,
            "messages": [
                ["role": "system", "content": structured ? "严格按当前请求提供的 JSON schema 输出单个 JSON 对象，不附加解释或 Markdown。仅使用提供的证据，证据不足时遵循请求中的空结果规则，不要编造内容。若请求是筛选条件解析，不支持的条件放入 unsupported，不可忽略。" : "你是 Catfolio 的投资组合分析助手。只根据用户手机提供的组合摘要回答，不虚构实时新闻或行情；明确说明这不是投资建议。" + L10n.responseLanguageInstruction],
                ["role": "user", "content": "\(context)\n\n问题：\(question)"],
            ],
        ]
        var request = URLRequest(url: URL(string: "https://api.deepseek.com/chat/completions")!)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        request.timeoutInterval = 45
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await LocalRequestSessions.ephemeral.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LocalServiceError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let detail = ((object?["error"] as? [String: Any])?["message"] as? String)
                ?? "AI 请求失败（\(http.statusCode)）"
            throw LocalServiceError.remote(detail)
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String,
              !content.isEmpty else { throw LocalServiceError.invalidResponse }
        return content
    }

    private func completeWithCodex(question: String, context: String) async throws -> String {
        guard CodexOAuthClient.cachedConnected else {
            throw LocalServiceError.missingCodexConnection
        }
        return try await CodexOAuthClient().complete(
            prompt: "\(context)\n\n问题：\(question)"
        )
    }

    private static func cleanJSON(_ text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("```") {
            var lines = value.components(separatedBy: .newlines)
            if !lines.isEmpty { lines.removeFirst() }
            if lines.last?.trimmingCharacters(in: .whitespacesAndNewlines) == "```" { lines.removeLast() }
            value = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value
    }
}

enum LocalETFLookThrough {
    /// Exact offline directory membership; does not expand positions or fetch holdings.
    static func isKnownFund(symbol: String) -> Bool {
        funds[symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()] != nil
    }
    private struct FundDefinition {
        let resource: String
        let label: String
    }

    private struct Dataset: Decodable {
        let benchmark: String?
        let asOf: String?
        let source: String?
        let sourceURL: String?
        let rows: [Constituent]

        enum CodingKeys: String, CodingKey {
            case rows, source, benchmark
            case asOf = "as_of"
            case sourceURL = "source_url"
        }
    }

    private struct Constituent: Decodable {
        let ticker: String
        let name: String
        let sector: String?
        let weight: Double

        enum CodingKeys: String, CodingKey {
            case ticker, name, sector
            case weight = "weight_percent"
        }
    }

    private struct AggregatedExposure {
        var name: String
        var sector: String?
        var fromETFUSD: Double
        var costUSD: Double? = 0
    }

    private struct HoldingsCatalog: Decodable {
        let schemaVersion: Int
        let funds: [String: Dataset]
    }

    private static let additionalDatasets: [String: Dataset] = {
        guard let url = Bundle.main.url(forResource: "etf_holdings", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let catalog = try? JSONDecoder().decode(HoldingsCatalog.self, from: data),
              catalog.schemaVersion == 1 else { return [:] }
        return catalog.funds
    }()

    private static let funds: [String: FundDefinition] = {
        let sp500 = FundDefinition(resource: "sp500_holdings", label: "S&P 500")
        let nasdaq100 = FundDefinition(resource: "eqqq_holdings", label: "EQQQ")
        var definitions: [String: FundDefinition] = [
            "VUAG": sp500, "VUAG.L": sp500,
            "VUSA": sp500, "VUSA.L": sp500,
            "SPY": sp500, "VOO": sp500, "IVV": sp500,
            // XS2D already embeds 2x daily leverage in its price path. Allocate
            // its net position value once; multiplying the holding by 2 here
            // would overstate the portfolio's cost and market value.
            "XS2D": sp500, "XS2D.L": sp500,
            "DBPG": sp500, "DBPG.DE": sp500,
            "XS2L": sp500, "XS2L.MI": sp500,
            "EQQQ": nasdaq100, "EQQQ.L": nasdaq100,
            "EQQU": nasdaq100, "EQQU.L": nasdaq100,
        ]
        // Exact fund snapshots take precedence over the historical index proxy.
        for ticker in additionalDatasets.keys {
            definitions[ticker] = FundDefinition(resource: ticker, label: ticker)
        }
        return definitions
    }()

    static func make(document: LocalPortfolioDocument, basis: ETFLookThroughBasis) throws -> ETFLookThroughResponse {
        if document.positions.contains(where: { $0.publicDisclosure != nil }) {
            guard basis == .market,
                  document.positions.allSatisfy({ $0.publicDisclosure?.value != nil && $0.publicDisclosure?.instrumentLabel == nil }) else {
                throw LocalServiceError.remote("当前数据不足，暂时无法按该口径计算。")
            }
        }
        let supported = Set(funds.keys)
        let etfs = document.positions.filter { supported.contains($0.ticker.uppercased()) }
        guard !etfs.isEmpty else { throw LocalServiceError.noSupportedETF }

        let requiredResources = Set(etfs.compactMap { funds[$0.ticker.uppercased()]?.resource })
        var datasets: [String: Dataset] = [:]
        for resource in requiredResources {
            if let dataset = additionalDatasets[resource] {
                datasets[resource] = dataset
                continue
            }
            guard let url = Bundle.main.url(forResource: resource, withExtension: "json"),
                  let dataset = try? JSONDecoder().decode(Dataset.self, from: Data(contentsOf: url)) else {
                throw LocalServiceError.invalidResponse
            }
            datasets[resource] = dataset
        }

        func etfExposure(_ position: LocalPositionRecord) throws -> Double {
            switch basis {
            case .market:
                try LocalPortfolioEngine.usd(position.publicDisclosure.map { $0.value ?? .nan } ?? (position.shares * position.quotePrice), currency: position.quoteCurrency)
            case .cost:
                try LocalPortfolioEngine.usd(position.shares * position.averageCost, currency: position.currency)
            }
        }
        func directMarketValue(_ position: LocalPositionRecord) throws -> Double {
            try LocalPortfolioEngine.usd(
                position.publicDisclosure.map { $0.value ?? .nan } ?? (position.shares * position.quotePrice),
                currency: position.quoteCurrency
            )
        }
        func positionCost(_ position: LocalPositionRecord) throws -> Double? {
            guard position.publicDisclosure == nil, position.shares.isFinite,
                  position.shares > 0, position.averageCost.isFinite,
                  position.averageCost > 0 else { return nil }
            let cost = try LocalPortfolioEngine.usd(position.shares * position.averageCost, currency: position.currency)
            return cost.isFinite && cost > 0 ? cost : nil
        }
        func estimatedPercent(market: Double, cost: Double?) -> Double? {
            guard basis == .market, let cost, cost.isFinite, cost > 0, market.isFinite else { return nil }
            let result = (market / cost - 1) * 100
            return result.isFinite ? result : nil
        }

        var etfExposures: [(position: LocalPositionRecord, amount: Double, definition: FundDefinition)] = []
        for position in etfs {
            guard let definition = funds[position.ticker.uppercased()] else { continue }
            etfExposures.append((position, try etfExposure(position), definition))
        }
        let etfTotal = etfExposures.reduce(0) { $0 + $1.amount }
        let directPositions = document.positions.filter { !supported.contains($0.ticker.uppercased()) }
        var direct: [String: (value: Double, name: String)] = [:]
        var directCosts: [String: Double] = [:]
        var missingDirectCosts: Set<String> = []
        for position in directPositions {
            let ticker = position.ticker.uppercased()
            let current = direct[ticker]?.value ?? 0
            direct[ticker] = (try current + directMarketValue(position), position.name)
            if let cost = try positionCost(position) {
                directCosts[ticker, default: 0] += cost
            } else {
                missingDirectCosts.insert(ticker)
            }
        }

        var aggregated: [String: AggregatedExposure] = [:]
        var otherFromETFUSD = 0.0
        var otherCostUSD: Double? = 0

        for exposure in etfExposures {
            guard let dataset = datasets[exposure.definition.resource] else { continue }
            let etfCost = try positionCost(exposure.position)
            var allocatedWeight = 0.0
            for constituent in dataset.rows {
                let weight = max(0, constituent.weight)
                allocatedWeight += weight
                let amount = exposure.amount * weight / 100
                let ticker = constituent.ticker.uppercased()
                if ticker == "CASH" || ticker == "ETF 其他" {
                    otherFromETFUSD += amount
                    if weight > 0 {
                        otherCostUSD = otherCostUSD.flatMap { sum in etfCost.map { sum + $0 * weight / 100 } }
                    }
                    continue
                }
                var current = aggregated[ticker] ?? AggregatedExposure(
                    name: constituent.name,
                    sector: constituent.sector,
                    fromETFUSD: 0
                )
                current.fromETFUSD += amount
                // Use the same weights for both known fund market value and
                // cost. This allocates fund P/L; it is not a constituent's
                // historical price return and requires no extra quote request.
                if weight > 0 {
                    current.costUSD = current.costUSD.flatMap { sum in etfCost.map { sum + $0 * weight / 100 } }
                }
                if current.sector == nil { current.sector = constituent.sector }
                aggregated[ticker] = current
            }
            let unallocatedWeight = max(0, 100 - allocatedWeight)
            otherFromETFUSD += exposure.amount * unallocatedWeight / 100
            if unallocatedWeight > 0 {
                otherCostUSD = otherCostUSD.flatMap { sum in etfCost.map { sum + $0 * unallocatedWeight / 100 } }
            }
        }

        var rows = aggregated.map { ticker, exposure -> ETFLookThroughRow in
            let directValue = direct.removeValue(forKey: ticker)
            let directUSD = directValue?.value ?? 0
            let combinedCost = missingDirectCosts.contains(ticker) ? nil
                : exposure.costUSD.map { $0 + (directCosts[ticker] ?? 0) }
            return ETFLookThroughRow(
                ticker: ticker,
                logoSymbol: ticker,
                name: directValue?.name.isEmpty == false ? directValue!.name : exposure.name,
                directUSD: directUSD,
                fromETFUSD: exposure.fromETFUSD,
                totalUSD: directUSD + exposure.fromETFUSD,
                etfWeightPercent: etfTotal > 0 ? exposure.fromETFUSD / etfTotal * 100 : 0,
                sector: SectorAttribution.resolvedSector(ticker: ticker, reportedSector: exposure.sector)?.displayName,
                estimatedHoldingPeriodPercent: estimatedPercent(market: directUSD + exposure.fromETFUSD, cost: combinedCost)
            )
        }

        let otherWeight = etfTotal > 0 ? otherFromETFUSD / etfTotal * 100 : 0
        let covered = max(0, 100 - otherWeight)
        if otherFromETFUSD > 0.001 {
            rows.append(ETFLookThroughRow(
                ticker: "ETF 其他", logoSymbol: nil, name: "基金现金、衍生品及未识别部分",
                directUSD: 0, fromETFUSD: otherFromETFUSD,
                totalUSD: otherFromETFUSD, etfWeightPercent: otherWeight, sector: "ETF / Other",
                estimatedHoldingPeriodPercent: estimatedPercent(market: otherFromETFUSD, cost: otherCostUSD)
            ))
        }
        rows.append(contentsOf: direct.map { ticker, item in
            ETFLookThroughRow(
                ticker: ticker, logoSymbol: ticker, name: item.name.isEmpty ? ticker : item.name,
                directUSD: item.value, fromETFUSD: 0, totalUSD: item.value, etfWeightPercent: 0,
                sector: SectorAttribution.primarySector(ticker: ticker)?.displayName
            )
        })
        rows.sort { $0.totalUSD > $1.totalUSD }

        let usedDefinitions = Dictionary(
            grouping: etfExposures.map(\.definition),
            by: \.resource
        ).compactMap { resource, definitions -> (FundDefinition, Dataset)? in
            guard let definition = definitions.first, let dataset = datasets[resource] else { return nil }
            return (definition, dataset)
        }.sorted { $0.0.label < $1.0.label }
        let dates = usedDefinitions.compactMap { definition, dataset in
            dataset.asOf.map { "\(definition.label) \($0)" }
        }
        let sources = Array(Set(usedDefinitions.compactMap { $0.1.source })).sorted()
        let singleDataset = usedDefinitions.count == 1 ? usedDefinitions.first?.1 : nil
        let xs2dAliases = Set(["XS2D", "XS2D.L", "DBPG", "DBPG.DE", "XS2L", "XS2L.MI"])
        let hasXS2D = etfs.contains { xs2dAliases.contains($0.ticker.uppercased()) }
        let onlyXS2D = etfs.allSatisfy { xs2dAliases.contains($0.ticker.uppercased()) }
        let sourceSummary = (sources + (hasXS2D ? ["XS2D：S&P 500 经济暴露近似"] : []))
            .joined(separator: " · ")
        let xs2dSourceURL = "https://etf.dws.com/en-gb/AssetDownload/Index/15d381e4-a965-436a-a89e-dc706840c3cf/Overall-Factsheet.pdf"

        return ETFLookThroughResponse(
            basis: basis.rawValue,
            etfTickers: etfs.map(\.ticker).sorted(),
            etfTotalUSD: etfTotal,
            coveredWeightPercent: covered,
            otherWeightPercent: otherWeight,
            constituentCount: aggregated.count,
            holdingsAsOf: dates.joined(separator: " · "),
            holdingsSource: sourceSummary,
            holdingsSourceURL: hasXS2D ? (onlyXS2D ? xs2dSourceURL : nil) : singleDataset?.sourceURL,
            rows: rows
        )
    }
}
