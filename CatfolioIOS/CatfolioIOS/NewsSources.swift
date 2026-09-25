import Foundation

// MARK: - Settings

/// The feeds news leads come from. Every feature that looks for news — the
/// attention scan, a security's developments, today's move — asks
/// `NewsSourceHub`, so a choice made in 设置 › 新闻 reaches all of them.
enum NewsProvider: String, CaseIterable, Identifiable, Sendable {
    case googleNews
    case yahooFinance
    case secEdgar
    case gdelt
    case finnhub

    var id: String { rawValue }

    var title: String {
        switch self {
        case .googleNews: "Google News"
        case .yahooFinance: "Yahoo Finance"
        case .secEdgar: "SEC EDGAR"
        case .gdelt: "GDELT"
        case .finnhub: "Finnhub"
        }
    }

    var iconName: String {
        switch self {
        case .googleNews: "magnifyingglass"
        case .yahooFinance: "chart.line.uptrend.xyaxis"
        case .secEdgar: "building.columns"
        case .gdelt: "globe"
        case .finnhub: "newspaper"
        }
    }

    var enabledKey: String { "news.provider.\(rawValue)" }

    var isEnabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    /// Switched on and, where the feed needs a key, configured.
    var isActive: Bool { isEnabled && (self != .finnhub || LocalServiceKeys.hasFinnhubKey) }
}

enum NewsSettings {
    static let blockedSitesKey = "news.blockedSites"
    static let queryPlanKey = "news.queryPlan"
    static let readsArticlesKey = "news.readsArticles"

    /// Site names or domains, one per line, lower-cased.
    static var blockedSites: [String] {
        sites(from: UserDefaults.standard.string(forKey: blockedSitesKey) ?? "")
    }

    static func sites(from stored: String) -> [String] {
        stored.components(separatedBy: .newlines).map(normalizedSite).filter { !$0.isEmpty }
    }

    /// "https://www.fool.com/investing/…" and "Fool.com" both become "fool.com".
    static func normalizedSite(_ text: String) -> String {
        var site = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let host = URL(string: site)?.host { site = host }
        if site.hasPrefix("www.") { site.removeFirst(4) }
        return site
    }

    static var usesQueryPlan: Bool { UserDefaults.standard.object(forKey: queryPlanKey) as? Bool ?? true }
    static var readsArticles: Bool { UserDefaults.standard.object(forKey: readsArticlesKey) as? Bool ?? true }

    /// Google wraps every link, so a blocked domain is also matched by name:
    /// "fool.com" catches a story Google credits to "Motley Fool".
    static func isBlocked(_ source: PortfolioAttentionSource, sites: [String]) -> Bool {
        guard !sites.isEmpty else { return false }
        let publisher = source.publisher.lowercased()
        let compactPublisher = publisher.filter { $0.isLetter || $0.isNumber }
        let host = source.url.host?.lowercased() ?? ""
        return sites.contains { site in
            if publisher.contains(site) || host == site || host.hasSuffix("." + site) { return true }
            guard let label = siteName(site), label.count >= 4 else { return false }
            return compactPublisher.contains(label)
        }
    }

    /// "fool.com" → "fool", "news.example.co.uk" → "example".
    private static func siteName(_ site: String) -> String? {
        let labels = site.split(separator: ".").map(String.init)
        guard labels.count >= 2 else { return nil }
        let secondLevel = ["co", "com", "net", "org", "gov", "ac"]
        let index = labels.count >= 3 && secondLevel.contains(labels[labels.count - 2]) ? labels.count - 3 : labels.count - 2
        return labels[index]
    }
}

// MARK: - Query plan

/// The searches run for one holding. One broad search surfaces what is
/// popular; the two narrow ones keep a lawsuit or a results day from being
/// crowded out by commentary. The plan is fixed, not chosen by a model, so
/// the same holding is always searched the same way.
enum NewsQueryPlan: String, CaseIterable {
    case legal
    case earnings

    func query(name: String, ticker: String) -> String? {
        guard let subject = Self.searchName(name, ticker: ticker) else { return nil }
        switch self {
        case .legal:
            return "\"\(subject)\" (lawsuit OR investigation OR probe OR restatement OR subpoena) when:30d"
        case .earnings:
            return "\"\(subject)\" (earnings OR results OR guidance) when:30d"
        }
    }

