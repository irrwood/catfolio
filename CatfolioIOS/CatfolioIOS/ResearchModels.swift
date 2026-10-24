import SwiftUI
import Charts
import CryptoKit
import Observation

actor ResearchAnalysisCache {
    static let shared = ResearchAnalysisCache()
    private let directory: URL

    init(directory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("research-analysis-v1", isDirectory: true)) {
        self.directory = directory
    }

    private func file(for scope: String) -> URL {
        let key = SHA256.hash(data: Data(scope.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(key).appendingPathExtension("json")
    }

    func load(scope: String) -> PortfolioAttentionReport? {
        guard let data = try? Data(contentsOf: file(for: scope)) else { return nil }
        return try? JSONDecoder().decode(PortfolioAttentionReport.self, from: data)
    }

    /// The account scope a report is saved under: the language, demo or real
    /// data, and the selected accounts. Shared by the attention page and its
    /// preview on the Performance tab, so both read the same report.
    @MainActor static func scope(locale: Locale, model: AppModel) -> String {
        let keys = [locale.identifier, model.isFakeDataMode ? "demo" : "real"] + model.selectedAccountKeys.sorted()
        return keys.map { "\($0.utf8.count):\($0)" }.joined()
    }

    func save(_ report: PortfolioAttentionReport, scope: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(report).write(to: file(for: scope), options: [.atomic, .completeFileProtectionUnlessOpen])
    }
}

/// Research is read-only: market context and selected-account holdings never
/// write into the portfolio ledger. Historical closes are not live quotes.
struct ResearchMarketSnapshot: Identifiable {
    struct Point: Identifiable {
        let id: String
        let value: Double
    }
    let id: String
    let title: String
    let points: [Point]
    var latest: Point? { points.last }
    var changeBasisPoints: Double? {
        guard points.count >= 2 else { return nil }
        return (points[points.count - 1].value - points[points.count - 2].value) * 100
    }
    var changePercent: Double? {
        guard points.count >= 2, points[points.count - 2].value > 0 else { return nil }
        return (points[points.count - 1].value / points[points.count - 2].value - 1) * 100
    }

    init(id: String, title: String, history: [String: Double]) {
        self.id = id
        self.title = title
        points = history.filter { $0.value.isFinite && $0.value > 0 }
            .sorted { $0.key < $1.key }.map { Point(id: $0.key, value: $0.value) }
    }
}

/// One security from the offline directory, ready to open in the detail
/// sheet whether or not anything is held.
struct MarketSecurityResult: Identifiable, Hashable, Sendable {
    let ticker: String
    let name: String
    let market: String
    let exchange: String?
    let currency: String?
    let sector: String?
    let isFund: Bool
    var id: String { ticker }

    /// Where it trades, short: the exchange in the US, the market elsewhere,
    /// whose own exchange names run too long for a row.
    var venue: String {
        let place = market == "US" ? exchange ?? market : market
        return isFund ? (place.isEmpty ? "ETF" : "ETF · \(place)") : place
    }

    static func search(
        _ query: String,
        in catalog: CompanyReferenceCatalog,
        limit: Int = 40,
        shouldCancel: () -> Bool = { false }
    ) -> [Self] {
        catalog.search(query, limit: limit, shouldCancel: shouldCancel).map { entry in
            Self(
                ticker: catalog.brokerSymbol(for: entry),
                name: entry.name ?? entry.symbol,
                market: entry.market,
                exchange: entry.exchange,
                currency: entry.currency ?? CompanyReferenceCatalog.listingCurrency(market: entry.market),
                sector: entry.sector,
                isFund: HoldingSecurityKind.classify(instrumentType: entry.instrumentType, names: [entry.name ?? ""]) == .fund
            )
        }
    }

    /// Keep the directory's relevance order, including its alias ranking.
    /// Holdings enrich selection and fill missing symbols; ownership is never
    /// a ranking signal. Broker-only matches enter at their matching tier.
    static func includingHoldings(_ results: [Self], holdings: [Holding], query: String) -> [Self] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        var seen = Set<String>()
        var merged = results.filter { seen.insert($0.ticker.uppercased()).inserted }
        let additions = holdings.filter {
            !seen.contains($0.ticker.uppercased())
                && ($0.ticker.localizedStandardContains(text)
                    || $0.shortName.localizedStandardContains(text)
                    || $0.displayName.localizedStandardContains(text))
        }.map { holding in
            Self(ticker: holding.ticker, name: holding.displayName, market: "",
                 exchange: nil, currency: holding.quoteCurrency, sector: holding.sector,
                 isFund: HoldingSecurityKind.classify(holding) == .fund)
        }.sorted {
            let lhs = $0.directMatchRank(text) ?? 3, rhs = $1.directMatchRank(text) ?? 3
            if lhs != rhs { return lhs < rhs }
            if $0.ticker.count != $1.ticker.count { return $0.ticker.count < $1.ticker.count }
            return $0.ticker < $1.ticker
        }
        for addition in additions where seen.insert(addition.ticker.uppercased()).inserted {
            let rank = addition.directMatchRank(text) ?? 3
            // An alias may match even though the displayed name/code does
            // not. Preserve that catalog result's priority rather than
            // trying to re-score it from its display text.
            let index = merged.firstIndex { ($0.directMatchRank(text) ?? 0) > rank } ?? merged.endIndex
            merged.insert(addition, at: index)
        }
        return merged
    }

    private func directMatchRank(_ query: String) -> Int? {
        func fold(_ value: String) -> String {
            value.folding(options: [.caseInsensitive, .diacriticInsensitive],
                          locale: Locale(identifier: "en_US_POSIX"))
        }
        let text = fold(query), symbol = fold(ticker), company = fold(name)
        if symbol == text { return 0 }
        if symbol.hasPrefix(text) { return 1 }
        if company.hasPrefix(text) { return 2 }
        if company.contains(text) || symbol.contains(text) { return 3 }
        return nil
    }

    func resolvedHolding(in holdings: [Holding]) -> Holding {
        holdings.first { $0.ticker.caseInsensitiveCompare(ticker) == .orderedSame } ?? holding
    }

    /// No shares and no cost, the same shape as an ETF look-through
    /// constituent: the detail sheet leaves its position blocks out rather
    /// than showing zeros.
    var holding: Holding {
        Holding(
            ticker: ticker,
            logoSymbol: ticker,
            displayName: name,
            sector: sector,
            source: nil,
            shares: 0,
            averageCost: 0,
            costCurrency: nil,
            quotePrice: 0,
            quoteCurrency: currency,
            todayChangePercent: nil,
            marketValue: 0,
            weight: 0,
            unrealized: 0,
            unrealizedPercent: 0,
            fxPnl: nil,
            fxPnlPercent: nil,
            fxPnlStatus: nil,
            fxPnlSource: nil
        )
    }
}
