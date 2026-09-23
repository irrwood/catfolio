import SwiftUI

/// The security page's entry to insider trades. Nothing loads until it is
/// tapped; the trades open in a sheet of their own.
struct HoldingInsiderTradesCard: View {
    let holding: Holding
    @State private var showsTrades = false
    @Namespace private var zoom

    var body: some View {
        Button {
            showsTrades = true
        } label: {
            HoldingDetailActionCardLabel(
                title: L10n.text("内部人士交易"),
                subtitle: L10n.text("只看主动买卖 · 已排除计划交易、代扣税与行权卖出")
            )
        }
        .buttonStyle(.plain)
        .matchedTransitionSource(id: "insiders-\(holding.ticker)", in: zoom)
        .accessibilityIdentifier("holding-insider-trades")
        .appSheet(isPresented: $showsTrades) {
            InsiderTradesSheet(symbol: holding.ticker)
                .navigationTransition(.zoom(sourceID: "insiders-\(holding.ticker)", in: zoom))
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
    }
}

struct InsiderTradesSheet: View {
    @Environment(\.dismiss) private var dismiss
    let symbol: String
    @State private var snapshot: InsiderTradesSnapshot?
    @State private var errorMessage: String?
    @State private var isLoading = false
    @State private var showsAll = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if let snapshot {
                        content(snapshot)
                    } else if let errorMessage {
                        ContentUnavailableView {
                            Label(L10n.text("无法加载内部人士交易"), systemImage: "exclamationmark.triangle")
                        } description: {
                            Text(L10n.message(errorMessage))
                        } actions: {
                            Button(L10n.text("重试")) { Task { await load(forceRefresh: true) } }
                        }
                        .padding(.top, 40)
                    } else {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.top, 80)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
                .padding(.bottom, 24)
            }
            .softTopScrollEdge()
            .appPageBackground().navigationTitle(L10n.text("内部人士交易"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel(L10n.text("关闭"))
                }
                ToolbarItem(placement: .primaryAction) {
                    if isLoading, snapshot != nil {
                        ProgressView().controlSize(.small)
                    } else {
                        Button { Task { await load(forceRefresh: true) } } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .accessibilityLabel(L10n.text("刷新"))
                        .disabled(isLoading)
                    }
                }
            }
        }
        .task { await load(forceRefresh: false) }
    }

    @ViewBuilder
    private func content(_ snapshot: InsiderTradesSnapshot) -> some View {
        let discretionary = snapshot.trades.filter(\.isDiscretionary)
        let shown = showsAll ? snapshot.trades : discretionary

        InsiderTradesSummaryCard(snapshot: snapshot)

        Picker(L10n.text("显示"), selection: $showsAll) {
            Text(L10n.text("主动买卖 \(discretionary.count)")).tag(false)
            Text(L10n.text("全部 \(snapshot.trades.count)")).tag(true)
        }
        .pickerStyle(.segmented)

        if shown.isEmpty {
            Text(snapshot.trades.isEmpty
                 ? L10n.text("暂无内部人士交易记录。")
                 : L10n.text("这段记录里没有主动买卖：全是 10b5-1 计划交易、代扣税或行权后的卖出，或授予、行权等非公开市场交易。"))
                .appText(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(shown) { trade in
                    InsiderTradeRow(trade: trade)
                    if trade.id != shown.last?.id {
                        Divider()
                    }
                }
            }
        }

        Text(L10n.text("来源 Nasdaq，整理自 SEC Form 4 申报。主动买卖只含公开市场交易，已排除：Rule 10b5-1 预设计划交易（Nasdaq 标为 Automatic）；两位以上内部人同日同价的卖出，通常是股票归属时公司统一卖出代缴税款；行权当天的卖出；以及授予、行权、赠与等非公开市场交易。只有一人归属时的代扣税卖出无法从数据中区分，没有计划标记的卖出也可能出于税务或分散持仓，买入通常比卖出更有信息量。"))
            .appText(.micro, weight: .regular)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func load(forceRefresh: Bool) async {
        if snapshot == nil { snapshot = await InsiderTradesClient.shared.cached(symbol: symbol) }
        isLoading = true
        defer { isLoading = false }
        do {
            snapshot = try await InsiderTradesClient.shared.load(symbol: symbol, forceRefresh: forceRefresh)
            errorMessage = nil
        } catch is CancellationError {
        } catch {
            if snapshot == nil { errorMessage = error.localizedDescription }
        }
    }
}

