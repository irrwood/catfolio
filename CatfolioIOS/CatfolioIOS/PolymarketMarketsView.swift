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
    var localizedOutcome: String? = nil
    // Optional so existing on-device caches remain readable.
    var groupItemTitle: String? = nil
    var oneDayPriceChange: Double? = nil

    var outcomeText: String {
        switch outcome.lowercased() {
        case "yes": L10n.text("是")
        case "no": L10n.text("否")
        case "up": L10n.text("上涨")
        case "down": L10n.text("下跌")
        default: localizedOutcome ?? outcome
        }
    }

    var webURL: URL? {
        URL(string: "https://polymarket.com/event/\(eventSlug)")
    }

    var hasUsableContent: Bool {
        !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && !eventSlug.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && probability.isFinite && (0...1).contains(probability) && webURL != nil
    }

    func probabilityText(locale: Locale) -> String {
        probability.formatted(.percent.precision(.fractionLength(0)).locale(locale))
    }
}

/// One event title and up to three options, each with its own volume. Keep
/// probability values untouched; rounding and grouping are presentation only.
struct PolymarketRelatedEvent: Identifiable {
    let id: String
    let markets: [PolymarketRelatedMarket]
    var title: String { markets.first?.eventTitle ?? "" }
    var webURL: URL? { markets.first?.webURL }
    var visibleMarkets: [PolymarketRelatedMarket] {
        Array(markets.sorted { $0.probability > $1.probability }.prefix(3))
    }
    var hasMultipleOptions: Bool { markets.count > 1 }

    static func grouped(_ markets: [PolymarketRelatedMarket]) -> [Self] {
        var order: [String] = []
        var groups: [String: [PolymarketRelatedMarket]] = [:]
        var seen = Set<String>()
        for market in markets where seen.insert(market.id).inserted {
            let key = market.eventSlug.isEmpty ? market.id : market.eventSlug
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(market)
        }
        return order.map { Self(id: $0, markets: groups[$0] ?? []) }
    }
}

