import SwiftUI

/// 洞察: the interesting things in the reader's own trades — the best and
/// the worst, the hit rate, how long winners and losers were held, the shares
/// sold too early, the busiest day. Opened from 账户, under 全部历史.
struct TradingInsightsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.locale) private var locale
    @AppStorage(DisplayCurrency.preferenceKey) private var displayCurrency = DisplayCurrency.usd.rawValue
    @State private var insights: TradingInsights?
    @State private var names: [String: String] = [:]
    @State private var holdings: [Holding] = []
    @State private var failed = false

    private struct LoadKey: Hashable {
        let updatedAt: Date?
        let accountIDs: Set<String>
    }

    var body: some View {
        SettingsPage(title: L10n.text("洞察"), subtitle: subtitle, bottomInset: 24) {
            if let insights, !insights.isEmpty {
                content(insights)
            } else if insights != nil {
                SettingsFootnote(L10n.text("还没有可以分析的交易。导入或同步交易记录后再来看看。"))
            } else if failed {
                Button(L10n.text("无法读取交易，轻点重试")) { Task { await load() } }
                    .font(.caption)
                    .tint(.primary)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 200)
            }
        }
        .task(id: LoadKey(updatedAt: model.localUpdatedAt, accountIDs: Set(model.accounts.map(\.id)))) {
            await load()
        }
    }

    private var subtitle: String? {
        guard let insights, insights.tradeCount > 0 else { return nil }
        return L10n.text("从你的 \(insights.tradeCount) 笔交易里找到的")
    }

    // MARK: Content

    @ViewBuilder
    private func content(_ insights: TradingInsights) -> some View {
        summaryTiles(insights)

        let extremes = extremeRows(insights)
        if !extremes.isEmpty {
            SettingsSection(L10n.text("最好与最差的一笔")) { ForEach(extremes) { InsightRowView(row: $0) } }
        }
        let securities = securityRows(insights)
        if !securities.isEmpty {
            SettingsSection(L10n.text("股票")) { ForEach(securities) { InsightRowView(row: $0) } }
        }
        let habits = habitRows(insights)
        if !habits.isEmpty {
            SettingsSection(L10n.text("持有习惯")) { ForEach(habits) { InsightRowView(row: $0) } }
        }
        let hindsight = hindsightRows(insights)
        if !hindsight.isEmpty {
            SettingsSection(L10n.text("事后看")) { ForEach(hindsight) { InsightRowView(row: $0) } }
        }
        let rhythm = rhythmRows(insights)
        if !rhythm.isEmpty {
            SettingsSection(L10n.text("交易节奏")) { ForEach(rhythm) { InsightRowView(row: $0) } }
        }
        let open = openPositionRows()
        if !open.isEmpty {
            SettingsSection(L10n.text("当前持仓")) { ForEach(open) { InsightRowView(row: $0) } }
        }
        SettingsFootnote(footnote(insights))
    }

    private func footnote(_ insights: TradingInsights) -> String {
        var lines = [L10n.text("卖出按同一账户内先买先卖（FIFO）配对买入，持有天数按每批股数加权。")]
        if insights.hasEstimates {
            lines.append(L10n.text("券商没有给出结果的卖出，盈亏按导入的买入成本估算，并按当前汇率换算。"))
        }
        return lines.joined(separator: " ")
    }

    private func summaryTiles(_ insights: TradingInsights) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: SettingsTemplate.tileSpacing), count: 2),
                  spacing: SettingsTemplate.tileSpacing) {
            InsightTile(
                title: L10n.text("胜率"),
                value: insights.winRate.map { DisplayFormat.percent($0 * 100, signed: false) } ?? "—",
                caption: L10n.text("\(insights.wins.count) 胜 \(insights.losses.count) 负"))
            InsightTile(
                title: L10n.text("盈亏比"),
                value: insights.payoffRatio.map { String(format: "%.2f×", $0) } ?? "—",
                caption: insights.payoffRatio.map { ratio in
                    ratio >= 1 ? L10n.text("赚的时候比亏的时候多") : L10n.text("亏的时候比赚的时候多")
                } ?? L10n.text("需要有赚有亏"))
            InsightTile(
                title: L10n.text("平均持有"),
                value: insights.averageHoldingDays.map(days) ?? "—",
                caption: L10n.text("\(insights.trades.count) 次卖出"))
            InsightTile(
                title: L10n.text("交易"),
                value: L10n.text("\(insights.tradeCount) 笔"),
                caption: L10n.text("买入 \(insights.buyCount) · 卖出 \(insights.sellCount)"))
        }
    }

    private func extremeRows(_ insights: TradingInsights) -> [InsightRow] {
        var rows: [InsightRow] = []
        if let trade = insights.bestTrade, let profit = trade.profitUSD {
            rows.append(tradeRow("best", label: L10n.text("赚得最多的一笔"), trade: trade, value: money(profit, signed: true),
                                 tone: .positive))
        }
        if let trade = insights.bestReturn, let percent = trade.returnPercent {
            rows.append(tradeRow("best-return", label: L10n.text("回报率最高的一笔"), trade: trade,
                                 value: DisplayFormat.percent(percent), tone: .positive))
        }
        if let trade = insights.worstTrade, let profit = trade.profitUSD {
            rows.append(tradeRow("worst", label: L10n.text("亏得最多的一笔"), trade: trade, value: money(profit, signed: true),
                                 tone: .negative))
        }
        if let trade = insights.worstReturn, let percent = trade.returnPercent {
            rows.append(tradeRow("worst-return", label: L10n.text("亏损比例最高的一笔"), trade: trade,
                                 value: DisplayFormat.percent(percent), tone: .negative))
        }
        return rows
    }

    private func securityRows(_ insights: TradingInsights) -> [InsightRow] {
        var rows: [InsightRow] = []
        if let best = insights.bestSecurity {
            rows.append(InsightRow(id: "best-security", label: L10n.text("最赚钱的股票"), ticker: best.ticker,
                                   title: name(best.ticker), detail: securityDetail(best),
                                   value: money(best.profitUSD, signed: true), tone: .positive))
        }
        if let worst = insights.worstSecurity {
            rows.append(InsightRow(id: "worst-security", label: L10n.text("最亏钱的股票"), ticker: worst.ticker,
                                   title: name(worst.ticker), detail: securityDetail(worst),
                                   value: money(worst.profitUSD, signed: true), tone: .negative))
        }
        if let traded = insights.mostTraded {
            rows.append(InsightRow(id: "most-traded", label: L10n.text("交易最多的股票"), ticker: traded.key,
                                   title: name(traded.key), detail: nil,
                                   value: L10n.text("\(traded.count) 笔"), tone: .neutral))
        }
        if let dividend = insights.topDividend {
            rows.append(InsightRow(id: "top-dividend", label: L10n.text("分红最多的股票"), ticker: dividend.ticker,
                                   title: name(dividend.ticker),
                                   detail: L10n.text("全部分红 \(money(insights.dividendTotalUSD, signed: false))"),
                                   value: money(dividend.usd, signed: false), tone: .positive))
        }
        return rows
    }

    private func habitRows(_ insights: TradingInsights) -> [InsightRow] {
        var rows: [InsightRow] = []
        if let trade = insights.longestHold, let held = trade.holdingDays {
            rows.append(tradeRow("longest", label: L10n.text("拿得最久的一笔"), trade: trade, value: days(held),
                                 tone: .neutral, showsHolding: false))
        }
        if let trade = insights.quickestRoundTrip, let held = trade.holdingDays,
           trade.id != insights.longestHold?.id {
            rows.append(tradeRow("quickest", label: L10n.text("进出最快的一笔"), trade: trade, value: days(held),
                                 tone: .neutral, showsHolding: false))
        }
        if let winners = insights.averageWinnerHoldingDays, let losers = insights.averageLoserHoldingDays {
            let verdict: String
            if losers > winners * 1.2 {
                verdict = L10n.text("亏损的股票拿得更久：可能在等回本")
            } else if winners > losers * 1.2 {
                verdict = L10n.text("赚钱的股票拿得更久：让利润奔跑")
            } else {
                verdict = L10n.text("赚钱和亏钱的股票拿得差不多久")
            }
            rows.append(InsightRow(id: "holding-split", label: L10n.text("赚钱 vs 亏钱的持有时长"), ticker: nil,
                                   title: verdict,
                                   detail: L10n.text("盈利平均 \(days(winners)) · 亏损平均 \(days(losers))"),
                                   value: nil, tone: .neutral))
        }
        if insights.longestWinStreak >= 2 || insights.longestLossStreak >= 2 {
            rows.append(InsightRow(id: "streaks", label: L10n.text("最长连胜"), ticker: nil,
                                   title: L10n.text("连续 \(insights.longestWinStreak) 次卖出赚钱"),
                                   detail: L10n.text("最长连败 \(insights.longestLossStreak) 次"),
                                   value: nil, tone: .neutral))
        }
        return rows
    }

    private func hindsightRows(_ insights: TradingInsights) -> [InsightRow] {
        var rows: [InsightRow] = []
        if let early = insights.soldTooEarly {
            rows.append(InsightRow(id: "sold-early", label: L10n.text("卖早了"), ticker: early.ticker,
                                   title: name(early.ticker),
                                   detail: L10n.text("\(date(early.saleDate)) 以 \(price(early.salePrice, early.currency)) 卖出，现在 \(price(early.currentPrice, early.currency))"),
                                   value: DisplayFormat.percent(early.changePercent), tone: .positive))
        }
        if let escape = insights.soldJustInTime {
            rows.append(InsightRow(id: "sold-in-time", label: L10n.text("躲过一劫"), ticker: escape.ticker,
                                   title: name(escape.ticker),
                                   detail: L10n.text("\(date(escape.saleDate)) 以 \(price(escape.salePrice, escape.currency)) 卖出，现在 \(price(escape.currentPrice, escape.currency))"),
                                   value: DisplayFormat.percent(escape.changePercent), tone: .negative))
        }
        return rows
    }

    private func rhythmRows(_ insights: TradingInsights) -> [InsightRow] {
        var rows: [InsightRow] = []
        if let first = insights.firstTrade {
            let since = TradingInsights.days(from: first.date, to: Self.today) ?? 0
            rows.append(InsightRow(id: "first", label: L10n.text("第一笔交易"), ticker: first.ticker,
                                   title: name(first.ticker),
                                   detail: L10n.text("\(date(first.date)) · 已经投资 \(days(since))"),
                                   value: nil, tone: .neutral))
        }
        if let busiest = insights.busiestDay {
            rows.append(InsightRow(id: "busiest-day", label: L10n.text("最忙的一天"), ticker: nil,
                                   title: date(busiest.key), detail: nil,
                                   value: L10n.text("\(busiest.count) 笔"), tone: .neutral))
        }
        if let month = insights.busiestMonth {
            rows.append(InsightRow(id: "busiest-month", label: L10n.text("最活跃的月份"), ticker: nil,
                                   title: monthTitle(month.key), detail: nil,
                                   value: L10n.text("\(month.count) 笔"), tone: .neutral))
        }
        if let weekday = insights.favouriteWeekday {
            rows.append(InsightRow(id: "weekday", label: L10n.text("最常下单的日子"), ticker: nil,
                                   title: weekdayName(weekday), detail: nil,
                                   value: L10n.text("\(insights.weekdayCounts[weekday - 1]) 笔"), tone: .neutral))
        }
        if let buy = insights.largestBuy {
            rows.append(InsightRow(id: "largest-buy", label: L10n.text("最大的一笔买入"), ticker: buy.ticker,
                                   title: name(buy.ticker), detail: date(buy.date),
                                   value: money(buy.usd, signed: false), tone: .neutral))
        }
        if insights.dipBuyCount > 0 {
            rows.append(InsightRow(id: "dip-buys", label: L10n.text("越跌越买"), ticker: insights.mostDipBought?.key,
                                   title: insights.mostDipBought.map { name($0.key) } ?? L10n.text("逢低加仓"),
                                   detail: L10n.text("比上一次买入便宜 10% 以上又买"),
                                   value: L10n.text("\(insights.dipBuyCount) 次"), tone: .neutral))
        }
        return rows
    }

    private func openPositionRows() -> [InsightRow] {
        let open = holdings.filter { $0.shares > 0 && $0.unrealizedPercent.isFinite && $0.publicDisclosure == nil }
        var rows: [InsightRow] = []
        if let best = open.max(by: { $0.unrealizedPercent < $1.unrealizedPercent }), best.unrealizedPercent > 0 {
            rows.append(InsightRow(id: "open-best", label: L10n.text("浮盈最多"), ticker: best.ticker,
                                   logoSymbol: best.logoSymbol, title: best.shortName,
                                   detail: money(best.unrealized, signed: true),
                                   value: DisplayFormat.percent(best.unrealizedPercent), tone: .positive))
        }
        if let worst = open.min(by: { $0.unrealizedPercent < $1.unrealizedPercent }), worst.unrealizedPercent < 0 {
            rows.append(InsightRow(id: "open-worst", label: L10n.text("浮亏最深"), ticker: worst.ticker,
                                   logoSymbol: worst.logoSymbol, title: worst.shortName,
                                   detail: money(worst.unrealized, signed: true),
                                   value: DisplayFormat.percent(worst.unrealizedPercent), tone: .negative))
        }
        return rows
    }

    // MARK: Pieces

    private func tradeRow(_ id: String, label: String, trade: InsightClosedTrade, value: String,
                          tone: InsightRow.Tone, showsHolding: Bool = true) -> InsightRow {
        var parts = [L10n.text("\(date(trade.saleDate)) 卖出")]
        if showsHolding, let held = trade.holdingDays { parts.append(L10n.text("持有 \(days(held))")) }
        if let first = trade.firstBuyDate, !showsHolding { parts.insert(L10n.text("\(date(first)) 买入"), at: 0) }
        return InsightRow(id: id, label: label, ticker: trade.ticker, title: name(trade.ticker),
                          detail: parts.joined(separator: " · "), value: value, tone: tone)
    }

    private func securityDetail(_ result: TradingInsights.SecurityResult) -> String {
        let sales = L10n.text("\(result.saleCount) 次卖出")
        guard let percent = result.returnPercent else { return sales }
        return "\(sales) · \(DisplayFormat.percent(percent))"
    }

    private func name(_ ticker: String) -> String {
        holdings.first { $0.ticker.uppercased() == ticker }?.shortName ?? names[ticker] ?? ticker
    }

    private var currency: DisplayCurrency { DisplayCurrency(rawValue: displayCurrency) ?? .usd }

    private func money(_ usd: Double, signed: Bool) -> String {
        DisplayFormat.money(currency.fromUSD(usd), currency: currency.rawValue, signed: signed, fractionDigits: 2)
    }

    private func price(_ value: Double, _ currency: String) -> String {
        DisplayFormat.money(value, currency: currency, fractionDigits: 2)
    }

    private func days(_ value: Double) -> String {
        L10n.text("\(Int(value.rounded())) 天")
    }

    private static let utc = TimeZone(identifier: "UTC") ?? .current

    private static var today: String {
        Date().formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day())
    }

    private func date(_ text: String) -> String {
        guard let value = TradingInsights.date(text) else { return text }
        var style = Date.FormatStyle(date: .abbreviated, time: .omitted)
        style.locale = locale
        style.timeZone = Self.utc
        return value.formatted(style)
    }

    private func monthTitle(_ text: String) -> String {
        guard let value = TradingInsights.date(text + "-01") else { return text }
        var style = Date.FormatStyle().year().month(.wide)
        style.locale = locale
        style.timeZone = Self.utc
        return value.formatted(style)
    }

    private func weekdayName(_ weekday: Int) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        let symbols = calendar.weekdaySymbols
        return symbols.indices.contains(weekday - 1) ? symbols[weekday - 1] : ""
    }

    // MARK: Load

    @MainActor
    private func load() async {
        failed = false
        do {
            let ledger = try await model.activityLedger()
            let accountIDs = Set(ledger.accounts.map(\.id))
            let transactions = ledger.transactions.filter { accountIDs.contains($0.accountKey) }
            let positions = (try? await model.holdings(forAccounts: accountIDs)) ?? []
            try Task.checkCancellation()
            var quotes: [String: TradingInsights.Quote] = [:]
            for holding in positions where holding.shares > 0 && holding.quotePrice > 0 {
                guard let currency = holding.quoteCurrency else { continue }
                quotes[holding.ticker.uppercased()] = .init(price: holding.quotePrice, currency: currency)
            }
            let built = await Task.detached(priority: .userInitiated) {
                TradingInsights.build(transactions: transactions, quotes: quotes)
            }.value
            try Task.checkCancellation()
            names = Dictionary(ledger.securityNames.map { ($0.key.uppercased(), $0.value) },
                               uniquingKeysWith: { first, _ in first })
            holdings = positions
            insights = built
        } catch {
            guard !Task.isCancelled else { return }
            failed = true
        }
    }
}

