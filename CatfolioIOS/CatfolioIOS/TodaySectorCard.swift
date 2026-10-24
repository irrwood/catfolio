import SwiftUI

/// Sector content sharing the daily summary's card surface.
struct TodaySectorCard: View {
    let rows: [TodayDetailView.SectorBreakdown]
    let onSelect: (TodayDetailView.SectorBreakdown) -> Void
    @ScaledMetric(relativeTo: .callout) private var amountFontSize = TypeScale.callout.size

    private var largestMagnitude: Double { rows.map { abs($0.amount) }.max() ?? 0 }
    private var sortOrder: TodaySectorSortOrder { .automatic(for: rows.map(\.amount)) }
    private var amountColumnWidth: CGFloat {
        let widest = rows.map {
            Typography.numberWidth(TodaySectorRow.amountText($0.amount), size: amountFontSize, weight: .semibold)
        }.max() ?? 0
        return min(96, max(48, ceil(widest) + 2))
    }

    var body: some View {
        sectorRows
            .padding(.bottom, 12)
    }

    private var sectorRows: some View {
        VStack(spacing: 0) {
            ForEach(sortOrder.sorted(rows, amount: \.amount, id: \.id)) { row in
                Button { onSelect(row) } label: {
                    TodaySectorRow(row: row, largestMagnitude: largestMagnitude,
                                   amountColumnWidth: amountColumnWidth)
                        .padding(.horizontal, 12)
                        .contentShape(Rectangle())
                }
                .buttonStyle(SettingsRowButtonStyle())
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(row.displayName)
                .accessibilityValue(TodaySectorRow.amountText(row.amount))
                .accessibilityIdentifier("today-sector.\(row.id)")
            }
        }
    }
}

struct TodaySectorRow: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.locale) private var appLocale
    let row: TodayDetailView.SectorBreakdown
    let largestMagnitude: Double
    let amountColumnWidth: CGFloat

    private var title: String {
        switch row.sector {
        case .technology: L10n.text("today.sector.technology")
        case .healthcare: L10n.text("today.sector.healthcare")
        case .financials: L10n.text("today.sector.financials")
        case .consumerCyclical: L10n.text("today.sector.consumerCyclical")
        case .consumerDefensive: L10n.text("today.sector.consumerDefensive")
        case .industrials: L10n.text("today.sector.industrials")
        case .energy: L10n.text("today.sector.energy")
        case .materials: L10n.text("today.sector.materials")
        case .realEstate: L10n.text("today.sector.realEstate")
        case .utilities: L10n.text("today.sector.utilities")
        case .communication: L10n.text("today.sector.communication")
        case nil: L10n.text("today.sector.unclassified")
        }
    }

    private var tint: Color { row.amount >= 0 ? CatfolioTheme.positive : CatfolioTheme.danger }

    static func amountText(_ amount: Double) -> String {
        let magnitude = abs(DisplayCurrency.current.fromUSD(amount))
        return DisplayFormat.money(amount, signed: true,
                                   fractionDigits: magnitude > 0 && magnitude < 1 ? 2 : 0)
    }

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        icon
                        Text(title)
                            .appText(.callout, weight: .medium)
                            .foregroundStyle(CatfolioTheme.primaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    HStack(spacing: 12) {
                        TodaySectorBar(amount: row.amount, largestMagnitude: largestMagnitude, tint: tint)
                            .frame(width: 48)
                        HStack(spacing: 4) {
                            amount
                            chevron
                        }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
            } else {
                compactRow
            }
        }
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }

    private var compactRow: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                icon
                Text(title)
                    .appText(.callout, weight: .medium)
                    .foregroundStyle(CatfolioTheme.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                    .frame(width: appLocale.identifier.hasPrefix("zh") ? 36 : 64, alignment: .leading)
            }
            TodaySectorBar(amount: row.amount, largestMagnitude: largestMagnitude, tint: tint)
            HStack(spacing: 4) {
                amount.frame(width: amountColumnWidth, alignment: .trailing)
                chevron
            }
        }
    }

    private var icon: some View {
        let colors = CatfolioTheme.sectorIconColors(for: row.sector, scheme: colorScheme)
        return Image(systemName: row.sector == nil ? "questionmark" : row.symbolName)
            .symbolVariant(.fill)
            .symbolRenderingMode(.monochrome)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(colors.foreground)
            .frame(width: 24, height: 24)
            .background(colors.background, in: Circle())
            .accessibilityHidden(true)
    }

    private var amount: some View {
        FinancialText(Self.amountText(row.amount), isDirectional: true)
            .appNumber(.callout, weight: .semibold)
            .foregroundStyle(tint)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
    }
}

struct TodaySectorBar: View {
    static let height: CGFloat = 24
    private static let barHeight: CGFloat = 8
    let amount: Double
    let largestMagnitude: Double
    let tint: Color

    static func ratio(amount: Double, largestMagnitude: Double) -> Double {
        largestMagnitude > 0 ? min(1, abs(amount) / largestMagnitude) : 0
    }

    var body: some View {
        GeometryReader { geometry in
            let zero = geometry.size.width / 2
            let width = geometry.size.width / 2 * Self.ratio(amount: amount, largestMagnitude: largestMagnitude)
            let isLoss = amount < 0
            ZStack(alignment: .topLeading) {
                Capsule()
                    .fill(CatfolioTheme.subtleFill)
                    .frame(width: geometry.size.width, height: Self.barHeight)
                    .offset(y: (Self.height - Self.barHeight) / 2)
                // Keep the gradient on the shared magnitude scale so short
                // bars only reach a hint of teal/violet, rather than its tip.
                LinearGradient(
                    colors: [tint, isLoss ? CatfolioTheme.sectorLossTip : CatfolioTheme.sectorGainTip],
                    startPoint: isLoss ? .trailing : .leading,
                    endPoint: isLoss ? .leading : .trailing)
                    .frame(width: zero, height: Self.barHeight)
                    .mask(alignment: isLoss ? .trailing : .leading) {
                        UnevenRoundedRectangle(cornerRadii: .init(
                            topLeading: isLoss ? 4 : 0,
                            bottomLeading: isLoss ? 4 : 0,
                            bottomTrailing: isLoss ? 0 : 4,
                            topTrailing: isLoss ? 0 : 4))
                            .frame(width: width, height: Self.barHeight)
                    }
                    .offset(x: isLoss ? 0 : zero,
                            y: (Self.height - Self.barHeight) / 2)
                Capsule()
                    .fill(CatfolioTheme.primaryText)
                    .frame(width: 2, height: Self.barHeight)
                    .offset(x: zero - 1, y: (Self.height - Self.barHeight) / 2)
            }
        }
        .frame(height: Self.height)
        .accessibilityHidden(true)
    }
}