/// Open-market buying and selling insiders chose to do, over three and
/// twelve months.
struct InsiderTradesSummaryCard: View {
    let snapshot: InsiderTradesSnapshot
    private let column: CGFloat = 112

    var body: some View {
        let recent = snapshot.summary(months: 3)
        let year = snapshot.summary(months: 12)

        VStack(alignment: .leading, spacing: 0) {
            ViewThatFits(in: .horizontal) {
                comparisonTable(recent: recent, year: year)
                stackedComparison(recent: recent, year: year)
            }
            if !year.isComplete, let start = snapshot.coverageStart {
                Text(L10n.text("12 个月只含 \(start.formatted(date: .abbreviated, time: .omitted)) 之后的记录。"))
                    .appText(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 12)
            }
        }
        .padding(.horizontal, 16)
        .holdingDetailGlassCard()
    }

    private func comparisonTable(recent: InsiderTradesSnapshot.Summary,
                                 year: InsiderTradesSnapshot.Summary) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L10n.text("主动交易"))
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(L10n.text("近 3 个月")).frame(width: column, alignment: .trailing)
                Text(L10n.text("近 12 个月")).frame(width: column, alignment: .trailing)
            }
            .appText(.caption, weight: .semibold)
            .foregroundStyle(.secondary)
            .padding(.vertical, 12)
            Divider()
            row(L10n.text("买入"),
                recent: (recent.buys, recent.valueBought), year: (year.buys, year.valueBought))
            Divider()
            row(L10n.text("卖出"),
                recent: (recent.sells, recent.valueSold), year: (year.sells, year.valueSold))
            Divider()
            HStack {
                Text(L10n.text("净买入额")).appText(.callout, weight: .medium)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .researchLayoutFrame("insider.net.label")
                net(recent.netValue, count: recent.buys + recent.sells)
                    .frame(width: column, alignment: .trailing)
                net(year.netValue, count: year.buys + year.sells)
                    .frame(width: column, alignment: .trailing)
            }
            .padding(.vertical, 12)
        }
    }

    /// Keep the familiar table whenever its labels fit. Narrow screens and
    /// larger text show each period in turn, so neither names nor amounts
    /// compete for the few points left beside two fixed amount columns.
    private func stackedComparison(recent: InsiderTradesSnapshot.Summary,
                                   year: InsiderTradesSnapshot.Summary) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.text("主动交易"))
                .appText(.caption, weight: .semibold).foregroundStyle(.secondary)
            periodSummary(L10n.text("近 3 个月"), summary: recent, netLabelID: "insider.net.label")
            Divider()
            periodSummary(L10n.text("近 12 个月"), summary: year, netLabelID: "insider.net.label.year")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
    }

    private func periodSummary(_ title: String, summary: InsiderTradesSnapshot.Summary,
                               netLabelID: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).appText(.caption, weight: .semibold).foregroundStyle(.secondary)
            adaptiveRow(L10n.text("买入")) { tradeValue(count: summary.buys, value: summary.valueBought) }
            adaptiveRow(L10n.text("卖出")) { tradeValue(count: summary.sells, value: summary.valueSold) }
            adaptiveRow(L10n.text("净买入额"), labelID: netLabelID) {
                net(summary.netValue, count: summary.buys + summary.sells)
            }
        }
    }

    private func adaptiveRow<Value: View>(_ title: String, labelID: String? = nil,
                                         @ViewBuilder value: () -> Value) -> some View {
        let label = Text(title).appText(.callout, weight: .medium)
            .fixedSize(horizontal: true, vertical: false)
            .researchLayoutFrame(labelID)
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                label
                Spacer(minLength: 0)
                value().fixedSize(horizontal: true, vertical: false)
            }
            VStack(alignment: .leading, spacing: 6) {
                label
                value().fixedSize(horizontal: true, vertical: false)
            }
        }
    }

    /// The amount, with the number of trades under it in small type.
    private func row(_ title: String, recent: (Int, Double), year: (Int, Double)) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).appText(.callout, weight: .medium)
                .fixedSize(horizontal: true, vertical: false)
                .frame(maxWidth: .infinity, alignment: .leading)
            cell(count: recent.0, value: recent.1)
            cell(count: year.0, value: year.1)
        }
        .padding(.vertical, 12)
    }

    private func cell(count: Int, value: Double) -> some View {
        tradeValue(count: count, value: value)
            .frame(width: column, alignment: .trailing)
    }

    private func tradeValue(count: Int, value: Double) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            if count == 0 {
                Text("—").appNumber(.callout).foregroundStyle(.secondary)
            } else {
                Text(DisplayFormat.compactMoney(value, currency: "USD")).appNumber(.callout)
                Text(L10n.text("\(count) 笔")).appNumber(.caption).foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }

    @ViewBuilder
    private func net(_ value: Double, count: Int) -> some View {
        if count == 0 {
            Text("—").appNumber(.callout).foregroundStyle(.secondary)
        } else {
            Text((value >= 0 ? "+" : "") + DisplayFormat.compactMoney(value, currency: "USD"))
                .appNumber(.callout, weight: .semibold)
                .foregroundStyle(value > 0 ? CatfolioPalette.green500 : value < 0 ? CatfolioPalette.rose500 : .secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }
}

private struct InsiderTradeRow: View {
    let trade: InsiderTrade

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(trade.insider.capitalized)
                    .appText(.callout, weight: .semibold)
                    .lineLimit(1)
                Text(details)
                    .appText(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 4) {
                Text(kindTitle)
                    .appText(.caption, weight: .semibold)
                    .foregroundStyle(kindColor)
                Text(amount)
                    .appNumber(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }

    private var details: String {
        [relation, ownership, trade.date.formatted(date: .abbreviated, time: .omitted)]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    private var amount: String {
        var parts = [L10n.text("\(DisplayFormat.compact(trade.shares)) 股")]
        if let value = trade.value {
            parts.append(DisplayFormat.compactMoney(value, currency: "USD"))
        }
        return parts.joined(separator: " · ")
    }

    private var relation: String {
        switch trade.relation.lowercased() {
        case "officer": L10n.text("高管")
        case "director": L10n.text("董事")
        default: trade.relation
        }
    }

    private var ownership: String {
        switch trade.ownType.lowercased() {
        case "direct": L10n.text("直接持有")
        case "indirect": L10n.text("间接持有")
        default: trade.ownType
        }
    }

    private var kindTitle: String {
        switch trade.kind {
        case .buy: L10n.text("主动买入")
        case .sell: L10n.text("主动卖出")
        case .planBuy: L10n.text("计划买入 · 10b5-1")
        case .planSell: L10n.text("计划卖出 · 10b5-1")
        case .sellToCover: L10n.text("疑似代扣税卖出")
        case .exerciseSale: L10n.text("行权后卖出")
        case .exercise: L10n.text("期权行权")
        case .nonMarketAcquisition: L10n.text("非公开市场取得")
        case .nonMarketDisposition: L10n.text("非公开市场处置")
        case .other: L10n.text("其他")
        }
    }

    private var kindColor: Color {
        switch trade.kind {
        case .buy: CatfolioPalette.green500
        case .sell: CatfolioPalette.rose500
        default: .secondary
        }
    }
}