/// One finding: what it is, about which security, and its figure.
struct InsightRow: Identifiable {
    enum Tone { case positive, negative, neutral }

    let id: String
    let label: String
    let ticker: String?
    var logoSymbol: String?
    let title: String
    let detail: String?
    let value: String?
    let tone: Tone

    init(id: String, label: String, ticker: String?, logoSymbol: String? = nil, title: String,
         detail: String?, value: String?, tone: Tone) {
        self.id = id
        self.label = label
        self.ticker = ticker
        self.logoSymbol = logoSymbol
        self.title = title
        self.detail = detail
        self.value = value
        self.tone = tone
    }
}

private struct InsightRowView: View {
    let row: InsightRow

    private var valueColor: Color {
        switch row.tone {
        case .positive: CatfolioTheme.positive
        case .negative: CatfolioTheme.danger
        case .neutral: CatfolioTheme.primaryText
        }
    }

    var body: some View {
        SettingsRowContainer {
            HStack(alignment: .center, spacing: SettingsTemplate.iconSpacing) {
                if let ticker = row.ticker {
                    AssetLogo(ticker: ticker, logoSymbol: row.logoSymbol, size: 36, cornerRadius: 10)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.label)
                        .appText(.caption, weight: .medium)
                        .foregroundStyle(SettingsTemplate.secondaryText)
                    Text(row.title)
                        .appText(.body, weight: .semibold)
                        .foregroundStyle(CatfolioTheme.primaryText)
                        .lineLimit(2)
                    if let detail = row.detail {
                        Text(detail)
                            .appText(.caption)
                            .foregroundStyle(SettingsTemplate.subtitleText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let value = row.value {
                    Text(value)
                        .appNumber(.callout, weight: .semibold)
                        .foregroundStyle(valueColor)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A headline figure, in the same card as every settings row.
private struct InsightTile: View {
    let title: String
    let value: String
    let caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .appText(.caption, weight: .semibold)
                .foregroundStyle(SettingsTemplate.secondaryText)
            Text(value)
                .font(Typography.number(size: 24, weight: .semibold))
                .foregroundStyle(CatfolioTheme.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(caption)
                .appText(.caption)
                .foregroundStyle(SettingsTemplate.subtitleText)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
        .settingsCardSurface()
        .accessibilityElement(children: .combine)
    }
}
