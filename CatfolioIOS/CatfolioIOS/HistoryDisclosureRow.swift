import SwiftUI

/// Supplemental disclosures use the same compact geometry as a history row.
struct HistoryDisclosureRow: View {
    let record: PublicInvestorActivityItem

    var body: some View {
        HStack(spacing: 12) {
            AssetLogo(ticker: record.historyTicker ?? record.activity.cusip ?? "",
                      logoSymbol: record.historyTicker, size: 42)
            VStack(alignment: .leading, spacing: 4) {
                Text(record.securityName)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                Text(record.historySubtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            FinancialText(record.historyAmount)
                .appNumber(.subheading, weight: .semibold)
                .foregroundStyle(CatfolioTheme.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("history-disclosure-\(record.id)")
    }
}
