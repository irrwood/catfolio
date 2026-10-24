import Foundation
import Observation

/// Search data is independent of its presentation: phone results and sidebar
/// rows use the same directory, holdings merge, pagination and quote provider.
@MainActor @Observable
final class SecuritySearchModel {
    struct Request: Equatable {
        let query: String
        let limit: Int
        let holdings: [Holding]
    }

    struct QuoteRequest: Equatable {
        let entries: [WatchlistEntry]

        static func == (lhs: Self, rhs: Self) -> Bool {
            // Entries have fresh membership UUIDs; those belong to Watchlist
            // persistence, not to the identity of a search quote request.
            lhs.entries.map(\.id) == rhs.entries.map(\.id)
                && lhs.entries.map(\.quote) == rhs.entries.map(\.quote)
        }
    }

    typealias DirectorySearch = @Sendable (String, Int) async -> [MarketSecurityResult]
    typealias MainlandSearch = @Sendable (String) async throws -> [MarketSecurityResult]
    typealias QuoteLoader = @Sendable ([WatchlistEntry]) async -> [String: WatchlistQuote]

    private(set) var searchedQuery = ""
    private(set) var hasMore = false
    private(set) var quotes: [String: WatchlistQuote] = [:]
    private var directoryResults: [MarketSecurityResult] = []
    private var expandedQuery = ""
    private var expandedLimit = 15
    @ObservationIgnored private var searchGeneration = UUID()
    @ObservationIgnored private var quoteGeneration = UUID()
    @ObservationIgnored private let directorySearch: DirectorySearch
    @ObservationIgnored private let mainlandSearch: MainlandSearch
    @ObservationIgnored private let quoteLoader: QuoteLoader
    @ObservationIgnored private let searchDelay: Duration
    @ObservationIgnored private let quoteDelay: Duration

    init(searchDelay: Duration = .milliseconds(120), quoteDelay: Duration = .milliseconds(350),
         directorySearch: @escaping DirectorySearch = SecuritySearchModel.searchDirectory,
         mainlandSearch: @escaping MainlandSearch = { try await AKShareMarketDataClient().search($0) },
         quoteLoader: @escaping QuoteLoader = { await WatchlistMarketData.load($0, forceRefresh: false) }) {
        self.searchDelay = searchDelay
        self.quoteDelay = quoteDelay
        self.directorySearch = directorySearch
        self.mainlandSearch = mainlandSearch
        self.quoteLoader = quoteLoader
    }

    func request(query: String, holdings: [Holding]) -> Request {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return Request(query: text, limit: expandedQuery == text ? expandedLimit : 15, holdings: holdings)
    }

    func results(for request: Request) -> [MarketSecurityResult] {
        MarketSecurityResult.includingHoldings(searchedQuery == request.query ? directoryResults : [],
                                              holdings: request.holdings, query: request.query)
    }

    func loadMore(for query: String) {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text == searchedQuery, hasMore else { return }
        expandedLimit = (expandedQuery == text ? expandedLimit : 15) + 25
        expandedQuery = text
    }

    func search(_ request: Request) async {
        let generation = UUID()
        searchGeneration = generation
        if expandedQuery != request.query { expandedQuery = ""; expandedLimit = 15 }
        guard !request.query.isEmpty else {
            directoryResults = []; searchedQuery = ""; hasMore = false
            return
        }
        do { try await Task.sleep(for: searchDelay) } catch { return }
        guard !Task.isCancelled, generation == searchGeneration else { return }
        var results = await directorySearch(request.query, request.limit + 1)
        guard !Task.isCancelled, generation == searchGeneration else { return }
        apply(results, request: request)
        if ChinaMarketDataClient.shouldSearch(request.query),
           let mainland = try? await mainlandSearch(request.query) {
            let tickers = Set(mainland.map { $0.ticker.uppercased() })
            results = mainland + results.filter { !tickers.contains($0.ticker.uppercased()) }
        }
        guard !Task.isCancelled, generation == searchGeneration else { return }
        apply(results, request: request)
    }

    func quoteRequest(for request: Request) -> QuoteRequest {
        var seen = Set<String>()
        let entries = results(for: request).map { Self.entry(for: $0, holdings: request.holdings) }
        return QuoteRequest(entries: entries.filter { seen.insert($0.id).inserted })
    }

    func loadQuotes(_ request: QuoteRequest) async {
        let generation = UUID()
        quoteGeneration = generation
        guard !request.entries.isEmpty else { return }
        do { try await Task.sleep(for: quoteDelay) } catch { return }
        guard !Task.isCancelled, generation == quoteGeneration else { return }
        let loaded = await quoteLoader(request.entries)
        guard !Task.isCancelled, generation == quoteGeneration else { return }
        quotes.merge(loaded.filter { $0.value.isValid }) { _, latest in latest }
    }

    func quote(for result: MarketSecurityResult, holdings: [Holding]) -> WatchlistQuote? {
        let entry = Self.entry(for: result, holdings: holdings)
        return quotes[entry.id] ?? entry.quote
    }

    static func entry(for result: MarketSecurityResult, holdings: [Holding]) -> WatchlistEntry {
        WatchlistEntry(holding: result.resolvedHolding(in: holdings))
    }

    private func apply(_ results: [MarketSecurityResult], request: Request) {
        let applying = CompanyReferenceCatalog.searchSignposter.beginInterval("search.apply")
        directoryResults = Array(results.prefix(request.limit))
        hasMore = results.count > request.limit
        searchedQuery = request.query
        CompanyReferenceCatalog.searchSignposter.endInterval("search.apply", applying)
    }

    private nonisolated static func searchDirectory(_ query: String, limit: Int) async -> [MarketSecurityResult] {
        let worker = Task.detached(priority: .userInitiated) { () -> [MarketSecurityResult] in
            guard let catalog = try? CompanyReferenceCatalog.bundled.get() else { return [] }
            return MarketSecurityResult.search(query, in: catalog, limit: limit,
                                               shouldCancel: { Task.isCancelled })
        }
        return await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
    }
}
