import Foundation

struct DCABundledHistory: Decodable, Sendable {
    let schemaVersion: Int
    let symbol: String
    let currency: String
    let source: String
    let priceBasis: String
    let sourceURL: String
    let retrievedAt: String
    let firstDay: String
    let asOf: String
    let count: Int
    let prices: [PolicyPricePoint]

    static let spy: Result<Self, Error> = Result {
        guard let url = Bundle.main.url(forResource: "spy_daily_history", withExtension: "json") else {
            throw DCAError(message: "Bundled SPY history is missing")
        }
        return try decode(Data(contentsOf: url))
    }
    static func decode(_ data: Data) throws -> Self {
        let snapshot = try JSONDecoder().decode(Self.self, from: data)
        guard snapshot.schemaVersion == 1, snapshot.symbol == "SPY", snapshot.currency == "USD",
              snapshot.source == "Yahoo Finance", snapshot.priceBasis == "split-adjusted-close",
              snapshot.count == snapshot.prices.count, snapshot.count > 1,
              snapshot.firstDay == snapshot.prices.first?.day, snapshot.asOf == snapshot.prices.last?.day,
              valid(snapshot.prices) else { throw DCAError(message: "Invalid bundled SPY history") }
        return snapshot
    }
    static func valid(_ prices: [PolicyPricePoint]) -> Bool {
        prices.count >= 2 && prices.allSatisfy {
            $0.close.isFinite && $0.close > 0 && DayDateCodec.date(from: $0.day).map { DayDateCodec.string(from: $0) } == $0.day
        } && zip(prices, prices.dropFirst()).allSatisfy { $0.day < $1.day }
    }
    /// Replace a snapshot only with a valid, complete series. Never splice differently adjusted histories.
    static func canReplace(_ local: [PolicyPricePoint], with refreshed: [PolicyPricePoint]) -> Bool {
        guard valid(refreshed) else { return false }
        return local.isEmpty || Set(local.map(\.day)).isSubset(of: Set(refreshed.map(\.day)))
    }
    static func equal(_ lhs: [PolicyPricePoint], _ rhs: [PolicyPricePoint]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { $0.day == $1.day && $0.close == $1.close }
    }
}