    /// What a newspaper calls the company: "Alphabet Inc. Class A" is
    /// "Alphabet". A name in Chinese is left to the base search, which
    /// already runs in that edition.
    static func searchName(_ name: String, ticker: String) -> String? {
        guard !name.unicodeScalars.contains(where: { (0x3400...0x9fff).contains($0.value) }) else { return nil }
        let suffixes: Set<String> = ["inc", "incorporated", "corp", "corporation", "company", "co", "plc", "ltd",
                                     "limited", "holdings", "holding", "group", "class", "nv", "sa", "ag", "se",
                                     "adr", "ads", "common", "ordinary", "shares", "llc", "lp"]
        var words: [String] = []
        for word in name.split(whereSeparator: \.isWhitespace).map(String.init) {
            let bare = word.trimmingCharacters(in: .punctuationCharacters).lowercased()
                .replacingOccurrences(of: ".", with: "")
            if suffixes.contains(bare) || word == "-" { break }
            words.append(word.trimmingCharacters(in: CharacterSet(charactersIn: ",")))
        }
        if words.first?.lowercased() == "the" { words.removeFirst() }
        let subject = words.joined(separator: " ")
        if subject.count >= 3 { return subject }
        return ticker.count >= 3 ? ticker.uppercased() : nil
    }
}

// MARK: - Providers

struct NewsQuery: Sendable {
    let ticker: String
    let name: String
    let language: String
}

protocol NewsSourceProvider: Sendable {
    var kind: NewsProvider { get }
    func sources(for query: NewsQuery) async -> [PortfolioAttentionSource]
    /// Several holdings at once. A feed with a strict rate limit overrides
    /// this to ask once for all of them.
    func sources(for queries: [NewsQuery]) async -> [String: [PortfolioAttentionSource]]
}

extension NewsSourceProvider {
    func sources(for queries: [NewsQuery]) async -> [String: [PortfolioAttentionSource]] {
        var result: [String: [PortfolioAttentionSource]] = [:]
        // Four holdings at a time: a portfolio's worth of searches at once
        // is what gets a caller throttled.
        for chunk in stride(from: 0, to: queries.count, by: 4).map({ Array(queries[$0..<min($0 + 4, queries.count)]) }) {
            await withTaskGroup(of: (String, [PortfolioAttentionSource]).self) { group in
                for query in chunk {
                    group.addTask { (query.ticker, await sources(for: query)) }
                }
                for await (ticker, sources) in group { result[ticker] = sources }
            }
        }
        return result
    }
}

struct GoogleNewsProvider: NewsSourceProvider {
    let kind = NewsProvider.googleNews
    var usesQueryPlan = NewsSettings.usesQueryPlan

    func sources(for query: NewsQuery) async -> [PortfolioAttentionSource] {
        var searches: [(label: String, url: URL, limit: Int)] = [
            (query.language, ContentLanguage.newsURL(ticker: query.ticker, name: query.name, language: query.language), 20),
        ]
        // A Chinese reader still needs the original reporting, which is in English.
        if query.language.hasPrefix("zh") {
            searches.append(("en", ContentLanguage.newsURL(ticker: query.ticker, name: query.name, language: "en"), 20))
        }
        if usesQueryPlan {
            for plan in NewsQueryPlan.allCases {
                guard let text = plan.query(name: query.name, ticker: query.ticker) else { continue }
                searches.append(("en-\(plan.rawValue)", ContentLanguage.newsURL(query: text, language: "en"), 10))
            }
        }
        return await withTaskGroup(of: (Int, [PortfolioAttentionSource]).self) { group in
            for (index, search) in searches.enumerated() {
                group.addTask {
                    guard let data = await SecurityDebateResearch.get(search.url, language: query.language) else {
                        return (index, [])
                    }
                    guard let stories = SecurityDebateResearch.parseRSSChecked(
                        data, ticker: "\(query.ticker)-\(search.label)", limit: search.limit
                    ) else {
                        DataSourceHealth.reportUnusable(DataSource.of(search.url), issue: .invalidFormat)
                        return (index, [])
                    }
                    return (index, stories)
                }
            }
            var collected: [(Int, [PortfolioAttentionSource])] = []
            for await item in group { collected.append(item) }
            return collected.sorted { $0.0 < $1.0 }.flatMap(\.1)
        }
    }
}

struct YahooFinanceNewsProvider: NewsSourceProvider {
    let kind = NewsProvider.yahooFinance

    func sources(for query: NewsQuery) async -> [PortfolioAttentionSource] {
        await SecurityDebateResearch().yahooNews(ticker: query.ticker, name: query.name)
    }
}

