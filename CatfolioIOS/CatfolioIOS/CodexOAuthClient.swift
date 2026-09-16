import Foundation
import CryptoKit
import FoundationModels
import OSLog

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

    /// The same request as `complete`, delivered as it is written: the
    /// answer, and a summary of the model's thinking before it.
    func streamCompletion(prompt: String, emit: @escaping @Sendable (AIStreamEvent) -> Void) async throws {
        guard var credentials = try Self.load(CodexCredentials.self, key: Self.credentialsKey) else {
            Self.cache(Self.disconnectedStatus)
            throw LocalServiceError.missingCodexConnection
        }
        if credentials.expiresAt.timeIntervalSinceNow < 5 * 60 {
            credentials = try await refresh(credentials)
        }
        do {
            try await requestStream(prompt: prompt, credentials: credentials, summarizesReasoning: true, emit: emit)
        } catch CodexRequestError.unauthorized {
            let refreshed = try await refresh(credentials, force: true)
            try await requestStream(prompt: prompt, credentials: refreshed, summarizesReasoning: true, emit: emit)
        } catch is ReasoningSummaryRejected {
            // The backend is not the documented API; if it will not summarise
            // the reasoning, the answer still streams without it.
            try await requestStream(prompt: prompt, credentials: credentials, summarizesReasoning: false, emit: emit)
        }
    }

    private struct ReasoningSummaryRejected: Error {}

    private func requestStream(
        prompt: String,
        credentials: CodexCredentials,
        summarizesReasoning: Bool,
        emit: @escaping @Sendable (AIStreamEvent) -> Void
    ) async throws {
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
        if summarizesReasoning {
            body["reasoning"] = ["effort": "medium", "summary": "auto"]
        }
        var request = URLRequest(url: Self.codexResponsesURL)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 130
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(credentials.accountID, forHTTPHeaderField: "chatgpt-account-id")
        request.setValue("catfolio_ios", forHTTPHeaderField: "originator")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await Self.session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw LocalServiceError.invalidResponse }
        if http.statusCode == 401 { throw CodexRequestError.unauthorized }
        guard (200..<300).contains(http.statusCode) else {
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count > 64_000 { break }
            }
            if summarizesReasoning, http.statusCode == 400 { throw ReasoningSummaryRejected() }
            try Self.requireSuccess(http, data: data, fallback: L10n.text("Codex 分析请求失败"))
            throw LocalServiceError.invalidResponse
        }
        var summaryIndex: Int?
        var wroteAnswer = false
        for try await line in bytes.lines {
            try Task.checkCancellation()
            for event in try AIStreamParsing.codexEvents(line, summaryIndex: &summaryIndex) {
                if case .text = event { wroteAnswer = true }
                emit(event)
            }
        }
        guard wroteAnswer else { throw LocalServiceError.invalidResponse }
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
