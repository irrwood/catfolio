import SwiftUI

/// Cash-flow reports are actual filing periods. Keep their chronological order
/// independent of the order returned by a provider or an older cached response.
enum CashFlowPeriodSelection {
    static func preferredKind(in periods: [CashFlowStatementPeriod]) -> FinancialPeriodKind {
        periods.contains { $0.kind == .quarterly } ? .quarterly : .annual
    }

    static func periods(in periods: [CashFlowStatementPeriod], kind: FinancialPeriodKind) -> [CashFlowStatementPeriod] {
        periods.filter { $0.kind == kind && $0.operatingCashFlow.isFinite }
            .sorted { ($0.periodEnd, $0.filedDate ?? "") > ($1.periodEnd, $1.filedDate ?? "") }
    }
}

struct CashFlowRowPresentation: Identifiable {
    let id: String
    let title: String
    let value: Double?
    var isTotal = false
    var isBalance = false
}

struct CashFlowSectionPresentation: Identifiable {
    let id: String
    let rows: [CashFlowRowPresentation]
}

/// Financial line items retain their reported signs and missing disclosures.
struct CashFlowStatementPresentation {
    let period: CashFlowStatementPeriod

    var changeInCash: CashFlowRowPresentation {
        .init(id: "changeInCash", title: L10n.text("现金净变动"),
              value: period.details?.value(.changeInCash), isTotal: true)
    }

    var sections: [CashFlowSectionPresentation] {
        var result: [CashFlowSectionPresentation] = [
            .init(id: "operating", rows: [.init(id: "operating", title: L10n.text("经营现金流"), value: period.operatingCashFlow, isTotal: true)] + [
                detail(.netIncome, "净利润"),
                detail(.depreciationAndAmortization, "折旧与摊销"),
                detail(.deferredIncomeTaxes, "递延所得税"),
                detail(.stockBasedCompensation, "股权激励"),
                detail(.changeInWorkingCapital, "营运资本变动"),
                detail(.otherNonCashItems, "其他非现金项目"),
            ]),
            .init(id: "investing", rows: [.init(id: "investing", title: L10n.text("投资现金流"), value: period.investingCashFlow, isTotal: true)] + [
                .init(id: "capitalExpenditure", title: L10n.text("资本开支"), value: period.capitalExpenditure.map { -abs($0) }),
                detail(.acquisitions, "收购支出"),
                detail(.investmentPurchases, "购买投资"),
                detail(.investmentSalesAndMaturities, "出售及到期投资"),
                detail(.otherInvestingActivities, "其他投资活动"),
            ]),
            .init(id: "financing", rows: [.init(id: "financing", title: L10n.text("融资现金流"), value: period.financingCashFlow, isTotal: true)] + [
                detail(.debtIssued, "新增借款"),
                detail(.debtRepaid, "偿还借款"),
                detail(.dividendsPaid, "支付股息"),
                detail(.commonStockRepurchased, "回购普通股"),
                detail(.commonStockIssued, "发行普通股"),
                detail(.financeLeasePrincipalPayments, "融资租赁本金支付"),
                detail(.otherFinancingActivities, "其他融资活动"),
            ]),
            .init(id: "cash", rows: [
                .init(id: "exchangeRate", title: L10n.text("汇率变动影响"),
                      value: period.details?.value(.effectOfExchangeRates), isTotal: true),
                changeInCash,
                detail(.cashAtBeginningOfPeriod, "期初现金", isBalance: true),
                detail(.cashAtEndOfPeriod, "期末现金", isBalance: true),
            ]),
        ]
        var freeCashFlowRows: [CashFlowRowPresentation] = [
            .init(id: "baseFreeCashFlow", title: L10n.text("自由现金流"), value: period.freeCashFlow, isTotal: true),
            .init(id: "leaseAdjustedFreeCashFlow", title: L10n.text("融资租赁调整后自由现金流"),
                  value: period.leaseAdjustedFreeCashFlow, isTotal: true),
        ]
        if let sourceValue = period.details?.sourceFreeCashFlow, sourceValue.isFinite {
            freeCashFlowRows.append(.init(id: "sourceFreeCashFlow", title: L10n.text("数据源口径自由现金流"),
                                         value: sourceValue, isTotal: true))
        }
        result.append(.init(id: "freeCashFlow", rows: freeCashFlowRows))
        return result
    }

    func amount(_ value: Double?, signed: Bool = true) -> String {
        guard let value, value.isFinite else { return "—" }
        let formatted = DisplayFormat.compactMoney(value, currency: period.currency, precision: .statement)
        return signed && value > 0 ? "+\(formatted)" : formatted
    }

    private func detail(_ item: CashFlowLineItem, _ title: String, isBalance: Bool = false) -> CashFlowRowPresentation {
        let qualifier = period.details?.isPartial(item) == true ? L10n.text("（已披露项）") : ""
        let cashQualifier = isBalance && period.details?.cashIncludesRestrictedCash == true ? L10n.text("（含受限现金）") : ""
        return .init(id: item.rawValue, title: L10n.label(title) + cashQualifier + qualifier,
                     value: period.details?.value(item), isBalance: isBalance)
    }
}

struct CashFlowStatementRows: View {
    @Environment(\.locale) private var appLocale
    let period: CashFlowStatementPeriod

    var body: some View {
        let presentation = CashFlowStatementPresentation(period: period)
        VStack(alignment: .leading, spacing: 22) {
            ForEach(presentation.sections) { section in
                VStack(spacing: 0) {
                    ForEach(Array(section.rows.enumerated()), id: \.element.id) { index, row in
                        CashFlowValueRow(row: row, presentation: presentation,
                                         indented: !row.isTotal)
                            .padding(.vertical, row.isTotal ? 15 : 13)
                        if index < section.rows.count - 1 { Divider() }
                    }
                }
                .accessibilityIdentifier("cash-flow-section-\(section.id)")
            }
        }
    }
}

private struct CashFlowValueRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let row: CashFlowRowPresentation
    let presentation: CashFlowStatementPresentation
    let indented: Bool

    var body: some View {
        let amount = presentation.amount(row.value, signed: !row.isBalance)
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 12))
        layout {
            Text(row.title)
                .font(.subheadline.weight(row.isTotal ? .semibold : .regular))
                .foregroundStyle(row.isTotal ? .primary : .secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            FinancialText(amount)
                .appNumber(.subheading, weight: row.isTotal ? .semibold : .regular)
                .monospacedDigit()
                .fixedSize(horizontal: true, vertical: false)
                .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : nil, alignment: .trailing)
        }
        .padding(.leading, indented ? 16 : 0)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.title)
        .accessibilityValue(row.value?.isFinite == true ? amount : L10n.text("暂无数据"))
        .accessibilityIdentifier("cash-flow-row-\(row.id)")
    }
}
