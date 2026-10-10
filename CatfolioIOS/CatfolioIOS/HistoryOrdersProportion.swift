import SwiftUI

struct HistoryOrdersProportion: View {
    let breakdown: HistoryOrdersBreakdown
    @State private var selectedTicker: String?

    init(breakdown: HistoryOrdersBreakdown, initialSelection: String? = nil) {
        self.breakdown = breakdown
        _selectedTicker = State(initialValue: initialSelection)
    }

    private var selectedRow: HistoryOrdersBreakdown.Row? {
        breakdown.rows.first { $0.id == selectedTicker }
    }

    var body: some View {
        VStack(spacing: SettingsTemplate.sectionSpacing) {
            Menu {
                Button(L10n.text("全部")) { selectedTicker = nil }
                ForEach(breakdown.rows) { row in
                    Button { selectedTicker = row.id } label: {
                        Label(description(row), systemImage: row.id == selectedRow?.id ? "checkmark" : "circle")
                    }
                }
            } label: {
                HistoryRingSelectionLabel(
                    title: selectedRow.map(displayName) ?? L10n.text("比例"),
                    percentage: selectedRow.map(percentage),
                    choices: breakdown.rows.map { .init(title: displayName($0), percentage: percentage($0)) })
                .foregroundStyle(selectedRow.map(color) ?? CatfolioTheme.primaryText)
            }
            .buttonStyle(.plain)
            .disabled(breakdown.rows.isEmpty)
            .accessibilityLabel(L10n.text("已实现盈亏占比"))
            .accessibilityValue(selectedRow.map(description) ?? L10n.text("全部"))
            .accessibilityIdentifier("orders-contribution-selection")

            HistoryProportionRing(layout: HistoryRingLayout(rows: breakdown.rows) {
                breakdown.share(for: $0) ?? 0
            }, selection: Binding(get: { selectedRow?.id }, set: { selectedTicker = $0 }), color: color)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L10n.text("已实现盈亏占比"))
            .accessibilityValue(selectedRow.map(description) ?? L10n.text("全部"))
            .accessibilityAdjustableAction { direction in
                guard !breakdown.rows.isEmpty else { return }
                guard let row = selectedRow,
                      let index = breakdown.rows.firstIndex(where: { $0.id == row.id }) else {
                    selectedTicker = breakdown.rows.first?.id
                    return
                }
                switch direction {
                case .increment: selectedTicker = breakdown.rows[min(index + 1, breakdown.rows.count - 1)].id
                case .decrement: selectedTicker = breakdown.rows[max(index - 1, 0)].id
                @unknown default: break
                }
            }
            .accessibilityIdentifier("orders-contribution-ring")
        }
        .padding(SettingsTemplate.rowHorizontalPadding)
    }

    private func color(_ row: HistoryOrdersBreakdown.Row) -> Color {
        let index = breakdown.rows.firstIndex(where: { $0.id == row.id }) ?? 0
        return CatfolioPalette.dividendSeries[index % CatfolioPalette.dividendSeries.count]
    }

    private func displayName(_ row: HistoryOrdersBreakdown.Row) -> String {
        CompanyNameCatalog.displayName(ticker: row.ticker, fallback: row.name)
    }

    private func percentage(_ row: HistoryOrdersBreakdown.Row) -> String {
        breakdown.share(for: row).map { DisplayFormat.percent($0 * 100, signed: false) } ?? "—"
    }

    private func description(_ row: HistoryOrdersBreakdown.Row) -> String {
        let amount = row.amountUSD.map { DisplayFormat.money($0, signed: true) } ?? "—"
        return "\(displayName(row)) · \(row.ticker) · \(percentage(row)) · \(amount)"
    }
}
