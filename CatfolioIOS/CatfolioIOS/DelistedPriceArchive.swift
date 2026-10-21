import Foundation

/// A finite historical series for a delisted security, never a live quote or
/// its acquirer's price. CYBR has no splits or dividends in this verified
/// interval, so raw, split-adjusted and total-return closes share one basis.
struct DelistedPriceArchive: Decodable, Sendable {
    let schemaVersion: Int
    let symbol: String
    let currency: String
    let source: String
    let sourceURL: String
    let retrievedAt: String
    let firstDay: String
    let lastTradingDay: String
    let priceBasis: String
    let corporateActionsCheckedThrough: String
    let count: Int
    let bars: [MarketDailyBar]

    private static let cybr: Result<Self, Error> = Result {
        guard let url = Bundle.main.url(forResource: "cybr_delisted_daily_history", withExtension: "json") else {
            throw LocalServiceError.noHistoricalPrices
        }
        return try decode(Data(contentsOf: url))
    }

    static func entry(for symbol: String) -> Self? {
        guard symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "CYBR" else { return nil }
        return try? cybr.get()
    }

    static func decode(_ data: Data) throws -> Self {
        let archive = try JSONDecoder().decode(Self.self, from: data)
        guard archive.schemaVersion == 1, archive.symbol == "CYBR", archive.currency == "USD",
              archive.source == "Alpaca SIP", archive.priceBasis == "raw-no-splits-or-dividends",
              archive.corporateActionsCheckedThrough == archive.lastTradingDay,
              archive.lastTradingDay == "2026-02-10", archive.count == archive.bars.count,
              archive.count > 1, archive.firstDay == archive.bars.first?.date,
              archive.lastTradingDay == archive.bars.last?.date,
              archive.bars.allSatisfy({ bar in
                  DayDateCodec.date(from: bar.date).map { DayDateCodec.string(from: $0) } == bar.date
                      && bar.close.isFinite && bar.close > 0 && bar.high.isFinite && bar.low.isFinite
                      && bar.low > 0 && bar.low <= bar.close && bar.close <= bar.high
                      && bar.volume.isFinite && bar.volume >= 0
              }), zip(archive.bars, archive.bars.dropFirst()).allSatisfy({ $0.date < $1.date }) else {
            throw LocalServiceError.invalidResponse
        }
        return archive
    }

    func dailyBars(from: String, to: String) -> [MarketDailyBar] {
        bars.filter { $0.date >= from && $0.date <= to }
    }

    func closes(from: String, to: String) -> [String: Double] {
        Dictionary(uniqueKeysWithValues: dailyBars(from: from, to: to).map { ($0.date, $0.close) })
    }
}
