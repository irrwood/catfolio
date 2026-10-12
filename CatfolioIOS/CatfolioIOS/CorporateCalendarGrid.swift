import SwiftUI

/// Keep the fixed month grid separate from the page and its lazy event list.
/// Each day has a small, stable view type instead of capturing the whole page.
struct CorporateCalendarGrid: View {
    let days: [String]
    let calendar: Calendar
    let leadingBlanks: Int
    let today: String
    let byDay: [String: [CorporateEvent]]
    let scope: CorporateCalendarHoldings
    @Binding var selectedDay: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 6) {
            weekdayRow
            // A month has at most six fixed rows. Stack layout avoids the
            // lazy grid's initial measurement work for an entirely visible grid.
            ForEach(0..<((leadingBlanks + days.count + 6) / 7), id: \.self) { row in
                HStack(spacing: 6) {
                    ForEach(0..<7, id: \.self) { column in
                        cell(row * 7 + column - leadingBlanks)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func cell(_ index: Int) -> some View {
        if days.indices.contains(index) {
            let day = days[index]
            let tickers = (byDay[day] ?? []).map(\.ticker).reduce(into: [String]()) {
                if !$0.contains($1) { $0.append($1) }
            }
            let date = CorporateCalendarDay.date(day, calendar: calendar) ?? Date()
            let label = date.formatted(.dateTime.month().day().locale(calendar.locale ?? .current))
            CorporateCalendarDayCell(day: day, dateLabel: label, tickers: tickers,
                logoSymbol: tickers.first.flatMap { scope.byTicker[$0.uppercased()]?.logoSymbol },
                isToday: day == today, isSelected: day == selectedDay) {
                    withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) {
                        selectedDay = selectedDay == day ? nil : day
                    }
                }
        } else {
            Color.clear.frame(height: 76).frame(maxWidth: .infinity)
        }
    }

    private var weekdayRow: some View {
        let symbols = calendar.shortStandaloneWeekdaySymbols
        let ordered = Array(symbols[(calendar.firstWeekday - 1)...] + symbols[..<(calendar.firstWeekday - 1)])
        return HStack(spacing: 6) {
            ForEach(Array(ordered.enumerated()), id: \.offset) { _, symbol in
                Text(symbol)
                    .appText(.caption, weight: .medium)
                    .foregroundStyle(SettingsTemplate.secondaryText)
                    .frame(maxWidth: .infinity)
            }
        }
    }
}

private struct CorporateCalendarDayCell: View {
    let day: String
    let dateLabel: String
    let tickers: [String]
    let logoSymbol: String?
    let isToday: Bool
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(spacing: 4) {
                Text(String(Int(day.suffix(2)) ?? 0))
                    .appNumber(.caption, weight: isToday ? .bold : .medium)
                    .foregroundStyle(isToday ? CatfolioTheme.primaryText : SettingsTemplate.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
                if let first = tickers.first {
                    AssetLogo(ticker: first, logoSymbol: logoSymbol, size: 26, cornerRadius: 8)
                }
                Text(tickers.count > 1 ? "+\(tickers.count - 1)" : " ")
                    .appNumber(.nano, weight: .medium)
                    .foregroundStyle(SettingsTemplate.secondaryText)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
            .frame(height: 76)
            .frame(maxWidth: .infinity)
            .background(isSelected ? Color.primary.opacity(0.1) : SettingsTemplate.card,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                if isToday {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(CatfolioTheme.primaryText, lineWidth: 1.5)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(dateLabel)
        .accessibilityValue(tickers.joined(separator: ", "))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("corporate-calendar.day.\(day)")
    }
}
