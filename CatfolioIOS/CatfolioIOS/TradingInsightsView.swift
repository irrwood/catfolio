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
        InsightPersonaCard(title: L10n.text("你的交易人格"), labels: insights.personas.map(personaTitle),
                           lines: personaLines(insights))

        section(L10n.text("盈利与亏损"), profitRows(insights))
        section(L10n.text("时间与行为"), timeRows(insights))
        section(L10n.text("仓位与风险"), riskRows(insights))
        section(L10n.text("如果当初……"), whatIfRows(insights))
        section(L10n.text("投资生涯"), careerRows(insights))
        section(L10n.text("当前持仓"), openPositionRows())
        SettingsFootnote(footnote(insights))
    }

    @ViewBuilder
    private func section(_ title: String, _ rows: [InsightRow]) -> some View {
        if !rows.isEmpty {
            SettingsSection(title) { ForEach(rows) { InsightRowView(row: $0) } }
        }
    }

    private func footnote(_ insights: TradingInsights) -> String {
        var lines = [L10n.text("卖出按同一账户内先买先卖（FIFO）配对买入，持有天数按每批股数加权。")]
        if insights.hasEstimates {
            lines.append(L10n.text("券商没有给出结果的卖出，盈亏按导入的买入成本估算，并按当前汇率换算。"))
        }
        lines.append(L10n.text("“之后走势”只比较你仍持有的股票的今日价格；“如果当初”是模拟，不是真实收益。"))
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

    // MARK: Persona

    private func personaTitle(_ persona: TradingInsights.Persona) -> String {
        switch persona {
        case .sniper: L10n.text("狙击手")
        case .longHolder: L10n.text("长期持有者")
        case .letsWinnersRun: L10n.text("让利润奔跑")
        case .waitsToBreakEven: L10n.text("回本等待者")
        case .dipHunter: L10n.text("抄底猎手")
        case .trendFollower: L10n.text("趋势追随者")
        case .rapidTrier: L10n.text("高频试错者")
        case .explorer: L10n.text("稳健探索者")
        }
    }

    private func personaLines(_ insights: TradingInsights) -> [String] {
        var lines: [String] = []
        var signs: [String] = []
        if let day = insights.impulsiveWeekday { signs.append(L10n.text("\(shortWeekday(day))冲动型")) }
        if let day = insights.cuttingWeekday { signs.append(L10n.text("\(shortWeekday(day))割肉型")) }
        if !signs.isEmpty { lines.append(L10n.text("投资星座：\(signs.joined(separator: L10n.listSeparator))")) }
        let words = self.keywords(insights)
        if !words.isEmpty { lines.append(L10n.text("关键词：\(words.joined(separator: " · "))")) }
        return lines
    }

    /// Five words for the reader's trading: the latest year's most traded
    /// securities, then the habits that stand out.
    private func keywords(_ insights: TradingInsights) -> [String] {
        var words = insights.keywordTickers
        if let persona = insights.personas.first, persona != .explorer { words.append(personaTitle(persona)) }
        if insights.chaseBuyCount >= 2 { words.append(L10n.text("追高")) }
        if insights.dipBuyCount >= 2 { words.append(L10n.text("抄底")) }
        if let loss = insights.averageLossReturn, loss <= -20 { words.append(L10n.text("止损太晚")) }
        if insights.revengeBuyCount >= 2 { words.append(L10n.text("报复性交易")) }
        if let held = insights.averageHoldingDays {
            if held >= 90 { words.append(L10n.text("拿得住")) }
            if held <= 14 { words.append(L10n.text("快进快出")) }
        }
        return Array(words.prefix(5))
    }

    // MARK: Profit and loss

    private func profitRows(_ insights: TradingInsights) -> [InsightRow] {
        var rows: [InsightRow] = []
        if let trade = insights.bestTrade, let profit = trade.profitUSD {
            rows.append(tradeRow("best", label: L10n.text("最大单笔盈利"), trade: trade,
                                 value: money(profit, signed: true), tone: .positive, showsShare: true))
        }
        if let trade = insights.worstTrade, let profit = trade.profitUSD {
            rows.append(tradeRow("worst", label: L10n.text("最大单笔亏损"), trade: trade,
                                 value: money(profit, signed: true), tone: .negative, showsShare: true))
        }
        if let trade = insights.bestReturn, let percent = trade.returnPercent {
            rows.append(tradeRow("best-return", label: L10n.text("回报率最高的一笔"), trade: trade,
                                 value: DisplayFormat.percent(percent), tone: .positive))
        }
        if let trade = insights.worstReturn, let percent = trade.returnPercent {
            rows.append(tradeRow("worst-return", label: L10n.text("亏损比例最高的一笔"), trade: trade,
                                 value: DisplayFormat.percent(percent), tone: .negative))
        }
        if let leader = insights.mostAccurateSecurity, let rate = leader.winRate {
            var detail = L10n.text("\(leader.winCount + leader.lossCount) 次卖出，\(leader.winCount) 次赚钱")
            if let average = leader.averageReturn { detail += " · " + L10n.text("平均 \(DisplayFormat.percent(average))") }
            rows.append(InsightRow(id: "accuracy", label: L10n.text("胜率最高的标的"), ticker: leader.ticker,
                                   title: name(leader.ticker), detail: detail,
                                   value: DisplayFormat.percent(rate * 100, signed: false), tone: .positive))
        }
        if let buyer = insights.bestBuyer, let after = buyer.averageAfterBuy {
            rows.append(InsightRow(id: "best-buyer", label: L10n.text("最会买的股票"), ticker: buyer.ticker,
                                   title: name(buyer.ticker),
                                   detail: L10n.text("\(buyer.afterBuys.count) 次买入，平均买入后至今"),
                                   value: DisplayFormat.percent(after), tone: .positive))
        }
        if let seller = insights.bestSeller, let after = seller.averageAfterSale {
            rows.append(InsightRow(id: "best-seller", label: L10n.text("最会卖的股票"), ticker: seller.ticker,
                                   title: name(seller.ticker),
                                   detail: L10n.text("卖出后至今的平均走势"),
                                   value: DisplayFormat.percent(after), tone: .positive))
        }
        if let afterBuy = insights.averageAfterBuy, let afterSale = insights.averageAfterSale {
            let verdict: String
            if afterBuy > 0, afterSale > 0 {
                verdict = L10n.text("你买得很准，但总卖太早")
            } else if afterBuy > 0, afterSale <= 0 {
                verdict = L10n.text("买得准，也卖得好")
            } else if afterSale <= 0 {
                verdict = L10n.text("卖得比买得好")
            } else {
                verdict = L10n.text("买入和卖出的时机都还有空间")
            }
            rows.append(InsightRow(id: "timing", label: L10n.text("买卖时机"), ticker: nil, title: verdict,
                                   detail: L10n.text("买入后平均 \(DisplayFormat.percent(afterBuy)) · 卖出后平均 \(DisplayFormat.percent(afterSale))"),
                                   value: nil, tone: .neutral))
        }
        if let trade = insights.comebackTrade, let percent = trade.returnPercent {
            rows.append(tradeRow("comeback", label: L10n.text("回本王"), trade: trade,
                                 value: DisplayFormat.percent(percent), tone: .positive,
                                 note: L10n.text("跌了还加仓，最后赚钱离场")))
        }
        if let first = insights.neverRecovered.first {
            let others = insights.neverRecovered.dropFirst().prefix(2).map { name($0.ticker) }
            rows.append(InsightRow(id: "never-recovered", label: L10n.text("永远没回本"), ticker: first.ticker,
                                   title: name(first.ticker),
                                   detail: others.isEmpty
                                       ? L10n.text("\(first.lossCount) 次卖出全部亏损")
                                       : L10n.text("还有 \(others.joined(separator: L10n.listSeparator))"),
                                   value: money(first.profitUSD, signed: true), tone: .negative))
        }
        if let lossCut = insights.averageLossReturn {
            let gain = insights.averageWinReturn.map { DisplayFormat.percent($0) } ?? "—"
            var detail = L10n.text("盈利单平均在 \(gain) 卖出")
            if let winners = insights.averageWinnerHoldingDays, let losers = insights.averageLoserHoldingDays {
                detail += " · " + L10n.text("盈利拿 \(days(winners))，亏损拿 \(days(losers))")
            }
            let title: String
            if let winners = insights.averageWinnerHoldingDays, let losers = insights.averageLoserHoldingDays,
               losers > winners * 1.2 {
                title = L10n.text("拿住亏损、卖掉盈利：有处置效应")
            } else {
                title = L10n.text("平均亏多少止损")
            }
            rows.append(InsightRow(id: "cut-speed", label: L10n.text("割肉速度"), ticker: nil, title: title,
                                   detail: detail, value: DisplayFormat.percent(lossCut), tone: .negative))
        }
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
        if let nemesis = insights.nemesis, nemesis.ticker != insights.neverRecovered.first?.ticker {
            rows.append(InsightRow(id: "nemesis", label: L10n.text("你的专属对手盘"), ticker: nemesis.ticker,
                                   title: name(nemesis.ticker),
                                   detail: L10n.text("在它身上亏了 \(nemesis.lossCount) 次，赚了 \(nemesis.winCount) 次"),
                                   value: money(nemesis.profitUSD, signed: true), tone: .negative))
        }
        return rows
    }

    // MARK: Time and behaviour

    private func timeRows(_ insights: TradingInsights) -> [InsightRow] {
        var rows: [InsightRow] = []
        let weekdays = insights.openingWeekdays.filter { $0.averageReturn != nil }
        if weekdays.count >= 2,
           let best = weekdays.max(by: { ($0.averageReturn ?? 0) < ($1.averageReturn ?? 0) }),
           let worst = weekdays.min(by: { ($0.averageReturn ?? 0) < ($1.averageReturn ?? 0) }),
           let bestDay = Int(best.key), let worstDay = Int(worst.key) {
            rows.append(InsightRow(id: "lucky-day", label: L10n.text("你的幸运星期几"), ticker: nil,
                                   title: L10n.text("\(weekdayName(bestDay))开的仓表现最好"),
                                   detail: L10n.text("\(weekdayName(worstDay))开的仓平均 \(DisplayFormat.percent(worst.averageReturn ?? 0))，表现最差"),
                                   value: DisplayFormat.percent(best.averageReturn ?? 0), tone: .positive))
        }
        let sessions = insights.sessionParts.filter { $0.averageReturn != nil }
        if sessions.count >= 2,
           let best = sessions.max(by: { ($0.averageReturn ?? 0) < ($1.averageReturn ?? 0) }),
           let part = TradingInsights.SessionPart(rawValue: best.key) {
            let detail = sessions.map { bucket in
                "\(sessionTitle(TradingInsights.SessionPart(rawValue: bucket.key) ?? .other)) "
                    + DisplayFormat.percent((bucket.winRate ?? 0) * 100, signed: false)
            }.joined(separator: " · ")
            rows.append(InsightRow(id: "session", label: L10n.text("最佳交易时段"), ticker: nil,
                                   title: L10n.text("\(sessionTitle(part))开的仓最好"),
                                   detail: L10n.text("胜率：\(detail)"),
                                   value: DisplayFormat.percent(best.averageReturn ?? 0), tone: .positive))
        }
        if insights.chasingMonth != nil || insights.patientMonth != nil {
            var parts: [String] = []
            if let month = insights.chasingMonth { parts.append(L10n.text("\(monthName(month))你最爱追高")) }
            if let month = insights.patientMonth { parts.append(L10n.text("\(monthName(month))你最能拿住单")) }
            rows.append(InsightRow(id: "month-persona", label: L10n.text("月度人格"), ticker: nil,
                                   title: parts.joined(separator: L10n.clauseSeparator), detail: nil,
                                   value: nil, tone: .neutral))
        }
        let ranges = insights.holdingRanges
        if ranges.count >= 2 {
            let best = ranges.filter { $0.count >= 3 && $0.averageReturn != nil }
                .max { ($0.averageReturn ?? 0) < ($1.averageReturn ?? 0) }
            let detail = ranges.map { bucket in
                "\(rangeTitle(bucket.key)) \(bucket.count) " + L10n.text("笔") + " "
                    + DisplayFormat.percent((bucket.winRate ?? 0) * 100, signed: false)
            }.joined(separator: " · ")
            rows.append(InsightRow(id: "holding-ranges", label: L10n.text("持有期分析"), ticker: nil,
                                   title: best.map { L10n.text("最优持有区间：\(rangeTitle($0.key))") }
                                       ?? L10n.text("各持有期的胜率"),
                                   detail: detail,
                                   value: best?.averageReturn.map { DisplayFormat.percent($0) }, tone: .neutral))
        }
        if let short = insights.shortTermTrades {
            rows.append(InsightRow(id: "short-term", label: L10n.text("频繁交易税"), ticker: nil,
                                   title: L10n.text("持有不到一周的 \(short.count) 笔交易"),
                                   detail: L10n.text("胜率 \(DisplayFormat.percent((short.winRate ?? 0) * 100, signed: false))"),
                                   value: money(short.profitUSD, signed: true),
                                   tone: short.profitUSD >= 0 ? .positive : .negative))
        }
        var impulses: [String] = []
        if insights.quickFlipCount > 0 { impulses.append(L10n.text("3 天内买了又卖 \(insights.quickFlipCount) 次")) }
        if insights.revengeBuyCount > 0 { impulses.append(L10n.text("亏损卖出后一周内又买回 \(insights.revengeBuyCount) 次")) }
        if insights.chaseBuyCount > 0 { impulses.append(L10n.text("比上次贵 10% 以上还追 \(insights.chaseBuyCount) 次")) }
        if !impulses.isEmpty {
            rows.append(InsightRow(id: "impulse", label: L10n.text("冲动交易检测"), ticker: insights.revengeTicker,
                                   title: insights.revengeTicker.map { L10n.text("最常报复性买回：\(name($0))") }
                                       ?? L10n.text("这些可能是冲动之下的交易"),
                                   detail: impulses.joined(separator: " · "), value: nil, tone: .neutral))
        }
        if insights.longestWinStreak >= 2 || insights.longestLossStreak >= 2 {
            rows.append(InsightRow(id: "streaks", label: L10n.text("最长连胜"), ticker: nil,
                                   title: L10n.text("连续 \(insights.longestWinStreak) 次卖出赚钱"),
                                   detail: L10n.text("最长连败 \(insights.longestLossStreak) 次"),
                                   value: nil, tone: .neutral))
        }
        if let trade = insights.longestHold, let held = trade.holdingDays {
            rows.append(tradeRow("longest", label: L10n.text("拿得最久的一笔"), trade: trade, value: days(held),
                                 tone: .neutral, showsHolding: false))
        }
        if let trade = insights.quickestRoundTrip, let held = trade.holdingDays,
           trade.id != insights.longestHold?.id {
            rows.append(tradeRow("quickest", label: L10n.text("进出最快的一笔"), trade: trade, value: days(held),
                                 tone: .neutral, showsHolding: false))
        }
        return rows
    }

    // MARK: Size and risk

    private func riskRows(_ insights: TradingInsights) -> [InsightRow] {
        var rows: [InsightRow] = []
        if let split = insights.heavyTrades, let heavy = split.heavy.winRate, let rest = split.rest.winRate {
            let title = heavy > rest + 0.05 ? L10n.text("你重仓时更准")
                : heavy < rest - 0.05 ? L10n.text("你重仓时更慌") : L10n.text("重仓和平时差不多")
            rows.append(InsightRow(id: "heavy", label: L10n.text("重仓魔咒"), ticker: nil, title: title,
                                   detail: L10n.text("仓位最大的 5 笔胜率 \(DisplayFormat.percent(heavy * 100, signed: false))，其余 \(DisplayFormat.percent(rest * 100, signed: false))"),
                                   value: split.heavy.averageReturn.map { DisplayFormat.percent($0) },
                                   tone: (split.heavy.averageReturn ?? 0) >= 0 ? .positive : .negative))
        }
        if let trade = insights.smallPositionStar, let percent = trade.returnPercent {
            rows.append(tradeRow("small-star", label: L10n.text("小仓位奇迹"), trade: trade,
                                 value: DisplayFormat.percent(percent), tone: .positive,
                                 note: L10n.text("小仓位却赚得最多：这个想法也许值得更大权重")))
        }
        if let concentration = insights.lossConcentration {
            rows.append(InsightRow(id: "black-swan", label: L10n.text("黑天鹅贡献"), ticker: nil,
                                   title: L10n.text("\(concentration.count) 笔交易造成了你 \(DisplayFormat.percent(concentration.share * 100, signed: false)) 的已实现亏损"),
                                   detail: insights.worstTrade.map { L10n.text("最大的一笔是 \(name($0.ticker))") },
                                   value: nil, tone: .negative))
        }
        if let steady = insights.steadiestSecurity, let score = steady.steadiness {
            var detail = L10n.text("\(steady.saleCount) 次卖出")
            if let average = steady.averageReturn { detail += " · " + L10n.text("平均 \(DisplayFormat.percent(average))") }
            rows.append(InsightRow(id: "steady", label: L10n.text("风险调整赢家"), ticker: steady.ticker,
                                   title: name(steady.ticker),
                                   detail: detail + " · " + L10n.text("收益稳定度 \(String(format: "%.2f", score))"),
                                   value: nil, tone: .positive))
        }
        return rows
    }

    // MARK: What if

    private func whatIfRows(_ insights: TradingInsights) -> [InsightRow] {
        var rows: [InsightRow] = []
        if let saving = insights.stopLossSavingUSD {
            rows.append(InsightRow(id: "stop-loss", label: L10n.text("如果每笔亏损在 −10% 止损"), ticker: nil,
                                   title: L10n.text("已实现盈亏会从 \(money(insights.realisedUSD, signed: true)) 变成 \(money(insights.realisedUSD + saving, signed: true))"),
                                   detail: L10n.text("模拟，不是真实收益"),
                                   value: money(saving, signed: true), tone: .positive))
        }
        if let finger = insights.costliestSale {
            rows.append(InsightRow(id: "finger", label: L10n.text("最贵的一根手指"), ticker: finger.ticker,
                                   title: name(finger.ticker),
                                   detail: L10n.text("\(date(finger.saleDate)) 以 \(price(finger.salePrice, finger.currency)) 卖出，现在 \(price(finger.currentPrice, finger.currency))"),
                                   value: money(finger.missedUSD, signed: false), tone: .negative))
        }
        if let early = insights.soldTooEarly, early.ticker != insights.costliestSale?.ticker {
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

    // MARK: Career

    private func careerRows(_ insights: TradingInsights) -> [InsightRow] {
        var rows: [InsightRow] = []
        if let first = insights.firstTrade {
            let since = TradingInsights.days(from: first.date, to: Self.today) ?? 0
            rows.append(InsightRow(id: "first", label: L10n.text("交易年龄"), ticker: first.ticker,
                                   title: L10n.text("第一笔是 \(name(first.ticker))"),
                                   detail: L10n.text("\(date(first.date)) · 已经投资 \(days(since))"),
                                   value: L10n.text("\(insights.tradeCount) 笔"), tone: .neutral))
        }
        for milestone in insights.milestones {
            rows.append(InsightRow(id: "milestone-\(milestone.count)", label: L10n.text("里程碑"), ticker: nil,
                                   title: L10n.text("第 \(milestone.count) 笔交易"),
                                   detail: date(milestone.date), value: nil, tone: .neutral))
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
        if let traded = insights.mostTraded {
            rows.append(InsightRow(id: "most-traded", label: L10n.text("交易最多的股票"), ticker: traded.key,
                                   title: name(traded.key), detail: nil,
                                   value: L10n.text("\(traded.count) 笔"), tone: .neutral))
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
        if let dividend = insights.topDividend {
            rows.append(InsightRow(id: "top-dividend", label: L10n.text("分红最多的股票"), ticker: dividend.ticker,
                                   title: name(dividend.ticker),
                                   detail: L10n.text("全部分红 \(money(insights.dividendTotalUSD, signed: false))"),
                                   value: money(dividend.usd, signed: false), tone: .positive))
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
                          tone: InsightRow.Tone, showsHolding: Bool = true, showsShare: Bool = false,
                          note: String? = nil) -> InsightRow {
        var parts = [L10n.text("\(date(trade.saleDate)) 卖出")]
        if showsHolding, let held = trade.holdingDays { parts.append(L10n.text("持有 \(days(held))")) }
        if let first = trade.firstBuyDate, !showsHolding { parts.insert(L10n.text("\(date(first)) 买入"), at: 0) }
        if showsShare, let share = trade.bookShare {
            parts.append(L10n.text("占当时持仓成本 \(DisplayFormat.percent(share * 100, signed: false))"))
        }
        var detail = parts.joined(separator: " · ")
        if let note { detail = note + "\n" + detail }
        return InsightRow(id: id, label: label, ticker: trade.ticker, title: name(trade.ticker),
                          detail: detail, value: value, tone: tone)
    }

    private func shortWeekday(_ weekday: Int) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        let symbols = calendar.shortWeekdaySymbols
        return symbols.indices.contains(weekday - 1) ? symbols[weekday - 1] : ""
    }

    private func monthName(_ month: Int) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        let symbols = calendar.monthSymbols
        return symbols.indices.contains(month - 1) ? symbols[month - 1] : ""
    }

    private func sessionTitle(_ part: TradingInsights.SessionPart) -> String {
        switch part {
        case .open: L10n.text("开盘 30 分钟")
        case .midday: L10n.text("午盘")
        case .close: L10n.text("尾盘 30 分钟")
        case .other: L10n.text("其他时段")
        }
    }

    private func rangeTitle(_ key: String) -> String {
        switch TradingInsights.HoldingRange(rawValue: key) {
        case .day: L10n.text("1 天内")
        case .week: L10n.text("1 周内")
        case .month: L10n.text("1 月内")
        case .quarter: L10n.text("3 月内")
        case .longer: L10n.text("3 个月以上")
        case nil: key
        }
    }

    private func securityDetail(_ result: TradingInsights.SecurityResult) -> String {
        let sales = L10n.text("\(result.saleCount) 次卖出")
        guard let percent = result.returnPercent else { return sales }
        return "\(sales) · \(DisplayFormat.percent(percent))"
    }

    private func name(_ ticker: String) -> String {
        holdings.first { $0.ticker.uppercased() == ticker }?.shortName ?? names[ticker]
            // A security sold out has no holding to name it; the catalogue does.
            ?? CompanyNameCatalog.displayName(ticker: ticker, fallback: ticker)
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

            // Securities sold out have no live price. Fetch their latest close
            // so "what if" and after-sale timing include them too, then
            // recount; what is on screen stays up meanwhile.
            let missing = TradingInsights.tickersNeedingQuotes(transactions: transactions, quotes: quotes)
            guard !missing.isEmpty else { return }
            let end = Date()
            let closes = await LocalMarketDataClient().historicalCloses(
                symbols: Array(missing.keys),
                from: DayDateCodec.string(from: end.addingTimeInterval(-14 * 86_400)),
                to: DayDateCodec.string(from: end))
            try Task.checkCancellation()
            var completed = quotes
            for (ticker, currency) in missing {
                if let closes = closes[ticker],
                   let quote = TradingInsights.quote(fromCloses: closes, ticker: ticker, currency: currency) {
                    completed[ticker] = quote
                }
            }
            guard completed.count > quotes.count else { return }
            let recounted = await Task.detached(priority: .userInitiated) {
                TradingInsights.build(transactions: transactions, quotes: completed)
            }.value
            try Task.checkCancellation()
            insights = recounted
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

/// The page's opening card: the reader's trading persona, in a few labels,
/// with the star sign and keywords under it — the part worth sharing.
private struct InsightPersonaCard: View {
    let title: String
    let labels: [String]
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .appText(.caption, weight: .semibold)
                .foregroundStyle(SettingsTemplate.secondaryText)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { chips }
                VStack(alignment: .leading, spacing: 8) { chips }
            }
            ForEach(lines, id: \.self) { line in
                Text(line)
                    .appText(.label)
                    .foregroundStyle(CatfolioTheme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(SettingsTemplate.rowHorizontalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsCardSurface()
        .accessibilityElement(children: .combine)
    }

    private var chips: some View {
        ForEach(labels, id: \.self) { label in
            Text(label)
                .appText(.body, weight: .semibold)
                .foregroundStyle(CatfolioTheme.primaryText)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.primary.opacity(0.06), in: Capsule())
        }
    }
}
