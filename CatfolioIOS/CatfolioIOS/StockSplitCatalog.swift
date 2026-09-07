import Foundation

/// Share counts before a split do not describe the same thing as share counts
/// after one, so a ledger that spans a split cannot be matched lot-for-lot
/// without adjusting for it.
///
/// Covers every US split on record, not just the ones a particular portfolio
/// happens to contain: which tickers matter is the user's business, not the
/// catalogue's.
struct StockSplitCatalog: Decodable, Sendable {
    struct Event: Decodable, Sendable, Equatable {
        /// Execution date, `yyyy-MM-dd`. Holdings acquired before this need
        /// adjusting; anything after it is already on the new basis.
        let d: String
        /// Shares before.
        let f: Double
        /// Shares after.
        let t: Double

        /// Multiply a pre-split quantity by this. Below 1 for a reverse split.
        var factor: Double? {
            guard f > 0, t > 0, f.isFinite, t.isFinite else { return nil }
            let value = t / f
            return value.isFinite && value > 0 ? value : nil
        }

        var isReverse: Bool { t < f }
    }

    let schemaVersion: Int
    let splits: [String: [Event]]

    enum CatalogError: Error { case missingResource }

    static let bundled = Result { try load() }

    static func load(bundle: Bundle = .main) throws -> Self {
        guard let url = bundle.url(forResource: "stock_splits", withExtension: "json") else {
            throw CatalogError.missingResource
        }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }

    /// Splits for `ticker` that executed after `date`, oldest first.
    ///
    /// Only splits after a purchase apply to it — one that happened before is
    /// already reflected in the quantity the broker reported.
    func events(ticker: String, after date: String) -> [Event] {
        guard let all = splits[Self.normalized(ticker)] else { return [] }
        return all.filter { $0.d > date }
    }

    /// Combined multiplier to bring a quantity from `date` onto today's basis.
    /// Returns 1 when nothing applies, `nil` if any event is unusable.
    func adjustment(ticker: String, from date: String) -> Double? {
        var factor = 1.0
        for event in events(ticker: ticker, after: date) {
            guard let step = event.factor else { return nil }
            factor *= step
        }
        return factor.isFinite && factor > 0 ? factor : nil
    }

    /// US listings only, so a suffixed symbol is not silently matched against
    /// a same-named US ticker — NG.L is National Grid, NG is NovaGold.
    static func normalized(_ ticker: String) -> String {
        ticker.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    var tickerCount: Int { splits.count }
    var eventCount: Int { splits.values.reduce(0) { $0 + $1.count } }
}