struct SECEdgarProvider: NewsSourceProvider {
    let kind = NewsProvider.secEdgar

    func sources(for query: NewsQuery) async -> [PortfolioAttentionSource] {
        await SecurityDebateResearch().secFilings(ticker: query.ticker, name: query.name)
    }
}

/// GDELT asks for one request every five seconds from each caller, so a
/// whole portfolio goes into one query and every caller shares this gate.
actor GDELTGate {
    static let shared = GDELTGate()
    private var nextSlot = Date.distantPast

    /// Waits for the next free slot, or declines if that is further off than
    /// the caller can wait.
    func reserve(maximumWait: TimeInterval) async -> Bool {
        let now = Date()
        let start = max(now, nextSlot)
        let wait = start.timeIntervalSince(now)
        guard wait <= maximumWait else { return false }
        nextSlot = start.addingTimeInterval(5.5)
        if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
        return true
    }

    /// A refusal means the last slot was too soon; leave a wider gap.
    func backOff() {
        nextSlot = max(nextSlot, Date()).addingTimeInterval(10)
    }
}

struct GDELTProvider: NewsSourceProvider {
    let kind = NewsProvider.gdelt

    func sources(for query: NewsQuery) async -> [PortfolioAttentionSource] {
        await sources(for: [query])[query.ticker] ?? []
    }

    func sources(for queries: [NewsQuery]) async -> [String: [PortfolioAttentionSource]] {
        // GDELT refuses short phrases, and a two-letter ticker matches noise.
        let subjects = queries.compactMap { query -> (NewsQuery, String)? in
            guard let name = NewsQueryPlan.searchName(query.name, ticker: query.ticker), name.count >= 4 else { return nil }
            return (query, name)
        }
        var result: [String: [PortfolioAttentionSource]] = [:]
        // Two requests at most: a third would keep the analysis waiting
        // fifteen seconds on one feed.
        let chunks = stride(from: 0, to: subjects.count, by: 8).prefix(2)
            .map { Array(subjects[$0..<min($0 + 8, subjects.count)]) }
        for chunk in chunks {
            guard await GDELTGate.shared.reserve(maximumWait: 12) else { break }
            let phrases = chunk.map { "\"\($0.1)\"" }
            let terms = phrases.count == 1 ? phrases[0] : "(" + phrases.joined(separator: " OR ") + ")"
            var components = URLComponents(string: "https://api.gdeltproject.org/api/v2/doc/doc")!
            components.queryItems = [
                URLQueryItem(name: "query", value: "\(terms) sourcelang:english"),
                URLQueryItem(name: "mode", value: "ArtList"),
                URLQueryItem(name: "format", value: "json"),
                URLQueryItem(name: "maxrecords", value: "100"),
                URLQueryItem(name: "timespan", value: "14d"),
            ]
            guard let url = components.url,
                  let data = await SecurityDebateResearch.get(url, language: "en") else {
                await GDELTGate.shared.backOff()
                continue
            }
            guard let articles = Self.articles(in: data) else {
                // Over the limit GDELT answers 200 with a plain-text notice.
                let issue: DataSourceDataIssue =
                    ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) == nil
                    ? .invalidFormat : .missingRequiredFields
                DataSourceHealth.reportUnusable(DataSource.of(url), issue: issue)
                await GDELTGate.shared.backOff()
                continue
            }
            for (query, _) in chunk {
                let matched = articles.filter {
                    SecurityDebateResearch.mentionsCompany($0.title, ticker: query.ticker, name: query.name)
                }
                result[query.ticker] = matched.prefix(12).enumerated().map { index, article in
                    let publisher = Self.publisher(forDomain: article.domain)
                    return PortfolioAttentionSource(
                        id: "\(query.ticker.lowercased())-gdelt-\(index + 1)",
                        title: article.title,
                        publisher: publisher,
                        url: article.url,
                        publishedAt: article.seen,
                        tier: SecurityDebateResearch.tier(for: publisher)
                    )
                }
            }
        }
        return result
    }

    struct Article {
        let title: String
        let url: URL
        let domain: String
        let seen: Date?
    }

    static func articles(in data: Data) -> [Article]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard let rows = object["articles"] as? [[String: Any]] else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return rows.compactMap { item in
            guard let title = (item["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty,
                  let link = item["url"] as? String, let url = URL(string: link) else { return nil }
            let domain = (item["domain"] as? String) ?? url.host ?? ""
            return Article(title: title, url: url, domain: domain,
                           seen: (item["seendate"] as? String).flatMap(formatter.date(from:)))
        }
    }

    /// GDELT reports a domain, not a publisher. The ones the tier legend
    /// knows by name are named, so a Reuters story still reads as a wire.
    static func publisher(forDomain domain: String) -> String {
        let host = NewsSettings.normalizedSite(domain)
        let names = [
            "reuters.com": "Reuters", "bloomberg.com": "Bloomberg", "apnews.com": "Associated Press",
            "wsj.com": "The Wall Street Journal", "ft.com": "Financial Times", "cnbc.com": "CNBC",
            "marketwatch.com": "MarketWatch", "barrons.com": "Barron's", "nytimes.com": "The New York Times",
            "businesswire.com": "Business Wire", "globenewswire.com": "GlobeNewswire",
            "prnewswire.com": "PR Newswire", "fool.com": "The Motley Fool", "seekingalpha.com": "Seeking Alpha",
        ]
        return names.first { host == $0.key || host.hasSuffix("." + $0.key) }?.value ?? host
    }
}

