import SwiftUI

struct CompanyFinancialsView: View {
    private enum Statement: String, CaseIterable, Identifiable {
        case income = "利润表"
        case balance = "资产负债表"
        case cashFlow = "现金流"

        var id: String { rawValue }
    }

    let ticker: String
    let companyName: String

    @State private var statement: Statement = .income
    @State private var periodKind: FinancialPeriodKind = .annual
    @State private var selectedPeriodEnd: String?
    @State private var financials: CompanyFinancialsData?
    @State private var errorMessage: String?
    @State private var isLoading = false

    init(holding: Holding) {
        ticker = holding.ticker
        companyName = holding.shortName
    }

    static func supports(_ holding: Holding) -> Bool {
        let searchable = "\(holding.ticker) \(holding.displayName)".uppercased()
        let exclusions = [" ETF", "UCITS", "FUND", "INDEX", " ETF "]
        return !exclusions.contains(where: searchable.contains)
            && holding.ticker.rangeOfCharacter(from: .letters) != nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                statementSelector

                if isLoading, financials == nil {
                    loadingState
                } else if let financials {
                    statementContent(financials)
                    sourceFooter(financials)
                } else {
                    emptyState
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 40)
        }
        .background(Color(uiColor: .systemBackground))
        .navigationTitle("财务 · \(ticker)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .refreshable { await load(forceRefresh: true) }
        .task { await load(forceRefresh: false) }
        .onChange(of: statement) { _, _ in selectedPeriodEnd = nil }
        .onChange(of: periodKind) { _, _ in selectedPeriodEnd = nil }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(companyName)
                .font(.title2.weight(.bold))
            Text("\(ticker) · SEC 原始申报数据")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
    }

