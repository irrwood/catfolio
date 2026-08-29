import Foundation

enum CatfolioAPIError: LocalizedError {
    case invalidServerURL
    case invalidResponse
    case server(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidServerURL:
            return "服务地址无效"
        case .invalidResponse:
            return "服务器返回了无法识别的数据"
        case let .server(code, message):
            return "连接失败（\(code)）：\(message)"
        }
    }
}

struct APIClient {
    let baseURL: URL

    init(serverURL: String) throws {
        let normalized = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: normalized), url.scheme != nil, url.host != nil else {
            throw CatfolioAPIError.invalidServerURL
        }
        baseURL = url
    }

    func get<T: Decodable>(_ path: String) async throws -> T {
        try await request(path: path, method: "GET", body: nil, queryItems: nil)
    }

    func get<T: Decodable>(_ path: String, query: [String: String]) async throws -> T {
        let items = query
            .sorted { $0.key < $1.key }
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        return try await request(path: path, method: "GET", body: nil, queryItems: items)
    }

    func post<T: Decodable>(_ path: String, json: [String: String]) async throws -> T {
        let data = try JSONSerialization.data(withJSONObject: json)
        return try await request(path: path, method: "POST", body: data, queryItems: nil)
    }

    private func request<T: Decodable>(path: String, method: String, body: Data?, queryItems: [URLQueryItem]?) async throws -> T {
        let cleanPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let endpoint = baseURL.appendingPathComponent(cleanPath)
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = queryItems
        guard let url = components?.url else {
            throw CatfolioAPIError.invalidServerURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CatfolioAPIError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw CatfolioAPIError.server(http.statusCode, serverMessage(from: data, statusCode: http.statusCode))
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw CatfolioAPIError.invalidResponse
        }
    }

    private func serverMessage(from data: Data, statusCode: Int) -> String {
        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return HTTPURLResponse.localizedString(forStatusCode: statusCode)
        }
        if let detail = payload["detail"] as? String {
            return detail
        }
        if let detail = payload["detail"] as? [String: Any] {
            return detail["message"] as? String
                ?? detail["error"] as? String
                ?? HTTPURLResponse.localizedString(forStatusCode: statusCode)
        }
        return payload["message"] as? String
            ?? payload["error"] as? String
            ?? HTTPURLResponse.localizedString(forStatusCode: statusCode)
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var serverURL: String {
        didSet { UserDefaults.standard.set(serverURL, forKey: Self.serverKey) }
    }
    @Published var overview: PortfolioOverview?
    @Published var portfolioChart: PortfolioChartResponse?
    @Published var holdings: [Holding] = []
    @Published var comparison: ComparisonResponse?
    @Published var isPortfolioLoading = false
    @Published var isReturnsLoading = false
    @Published var portfolioError: String?
    @Published var returnsError: String?
    @Published var connectionMessage: String?
    @Published var activeBroker: BrokerProvider?
    @Published var brokerConnectionStates: [BrokerProvider: BrokerConnectionState] = [:]
    @Published var isBrokerLoading = false
    @Published var isBrokerSyncing = false
    @Published var brokerMessage: String?

    private static let serverKey = "catfolio.serverURL"

    init() {
        serverURL = UserDefaults.standard.string(forKey: Self.serverKey) ?? "http://127.0.0.1:8000"
    }

    func refreshPortfolio() async {
        isPortfolioLoading = true
        portfolioError = nil
        defer { isPortfolioLoading = false }
        do {
            let client = try APIClient(serverURL: serverURL)
            async let overviewRequest: PortfolioOverview = client.get("/api/portfolio/overview")
            async let chartRequest: PortfolioChartResponse = client.get("/api/portfolio/chart")
            async let holdingsRequest: HoldingsResponse = client.get("/api/holdings/detail")
            let (overview, chart, holdings) = try await (overviewRequest, chartRequest, holdingsRequest)
            self.overview = overview
            portfolioChart = chart
            self.holdings = holdings.rows
        } catch {
            portfolioError = error.localizedDescription
        }
    }

    func refreshReturns() async {
        isReturnsLoading = true
        returnsError = nil
        defer { isReturnsLoading = false }
        do {
            let client = try APIClient(serverURL: serverURL)
            comparison = try await client.get("/api/comparison")
        } catch {
            returnsError = error.localizedDescription
        }
    }

    func volumeProfile(for ticker: String) async throws -> VolumeProfile {
        let client = try APIClient(serverURL: serverURL)
        let encoded = ticker.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ticker
        return try await client.get("/api/holdings/\(encoded)/volume-profile")
    }

    func loadBriefing() async throws -> String {
        let client = try APIClient(serverURL: serverURL)
        let response: BriefingResponse = try await client.post("/api/ai/briefing", json: ["lang": "zh"])
        return response.briefing
    }

    func askAI(_ question: String) async throws -> String {
        let client = try APIClient(serverURL: serverURL)
        let response: AskResponse = try await client.post("/api/ai/ask", json: ["lang": "zh", "question": question])
        return response.answer
    }

    func testConnection() async {
        connectionMessage = "正在连接…"
        do {
            let client = try APIClient(serverURL: serverURL)
            let summary: PortfolioSummary = try await client.get("/api/portfolio/summary")
            connectionMessage = "连接成功，已读取 \(summary.openPositions) 个持仓"
        } catch {
            connectionMessage = error.localizedDescription
        }
    }

    func loadBrokerStatus() async {
        isBrokerLoading = true
        defer { isBrokerLoading = false }
        do {
            let client = try APIClient(serverURL: serverURL)
            let overview: BrokerOverview = try await client.get("/api/broker")
            activeBroker = overview.provider
        } catch {
            brokerMessage = error.localizedDescription
        }
    }

    func selectBroker(_ provider: BrokerProvider) async {
        guard provider != activeBroker else { return }
        isBrokerLoading = true
        brokerMessage = "正在切换到 \(provider.displayName)…"
        defer { isBrokerLoading = false }
        do {
            let client = try APIClient(serverURL: serverURL)
            let response: SaveSettingResponse = try await client.post(
                "/api/settings/save-key",
                json: ["name": "BROKER_PROVIDER", "value": provider.rawValue]
            )
            guard response.ok else {
                throw CatfolioAPIError.server(400, response.error ?? "服务端未保存券商设置")
            }
            activeBroker = provider
            brokerMessage = "已切换到 \(provider.displayName)"
        } catch {
            brokerMessage = error.localizedDescription
        }
    }

    func testBroker(_ provider: BrokerProvider) async {
        brokerConnectionStates[provider] = .testing
        do {
            let client = try APIClient(serverURL: serverURL)
            let result: BrokerConnectionResult = try await client.get("/api/brokers/\(provider.rawValue)/test")
            brokerConnectionStates[provider] = .success(result.message)
        } catch {
            brokerConnectionStates[provider] = .failure(error.localizedDescription)
        }
    }

    func syncActiveBroker() async {
        guard let activeBroker else {
            brokerMessage = "请先读取或选择券商数据源"
            return
        }
        isBrokerSyncing = true
        brokerMessage = "正在从 \(activeBroker.displayName) 同步…"
        defer { isBrokerSyncing = false }
        do {
            let client = try APIClient(serverURL: serverURL)
            let result: BrokerRefreshEnvelope = try await client.post("/api/refresh/broker", json: [:])
            let count = result.refresh.holdings ?? result.summary.openPositions
            brokerMessage = "\(result.provider.displayName) 同步完成，共 \(count) 个持仓"
            await refreshPortfolio()
        } catch {
            brokerMessage = error.localizedDescription
        }
    }

    func loadETFLookThrough(basis: ETFLookThroughBasis) async throws -> ETFLookThroughResponse {
        let client = try APIClient(serverURL: serverURL)
        return try await client.get("/api/etf-lookthrough", query: ["basis": basis.rawValue])
    }
}
