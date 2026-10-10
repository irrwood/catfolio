import SwiftUI

/// Figma 625:22179: the converted total above its original-currency sources.
/// The prepared ledger remains responsible for every amount and trade count.
struct HistoryRealisedSummaryCard: View {
    let calculation: RealisedProfitSummary
    var ordersBreakdown: HistoryOrdersBreakdown? = nil

    private var hasValuedSales: Bool {
        calculation.brokerCount + calculation.estimatedCount > 0
    }

    var body: some View {
        SettingsCard {
            if let ordersBreakdown {
                HistoryOrdersProportion(breakdown: ordersBreakdown)
            }
            HistorySummaryRow(title: L10n.text("已实现盈亏"), icon: .asset("HistoryRealisedRocket"),
                value: hasValuedSales ? DisplayFormat.money(calculation.combinedUSD, signed: true) : "—",
                valueColor: hasValuedSales
                    ? (calculation.combinedUSD >= 0 ? CatfolioTheme.positive : CatfolioTheme.danger)
                    : SettingsTemplate.secondaryText)

            if !calculation.brokerTotals.isEmpty {
                sourceRow(title: L10n.text("Broker Result"), count: calculation.brokerCount,
                          values: brokerValues, icon: .asset("HistoryBrokerCalculator"))
            }
            if calculation.estimatedCount > 0 {
                sourceRow(title: L10n.text("本地估算"), count: calculation.estimatedCount,
                          values: [DisplayFormat.money(calculation.estimatedUSD, signed: true)],
                          icon: .asset("HistoryBrokerCalculator"))
            }
            if calculation.unavailableCount > 0 {
                sourceRow(title: L10n.text("缺买入成本"), count: calculation.unavailableCount,
                          values: ["—"])
            }
            if calculation.saleCount == 0 {
                SettingsRowContainer {
                    Text(L10n.text("没有卖出记录"))
                        .appText(.callout)
                        .foregroundStyle(SettingsTemplate.secondaryText)
                }
            }
        }
        .accessibilityIdentifier("history-realised-summary")
    }

    private var brokerValues: [String] {
        calculation.brokerTotals.keys.sorted().map { currency in
            DisplayFormat.money(
                NSDecimalNumber(decimal: calculation.brokerTotals[currency]!).doubleValue,
                currency: currency, signed: true, fractionDigits: 2)
        }
    }

    private func sourceRow(title: String, count: Int, values: [String],
                           icon: SettingsIconSource? = nil) -> some View {
        SettingsRowContainer {
            VStack(alignment: .leading, spacing: HistorySummaryLayout.detailSpacing) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: SettingsTemplate.iconSpacing) {
                        HistorySummaryLabel(title: title, icon: icon).fixedSize()
                        Spacer(minLength: 0)
                        tradeCount(count).fixedSize()
                    }
                    VStack(alignment: .leading, spacing: HistorySummaryLayout.detailSpacing) {
                        HistorySummaryLabel(title: title, icon: icon)
                        tradeCount(count)
                    }
                }
                HistoryCurrencyAmounts(values: values)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func tradeCount(_ count: Int) -> some View {
        Text(verbatim: "\(count)/\(calculation.saleCount)")
            .appNumber(.callout, weight: .semibold)
            .foregroundStyle(SettingsTemplate.secondaryText)
            .accessibilityLabel(L10n.text("\(count)/\(calculation.saleCount) 笔"))
    }
}