enum PolymarketClientError: LocalizedError {
    case invalidResponse
    case remote(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            L10n.text("Polymarket 返回了无法识别的数据")
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
        let groupItemTitle: String?
        let oneDayPriceChange: Double?

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
            case groupItemTitle
            case oneDayPriceChange
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = (try? container.decode(String.self, forKey: .id)) ?? UUID().uuidString
            question = (try? container.decode(String.self, forKey: .question)) ?? L10n.text("Polymarket 盘口")
            active = try? container.decodeIfPresent(Bool.self, forKey: .active)
            closed = try? container.decodeIfPresent(Bool.self, forKey: .closed)
            outcomes = container.stringArray(forKey: .outcomes)
            outcomePrices = container.doubleArray(forKey: .outcomePrices)
            volume = container.flexibleDouble(forKey: .volumeNum)
                ?? container.flexibleDouble(forKey: .volume)
                ?? 0
            volume24Hours = container.flexibleDouble(forKey: .volume24Hours) ?? 0
            endDate = container.flexibleDate(forKey: .endDate)
            groupItemTitle = try? container.decodeIfPresent(String.self, forKey: .groupItemTitle)
            oneDayPriceChange = container.flexibleDouble(forKey: .oneDayPriceChange)
        }
    }

    private let session: URLSession
    private let diskCacheURL: URL
    private var cache: [String: CacheEntry] = [:]
    private var didLoadCache = false
    private let freshness: TimeInterval = 15 * 60

    init(session suppliedSession: URLSession? = nil, cacheURL: URL? = nil) {
        diskCacheURL = cacheURL ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("catfolio-polymarket-markets.json")
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 12
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.urlCache = URLCache(
            memoryCapacity: 4 * 1_024 * 1_024,
            diskCapacity: 20 * 1_024 * 1_024
        )
        session = suppliedSession ?? URLSession(configuration: configuration)
    }

    func relatedMarkets(
        ticker: String,
        companyName: String,
        forceRefresh: Bool = false,
        language: String = AppLanguage.currentIdentifier
    ) async throws -> [PolymarketRelatedMarket] {
        loadCacheIfNeeded()
        let cacheKey = ContentLanguage.cacheKey(Self.cacheKey(ticker: ticker, companyName: companyName), language: language)
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

            let ranked = Self.rank(events: events)
            let markets = try await localizedMarkets(ranked, events: events, language: language, forceRefresh: forceRefresh)
            cache[cacheKey] = CacheEntry(fetchedAt: Date(), markets: markets)
            persistCache()
            return markets
        } catch {
            if let cached { return cached.markets }
            throw error
        }
    }

    /// Nil is not loaded / unknown, [] is a previously successful empty lookup.
    func cachedRelatedMarkets(ticker: String, companyName: String,
                              language: String = AppLanguage.currentIdentifier) -> [PolymarketRelatedMarket]? {
        loadCacheIfNeeded()
        let key = ContentLanguage.cacheKey(Self.cacheKey(ticker: ticker, companyName: companyName), language: language)
        guard let entry = cache[key] else { return nil }
        let markets = entry.markets.filter(\.hasUsableContent)
        // Positive user caches remain usable. An expired negative lookup must
        // not suppress newly created markets forever on subsequent visits.
        guard !markets.isEmpty || Date().timeIntervalSince(entry.fetchedAt) < freshness else { return nil }
        return markets
    }

    /// Search establishes identity and quote selection; locale changes presentation only.
    private func localizedMarkets(_ ranked: [PolymarketRelatedMarket], events: [SearchEvent],
                                  language: String, forceRefresh: Bool) async throws -> [PolymarketRelatedMarket] {
        guard !ranked.isEmpty else { return [] }
        struct Payload: Decodable { let markets: [Translation] }
        struct Translation: Decodable {
            struct Event: Decodable { let title: String }
            let id: String
            let question: String
            let outcomes: String?
            let groupItemTitle: String?
            let events: [Event]?
        }
        var url = URLComponents(string: "https://gamma-api.polymarket.com/markets/keyset")!
        url.queryItems = [URLQueryItem(name: "locale", value: language.hasPrefix("zh") ? "zh" : "en"),
                          URLQueryItem(name: "limit", value: "100")]
            + ranked.map { URLQueryItem(name: "id", value: $0.id) }
        var request = URLRequest(url: url.url!, cachePolicy: forceRefresh ? .reloadIgnoringLocalCacheData : .useProtocolCachePolicy)
        request.setValue(language, forHTTPHeaderField: "Accept-Language")
        let (data, response) = try await session.recordedData(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw PolymarketClientError.invalidResponse
        }
        let translations: [Translation]
        do {
            translations = try JSONDecoder().decode(Payload.self, from: data).markets
        } catch {
            DataSourceHealth.reportUnusable(DataSource.of(request.url), issue: .invalidFormat)
            throw error
        }
        return ranked.compactMap { market in
            guard let translated = translations.first(where: { $0.id == market.id }),
                  ContentLanguage.acceptsHeadline(translated.question, language: language) else { return nil }
            let original = events.flatMap { $0.markets ?? [] }.first { $0.id == market.id }
            let labels = translated.outcomes.flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) } ?? []
            let index = original?.outcomes.firstIndex(of: market.outcome)
            let label = index.flatMap { labels.indices.contains($0) ? labels[$0] : nil }
            return PolymarketRelatedMarket(id: market.id, question: translated.question,
                eventTitle: translated.events?.first?.title ?? translated.question,
                eventSlug: market.eventSlug, outcome: market.outcome, probability: market.probability,
                volume24Hours: market.volume24Hours, totalVolume: market.totalVolume,
                endDate: market.endDate, localizedOutcome: label,
                groupItemTitle: translated.groupItemTitle ?? (language.hasPrefix("zh") ? nil : market.groupItemTitle),
                oneDayPriceChange: market.oneDayPriceChange)
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
        let (data, response) = try await session.recordedData(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PolymarketClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw PolymarketClientError.remote(L10n.text("暂时无法读取 Polymarket（HTTP \(http.statusCode)）"))
        }
        do {
            return try JSONDecoder().decode(SearchResponse.self, from: data).events ?? []
        } catch {
            DataSourceHealth.reportUnusable(DataSource.of(request.url), issue: .invalidFormat)
            throw PolymarketClientError.invalidResponse
        }
    }

    private static func rank(events: [SearchEvent]) -> [PolymarketRelatedMarket] {
        var results: [PolymarketRelatedMarket] = []
        var marketIDs = Set<String>()

        for event in events
        where event.active != false && event.closed != true && event.archived != true {
            let activeMarkets = (event.markets ?? []).filter { $0.active != false && $0.closed != true }
            for market in activeMarkets where marketIDs.insert(market.id).inserted {
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
                        endDate: market.endDate,
                        groupItemTitle: market.groupItemTitle,
                        // Gamma's change belongs to the first quote. Do not
                        // attach it to a different selected outcome.
                        oneDayPriceChange: market.outcomes.first == quote.outcome
                            ? market.oneDayPriceChange : nil
                    )
                )
            }
        }

        let ranked = results.sorted { left, right in
            if left.volume24Hours != right.volume24Hours {
                return left.volume24Hours > right.volume24Hours
            }
            return left.totalVolume > right.totalVolume
        }
        // Retain the top options of each event, not five unrelated flattened
        // rows. Each option retains its own original quote and volume.
        return PolymarketRelatedEvent.grouped(ranked).prefix(5).flatMap(\.visibleMarkets)
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

    private var cacheURL: URL { diskCacheURL }
}

