import SwiftUI

/// Sector content sharing the daily summary's card surface.
struct TodaySectorCard: View {
    let rows: [TodayDetailView.SectorBreakdown]
    let onSelect: (TodayDetailView.SectorBreakdown) -> Void

    private var largestMagnitude: Double { rows.map { abs($0.amount) }.max() ?? 0 }
    private var zeroFraction: CGFloat { TodaySectorBar.centeredZeroFraction(for: rows.map(\.amount)) }
    private var sortOrder: TodaySectorSortOrder { .automatic(for: rows.map(\.amount)) }

    var body: some View {
        sectorRows
            .padding(.bottom, 12)
            .overlayPreferenceValue(TodaySectorAxisBounds.self) { anchors in
                GeometryReader { geometry in
                    if let first = anchors.first, let last = anchors.last {
                        let firstBar = geometry[first]
                        let lastBar = geometry[last]
                        let top = firstBar.midY - TodaySectorBar.barHeight / 2
                        let bottom = lastBar.midY + TodaySectorBar.barHeight / 2
                        Rectangle()
                            .fill(SettingsTemplate.separator)
                            .frame(width: SettingsTemplate.separatorHeight, height: bottom - top)
                            .offset(x: firstBar.minX + firstBar.width * zeroFraction
                                - SettingsTemplate.separatorHeight / 2, y: top)
                    }
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
    }

    private var sectorRows: some View {
        VStack(spacing: 0) {
            ForEach(sortOrder.sorted(rows, amount: \.amount, id: \.id)) { row in
                Button { onSelect(row) } label: {
                    TodaySectorRow(row: row, largestMagnitude: largestMagnitude, zeroFraction: zeroFraction)
                        .padding(.horizontal, 12)
                        .contentShape(Rectangle())
                }
                .buttonStyle(SettingsRowButtonStyle())
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(row.displayName)
                .accessibilityValue(DisplayFormat.money(row.amount, signed: true, fractionDigits: 2))
                .accessibilityIdentifier("today-sector.\(row.id)")
            }
        }
    }
}

private struct TodaySectorAxisBounds: PreferenceKey {
    static let defaultValue: [Anchor<CGRect>] = []

    static func reduce(value: inout [Anchor<CGRect>], nextValue: () -> [Anchor<CGRect>]) {
        value.append(contentsOf: nextValue())
    }
}

struct TodaySectorRow: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.locale) private var appLocale
    let row: TodayDetailView.SectorBreakdown
    let largestMagnitude: Double
    var zeroFraction: CGFloat = 0.5

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
                        TodaySectorBar(amount: row.amount, largestMagnitude: largestMagnitude, tint: tint,
                                       zeroFraction: zeroFraction)
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
        HStack(spacing: 8) {
            icon
            Text(title)
                .appText(.callout, weight: .medium)
                .foregroundStyle(CatfolioTheme.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
                .frame(width: appLocale.identifier.hasPrefix("zh") ? 36 : 64, alignment: .leading)
            TodaySectorBar(amount: row.amount, largestMagnitude: largestMagnitude, tint: tint,
                           zeroFraction: zeroFraction)
                .anchorPreference(key: TodaySectorAxisBounds.self, value: .bounds) { [$0] }
            HStack(spacing: 4) {
                amount.frame(width: 88, alignment: .trailing)
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
        FinancialText(DisplayFormat.money(row.amount, signed: true, fractionDigits: 2), isDirectional: true)
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
    fileprivate static let barHeight: CGFloat = 20
    let amount: Double
    let largestMagnitude: Double
    let tint: Color
    var zeroFraction: CGFloat = 0.5

    /// Translate the occupied range as one group, keeping every bar's length
    /// and the common money-to-width scale unchanged.
    static func centeredZeroFraction(for amounts: [Double]) -> CGFloat {
        let gain = max(0, amounts.max() ?? 0)
        let loss = max(0, -(amounts.min() ?? 0))
        let maximum = max(gain, loss)
        guard maximum > 0 else { return 0.5 }
        return 0.5 + CGFloat(loss / maximum - gain / maximum) / 4
    }

    static func ratio(amount: Double, largestMagnitude: Double) -> Double {
        largestMagnitude > 0 ? min(1, abs(amount) / largestMagnitude) : 0
    }

    var body: some View {
        GeometryReader { geometry in
            let zero = geometry.size.width * zeroFraction
            let width = geometry.size.width / 2 * Self.ratio(amount: amount, largestMagnitude: largestMagnitude)
            let isLoss = amount < 0
            ZStack(alignment: .topLeading) {
                UnevenRoundedRectangle(cornerRadii: .init(
                    topLeading: isLoss ? 5 : 0,
                    bottomLeading: isLoss ? 5 : 0,
                    bottomTrailing: isLoss ? 0 : 5,
                    topTrailing: isLoss ? 0 : 5))
                    .fill(tint)
                    .frame(width: width, height: Self.barHeight)
                    .offset(x: isLoss ? zero - width : zero,
                            y: (Self.height - Self.barHeight) / 2)
            }
        }
        .frame(height: Self.height)
        .accessibilityHidden(true)
    }
}
