import SwiftUI

struct HistoryIncomeSummaryCard: View {
    let summary: HistoryIncomeSummary

    var body: some View {
        SettingsCard {
            HistorySummaryRow(title: L10n.text("总收益"), icon: .asset("HistoryRealisedRocket"),
                value: summary.amountUSD.map { DisplayFormat.money($0, signed: true) } ?? "—",
                valueColor: summary.amountUSD.map {
                    $0 >= 0 ? CatfolioTheme.positive : CatfolioTheme.danger
                } ?? SettingsTemplate.secondaryText)
        }
        .accessibilityIdentifier("history-income-summary")
    }
}
