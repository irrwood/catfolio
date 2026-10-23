import Foundation

enum WatchlistMarketData {
    static func load(_ entries: [WatchlistEntry], forceRefresh: Bool) async -> [String: WatchlistQuote] {
        await withTaskGroup(of: (String, WatchlistQuote?).self) { group in
            var pending = entries.makeIterator()
            for _ in 0..<min(4, entries.count) {
                if let entry = pending.next() {
                    group.addTask { (entry.id, await quote(for: entry, forceRefresh: forceRefresh)) }
                }
            }
            var result: [String: WatchlistQuote] = [:]
            while let (id, quote) = await group.next() {
                if let quote { result[id] = quote }
                if !Task.isCancelled, let entry = pending.next() {
                    group.addTask { (entry.id, await self.quote(for: entry, forceRefresh: forceRefresh)) }
                }
            }
            return result
        }
    }

    private static func quote(for entry: WatchlistEntry, forceRefresh: Bool) async -> WatchlistQuote? {
        if let security = ChinaSecurity(entry.ticker, currency: entry.currency) {
            guard let quote = try? await ChinaMarketDataClient().quote(security) else { return nil }
            return WatchlistQuote(price: quote.price, previousClose: quote.previousClose, observedAt: quote.observedAt)
        }
        let client = LocalMarketDataClient()
        let now = Date()
        async let daily = client.historicalCloses(symbol: entry.ticker,
            from: DayDateCodec.string(from: now.addingTimeInterval(-21 * 86400)),
            to: DayDateCodec.string(from: now), dividendAdjusted: false, forceRefresh: forceRefresh)
        async let intraday = client.intradayBars(symbol: entry.ticker, forceRefresh: forceRefresh,
                                                allowsStaleFallback: false)
        let closes = (try? await daily) ?? [:]
        let bars = (try? await intraday) ?? []
        guard !Task.isCancelled else { return nil }
        let live = bars.filter { $0.close.isFinite && $0.close > 0 && $0.timestamp <= now.addingTimeInterval(60) }
            .max { $0.timestamp < $1.timestamp }
            .map { ObservedMarketQuote(price: $0.close, observedAt: $0.timestamp) }
        let scale = LocalMarketDataClient.priceScale(ticker: entry.ticker, currency: entry.currency,
            referencePrice: entry.quote?.price, marketPrice: closes[closes.keys.max() ?? ""] ?? live?.price)
        return resolvedQuote(symbol: entry.ticker, closes: closes, live: live, scale: scale, now: now)
    }

    /// Match the prior close to the quote's market session, including holidays
    /// and a current daily candle already present in the history response.
    static func resolvedQuote(symbol: String, closes: [String: Double], live: ObservedMarketQuote?,
                              scale: Double = 1, now: Date = .now) -> WatchlistQuote? {
        guard scale.isFinite, scale > 0 else { return nil }
        let today = LocalMarketDataClient.sessionKey(for: now, symbol: symbol)
        let valid = closes.filter { $0.value.isFinite && $0.value > 0 && $0.key <= today }
        let latestDay = valid.keys.max()
        let validLive = live.flatMap { quote -> ObservedMarketQuote? in
            guard quote.price.isFinite, quote.price > 0, quote.observedAt <= now.addingTimeInterval(60) else { return nil }
            return quote
        }
        let liveDay = validLive.map { LocalMarketDataClient.sessionKey(for: $0.observedAt, symbol: symbol) }
        let day: String
        let price: Double
        let observedAt: Date?
        if let live = validLive, let liveDay, liveDay >= (latestDay ?? liveDay) {
            day = liveDay
            price = live.price
            observedAt = live.observedAt
        } else if let latestDay, let close = valid[latestDay] {
            day = latestDay
            price = close
            observedAt = LocalMarketDataClient.marketDayStart(day, symbol: symbol)
        } else { return nil }
        let previous = valid.keys.filter { $0 < day }.max().flatMap { valid[$0] }
        let result = WatchlistQuote(price: price * scale, previousClose: previous.map { $0 * scale }, observedAt: observedAt)
        return result.isValid ? result : nil
    }
}
