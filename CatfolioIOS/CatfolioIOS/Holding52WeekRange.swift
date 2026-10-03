import Foundation

struct Holding52WeekRequest: Hashable, Sendable {
    let ticker: String
    let currency: String

    init?(item: PortfolioHoldingListItem) {
        guard let holding = item.detailHolding,
              let currency = holding.quoteCurrency ?? InstrumentCurrencyRules.inferredPriceCurrency(for: item.ticker)
        else { return nil }
        ticker = item.ticker.uppercased()
        self.currency = currency
    }
}

struct Holding52WeekRange: Equatable, Sendable {
    let low: Double
    let high: Double
    let latestClose: Double
    let currency: String
    let startPrice: Double?

    init(low: Double, high: Double, latestClose: Double, currency: String, startPrice: Double? = nil) {
        self.low = low
        self.high = high
        self.latestClose = latestClose
        self.currency = currency
        self.startPrice = startPrice
    }

    static func make(bars: [MarketDailyBar], currency: String, scale: Double) -> Self? {
        guard scale.isFinite, scale > 0 else { return nil }
        let sessions = bars.filter {
            $0.low.isFinite && $0.high.isFinite && $0.close.isFinite
                && $0.low > 0 && $0.high >= $0.low && $0.close > 0
        }.sorted { $0.date > $1.date }.prefix(252)
        guard let latest = sessions.first, let start = sessions.last,
              let low = sessions.map(\.low).min(), let high = sessions.map(\.high).max(),
              (high * scale).isFinite, (latest.close * scale).isFinite,
              (start.close * scale).isFinite else { return nil }
        return Self(low: low * scale, high: high * scale,
                    latestClose: latest.close * scale, currency: currency, startPrice: start.close * scale)
    }

    /// Sorting needs the whole list, including rows outside the viewport.
    /// Fetch at most four at once, then publish one complete ranking.
    static func load(_ requests: [Holding52WeekRequest],
                     fetch: @escaping @Sendable (Holding52WeekRequest) async throws -> Self = {
                         try await LocalMarketDataClient().fiftyTwoWeekRange(ticker: $0.ticker, currency: $0.currency)
                     }) async -> [String: Self] {
        await withTaskGroup(of: (String, Self?).self) { group in
            var iterator = requests.makeIterator()
            var result: [String: Self] = [:]
            for _ in 0..<min(4, requests.count) {
                guard !Task.isCancelled, let request = iterator.next() else { break }
                group.addTask { (request.ticker, try? await fetch(request)) }
            }
            for await (ticker, range) in group {
                guard !Task.isCancelled else { group.cancelAll(); break }
                if let range { result[ticker] = range }
                if let request = iterator.next() {
                    group.addTask { (request.ticker, try? await fetch(request)) }
                }
            }
            return result
        }
    }
}

/// Every price and marker uses the listing's quote currency, including GBX.
/// ETF-only exposure and public disclosures do not imply a per-share cost.
struct Holding52WeekPrices {
    let current: Double?
    let cost: Double?
    let currency: String?
    let range: Holding52WeekRange?

    init(holding: Holding?, range: Holding52WeekRange?,
         usdRate: (String) -> Double? = LocalPortfolioEngine.usdRate(for:)) {
        self.range = range
        currency = range?.currency ?? holding?.quoteCurrency
        if let holding, let currency {
            current = VolumeProfileInterpretation.convertedPrice(holding.quotePrice,
                from: holding.quoteCurrency, to: currency, usdRate: usdRate) ?? range?.latestClose
            cost = holding.shares > 0 && holding.publicDisclosure == nil
                ? VolumeProfileInterpretation.convertedPrice(holding.averageCost,
                    from: holding.costCurrency, to: currency, usdRate: usdRate) : nil
        } else {
            current = range?.latestClose
            cost = nil
        }
    }

    var positions: Holding52WeekPositions? {
        guard let range else { return nil }
        return Holding52WeekPositions(low: range.low, high: range.high, current: current, cost: cost,
            start: range.startPrice)
    }

    /// Rank by the actual annual interval, independently of the cost marker
    /// and the display scale. Breakouts may be above 1 or below 0.
    var rangePosition: Double? {
        guard let range, let current, current.isFinite, current > 0,
              range.low.isFinite, range.high.isFinite, range.low > 0,
              range.high > range.low else { return nil }
        let position = (current - range.low) / (range.high - range.low)
        return position.isFinite ? position : nil
    }
}

/// Normalize all markers against the annual high/low, extending the scale for
/// any outside quote or cost. The blue segment runs from period start to now.
struct Holding52WeekPositions {
    let high: Double
    let low: Double
    let current: Double?
    let cost: Double?
    let start: Double?

