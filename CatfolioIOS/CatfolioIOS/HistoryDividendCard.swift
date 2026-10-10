import SwiftUI
import Charts

/// Figma 630:23673 / 630:23762: contribution ring above two summary amounts.
struct HistoryDividendCard: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var selectedTicker: String?
    let breakdown: HistoryDividendBreakdown
    let totalUSD: Double
    /// This calendar year's expected dividends; nil until known.
    var forecastUSD: Double? = nil

    init(breakdown: HistoryDividendBreakdown, totalUSD: Double,
         forecastUSD: Double? = nil, initialSelection: String? = nil) {
        self.breakdown = breakdown
        self.totalUSD = totalUSD
        self.forecastUSD = forecastUSD
        _selectedTicker = State(initialValue: initialSelection)
    }

    private var selectedRow: HistoryDividendBreakdown.Row? {
        breakdown.rows.first { $0.id == selectedTicker }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: SettingsTemplate.sectionSpacing) {
                selectionMenu
                ring
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(L10n.text("股息来源占比"))
                .accessibilityValue(selectedRow.map(selectionDescription) ?? L10n.text("全部"))
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
                .accessibilityIdentifier("dividend-contribution-ring")
            }
            .padding(SettingsTemplate.rowHorizontalPadding)
            summaryAmounts
        }
        .settingsCardSurface()
    }

    private var selectionMenu: some View {
        Menu {
            Button(L10n.text("全部")) {
                selectedTicker = nil
            }
            ForEach(breakdown.rows) { row in
                Button {
                    selectedTicker = row.id
                } label: {
                    Label(selectionDescription(row), systemImage: row.id == selectedRow?.id ? "checkmark" : "circle")
                }
            }
        } label: {
            HistoryRingSelectionLabel(
                title: selectedRow.map {
                    CompanyNameCatalog.displayName(ticker: $0.ticker, fallback: $0.name)
                } ?? L10n.text("比例"),
                percentage: selectedRow.map(percentage),
                choices: breakdown.rows.map {
                    .init(title: CompanyNameCatalog.displayName(ticker: $0.ticker, fallback: $0.name),
                          percentage: percentage($0))
                })
            .foregroundStyle(selectedRow.map(segmentColor) ?? CatfolioTheme.primaryText)
        }
        .buttonStyle(.plain)
        .disabled(breakdown.rows.isEmpty)
        .accessibilityLabel(L10n.text("股息来源占比"))
        .accessibilityValue(selectedRow.map(selectionDescription) ?? L10n.text("全部"))
        .accessibilityIdentifier("dividend-contribution-selection")
    }

    private var summaryAmounts: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: SettingsTemplate.rowVerticalPadding))
            : AnyLayout(HStackLayout(spacing: 10))
        return layout {
            summaryAmount(title: L10n.text("Total dividends"),
                value: breakdown.isComplete ? DisplayFormat.money(totalUSD) : "—",
                isNegative: totalUSD < 0)
            CatfolioPalette.calendarSeparator
                .frame(width: dynamicTypeSize.isAccessibilitySize ? nil : SettingsTemplate.separatorHeight,
                       height: dynamicTypeSize.isAccessibilitySize ? SettingsTemplate.separatorHeight : SettingsTemplate.iconSize)
                .accessibilityHidden(true)
            summaryAmount(title: L10n.text("Expected this yrs"),
                value: forecastUSD.map { DisplayFormat.money($0) } ?? "—")
        }
        .padding(.horizontal, SettingsTemplate.rowHorizontalPadding)
        .padding(.vertical, SettingsTemplate.rowVerticalPadding)
    }

    private func summaryAmount(title: String, value: String, isNegative: Bool = false) -> some View {
        VStack(spacing: SettingsTemplate.subtitleSpacing) {
            Text(title.uppercased())
                .appText(.caption, weight: .semibold)
                .foregroundStyle(SettingsTemplate.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            FinancialText(value)
                .appNumber(.subheading, weight: .semibold)
                .foregroundStyle(isNegative ? CatfolioTheme.loss(for: colorScheme) : CatfolioTheme.primaryText)
                .lineLimit(1).minimumScaleFactor(0.6)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    /// Each holding an arc in its own colour, largest first and clockwise
    /// from the top; a tap on an arc selects its heading. Unknown amounts
    /// or rate leave an empty ring, no shares.
    private var ring: some View {
        HistoryProportionRing(layout: HistoryDividendRingLayout(breakdown: breakdown),
                              selection: Binding(get: { selectedRow?.id }, set: { selectedTicker = $0 }),
                              color: segmentColor)
    }

    private func segmentColor(_ row: HistoryDividendBreakdown.Row) -> Color {
        guard let index = breakdown.rows.firstIndex(where: { $0.id == row.id }) else {
            return CatfolioPalette.dividendSelection
        }
        return CatfolioPalette.dividendSeries[index % CatfolioPalette.dividendSeries.count]
    }

    private func percentage(_ row: HistoryDividendBreakdown.Row) -> String {
        breakdown.share(for: row).map { DisplayFormat.percent($0 * 100, signed: false) } ?? "—"
    }

    private func selectionDescription(_ row: HistoryDividendBreakdown.Row) -> String {
        "\(CompanyNameCatalog.displayName(ticker: row.ticker, fallback: row.name)) · \(row.ticker) · \(percentage(row)) · \(row.amountUSD.map { DisplayFormat.money($0) } ?? "—")"
    }
}
