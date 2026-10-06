import SwiftUI
import UIKit

/// One History figure, laid out as Figma 487:5391: the icon and chevron on
/// top, the title over the amount at the foot. The colours stay the
/// settings card's own.
struct SettingsHistoryOverviewTile: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let title: String
    let icon: String
    let caption: String
    let value: String
    let valueColor: Color

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: SettingsTemplate.cardRadius, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .regular))
                    .frame(width: 26, height: 26)
                    .accessibilityHidden(true)
                Spacer(minLength: 0)
                // One line: a wrapped caption would push this tile's figures
                // out of line with its neighbour's.
                Text(caption)
                    .appText(.caption, weight: .semibold)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image("SettingsChevron")
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .frame(height: 24)
            Spacer(minLength: 8)
            // Figma's gap is between trimmed text boxes; the line boxes
            // here already carry most of it.
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(Typography.text(size: 14, weight: .bold))
                    .textCase(.uppercase)
                    .lineLimit(typeSize.isAccessibilitySize ? 4 : 1)
                    .minimumScaleFactor(0.8)
                Text(value)
                    .font(Typography.number(size: 20, weight: .semibold))
                    .foregroundStyle(valueColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
        }
        .foregroundStyle(CatfolioTheme.primaryText)
        .padding([.horizontal, .top], 16)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, minHeight: 109, alignment: .leading)
        .modifier(SettingsHistoryTileGlass())
        .contentShape(shape)
    }
}

struct SettingsHistoryTileGlass: ViewModifier {
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: SettingsTemplate.cardRadius, style: .continuous)
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: shape)
        } else {
            content.background(.regularMaterial, in: shape)
        }
    }
}

/// Uses the same prepared ledger and fund charges as History, across all
/// accounts and years. Display currency remains a presentation preference.
struct SettingsHistoryOverview: View {
    @Environment(AppModel.self) private var model
    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var typeSize
    @AppStorage(DisplayCurrency.preferenceKey) private var displayCurrency = DisplayCurrency.usd.rawValue
    @State private var prepared: HistoryPreparedLedger?
    @State private var annualFees: Double?
    @State private var failed = false
    @State private var loadedKey: LoadKey?

    private struct LoadKey: Hashable {
        let updatedAt: Date?
        let accountIDs: Set<String>
        let investorSelection: String
        let locale: String
    }

    private var loadKey: LoadKey {
        LoadKey(updatedAt: model.localUpdatedAt,
                accountIDs: Set(model.accounts.map(\.id)),
                investorSelection: model.publicInvestorSelection, locale: locale.identifier)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12),
                                     count: typeSize.isAccessibilitySize ? 1 : 2), spacing: 12) {
                overviewCard(.orders, title: L10n.text("已实现盈亏"), icon: "chart.line.uptrend.xyaxis.circle.fill",
                             caption: realisedCaption, amount: realisedAmount, signed: true)
                overviewCard(.dividends, title: L10n.text("股息"), icon: "dollarsign.circle.fill",
                             caption: "", amount: total(for: .dividends))
                overviewCard(.interest, title: L10n.text("利息"), icon: "building.columns.circle.fill",
                             caption: "", amount: total(for: .interest))
                overviewCard(.fees, title: L10n.text("年费用"), icon: "creditcard.circle.fill",
                             caption: "", amount: annualFees)
            }
            SettingsCard {
                SettingsNavigationRow(icon: .asset("SettingsInvoice"), title: L10n.text("全部历史")) {
                    HistoryView().environment(model)
                }
                .accessibilityIdentifier("settings.history-overview.all")
            }
            if failed {
                Button(L10n.text("无法读取速览，轻点重试")) {
                    Task { await load() }
                }
                .font(.caption)
                .tint(.primary)
            }
        }
        .accessibilityIdentifier("settings.history-overview")
        .task(id: loadKey) {
            guard loadedKey != loadKey else { return }
            await load()
        }
    }

    private var realisedAmount: Double? {
        guard let calculation = prepared?.realisedTotal,
              calculation.brokerCount + calculation.estimatedCount > 0 else { return nil }
        return calculation.combinedUSD
    }

    private var realisedCaption: String {
        guard let calculation = prepared?.realisedTotal else { return "" }
        // Nothing sold is not a state to announce; the empty figure says it.
        if calculation.saleCount == 0 { return "" }
        if !calculation.isComplete { return L10n.text("部分数据") }
        return ""
    }

    private func total(for category: HistoryCategory) -> Double? {
        prepared?.page(category: category, basis: .calendar, year: nil).totalUSD
    }

    private func overviewCard(_ category: HistoryCategory, title: String, icon: String,
                              caption: String, amount: Double?, signed: Bool = false) -> some View {
        let validAmount = amount.flatMap { $0.isFinite ? $0 : nil }
        let currency = DisplayCurrency(rawValue: displayCurrency) ?? .usd
        let value = validAmount.map {
            DisplayFormat.money(currency.fromUSD($0), currency: currency.rawValue,
                                signed: signed, fractionDigits: 2)
        } ?? "—"
        let color: Color = category == .fees || validAmount == nil || validAmount == 0
            ? .primary : ((validAmount ?? 0) < 0 ? CatfolioTheme.danger : CatfolioTheme.positive)
        return NavigationLink {
            HistoryView(initialCategory: category).environment(model)
        } label: {
            SettingsHistoryOverviewTile(title: title, icon: icon, caption: caption,
                                        value: value, valueColor: color)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(caption.isEmpty ? value : "\(caption) · \(value)")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("settings.history-overview.\(category.rawValue.lowercased())")
    }

    @MainActor
    /// A reload keeps the figures that are already up. Clearing them first
    /// blanked all four cards and put a progress line under the grid, which
    /// changed the section's height and shifted everything below it — the
    /// jump a reader saw on coming back from a page that changes the key.
    private func load() async {
        failed = false
        let requestKey = loadKey
        do {
            let ledger = try await model.activityLedger()
            let accountIDs = Set(ledger.accounts.map(\.id))
            let locale = locale
            async let holdings = model.holdings(forAccounts: accountIDs)
            let result = try await model.historyPreparationCache.prepared(
                ledger: ledger, accountIDs: accountIDs, locale: locale)
            try Task.checkCancellation()
            prepared = result
            loadedKey = requestKey
            let positions = try? await holdings
            try Task.checkCancellation()
            if let positions {
                let charges = HistoryFeeCharge.build(holdings: positions)
                annualFees = charges.isEmpty ? nil : charges.reduce(0) { $0 + $1.annual }
            }
        } catch {
            guard !Task.isCancelled else { return }
            failed = true
        }
    }
}
