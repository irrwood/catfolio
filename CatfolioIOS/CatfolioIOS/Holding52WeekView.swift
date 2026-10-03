import SwiftUI

/// Created only for visible rows while the 52-week display is selected.
/// The shared daily-bar cache also serves the individual security page.
struct Holding52WeekRow: View {
    @Environment(AppModel.self) private var model
    let item: PortfolioHoldingListItem
    let performancePeriod: HoldingPerformancePeriod
    var suppliedRange: Holding52WeekRange? = nil
    var loadsRange = true
    @State private var loaded: (key: String, range: Holding52WeekRange)?

    private var currency: String? {
        item.detailHolding?.quoteCurrency ?? InstrumentCurrencyRules.inferredPriceCurrency(for: item.ticker)
    }
    private var key: String { "\(item.ticker)|\(currency ?? "")" }

    var body: some View {
        HoldingRow(item: item, performancePeriod: performancePeriod,
            week52: Holding52WeekPrices(holding: item.detailHolding,
                range: suppliedRange ?? (loaded?.key == key ? loaded?.range : nil)))
            .task(id: "\(key)|\(loadsRange)|\(model.localUpdatedAt?.timeIntervalSince1970 ?? 0)") {
                guard loadsRange, item.detailHolding != nil, let currency else { return }
                let requestKey = key
                guard let range = try? await LocalMarketDataClient().fiftyTwoWeekRange(
                    ticker: item.ticker, currency: currency), !Task.isCancelled else { return }
                loaded = (requestKey, range)
            }
    }
}

/// The volume version of the 52-week row, loaded the same way for visible rows.
struct HoldingVolumeRow: View {
    @Environment(AppModel.self) private var model
    let item: PortfolioHoldingListItem
    let performancePeriod: HoldingPerformancePeriod
    var suppliedRange: HoldingVolumeRange? = nil
    var loadsRange = true
    @State private var loaded: (key: String, range: HoldingVolumeRange)?

    private var currency: String? {
        item.detailHolding?.quoteCurrency ?? InstrumentCurrencyRules.inferredPriceCurrency(for: item.ticker)
    }
    private var key: String { "\(item.ticker)|\(currency ?? "")" }

    var body: some View {
        HoldingRow(item: item, performancePeriod: performancePeriod,
            volume: HoldingVolumePrices(holding: item.detailHolding,
                range: suppliedRange ?? (loaded?.key == key ? loaded?.range : nil)))
            .task(id: "\(key)|\(loadsRange)|\(model.localUpdatedAt?.timeIntervalSince1970 ?? 0)") {
                guard loadsRange, item.detailHolding != nil, let currency else { return }
                let requestKey = key
                guard let range = try? await LocalMarketDataClient().volumeRange(
                    ticker: item.ticker, currency: currency), !Task.isCancelled else { return }
                loaded = (requestKey, range)
            }
    }
}

/// The 52-week bar's volume twin, as coarse: the track is the price span the
/// profile covers, the blue segment its value area — where most of the volume
/// traded — and the dark and white dots are the price and the cost.
struct HoldingVolumeProfileBar: View {
    let prices: HoldingVolumePrices
    private let valueAreaColor = Color(red: 52 / 255, green: 117 / 255, blue: 1)

    var body: some View {
        ZStack(alignment: .top) {
            Capsule().fill(CatfolioTheme.primaryText.opacity(0.10))
            if let range = prices.range, let y = scale(range) {
                let top = y(range.valueAreaHigh), bottom = y(range.valueAreaLow)
                Capsule().fill(valueAreaColor)
                    .frame(height: (bottom - top) * 32 + 8)
                    .offset(y: top * 32)
                if let current = prices.current {
                    Circle().fill(CatfolioPalette.blue900)
                        .frame(width: 6, height: 6)
                        .offset(y: 1 + y(current) * 32)
                }
                if let cost = prices.cost {
                    Circle().fill(.white)
                        .frame(width: 4, height: 4)
                        .offset(y: 2 + y(cost) * 32)
                }
            }
        }
        .frame(width: 8, height: 40)
        .accessibilityHidden(true)
    }

    /// 0 at the top of everything shown, 1 at the bottom, as the 52-week bar.
    private func scale(_ range: HoldingVolumeRange) -> ((Double) -> Double)? {
        let values = [range.bins.map(\.low).min(), range.bins.map(\.high).max(),
                      prices.current, prices.cost].compactMap { $0 }
        guard let low = values.min(), let high = values.max(), high > low else { return nil }
        return { (high - $0) / (high - low) }
    }
}

/// Figma 494:19187: an 8 × 40 range with a 6pt current marker and 4pt cost marker.
struct Holding52WeekBar: View {
    let positions: Holding52WeekPositions?
    private let rangeColor = Color(red: 52 / 255, green: 117 / 255, blue: 1)

    var body: some View {
        ZStack(alignment: .top) {
            Capsule().fill(CatfolioTheme.primaryText.opacity(0.10))
            if let positions {
                if let start = positions.start, let current = positions.current, start != current {
                    Capsule().fill(rangeColor)
                        .frame(height: abs(current - start) * 32 + 8)
                        .offset(y: min(start, current) * 32)
                }
                if let current = positions.current {
                    Circle().fill(CatfolioPalette.blue900)
                        .frame(width: 6, height: 6)
                        .offset(y: 1 + current * 32)
                }
                if let cost = positions.cost {
                    Circle().fill(.white)
                        .frame(width: 4, height: 4)
                        .offset(y: 2 + cost * 32)
                }
            }
        }
        .frame(width: 8, height: 40)
        .accessibilityHidden(true)
    }
}
