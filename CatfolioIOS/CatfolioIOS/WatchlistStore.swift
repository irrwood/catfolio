import Foundation
import Observation

/// A quote in the listing's own currency; no position size or portfolio FX.
struct WatchlistQuote: Codable, Equatable, Sendable {
    let price: Double
    let previousClose: Double?
    let observedAt: Date?

    var changeAmount: Double? {
        guard price.isFinite, price > 0, let previousClose,
              previousClose.isFinite, previousClose > 0 else { return nil }
        return price - previousClose
    }
    var changePercent: Double? {
        guard let changeAmount, let previousClose else { return nil }
        return changeAmount / previousClose * 100
    }
    var isValid: Bool {
        price.isFinite && price > 0
            && (previousClose.map { $0.isFinite && $0 > 0 } ?? true)
    }

    init(price: Double, previousClose: Double?, observedAt: Date?) {
        self.price = price
        self.previousClose = previousClose
        self.observedAt = observedAt
    }

    init(price: Double, changePercent: Double?, observedAt: Date?) {
        self.price = price
        self.observedAt = observedAt
        previousClose = changePercent.flatMap {
            $0.isFinite && $0 > -100 ? price / (1 + $0 / 100) : nil
        }
    }
}

struct WatchlistEntry: Codable, Equatable, Identifiable, Sendable {
    let ticker: String
    let currency: String
    let name: String
    let logoSymbol: String?
    let sector: String?
    /// Distinguishes a removed/re-added item from an older in-flight refresh.
    let membershipID: UUID
    var quote: WatchlistQuote?

    var id: String { ticker + "|" + currency }

    static func identity(for holding: Holding) -> (ticker: String, currency: String) {
        let currency = holding.quoteCurrency == "GBp" ? "GBX" : (holding.quoteCurrency ?? "USD").uppercased()
        return (LocalMarketDataClient.yahooSymbol(ticker: holding.ticker, currency: currency), currency)
    }

    init(holding: Holding, observation: SecurityMarketObservation? = nil) {
        let identity = Self.identity(for: holding)
        ticker = identity.ticker
        currency = identity.currency
        name = holding.displayName
        logoSymbol = holding.logoSymbol
        sector = holding.sector
        membershipID = UUID()
        if let observation,
           LocalMarketDataClient.yahooSymbol(ticker: observation.ticker, currency: observation.currency) == ticker,
           (observation.currency == "GBp" ? "GBX" : observation.currency.uppercased()) == currency {
            quote = WatchlistQuote(price: observation.price, changePercent: observation.changePercent,
                                   observedAt: observation.observedAt)
        } else if holding.quotePrice.isFinite, holding.quotePrice > 0 {
            quote = WatchlistQuote(price: holding.quotePrice, changePercent: holding.todayChangePercent, observedAt: nil)
        }
        if quote?.isValid == false { quote = nil }
    }

    /// Opens the normal security page without inventing a portfolio position.
    var holding: Holding {
        Holding(ticker: ticker, logoSymbol: logoSymbol, displayName: name, sector: sector, source: nil,
                shares: 0, averageCost: 0, costCurrency: nil, quotePrice: quote?.price ?? 0,
                quoteCurrency: currency, todayChangePercent: quote?.changePercent,
                marketValue: 0, weight: 0, unrealized: 0, unrealizedPercent: 0,
                fxPnl: nil, fxPnlPercent: nil, fxPnlStatus: nil, fxPnlSource: nil)
    }
}

@MainActor @Observable
final class WatchlistStore {
    static let storageKey = "catfolio.watchlist.v1"
    private(set) var entries: [WatchlistEntry]
    private(set) var isRefreshing = false
    private(set) var failedIDs: Set<String> = []
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let loader: @Sendable ([WatchlistEntry], Bool) async -> [String: WatchlistQuote]
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var refreshedAt: Date?

    init(defaults: UserDefaults = .standard,
         loader: @escaping @Sendable ([WatchlistEntry], Bool) async -> [String: WatchlistQuote] = {
             await WatchlistMarketData.load($0, forceRefresh: $1)
         }) {
        self.defaults = defaults
        self.loader = loader
        let saved = defaults.data(forKey: Self.storageKey)
            .flatMap { try? JSONDecoder().decode([WatchlistEntry].self, from: $0) } ?? []
        var seen: Set<String> = []
        entries = saved.filter { !$0.ticker.isEmpty && seen.insert($0.id).inserted }.map {
            var entry = $0
            if entry.quote?.isValid == false { entry.quote = nil }
            return entry
        }
    }

    func contains(_ holding: Holding) -> Bool {
        let identity = WatchlistEntry.identity(for: holding)
        return entries.contains { $0.ticker == identity.ticker && $0.currency == identity.currency }
    }

    func toggle(_ holding: Holding, observation: SecurityMarketObservation? = nil) {
        let entry = WatchlistEntry(holding: holding, observation: observation)
        guard !entry.ticker.isEmpty else { return }
        if entries.contains(where: { $0.id == entry.id }) {
            remove(id: entry.id)
        } else {
            entries.insert(entry, at: 0)
            refreshedAt = nil
            save()
        }
    }

    func remove(id: String) {
        entries.removeAll { $0.id == id }
        failedIDs.remove(id)
        save()
    }

    /// Keep cached values visible during refresh and after partial failures.
    func refresh(forceRefresh: Bool = false) async {
        guard !entries.isEmpty else { return }
        if !forceRefresh {
            guard !isRefreshing else { return }
            if let refreshedAt, Date().timeIntervalSince(refreshedAt) < 60 { return }
        }
        let request = UUID()
        generation = request
        let snapshot = entries
        isRefreshing = true
        defer { if generation == request { isRefreshing = false } }
        let quotes = await loader(snapshot, forceRefresh)
        guard generation == request, !Task.isCancelled else { return }
        var failed: Set<String> = []
        for requested in snapshot {
            guard let index = entries.firstIndex(where: { $0.membershipID == requested.membershipID }) else { continue }
            guard let quote = quotes[requested.id], quote.isValid else {
                failed.insert(requested.id)
                continue
            }
            if let existing = entries[index].quote?.observedAt,
               quote.observedAt.map({ $0 < existing }) ?? true {
                failed.insert(requested.id)
                continue
            }
            entries[index].quote = quote
        }
        failedIDs = failed
        refreshedAt = failed.isEmpty && snapshot.map(\.membershipID) == entries.map(\.membershipID) ? .now : nil
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