/// Finnhub's company news: US listings only, and only with the reader's key.
struct FinnhubNewsProvider: NewsSourceProvider {
    let kind = NewsProvider.finnhub

    struct Item: Decodable {
        let datetime: Int?
        let headline: String
        let source: String?
        let summary: String?
        let url: String
    }

    func sources(for query: NewsQuery) async -> [PortfolioAttentionSource] {
        guard let key = KeychainStore.string(for: LocalServiceKeys.finnhub)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty,
              let symbol = Self.symbol(for: query.ticker),
              let items = try? await Self.companyNews(symbol: symbol, days: 21, apiKey: key) else { return [] }
        return items
            .filter { SecurityDebateResearch.mentionsCompany($0.headline + " " + ($0.summary ?? ""),
                                                             ticker: query.ticker, name: query.name) }
            .sorted { ($0.datetime ?? 0) > ($1.datetime ?? 0) }
            .prefix(12).enumerated().compactMap { index, item in
                guard let url = URL(string: item.url), !item.headline.isEmpty else { return nil }
                let publisher = item.source.flatMap { $0.isEmpty ? nil : $0 } ?? "Finnhub"
                let summary = item.summary?.trimmingCharacters(in: .whitespacesAndNewlines)
                return PortfolioAttentionSource(
                    id: "\(query.ticker.lowercased())-finnhub-\(index + 1)",
                    title: item.headline,
                    publisher: publisher,
                    url: url,
                    publishedAt: item.datetime.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                    tier: SecurityDebateResearch.tier(for: publisher),
                    summary: summary.flatMap { $0.isEmpty ? nil : String($0.prefix(800)) }
                )
            }
    }

    /// "AAPL" and "BRK.B" are US listings; "VOD.L" and "0700.HK" are not.
    /// A single letter after the dot is a share class only for A to C —
    /// London, Tokyo and Frankfurt are single letters too.
    static func symbol(for ticker: String) -> String? {
        let symbol = ticker.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !symbol.isEmpty, !symbol.contains("-"), !symbol.contains(":") else { return nil }
        let parts = symbol.split(separator: ".")
        if parts.count == 1 { return symbol }
        return parts.count == 2 && ["A", "B", "C"].contains(parts[1]) ? symbol : nil
    }

    /// The key goes in a header rather than the URL, so it stays out of any
    /// log that records addresses.
    static func companyNews(symbol: String, days: Int, apiKey: String) async throws -> [Item] {
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.timeZone = TimeZone(identifier: "America/New_York")
        day.dateFormat = "yyyy-MM-dd"
        let now = Date()
        var components = URLComponents(string: "https://finnhub.io/api/v1/company-news")!
        components.queryItems = [
            URLQueryItem(name: "symbol", value: symbol),
            URLQueryItem(name: "from", value: day.string(from: now.addingTimeInterval(-Double(days) * 86_400))),
            URLQueryItem(name: "to", value: day.string(from: now)),
        ]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 15
        request.setValue(apiKey, forHTTPHeaderField: "X-Finnhub-Token")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await LocalRequestSessions.ephemeral.recordedData(for: request)
        guard let http = response as? HTTPURLResponse else { throw LocalServiceError.invalidResponse }
        switch http.statusCode {
        case 200..<300:
            guard let items = try? JSONDecoder().decode([Item].self, from: data) else {
                DataSourceHealth.reportUnusable(DataSource.of(request.url), issue: .invalidFormat)
                throw LocalServiceError.invalidResponse
            }
            return items
        case 401, 403:
            throw LocalServiceError.remote(L10n.text("Finnhub 拒绝了这个密钥，请检查后重试"))
        case 429:
            throw LocalServiceError.remote(L10n.text("Finnhub 请求过于频繁，请稍后再试"))
        default:
            throw LocalServiceError.remote(L10n.text("Finnhub 请求失败（\(http.statusCode)）"))
        }
    }
}

