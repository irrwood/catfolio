import SwiftUI

/// Row construction stays behind the lazy list's visibility boundary.
struct CorporateCalendarEventRow: View {
    let event: CorporateEvent
    let holding: Holding?
    let calendar: Calendar

    var body: some View {
        let date = CorporateCalendarDay.date(event.date, calendar: calendar) ?? Date()
        return HStack(spacing: 12) {
            AssetLogo(ticker: event.ticker, logoSymbol: holding?.logoSymbol, size: 36, cornerRadius: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(holding?.shortName ?? event.ticker)
                    .appText(.body, weight: .medium)
                    .foregroundStyle(CatfolioTheme.primaryText)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(date, format: .dateTime.month(.abbreviated).day())
                    Text("·")
                    Text(event.kindTitle)
                }
                .appText(.footnote)
                .foregroundStyle(SettingsTemplate.secondaryText)
            }
            Spacer(minLength: 8)
            if let income = event.incomeUSD(shares: holding?.shares ?? 0) {
                FinancialText(DisplayFormat.money(income, fractionDigits: 2))
                    .appNumber(.callout, weight: .medium)
                    .foregroundStyle(CatfolioTheme.primaryText)
            }
        }
        .padding(.horizontal, SettingsTemplate.rowHorizontalPadding)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("corporate-calendar.event.\(event.id)")
    }

}