/// One event: its question, then up to three options. Each option reads as
/// name and volume on the left, probability and its 24h move on the right.
struct PolymarketEventCard: View {
    @Environment(\.locale) private var locale
    let event: PolymarketRelatedEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(event.title)
                    .appText(.footnote, weight: .semibold)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }

            VStack(spacing: 12) {
                ForEach(event.visibleMarkets) { market in
                    optionRow(market)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityHint(L10n.text("打开 Polymarket 查看"))
    }

    private func optionRow(_ market: PolymarketRelatedMarket) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(optionTitle(market))
                        .appText(.footnote)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(L10n.text("\(DisplayFormat.compactMoney(market.totalVolume, currency: "USD")) volume"))
                        .appText(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .trailing, spacing: 2) {
                    Text(market.probabilityText(locale: locale))
                        .appNumber(.subheading, weight: .semibold)
                        .foregroundStyle(.primary)
                    change(market.oneDayPriceChange)
                }
                .fixedSize()
        }
        .accessibilityElement(children: .combine)
    }

    private func optionTitle(_ market: PolymarketRelatedMarket) -> String {
        if let title = market.groupItemTitle, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return title
        }
        return event.hasMultipleOptions ? market.question : market.outcomeText
    }

    /// A change in odds, not investment profit or loss. Direction colours
    /// follow the supplied market-card reference: up red, down green.
    @ViewBuilder
    private func change(_ change: Double?) -> some View {
        // Anything that would print as 0% reads as no move, not an arrow.
        if let change, change.isFinite, abs(change) >= 0.001 {
            let color = change > 0 ? CatfolioStyle.red : CatfolioStyle.green
            HStack(spacing: 2) {
                Image(systemName: change > 0 ? "arrow.up.right" : "arrow.down.right")
                    .font(.system(size: 9, weight: .bold))
                Text(abs(change).formatted(.percent.precision(.fractionLength(0...1)).locale(locale)))
                    .appNumber(.caption, weight: .medium)
            }
            .foregroundStyle(color)
            .accessibilityLabel(L10n.text("24h probability change") + " " +
                change.formatted(.percent.precision(.fractionLength(0...1)).locale(locale)))
        } else {
            Text(verbatim: "—")
                .appNumber(.caption, weight: .medium)
                .foregroundStyle(.quaternary)
                .accessibilityLabel(L10n.text("24h probability change unavailable"))
        }
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
