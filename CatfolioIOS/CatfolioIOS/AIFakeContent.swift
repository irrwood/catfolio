import SwiftUI

enum FakeAIContent {
    private static let initialMessageID = UUID(uuidString: "D3A0D10A-7A5E-49A1-9AF4-020260904001")!

    static func initialHistory() -> LocalChatHistory {
        let message = ChatMessage(
            id: initialMessageID,
            role: .assistant,
            text: attentionReport.markdownFallback,
            createdAt: Calendar.current.date(byAdding: .minute, value: -8, to: Date()) ?? Date()
        )
        return LocalChatHistory(
            messages: [message],
            attentionReports: [message.id: attentionReport]
        )
    }

    static var attentionReport: PortfolioAttentionReport {
        PortfolioAttentionReport(
            generatedAt: Calendar.current.date(byAdding: .minute, value: -8, to: Date()) ?? Date(),
            holdingsCount: 15,
            noMaterialChangeCount: 12,
            attentionRows: [
                PortfolioAttentionHolding(
                    ticker: "ORCL",
                    name: "Oracle Corporation",
                    attention: .high,
                    weight: 0.087,
                    portfolioContributionPercent: 0.40,
                    return60DPercent: 12.6,
                    volumeMultiple: 1.9,
                    distanceFrom52WHighPercent: -2.8,
                    distanceFrom52WLowPercent: 41.2,
                    ma200PositionPercent: 18.4,
                    signals: [
                        PortfolioAttentionSignal(kind: "daily_move", label: L10n.text("+4.8% 单日涨幅"), direction: "positive", value: 4.8),
                        PortfolioAttentionSignal(kind: "volume", label: L10n.text("成交量 1.9×"), direction: "positive", value: 1.9),
                    ],
                    fundamentals: PortfolioFundamentalSnapshot(
                        source: L10n.text("演示财务数据"),
                        latestPeriod: "FY 2026 Q1",
                        revenueGrowthYoY: 8.7,
                        operatingIncomeGrowthYoY: 11.2,
                        freeCashFlowGrowthYoY: 6.4
                    ),
                    thesis: PortfolioAttentionThesis(
                        stance: .strengthening,
                        basis: .price,
                        confidence: .high,
                        whatChanged: L10n.text("演示行情显示股价放量上行，并接近模拟的 52 周高位。"),
                        whyItMatters: L10n.text("ORCL 是演示组合中权重较高的科技持仓，短期动量增强会明显影响组合表现。"),
                        supportingEvidence: [L10n.text("60 日模拟收益为 +12.6%"), L10n.text("价格位于模拟 200 日均线之上 18.4%")],
                        counterEvidence: [L10n.text("接近阶段高位后，短线波动可能放大")],
                        risks: [L10n.text("估值扩张速度快于演示盈利增速")],
                        watchNext: [L10n.text("观察后续成交量能否维持"), L10n.text("关注回撤是否跌破短期趋势")],
                        riskFlags: []
                    ),
                    sources: []
                ),
                PortfolioAttentionHolding(
                    ticker: "ASML.AS",
                    name: "ASML Holding N.V.",
                    attention: .medium,
                    weight: 0.070,
                    portfolioContributionPercent: -0.15,
                    return60DPercent: -4.2,
                    volumeMultiple: 1.4,
                    distanceFrom52WHighPercent: -12.4,
                    distanceFrom52WLowPercent: 24.8,
                    ma200PositionPercent: 3.1,
                    signals: [
                        PortfolioAttentionSignal(kind: "pullback", label: L10n.text("距高点 -12.4%"), direction: "negative", value: -12.4),
                        PortfolioAttentionSignal(kind: "trend", label: L10n.text("仍高于 200 日线"), direction: "positive", value: 3.1),
                    ],
                    fundamentals: nil,
                    thesis: PortfolioAttentionThesis(
                        stance: .maintaining,
                        basis: .company,
                        confidence: .medium,
                        whatChanged: L10n.text("演示价格自阶段高位回落，但长期趋势尚未破坏。"),
                        whyItMatters: L10n.text("这类高波动半导体设备持仓容易放大组合的科技周期风险。"),
                        supportingEvidence: [L10n.text("模拟价格仍在 200 日均线上方"), L10n.text("仓位权重控制在 5%以内")],
                        counterEvidence: [L10n.text("60 日模拟收益仍为负值")],
                        risks: [L10n.text("行业资本开支周期可能带来进一步波动")],
                        watchNext: [L10n.text("观察 200 日均线支撑"), L10n.text("关注半导体板块相对强弱")],
                        riskFlags: []
                    ),
                    sources: []
                ),
                PortfolioAttentionHolding(
                    ticker: "UBER",
                    name: "Uber Technologies, Inc.",
                    attention: .medium,
                    weight: 0.035,
                    portfolioContributionPercent: -0.26,
                    return60DPercent: 5.8,
                    volumeMultiple: 1.6,
                    distanceFrom52WHighPercent: -7.5,
                    distanceFrom52WLowPercent: 33.6,
                    ma200PositionPercent: 9.7,
                    signals: [
                        PortfolioAttentionSignal(kind: "daily_drop", label: L10n.text("-5.6% 单日回撤"), direction: "negative", value: -5.6),
                        PortfolioAttentionSignal(kind: "elevated_volume", label: L10n.text("成交量 1.6×"), direction: "negative", value: 1.6),
                    ],
                    fundamentals: nil,
                    thesis: PortfolioAttentionThesis(
                        stance: .maintaining,
                        basis: .company,
                        confidence: .medium,
                        whatChanged: L10n.text("演示行情出现放量回撤，但中期累计表现仍为正。"),
                        whyItMatters: L10n.text("单日波动与成交量同时放大，值得确认这是短期获利回吐还是趋势转弱。"),
                        supportingEvidence: [L10n.text("60 日模拟收益仍为 +5.8%"), L10n.text("价格仍高于模拟 200 日均线")],
                        counterEvidence: [L10n.text("单日跌幅显著高于组合其他持仓")],
                        risks: [L10n.text("高波动成长股可能继续拖累短期收益")],
                        watchNext: [L10n.text("观察未来三个交易日能否收复跌幅"), L10n.text("关注成交量是否恢复正常")],
                        riskFlags: []
                    ),
                    sources: []
                ),
            ],
            warnings: [L10n.text("以上卡片为假数据模式的演示分析，不代表实时行情或投资建议。")]
        )
    }

