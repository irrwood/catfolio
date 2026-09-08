import Foundation
import SwiftUI

struct PolymarketRelatedMarket: Codable, Identifiable, Sendable {
    let id: String
    let question: String
    let eventTitle: String
    let eventSlug: String
    let outcome: String
    let probability: Double
    let volume24Hours: Double
    let totalVolume: Double
    let endDate: Date?

    var webURL: URL? {
        URL(string: "https://polymarket.com/event/\(eventSlug)")
    }
}

enum PolymarketClientError: LocalizedError {
    case invalidResponse
    case remote(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "Polymarket 返回了无法识别的数据"
        case let .remote(message):
            message
        }
    }
}

actor PolymarketClient {
    static let shared = PolymarketClient()

    private struct CacheEntry: Codable {
        let fetchedAt: Date
        let markets: [PolymarketRelatedMarket]
    }

    private struct SearchResponse: Decodable {
        let events: [SearchEvent]?
    }

    private struct SearchEvent: Decodable {
        let id: String
        let slug: String
        let title: String
        let active: Bool?
        let closed: Bool?
        let archived: Bool?
        let markets: [SearchMarket]?
    }

    private struct SearchMarket: Decodable {
        let id: String
        let question: String
        let active: Bool?
        let closed: Bool?
        let outcomes: [String]
        let outcomePrices: [Double]
        let volume: Double
        let volume24Hours: Double
        let endDate: Date?

        enum CodingKeys: String, CodingKey {
            case id
            case question
            case active
            case closed
            case outcomes
            case outcomePrices
            case volume
            case volumeNum
            case volume24Hours = "volume24hr"
            case endDate
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = (try? container.decode(String.self, forKey: .id)) ?? UUID().uuidString
            question = (try? container.decode(String.self, forKey: .question)) ?? "Polymarket 盘口"
            active = try? container.decodeIfPresent(Bool.self, forKey: .active)
            closed = try? container.decodeIfPresent(Bool.self, forKey: .closed)
            outcomes = container.stringArray(forKey: .outcomes)
            outcomePrices = container.doubleArray(forKey: .outcomePrices)
            volume = container.flexibleDouble(forKey: .volumeNum)
                ?? container.flexibleDouble(forKey: .volume)
                ?? 0
            volume24Hours = container.flexibleDouble(forKey: .volume24Hours) ?? 0
            endDate = container.flexibleDate(forKey: .endDate)
        }
    }

    private let session: URLSession
    private var cache: [String: CacheEntry] = [:]
    private var didLoadCache = false
    private let freshness: TimeInterval = 15 * 60

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 12
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.urlCache = URLCache(
            memoryCapacity: 4 * 1_024 * 1_024,
            diskCapacity: 20 * 1_024 * 1_024
        )
        session = URLSession(configuration: configuration)
    }

    func relatedMarkets(
        ticker: String,
        companyName: String,
        forceRefresh: Bool = false
    ) async throws -> [PolymarketRelatedMarket] {
        loadCacheIfNeeded()
        let cacheKey = Self.cacheKey(ticker: ticker, companyName: companyName)
        let cached = cache[cacheKey]

        if !forceRefresh,
           let cached,
           Date().timeIntervalSince(cached.fetchedAt) < freshness {
            return cached.markets
        }

        do {
            let queries = Self.searchQueries(ticker: ticker, companyName: companyName)
            var events: [SearchEvent] = []
            var eventIDs = Set<String>()

            for query in queries {
                for event in try await search(query: query, forceRefresh: forceRefresh)
                where eventIDs.insert(event.id).inserted {
                    events.append(event)
                }
            }

            let markets = Self.rank(events: events)
            cache[cacheKey] = CacheEntry(fetchedAt: Date(), markets: markets)
            persistCache()
            return markets
        } catch {
            if let cached { return cached.markets }
            throw error
        }
    }

    private func search(query: String, forceRefresh: Bool) async throws -> [SearchEvent] {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "gamma-api.polymarket.com"
        components.path = "/public-search"
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "events_status", value: "active"),
            URLQueryItem(name: "limit_per_type", value: "8"),
            URLQueryItem(name: "keep_closed_markets", value: "0"),
            URLQueryItem(name: "search_profiles", value: "false"),
            URLQueryItem(name: "search_tags", value: "false"),
            URLQueryItem(name: "cache", value: "true"),
        ]
        guard let url = components.url else { throw PolymarketClientError.invalidResponse }

        var request = URLRequest(
            url: url,
            cachePolicy: forceRefresh ? .reloadIgnoringLocalCacheData : .returnCacheDataElseLoad,
            timeoutInterval: 12
        )
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PolymarketClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw PolymarketClientError.remote("暂时无法读取 Polymarket（HTTP \(http.statusCode)）")
        }
        do {
            return try JSONDecoder().decode(SearchResponse.self, from: data).events ?? []
        } catch {
            throw PolymarketClientError.invalidResponse
        }
    }

    private static func rank(events: [SearchEvent]) -> [PolymarketRelatedMarket] {
        var results: [PolymarketRelatedMarket] = []
        var marketIDs = Set<String>()

        for event in events
        where event.active != false && event.closed != true && event.archived != true {
            for market in event.markets ?? []
            where market.active != false && market.closed != true && marketIDs.insert(market.id).inserted {
                guard let quote = displayedQuote(
                    outcomes: market.outcomes,
                    prices: market.outcomePrices
                ) else { continue }
                results.append(
                    PolymarketRelatedMarket(
                        id: market.id,
                        question: market.question,
                        eventTitle: event.title,
                        eventSlug: event.slug,
                        outcome: quote.outcome,
                        probability: quote.probability,
                        volume24Hours: market.volume24Hours,
                        totalVolume: market.volume,
                        endDate: market.endDate
                    )
                )
            }
        }

        return results.sorted { left, right in
            if left.volume24Hours != right.volume24Hours {
                return left.volume24Hours > right.volume24Hours
            }
            return left.totalVolume > right.totalVolume
        }
        .prefix(5)
        .map { $0 }
    }

    private static func displayedQuote(
        outcomes: [String],
        prices: [Double]
    ) -> (outcome: String, probability: Double)? {
        guard !outcomes.isEmpty, outcomes.count == prices.count else { return nil }
        if let yesIndex = outcomes.firstIndex(where: { $0.caseInsensitiveCompare("yes") == .orderedSame }) {
            return (outcomes[yesIndex], min(1, max(0, prices[yesIndex])))
        }
        guard let index = prices.indices.max(by: { prices[$0] < prices[$1] }) else { return nil }
        return (outcomes[index], min(1, max(0, prices[index])))
    }

    private static func searchQueries(ticker: String, companyName: String) -> [String] {
        let baseTicker = ticker
            .split(separator: ".", maxSplits: 1)
            .first
            .map(String.init)?
            .uppercased() ?? ticker.uppercased()
        let legalSuffixes: Set<String> = [
            "inc", "incorporated", "corp", "corporation", "plc", "ltd", "limited", "holdings",
        ]
        let words = companyName
            .replacingOccurrences(of: ",", with: " ")
            .replacingOccurrences(of: ".", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        let cleanName = words
            .filter { !legalSuffixes.contains($0.lowercased()) }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var queries = [baseTicker]
        if cleanName.count >= 3,
           cleanName.caseInsensitiveCompare(baseTicker) != .orderedSame {
            queries.append(cleanName)
        }
        return Array(queries.prefix(2))
    }

    private static func cacheKey(ticker: String, companyName: String) -> String {
        "\(ticker)|\(companyName)".lowercased()
    }

    private func loadCacheIfNeeded() {
        guard !didLoadCache else { return }
        didLoadCache = true
        guard let data = try? Data(contentsOf: cacheURL),
              let decoded = try? JSONDecoder().decode([String: CacheEntry].self, from: data) else { return }
        cache = decoded
    }

    private func persistCache() {
        let oldestAllowed = Date().addingTimeInterval(-7 * 24 * 60 * 60)
        cache = cache.filter { $0.value.fetchedAt >= oldestAllowed }
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }

    private var cacheURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("catfolio-polymarket-markets.json")
    }
}

