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