// MARK: - Hub

/// One place that asks every switched-on feed, applies the reader's site
/// rules and removes duplicates. Filings and publisher feeds come first, so
/// when one story reaches several feeds the most direct copy is the one kept.
struct NewsSourceHub {
    let providers: [any NewsSourceProvider]

    init(providers: [NewsProvider] = NewsProvider.allCases.filter(\.isActive)) {
        self.providers = providers.map { kind -> any NewsSourceProvider in
            switch kind {
            case .googleNews: GoogleNewsProvider()
            case .yahooFinance: YahooFinanceNewsProvider()
            case .secEdgar: SECEdgarProvider()
            case .gdelt: GDELTProvider()
            case .finnhub: FinnhubNewsProvider()
            }
        }
    }

    private static let order: [NewsProvider] = [.secEdgar, .finnhub, .yahooFinance, .gdelt, .googleNews]

    func sources(ticker: String, name: String,
                 language: String = ContentLanguage.current) async -> [PortfolioAttentionSource] {
        await sources(for: [NewsQuery(ticker: ticker, name: name, language: language)])[ticker] ?? []
    }

    func sources(for queries: [NewsQuery]) async -> [String: [PortfolioAttentionSource]] {
        guard !queries.isEmpty else { return [:] }
        let collected = await withTaskGroup(of: (NewsProvider, [String: [PortfolioAttentionSource]]).self) { group in
            for provider in providers {
                group.addTask { (provider.kind, await provider.sources(for: queries)) }
            }
            var result: [NewsProvider: [String: [PortfolioAttentionSource]]] = [:]
            for await (kind, sources) in group { result[kind] = sources }
            return result
        }
        let blocked = NewsSettings.blockedSites
        let excludesAggregators = AttentionEvidenceRules.excludeAggregators
        var result: [String: [PortfolioAttentionSource]] = [:]
        for query in queries {
            let merged = Self.order.flatMap { collected[$0]?[query.ticker] ?? [] }.filter { source in
                !NewsSettings.isBlocked(source, sites: blocked)
                    && !(excludesAggregators && AttentionEvidenceRules.isAggregator(source.publisher))
            }
            result[query.ticker] = SecurityDebateResearch.deduplicated(merged)
        }
        return result
    }
}

#if DEBUG
extension NewsSourceHub {
    /// `--probe-news`: asks each feed for two holdings and prints what came
    /// back, so a feed that silently returns nothing shows up in the log.
    static func probe() async {
        let queries = [NewsQuery(ticker: "NVDA", name: "NVIDIA Corporation", language: "en"),
                       NewsQuery(ticker: "PLTR", name: "Palantir Technologies Inc. Class A", language: "zh-Hans")]
        for kind in NewsProvider.allCases {
            let found = await NewsSourceHub(providers: [kind]).sources(for: queries)
            for query in queries {
                let sources = found[query.ticker] ?? []
                print("[news-probe] \(kind.rawValue) \(query.ticker): \(sources.count)")
                for source in sources.prefix(3) {
                    print("[news-probe]   [\(source.tier)] \(source.publisher) · \(source.title.prefix(70))")
                }
            }
        }
        let rows = await NewsSourceHub().sources(for: queries)
        print("[news-probe] hub NVDA \(rows["NVDA"]?.count ?? 0) PLTR \(rows["PLTR"]?.count ?? 0)")
        let research = SecurityDebateResearch()
        let leads = Array(SecurityDebateResearch.candidates(rows["NVDA"] ?? []).filter { $0.tier != "filing" }.prefix(3))
        let documents = await research.documents(sources: leads, ticker: "NVDA", name: "NVIDIA Corporation")
        for document in documents {
            print("[news-probe] read \(document.source.publisher): \(document.text.count) chars · \(document.text.prefix(90))")
        }
    }
}
#endif