struct PolymarketMarketsSection: View {
    let holding: Holding

    @Environment(\.openURL) private var openURL
    @State private var markets: [PolymarketRelatedMarket] = []
    @State private var errorMessage: String?
    @State private var isLoading = true

    static func supports(_ holding: Holding) -> Bool {
        let identity = "\(holding.displayName) \(holding.sector ?? "")".uppercased()
        return !["ETF", "UCITS", "INDEX", "FUND"].contains(where: identity.contains)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("Polymarket 热门盘口")
                    .font(.headline)
                Spacer()
                if !isLoading {
                    Button {
                        Task { await load(forceRefresh: true) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.subheadline.weight(.semibold))
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("刷新 Polymarket 盘口")
                }
            }
            .padding(.bottom, 10)

            if isLoading {
                loadingRows
            } else if !markets.isEmpty {
                marketRows
            } else {
                emptyState
            }

            Text("概率来自预测市场交易价格，仅供参考，不代表事实或投资建议。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.top, 10)
        }
        .contentCard()
        .task(id: taskID) {
            await load(forceRefresh: false)
        }
    }

    private var taskID: String {
        "\(holding.ticker)|\(holding.displayName)"
    }

    private var marketRows: some View {
        VStack(spacing: 0) {
            ForEach(Array(markets.enumerated()), id: \.element.id) { index, market in
                if index > 0 {
                    Divider().padding(.leading, 28)
                }
                Button {
                    if let url = market.webURL { openURL(url) }
                } label: {
                    PolymarketMarketRow(market: market)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var loadingRows: some View {
        VStack(spacing: 0) {
            ForEach(0..<3, id: \.self) { index in
                if index > 0 { Divider().padding(.leading, 28) }
                PolymarketMarketRow(
                    market: PolymarketRelatedMarket(
                        id: "placeholder-\(index)",
                        question: "正在读取最活跃的相关盘口",
                        eventTitle: "Polymarket",
                        eventSlug: "",
                        outcome: "Yes",
                        probability: 0.62,
                        volume24Hours: 12_500,
                        totalVolume: 220_000,
                        endDate: nil
                    )
                )
                .redacted(reason: .placeholder)
            }
        }
        .allowsHitTesting(false)
        .accessibilityLabel("正在读取 Polymarket 盘口")
    }

    private var emptyState: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: errorMessage == nil ? "scope" : "wifi.exclamationmark")
                .foregroundStyle(.secondary)
            Text(errorMessage ?? "暂时没有找到与 \(holding.ticker) 相关的活跃盘口")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 12)
    }

    @MainActor
    private func load(forceRefresh: Bool) async {
        isLoading = true
        errorMessage = nil
        do {
            let name = holding.displayName.components(separatedBy: " / ").first ?? holding.displayName
            let loaded = try await PolymarketClient.shared.relatedMarkets(
                ticker: holding.ticker,
                companyName: name,
                forceRefresh: forceRefresh
            )
            guard !Task.isCancelled else { return }
            markets = loaded
        } catch {
            guard !Task.isCancelled else { return }
            markets = []
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

private struct PolymarketMarketRow: View {
    let market: PolymarketRelatedMarket

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.caption.weight(.semibold))
                .foregroundStyle(CatfolioStyle.blue)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 5) {
                Text(market.question)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                HStack(spacing: 7) {
                    Text(activityText)
                    if let endDate = market.endDate {
                        Text("·")
                        Text("截止 \(endDate.formatted(.dateTime.month().day()))")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 6)

            VStack(alignment: .trailing, spacing: 3) {
                Text(probabilityText)
                    .appNumber(.heading, weight: .bold)
                    .foregroundStyle(CatfolioStyle.blue)
                Text(outcomeText)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            Image(systemName: "arrow.up.right")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 11)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(market.question)，\(outcomeText)概率\(probabilityText)，\(activityText)")
        .accessibilityHint("打开 Polymarket 查看")
    }

    private var probabilityText: String {
        market.probability.formatted(.percent.precision(.fractionLength(0...1)))
    }

    private var outcomeText: String {
        switch market.outcome.lowercased() {
        case "yes": "是"
        case "no": "否"
        case "up": "上涨"
        case "down": "下跌"
        default: market.outcome
        }
    }

    private var activityText: String {
        let amount = market.volume24Hours > 0 ? market.volume24Hours : market.totalVolume
        let prefix = market.volume24Hours > 0 ? "24h" : L10n.text("累计")
        return "\(prefix) \(DisplayFormat.compactMoney(amount, currency: "USD"))"
    }
}

private extension KeyedDecodingContainer {
    func flexibleDouble(forKey key: Key) -> Double? {
        if let value = try? decode(Double.self, forKey: key) { return value }
        if let value = try? decode(String.self, forKey: key) { return Double(value) }
        return nil
    }

    func stringArray(forKey key: Key) -> [String] {
        if let values = try? decode([String].self, forKey: key) { return values }
        guard let text = try? decode(String.self, forKey: key),
              let data = text.data(using: .utf8),
              let values = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return values
    }

    func doubleArray(forKey key: Key) -> [Double] {
        if let values = try? decode([Double].self, forKey: key) { return values }
        if let strings = try? decode([String].self, forKey: key) {
            return strings.compactMap(Double.init)
        }
        guard let text = try? decode(String.self, forKey: key),
              let data = text.data(using: .utf8) else { return [] }
        if let values = try? JSONDecoder().decode([Double].self, from: data) { return values }
        if let strings = try? JSONDecoder().decode([String].self, from: data) {
            return strings.compactMap(Double.init)
        }
        return []
    }

    func flexibleDate(forKey key: Key) -> Date? {
        guard let text = try? decode(String.self, forKey: key) else { return nil }
        if let date = ISO8601DateFormatter.withFractionalSeconds.date(from: text) { return date }
        return ISO8601DateFormatter().date(from: text)
    }
}

private extension ISO8601DateFormatter {
    static let withFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