    /// What the sample model "thinks" before it answers.
    static func reasoning(for question: String) -> String {
        L10n.text("先看问题问的是什么，再对照组合里权重最高的几只持仓。示例组合集中在科技和半导体，前五大持仓占了一半以上，所以回答要先说集中度，再说近期表现。")
            + "\n\n" + L10n.text("数字都来自 Catfolio 的组合摘要，这里只负责解释，不重新计算，最后提醒这不是投资建议。")
    }

    /// Text cut into the uneven pieces a model streams in.
    static func pieces(of text: String) -> [String] {
        var pieces: [String] = []
        var rest = Substring(text)
        var size = 2
        while !rest.isEmpty {
            let piece = rest.prefix(size)
            pieces.append(String(piece))
            rest = rest.dropFirst(piece.count)
            size = size % 5 + 2
        }
        return pieces
    }

    static func answer(to question: String) -> String {
        let normalized = question.lowercased()
        if normalized.contains("集中") || normalized.contains("风险") || normalized.contains("concentration") || normalized.contains("risk") {
            return [
                L10n.text("## 演示组合风险摘要"),
                L10n.text("- **指数重叠：** VOO、VUAG 与 EQQQ 的大型科技敞口存在部分重叠。"),
                L10n.text("- **科技周期：** ORCL、AMD 与 ASML 合计形成较明显的成长风格暴露。"),
                L10n.text("- **汇率波动：** 演示账户同时包含 USD、GBP、EUR、HKD、JPY 与 SGD 资产。"),
                L10n.text("> 以上内容完全由独立假数据生成，不包含你的真实持仓。")
            ].joined(separator: "\n\n")
        }
        if normalized.contains("表现") || normalized.contains("收益") || normalized.contains("performance") || normalized.contains("return") {
            return [
                L10n.text("## 近期表现（演示）"),
                L10n.text("ORCL 与 COST 是近期主要的模拟收益来源；UBER 和 ASML 的回撤形成部分抵消。组合仍保持正收益，但短期波动有所抬升。"),
                L10n.text("> 这是演示结论，不代表实时市场数据。")
            ].joined(separator: "\n\n")
        }
        return [
                L10n.text("## 假数据模式"),
                L10n.text("当前回答基于 Trading 212、Moomoo 与 IBKR 三个独立演示账户。可以继续询问组合风险、集中度或近期表现；所有数字和结论均为合成内容。")
            ].joined(separator: "\n\n")
    }
}
