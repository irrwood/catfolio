import SwiftUI
import UIKit

struct FastCostMarketPlot: View {
    @Environment(\.locale) private var appLocale
    let data: CostMarketRangeData
    let showsNetDeposit: Bool
    let transitionKey: String
    let showsLatestPoint: Bool
    let selectedPoint: CostMarketPlotPoint?
    let measuredRange: ChartDateRange?
    let selectionIndicatorLabel: String?
    let compactDates: Bool
    let onSelect: (Date) -> Void
    let onMeasure: (ChartDateRange) -> Void
    let onInteractionEnded: (Int) -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.portfolioChartOnCard) private var isOnCard
    @State private var seriesCache = CostMarketPlotSeriesCache()
    private let bottomHeight: CGFloat = 0

    var body: some View {
        // A selection changes this view every time the finger crosses a day.
        // Rebuilding both point arrays and sorting them in Series.init on
        // every move makes a long portfolio history compete with scrolling.
        let prepared = seriesCache.prepared(for: data, scheme: colorScheme, isOnCard: isOnCard,
                                            showsLatestPoint: showsLatestPoint)
        StandardLineChart(
            // Canvas paints later series above earlier ones. Keep the blue
            // net-deposit line underneath the adaptive white/green market
            // line so their crossings preserve the portfolio-value signal.
            series: showsNetDeposit ? [prepared.cost, prepared.market] : [prepared.market],
            interactionDates: prepared.interactionDates,
            domain: data.domain,
            yTicks: prepared.yTicks,
            axisWidth: 0,
            topInset: 0,
            bottomHeight: bottomHeight,
            interactionBottomInset: PortfolioHeroChartLayout.chartInteractionBottomInset,
            leadingLineOverflow: 0,
            trailingEndpointInset: 21,
            gridOpacity: 0,
            // Not the cost line's toggle: showing or hiding it swaps the line
            // in place instead of replaying the curve's bounce.
            transitionKey: "\(transitionKey)-\(colorScheme == .light ? "light" : "dark")",
            rangeTransitionKey: transitionKey,
            appearanceID: "portfolio-assets",
            dataTransition: .viewportZoom,
            seriesChangeBounce: 12,
            // No morph out of the loading lines at launch: the blue line
            // slid from the placeholder's slope to its real level.
            animatesInitialAppearance: false,
            selectedDate: selectedPoint?.date,
            measuredRange: measuredRange,
            selectionIndicatorLabel: selectionIndicatorLabel,
            selectionSeriesIDs: showsNetDeposit ? ["market", "cost"] : ["market"],
            rangeSeriesIDs: showsNetDeposit ? ["market", "cost"] : ["market"],
            rangePrimarySeriesID: "market",
            dimsFutureDuringSelection: true,
            yAxisLabel: { _ in "" },
            xAxisLabel: shortDate,
            onSelect: onSelect,
            onMeasure: onMeasure,
            onInteractionEnded: onInteractionEnded
        )
    }

    private func shortDate(_ date: Date) -> String {
        compactDates
            ? date.formatted(.dateTime.month(.abbreviated).day())
            : date.formatted(.dateTime.month(.abbreviated))
    }
}

/// Keeps the immutable chart geometry across selection-only body updates.
/// Every prepared range has a new identity, including a refreshed account or
/// currency response, so stale points cannot leak into a new portfolio.
@MainActor
final class CostMarketPlotSeriesCache {
    struct Prepared {
        let market: StandardLineChartSeries
        let cost: StandardLineChartSeries
        let interactionDates: [Date]
        let yTicks: [Double]
    }

    private struct Key: Equatable {
        let dataID: UUID
        let scheme: ColorScheme
        let isOnCard: Bool
        let showsLatestPoint: Bool
    }

    private var cachedKey: Key?
    private var cachedValue: Prepared?
    private(set) var rebuildCount = 0

    func prepared(for data: CostMarketRangeData, scheme: ColorScheme, isOnCard: Bool = false,
                  showsLatestPoint: Bool) -> Prepared {
        let key = Key(dataID: data.id, scheme: scheme, isOnCard: isOnCard, showsLatestPoint: showsLatestPoint)
        if key == cachedKey, let cachedValue { return cachedValue }

        let market = StandardLineChartSeries(
            id: "market",
            points: data.plottedRows.map {
                StandardLineChartPoint(id: $0.id, date: $0.date, value: $0.marketValue)
            },
            // White over the blue home page; on the Mac's white card the
            // gain green it already is at night.
            color: scheme == .light && !isOnCard ? .white : CatfolioTheme.gain(for: scheme),
            lineWidth: 2,
            latestPointRadius: showsLatestPoint ? 5 : 0,
            latestPointColor: scheme == .light ? .black : nil,
            latestPointUsesGlass: false
        )
        let cost = StandardLineChartSeries(
            id: "cost",
            points: data.plottedRows.map {
                StandardLineChartPoint(id: "cost|\($0.id)", date: $0.date, value: $0.cost)
            },
            color: CatfolioPalette.ChartSeries.blue,
            lineWidth: 2,
            latestPointRadius: showsLatestPoint ? 5 : 0,
            latestPointUsesGlass: false
        )
        let ticks = (0..<5).map { index in
            let fraction = Double(index) / 4
            return data.domain.upperBound
                - (data.domain.upperBound - data.domain.lowerBound) * fraction
        }
        let value = Prepared(market: market, cost: cost,
                             interactionDates: data.rows.map(\.date), yTicks: ticks)
        cachedKey = key
        cachedValue = value
        rebuildCount &+= 1
        return value
    }
}