    private var statementSelector: some View {
        VStack(spacing: 14) {
            HStack(spacing: 0) {
                ForEach(Statement.allCases) { item in
                    Button {
                        withAnimation(.easeOut(duration: 0.18)) { statement = item }
                    } label: {
                        VStack(spacing: 9) {
                            Text(item.rawValue)
                                .font(.subheadline.weight(statement == item ? .semibold : .regular))
                                .foregroundStyle(statement == item ? .primary : .secondary)
                                .frame(maxWidth: .infinity)
                            Capsule()
                                .fill(statement == item ? Color.primary : Color.clear)
                                .frame(height: 3)
                                .padding(.horizontal, 8)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            Picker("报告周期", selection: $periodKind) {
                Text("年度").tag(FinancialPeriodKind.annual)
                Text("季度").tag(FinancialPeriodKind.quarterly)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 230)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func statementContent(_ data: CompanyFinancialsData) -> some View {
        switch statement {
        case .income:
            let periods = data.income.filter { $0.kind == periodKind }
            if let selected = selected(from: periods) {
                IncomeFlowView(period: selected)
                periodSelector(periods, label: { periodLabel($0.fiscalYear, $0.fiscalPeriod) })
                incomeRows(selected)
            } else {
                missingPeriodState
            }
        case .balance:
            let periods = data.balance.filter { $0.kind == periodKind }
            if let selected = selected(from: periods) {
                BalanceFlowView(period: selected)
                periodSelector(periods, label: { periodLabel($0.fiscalYear, $0.fiscalPeriod) })
                balanceRows(selected)
            } else {
                missingPeriodState
            }
        case .cashFlow:
            let periods = data.cashFlow.filter { $0.kind == periodKind }
            if let selected = selected(from: periods) {
                CashFlowDiagram(period: selected)
                periodSelector(periods, label: { periodLabel($0.fiscalYear, $0.fiscalPeriod) })
                cashFlowRows(selected)
            } else {
                missingPeriodState
            }
        }
    }

    private func selected<T: Identifiable>(from periods: [T]) -> T? where T.ID == String {
        periods.first(where: { $0.id.contains(selectedPeriodEnd ?? "__none__") }) ?? periods.first
    }

    private func periodSelector<T: Identifiable>(
        _ periods: [T],
        label: @escaping (T) -> String
    ) -> some View where T.ID == String {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(periods) { period in
                    let isSelected = selectedPeriodEnd.map(period.id.contains) ?? (period.id == periods.first?.id)
                    Button {
                        selectedPeriodEnd = period.id
                    } label: {
                        Text(label(period))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                            .padding(.horizontal, 14)
                            .frame(height: 42)
                            .background(isSelected ? Color(uiColor: .secondarySystemBackground) : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func periodLabel(_ year: Int, _ fiscalPeriod: String) -> String {
        periodKind == .annual ? String(year) : "\(year) \(fiscalPeriod)"
    }

    private func incomeRows(_ period: IncomeStatementPeriod) -> some View {
        FinancialRows(currency: period.currency, rows: [
            ("营业收入", period.revenue, true),
            ("营业成本", period.costOfRevenue, false),
            ("毛利润", period.grossProfit, true),
            ("营业费用", period.operatingExpenses, false),
            ("营业利润", period.operatingIncome, true),
            ("净利润", period.netIncome, true),
        ])
    }

    private func balanceRows(_ period: BalanceSheetPeriod) -> some View {
        FinancialRows(currency: period.currency, rows: [
            ("总资产", period.assets, true),
            ("总负债", period.liabilities, false),
            ("股东权益", period.equity, true),
            ("现金及等价物", period.cash, true),
            ("有息债务", period.debt, false),
        ])
    }

    private func cashFlowRows(_ period: CashFlowStatementPeriod) -> some View {
        FinancialRows(currency: period.currency, rows: [
            ("经营现金流", period.operatingCashFlow, true),
            ("资本开支", period.capitalExpenditure, false),
            ("自由现金流", period.freeCashFlow, true),
            ("投资现金流", period.investingCashFlow, false),
            ("融资现金流", period.financingCashFlow, false),
        ])
    }

    private var loadingState: some View {
        VStack(spacing: 14) {
            ProgressView()
            Text("正在读取 SEC Company Facts…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 360)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("暂未读取到财务数据", systemImage: "chart.bar.xaxis")
        } description: {
            Text(errorMessage ?? "SEC 没有返回可用的 10-K / 10-Q 数据")
        } actions: {
            Button("重新读取") { Task { await load(forceRefresh: true) } }
        }
        .frame(minHeight: 360)
    }

    private var missingPeriodState: some View {
        ContentUnavailableView(
            "这个周期暂无数据",
            systemImage: "doc.text.magnifyingglass",
            description: Text("可以切换年度或季度；非美国证券会在 SEC 无覆盖时尝试使用已配置的 FMP。")
        )
        .frame(minHeight: 320)
    }

    private func sourceFooter(_ data: CompanyFinancialsData) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(data.source, systemImage: "building.columns")
                .font(.caption.weight(.semibold))
            Text("同一报告期存在重述时取最新申报值。金额保留报表原币种，不按持仓展示币种换算。")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(data.warnings, id: \.self) { warning in
                Text(warning)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 2)
    }

    @MainActor
    private func load(forceRefresh: Bool) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            financials = try await CompanyFinancialsClient.shared.load(
                ticker: ticker,
                forceRefresh: forceRefresh
            )
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct IncomeFlowView: View {
    let period: IncomeStatementPeriod

    var body: some View {
        FinancialFlowDiagram(
            currency: period.currency,
            left: .init(L10n.text("营业收入"), period.revenue, .inflow),
            middleTop: .init(L10n.text("毛利润"), period.grossProfit, .inflow),
            middleBottom: .init(L10n.text("营业成本"), period.costOfRevenue, .outflow),
            rightTop: .init(L10n.text("营业利润"), period.operatingIncome, .inflow),
            rightBottom: .init(L10n.text("营业费用"), period.operatingExpenses, .outflow)
        )
    }
}

private struct BalanceFlowView: View {
    let period: BalanceSheetPeriod

    var body: some View {
        FinancialSplitDiagram(
            currency: period.currency,
            source: .init(L10n.text("总资产"), period.assets, .inflow),
            upper: .init(L10n.text("股东权益"), period.equity, .inflow),
            lower: .init(L10n.text("总负债"), period.liabilities, .outflow)
        )
    }
}

private struct CashFlowDiagram: View {
    let period: CashFlowStatementPeriod

    var body: some View {
        FinancialSplitDiagram(
            currency: period.currency,
            source: .init(L10n.text("经营现金流"), period.operatingCashFlow, .inflow),
            upper: .init(L10n.text("自由现金流"), period.freeCashFlow, .inflow),
            lower: .init(L10n.text("资本开支"), period.capitalExpenditure, .outflow)
        )
    }
}

private struct FlowNode {
    enum Tone { case inflow, outflow }
    let title: String
    let value: Double
    let tone: Tone

    init(_ title: String, _ value: Double, _ tone: Tone) {
        self.title = title
        self.value = value
        self.tone = tone
    }

    var color: Color {
        switch tone {
        case .inflow: CatfolioPalette.statementInflow
        case .outflow: CatfolioPalette.statementOutflow
        }
    }
}

private struct FinancialFlowDiagram: View {
    let currency: String
    let left: FlowNode
    let middleTop: FlowNode
    let middleBottom: FlowNode
    let rightTop: FlowNode
    let rightBottom: FlowNode

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let revenueFlows = pairedFlowThickness(
                middleTop.value,
                middleBottom.value,
                span: 112
            )
            let grossThickness = revenueFlows.first
            let costThickness = revenueFlows.second
            let grossFlows = pairedFlowThickness(
                rightTop.value,
                rightBottom.value,
                span: grossThickness
            )
            let operatingThickness = grossFlows.first
            let expenseThickness = grossFlows.second
            let sourceTop: CGFloat = 116
            let grossCenter: CGFloat = 120
            let costCenter: CGFloat = 226
            let grossTop = grossCenter - grossThickness / 2
            let grossSourceCenter = sourceTop + grossThickness / 2
            let costSourceCenter = sourceTop + grossThickness + costThickness / 2
            let operatingSourceCenter = grossTop + operatingThickness / 2
            let expenseSourceCenter = grossTop + operatingThickness + expenseThickness / 2
            ZStack {
                Canvas { context, size in
                    let x0: CGFloat = 48
                    let x1 = size.width * 0.50
                    let x2 = size.width - 48
                    ribbon(context: &context, from: CGPoint(x: x0, y: grossSourceCenter), to: CGPoint(x: x1, y: grossCenter), thickness: grossThickness, color: middleTop.color)
                    ribbon(context: &context, from: CGPoint(x: x0, y: costSourceCenter), to: CGPoint(x: x1, y: costCenter), thickness: costThickness, color: middleBottom.color)
                    ribbon(context: &context, from: CGPoint(x: x1, y: operatingSourceCenter), to: CGPoint(x: x2, y: 90), thickness: operatingThickness, color: rightTop.color)
                    ribbon(context: &context, from: CGPoint(x: x1, y: expenseSourceCenter), to: CGPoint(x: x2, y: 181), thickness: expenseThickness, color: rightBottom.color)
                    bar(context: &context, x: x0, y: sourceTop, height: grossThickness + costThickness, color: left.color)
                    bar(context: &context, x: x1, y: grossTop, height: grossThickness, color: middleTop.color)
                    bar(context: &context, x: x1, y: costCenter - costThickness / 2, height: costThickness, color: middleBottom.color)
                    bar(context: &context, x: x2, y: 90 - operatingThickness / 2, height: operatingThickness, color: rightTop.color)
                    bar(context: &context, x: x2, y: 181 - expenseThickness / 2, height: expenseThickness, color: rightBottom.color)
                }
                nodeLabel(left, currency: currency).position(x: 48, y: 42)
                nodeLabel(middleTop, currency: currency).position(x: width * 0.50, y: 34)
                nodeLabel(middleBottom, currency: currency).position(x: width * 0.50, y: 285)
                nodeLabel(rightTop, currency: currency).position(x: width - 48, y: 24)
                nodeLabel(rightBottom, currency: currency).position(x: width - 48, y: 264)
            }
        }
        .frame(height: 325)
        .accessibilityElement(children: .combine)
    }
}

private struct FinancialSplitDiagram: View {
    let currency: String
    let source: FlowNode
    let upper: FlowNode
    let lower: FlowNode

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let splitFlows = pairedFlowThickness(upper.value, lower.value, span: 118)
            let upperThickness = splitFlows.first
            let lowerThickness = splitFlows.second
            let sourceTop: CGFloat = 118
            let upperSourceCenter = sourceTop + upperThickness / 2
            let lowerSourceCenter = sourceTop + upperThickness + lowerThickness / 2
            ZStack {
                Canvas { context, size in
                    let x0: CGFloat = 54
                    let x1 = size.width - 54
                    ribbon(context: &context, from: CGPoint(x: x0, y: upperSourceCenter), to: CGPoint(x: x1, y: 108), thickness: upperThickness, color: upper.color)
                    ribbon(context: &context, from: CGPoint(x: x0, y: lowerSourceCenter), to: CGPoint(x: x1, y: 218), thickness: lowerThickness, color: lower.color)
                    bar(context: &context, x: x0, y: sourceTop, height: upperThickness + lowerThickness, color: source.color)
                    bar(context: &context, x: x1, y: 108 - upperThickness / 2, height: upperThickness, color: upper.color)
                    bar(context: &context, x: x1, y: 218 - lowerThickness / 2, height: lowerThickness, color: lower.color)
                }
                nodeLabel(source, currency: currency).position(x: 54, y: 42)
                nodeLabel(upper, currency: currency).position(x: width - 54, y: 35)
                nodeLabel(lower, currency: currency).position(x: width - 54, y: 282)
            }
        }
        .frame(height: 320)
        .accessibilityElement(children: .combine)
    }
}

private func nodeLabel(_ node: FlowNode, currency: String) -> some View {
    VStack(spacing: 3) {
        Text(node.title)
            .font(.caption.weight(.semibold))
            .multilineTextAlignment(.center)
        Text(FinancialAmountFormatter.string(node.value, currency: currency))
            .font(.caption.weight(.bold))
            .foregroundStyle(node.color)
            .lineLimit(1)
            .minimumScaleFactor(0.72)
    }
    .frame(width: 104)
}

private func bar(context: inout GraphicsContext, x: CGFloat, y: CGFloat, height: CGFloat, color: Color) {
    let rect = CGRect(x: x - 7, y: y, width: 14, height: height)
    context.fill(Path(roundedRect: rect, cornerRadius: 5), with: .color(color))
}

private func ribbon(
    context: inout GraphicsContext,
    from: CGPoint,
    to: CGPoint,
    thickness: CGFloat,
    color: Color
) {
    let control = max(34, abs(to.x - from.x) * 0.42)
    var path = Path()
    path.move(to: CGPoint(x: from.x, y: from.y - thickness / 2))
    path.addCurve(
        to: CGPoint(x: to.x, y: to.y - thickness / 2),
        control1: CGPoint(x: from.x + control, y: from.y - thickness / 2),
        control2: CGPoint(x: to.x - control, y: to.y - thickness / 2)
    )
    path.addLine(to: CGPoint(x: to.x, y: to.y + thickness / 2))
    path.addCurve(
        to: CGPoint(x: from.x, y: from.y + thickness / 2),
        control1: CGPoint(x: to.x - control, y: to.y + thickness / 2),
        control2: CGPoint(x: from.x + control, y: from.y + thickness / 2)
    )
    path.closeSubpath()
    context.fill(path, with: .color(color.opacity(0.13)))
}

/// Allocate both branches from one shared span. This makes the two ribbons
/// meet exactly at their source bar instead of letting independent minimums
/// create visible gaps or overlaps.
private func pairedFlowThickness(
    _ firstValue: Double,
    _ secondValue: Double,
    span: CGFloat
) -> (first: CGFloat, second: CGFloat) {
    guard firstValue.isFinite, secondValue.isFinite, span > 0 else {
        return (span / 2, span / 2)
    }
    let firstWeight = abs(firstValue)
    let secondWeight = abs(secondValue)
    let total = firstWeight + secondWeight
    guard total > 0 else { return (span / 2, span / 2) }

    let minimum = min(10, span / 2)
    let rawFirst = span * CGFloat(firstWeight / total)
    let first = min(max(rawFirst, minimum), span - minimum)
    return (first, span - first)
}

private struct FinancialRows: View {
    let currency: String
    let rows: [(String, Double?, Bool)]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(row.0)
                        .foregroundStyle(index == 0 || row.2 ? .primary : .secondary)
                        .fontWeight(index == 0 || row.2 ? .semibold : .regular)
                    Spacer(minLength: 16)
                    Text(row.1.map { FinancialAmountFormatter.string($0, currency: currency) } ?? "—")
                        .appNumber(.subheading)
                        .fontWeight(index == 0 || row.2 ? .semibold : .regular)
                }
                .padding(.vertical, 15)
                if index < rows.count - 1 { Divider() }
            }
        }
    }
}

private enum FinancialAmountFormatter {
    /// A statement line: the shared ladder, held to three significant digits.
    static func string(_ value: Double, currency: String) -> String {
        DisplayFormat.compactMoney(value, currency: currency, precision: .statement)
    }
}
