import Foundation

/// Yahoo supplies actual session bounds, including early closes. Its chart
/// response uses an object with pre/post enabled and an array otherwise.
struct YahooTradingPeriods: Decodable {
    let windows: [MarketSessionWindow]

    private enum CodingKeys: String, CodingKey { case pre, regular, post }

    init(from decoder: Decoder) throws {
        if let rows = try? decoder.singleValueContainer().decode([[YahooTradingPeriod]].self) {
            windows = rows.flatMap { $0 }.map { $0.window(.regular) }
        } else {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            let pairs: [(CodingKeys, USMarketSession)] = [(.pre, .preMarket), (.regular, .regular), (.post, .postMarket)]
            windows = try pairs.flatMap { key, session in
                let rows = try values.decodeIfPresent([[YahooTradingPeriod]].self, forKey: key) ?? []
                return rows.flatMap { $0 }.map { $0.window(session) }
            }
        }
    }
}

struct YahooCurrentTradingPeriods: Decodable {
    let pre: YahooTradingPeriod?
    let regular: YahooTradingPeriod?
    let post: YahooTradingPeriod?

    var windows: [MarketSessionWindow] {
        [pre?.window(.preMarket), regular?.window(.regular), post?.window(.postMarket)].compactMap { $0 }
    }
}

struct YahooTradingPeriod: Decodable {
    let start: TimeInterval
    let end: TimeInterval

    func window(_ session: USMarketSession) -> MarketSessionWindow {
        .init(session: session, start: Date(timeIntervalSince1970: start), end: Date(timeIntervalSince1970: end))
    }
}
