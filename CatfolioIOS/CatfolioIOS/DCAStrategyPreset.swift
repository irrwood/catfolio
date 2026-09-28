import Foundation

/// Educational examples inspired by the article; numerical rules are Catfolio
/// examples, not thresholds or recommendations supplied by the publisher.
enum DCAStrategyPreset: String, CaseIterable, Identifiable {
    case fixed, modestDip, tieredDip
    var id: String { rawValue }
    static let sourceURL = URL(string: "https://www.etoro.com/zh/investing/recurring-investment-strategies/")!

    var title: String {
        switch self {
        case .fixed: L10n.text("固定金额")
        case .modestDip: L10n.text("回撤时小幅加投")
        case .tieredDip: L10n.text("分档加投")
        }
    }
    var detail: String {
        switch self {
        case .fixed: L10n.text("每期投入基础金额，不根据价格调整。")
        case .modestDip: L10n.text("距近 252 个交易日高点回撤达到 10% 时投入 1.5×，其余投入 1×。")
        case .tieredDip: L10n.text("距近 252 个交易日高点回撤达到 20% 时投入 2×；达到 10% 时投入 1.5×；其余投入 1×。")
        }
    }
    var plan: DCAConditionPlan? {
        switch self {
        case .fixed: nil
        case .modestDip:
            DCAConditionPlan(sourceText: detail, rules: [rule(threshold: -10, multiplier: 1.5)])
        case .tieredDip:
            // First matching rule wins: evaluate the deepest drawdown first.
            DCAConditionPlan(sourceText: detail, rules: [rule(threshold: -20, multiplier: 2),
                                                        rule(threshold: -10, multiplier: 1.5)])
        }
    }
    func matches(_ current: DCAConditionPlan?) -> Bool {
        guard let plan else { return current?.hasEffect != true }
        return current?.rules == plan.rules && current?.fallbackMultiplier == plan.fallbackMultiplier
    }
    private func rule(threshold: Double, multiplier: Double) -> DCAConditionRule {
        .init(id: "preset-\(rawValue)-\(Int(-threshold))", enabled: true, join: .all,
              conditions: [.init(metric: .drawdown, window: 252, comparison: .lte, threshold: threshold)],
              multiplier: multiplier)
    }
}
