import SwiftUI
import Charts
import CryptoKit
import Observation

/// Figma 264:13428: a coloured title, one quote row, and a 53pt sparkline.
/// Series colours identify the metric; the badge and change express direction.
struct ResearchMetricCard: View {
    let symbol: String
    let title: String
    let snapshot: ResearchMarketSnapshot?
    var isLoading = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .subheadline) private var titleSize = 16.0
    @ScaledMetric(relativeTo: .title3) private var valueSize = 20.0
    @ScaledMetric(relativeTo: .subheadline) private var changeSize = 14.0
    /// The figure's font, which also sets the height of its line.
    private var valueFont: Font { .system(size: valueSize, weight: .semibold, design: .rounded) }

    private var seriesColor: Color {
        switch symbol {
        case "^GSPC": CatfolioTheme.accent
        case "^IXIC": CatfolioTheme.services
        case "^VIX": CatfolioTheme.warning
        // This card's purple is specified directly in the Figma reference.
        default: Color(red: 139 / 255, green: 92 / 255, blue: 246 / 255)
        }
    }
    private var displayTitle: String {
        symbol == "^TNX" ? L10n.text("美国 10 年期国债") : title
    }
    private var showsSkeleton: Bool { isLoading && snapshot == nil }

    var body: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 7) {
                Text(displayTitle)
                    .font(.system(size: titleSize, weight: .semibold, design: .rounded))
                    .foregroundStyle(seriesColor)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                    .minimumScaleFactor(0.8)
                    .redacted(reason: showsSkeleton ? .placeholder : [])
                    .chartLoadingShimmer(active: showsSkeleton, appearanceID: "research-metric|\(symbol)")

                // Set like the macro cards below: the value, then its move
                // in quiet grey on the same baseline.
                // One value line tall whatever it holds — the figure, the
                // loading bar or 暂无数据 — so the card keeps its height
                // when the data lands.
                Text("0")
                    .font(valueFont)
                    .hidden()
                    .accessibilityHidden(true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: Alignment(horizontal: .leading, vertical: .firstTextBaseline)) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            quote
                            change
                        }
                    }
                .chartLoadingShimmer(active: showsSkeleton, appearanceID: "research-metric|\(symbol)")

                sparkline
                    .frame(height: 53)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("research-metric-\(symbol)")
    }

    @ViewBuilder private var quote: some View {
        if let value = snapshot?.latest?.value {
            Text(symbol == "^TNX"
                 ? (value / 100).formatted(.percent.precision(.fractionLength(2)))
                 : value.formatted(.number.precision(.fractionLength(2))))
                .font(valueFont)
                .monospacedDigit()
                .foregroundStyle(CatfolioTheme.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        } else if showsSkeleton {
            ChartSkeletonShape(width: 82, height: valueSize)
        } else {
            Text(L10n.text("暂无数据"))
                .font(.system(size: changeSize, design: .rounded))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var change: some View {
        if showsSkeleton {
            ChartSkeletonShape(width: 42, height: changeSize)
        } else if let value = snapshot?.changePercent {
            FinancialText(DisplayFormat.percent(value, signed: true))
                .font(.system(size: changeSize, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .fixedSize()
        }
    }

    @ViewBuilder private var sparkline: some View {
        if let snapshot, snapshot.points.count > 1 {
            let domain = StandardLineChartEntrancePhase.domain(snapshot.points.map(\.value))
            StandardLineChartEntrance(appearanceID: "research-metric|\(symbol)") { phase in
                Chart(Array(snapshot.points.enumerated()), id: \.element.id) { item in
                    LineMark(x: .value(L10n.text("日期"), item.offset),
                             y: .value(L10n.text("收盘"), phase.value(item.element.value,
                                fraction: Double(item.offset) / Double(snapshot.points.count - 1), domain: domain)))
                        .foregroundStyle(seriesColor)
                        .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.monotone)
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .chartXScale(domain: 0...(snapshot.points.count - 1))
                .chartYScale(domain: domain)
                .padding(.horizontal, 3)
                .padding(.vertical, 5)
                .accessibilityLabel(L10n.text("\(title)最近收盘走势"))
                .accessibilityValue("\(snapshot.points.first?.id ?? "") – \(snapshot.latest?.id ?? "")")
            }
        } else if showsSkeleton {
            StandardLineChartSkeleton(axisWidth: 0, topInset: 5, bottomHeight: 5,
                lineWidths: [3], appearanceID: "research-metric|\(symbol)")
        } else {
            Color.clear.accessibilityHidden(true)
        }
    }
}