    init?(low: Double, high: Double, current: Double?, cost: Double?, start: Double? = nil) {
        guard low.isFinite, high.isFinite, low > 0, high >= low else { return nil }
        let current = current.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let cost = cost.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let start = start.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let values = [low, high] + [current, cost, start].compactMap { $0 }
        let minimum = values.min()!, maximum = values.max()!
        let span = maximum - minimum
        func y(_ value: Double) -> Double { span > 0 ? (maximum - value) / span : 0.5 }
        self.high = y(high)
        self.low = y(low)
        self.current = current.map(y)
        self.cost = cost.map(y)
        self.start = start.map(y)
    }
}

/// The volume counterpart of the 52-week range: where the price and the
/// cost sit within the volume profile — the prices the last 160 sessions
/// actually traded at — rather than within the year's high and low.
struct HoldingVolumeRange: Equatable, Sendable {
    struct Bin: Equatable, Sendable {
        let low: Double
        let high: Double
        let volume: Double
    }

    let bins: [Bin]
    let valueAreaLow: Double
    let pointOfControl: Double
    let valueAreaHigh: Double
    let currency: String

    init(bins: [Bin], valueAreaLow: Double, pointOfControl: Double, valueAreaHigh: Double, currency: String) {
        self.bins = bins
        self.valueAreaLow = valueAreaLow
        self.pointOfControl = pointOfControl
        self.valueAreaHigh = valueAreaHigh
        self.currency = currency
    }

    init?(profile: VolumeProfile) {
        let bins = (profile.bins ?? []).compactMap { bin -> Bin? in
            guard bin.priceLow.isFinite, bin.priceHigh.isFinite, bin.volume.isFinite,
                  bin.priceLow > 0, bin.priceHigh >= bin.priceLow, bin.volume >= 0 else { return nil }
            return Bin(low: bin.priceLow, high: bin.priceHigh, volume: bin.volume)
        }
        guard profile.available, !bins.isEmpty,
              [profile.valueAreaLow, profile.pointOfControl, profile.valueAreaHigh].allSatisfy({ $0.isFinite && $0 > 0 }),
              profile.valueAreaLow <= profile.valueAreaHigh else { return nil }
        self.init(bins: bins, valueAreaLow: profile.valueAreaLow, pointOfControl: profile.pointOfControl,
                  valueAreaHigh: profile.valueAreaHigh, currency: profile.currency)
    }

    /// Where a price sits in the value area: 0 at its low edge, 1 at its high;
    /// below 0 or above 1 outside it, where volume thins out.
    func valueAreaPosition(of price: Double?) -> Double? {
        guard let price, price.isFinite, price > 0, valueAreaHigh > valueAreaLow else { return nil }
        let position = (price - valueAreaLow) / (valueAreaHigh - valueAreaLow)
        return position.isFinite ? position : nil
    }

    static func load(_ requests: [Holding52WeekRequest],
                     fetch: @escaping @Sendable (Holding52WeekRequest) async throws -> Self = {
                         try await LocalMarketDataClient().volumeRange(ticker: $0.ticker, currency: $0.currency)
                     }) async -> [String: Self] {
        await withTaskGroup(of: (String, Self?).self) { group in
            var iterator = requests.makeIterator()
            var result: [String: Self] = [:]
            for _ in 0..<min(4, requests.count) {
                guard !Task.isCancelled, let request = iterator.next() else { break }
                group.addTask { (request.ticker, try? await fetch(request)) }
            }
            for await (ticker, range) in group {
                guard !Task.isCancelled else { group.cancelAll(); break }
                if let range { result[ticker] = range }
                if let request = iterator.next() {
                    group.addTask { (request.ticker, try? await fetch(request)) }
                }
            }
            return result
        }
    }
}

/// Price and cost against a volume profile, in the profile's currency.
struct HoldingVolumePrices {
    let current: Double?
    let cost: Double?
    let currency: String?
    let range: HoldingVolumeRange?

    init(holding: Holding?, range: HoldingVolumeRange?,
         usdRate: (String) -> Double? = LocalPortfolioEngine.usdRate(for:)) {
        let prices = Holding52WeekPrices(holding: holding, range: nil, usdRate: usdRate)
        self.range = range
        currency = range?.currency ?? prices.currency
        if let range, let from = prices.currency {
            current = prices.current.flatMap {
                VolumeProfileInterpretation.convertedPrice($0, from: from, to: range.currency, usdRate: usdRate)
            }
            cost = prices.cost.flatMap {
                VolumeProfileInterpretation.convertedPrice($0, from: from, to: range.currency, usdRate: usdRate)
            }
        } else {
            current = prices.current
            cost = prices.cost
        }
    }

    var valueAreaPosition: Double? { range?.valueAreaPosition(of: current) }
}
