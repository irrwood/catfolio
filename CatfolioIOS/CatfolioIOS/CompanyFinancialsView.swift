import SwiftUI

struct CompanyFinancialsView: View {
    @AppStorage(ChartInteractionStyle.hapticsPreferenceKey) private var hapticsEnabled = true
    @Environment(\.locale) private var appLocale
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Statement: String, CaseIterable, Identifiable {
        case income = "利润表"
        case segments = "收入构成"
        case balance = "资产负债表"
        case cashFlow = "现金流"

        var id: String { rawValue }
    }

    let ticker: String
    let companyName: String
    var onAvailability: (HoldingResearchAvailability) -> Void = { _ in }

    @State private var statement: Statement = .income
    @State private var periodKind: FinancialPeriodKind = .annual
    @State private var selectedPeriodEnd: String?
    @State private var financials: CompanyFinancialsData?
    @State private var errorMessage: String?
    @State private var isLoading = false
    @State private var segmentKind: RevenueSegmentCatalog.Kind = .product
    @State private var segmentPeriods: [RevenueSegmentCatalog.Period]?
    @State private var segmentsAsOf: String?

    init(holding: Holding, onAvailability: @escaping (HoldingResearchAvailability) -> Void = { _ in }) {
        ticker = holding.ticker
        companyName = holding.shortName
        self.onAvailability = onAvailability
    }

    static func supports(_ holding: Holding) -> Bool {
        HoldingSecurityKind.classify(holding) != .fund
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                statementSelector

                if statement == .segments {
                    segmentContent
                } else if isLoading, financials == nil {
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
        .appPageBackground(Color(uiColor: .systemBackground))
        .softTopScrollEdge()
        .navigationTitle(L10n.text("财务 · \(ticker)"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button {
                    dismiss()
                } label: {
                    Label(L10n.text("关闭"), systemImage: "xmark")
                }
                .labelStyle(.iconOnly)
            }
        }
        .refreshable { await load(forceRefresh: true) }
        .task { await load(forceRefresh: false) }
        .task(id: segmentKind) { await loadSegments() }
        .onChange(of: statement) { _, _ in selectedPeriodEnd = nil }
        .onChange(of: segmentKind) { _, _ in selectedPeriodEnd = nil }
    }

    private var periodSelection: Binding<FinancialPeriodKind> {
        Binding(get: { periodKind }, set: { value in
            selectedPeriodEnd = nil
            periodKind = value
        })
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(companyName)
                .font(.title2.weight(.bold))
            Text(L10n.text("\(ticker) · SEC 原始申报数据"))
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
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { statement = item }
                    } label: {
                        VStack(spacing: 9) {
                            Text(L10n.label(item.rawValue))
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

            // Segments are only disclosed by fiscal year, so their tab picks
            // how revenue is split instead of a reporting period.
            if statement == .segments {
                Picker(L10n.text("拆分方式"), selection: $segmentKind) {
                    ForEach(RevenueSegmentCatalog.Kind.allCases) { kind in
                        Text(L10n.label(kind.rawValue)).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 230)
                .frame(maxWidth: .infinity, alignment: .leading)
                .sensoryFeedback(.selection, trigger: segmentKind) { _, _ in hapticsEnabled }
            } else {
                Picker(L10n.text("报告周期"), selection: periodSelection) {
                    Text(L10n.text("年度")).tag(FinancialPeriodKind.annual)
                    Text(L10n.text("季度")).tag(FinancialPeriodKind.quarterly)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 230)
                .frame(maxWidth: .infinity, alignment: .leading)
                .sensoryFeedback(.selection, trigger: periodKind) { _, _ in hapticsEnabled }
            }
        }
    }

    @ViewBuilder
    private var segmentContent: some View {
        if let periods = segmentPeriods {
            if let selected = selected(from: periods) {
                SegmentFlowDiagram(period: selected)
                periodSelector(periods, label: { String($0.fy) })
                SegmentRows(period: selected)
                segmentFooter(selected)
            } else {
                ContentUnavailableView(
                    L10n.text("暂无分部收入"),
                    systemImage: "chart.pie",
                    description: Text(L10n.text("这家公司没有按这种方式披露分部收入，或不在美股数据包覆盖范围内。"))
                )
                .frame(minHeight: 320)
            }
        } else {
            ProgressView().frame(maxWidth: .infinity).frame(height: 320)
        }
    }

    private func segmentFooter(_ period: RevenueSegmentCatalog.Period) -> some View {
        var notes: [String] = []
        if period.overlap == true {
            notes.append(L10n.text("这家公司披露的分部之间有重叠，合计超过总收入，比例按分部合计计算。"))
        }
        if period.eliminations != nil {
            notes.append(L10n.text("分部收入含分部间交易，比例按抵消前的分部合计计算。"))
        }
        if period.revenue == nil {
            notes.append(L10n.text("这一财年还没有对应的利润表，比例按分部合计计算。"))
        }
        return VStack(alignment: .leading, spacing: 7) {
            Label(L10n.text("FMP · 公司申报整理"), systemImage: "building.columns")
                .font(.caption.weight(.semibold))
            Text(L10n.text("分部收入只按财年披露，随 app 更新\(segmentsAsOf.map { L10n.text("，数据截至 \($0)") } ?? "")。金额保留报表原币种。"))
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(notes, id: \.self) { note in
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.top, 2)
    }

    @MainActor
    private func loadSegments() async {
        let kind = segmentKind
        let catalogue = await RevenueSegmentStore.shared.catalogue()
        guard !Task.isCancelled, kind == segmentKind else { return }
        segmentPeriods = catalogue?.periods(ticker: ticker, kind: kind) ?? []
        segmentsAsOf = catalogue?.asOf
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
        case .segments:
            EmptyView()
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
        .sensoryFeedback(.selection, trigger: selectedPeriodEnd) { _, _ in hapticsEnabled }
    }

    private func periodLabel(_ year: Int, _ fiscalPeriod: String) -> String {
        periodKind == .annual ? String(year) : "\(year) \(fiscalPeriod)"
    }

    private func incomeRows(_ period: IncomeStatementPeriod) -> some View {
        FinancialRows(currency: period.currency, rows: [
            (L10n.text("营业收入"), period.revenue, true),
            (L10n.text("营业成本"), period.costOfRevenue, false),
            (L10n.text("毛利润"), period.grossProfit, true),
            (L10n.text("营业费用"), period.operatingExpenses, false),
            (L10n.text("营业利润"), period.operatingIncome, true),
            (L10n.text("净利润"), period.netIncome, true),
        ])
    }

    private func balanceRows(_ period: BalanceSheetPeriod) -> some View {
        FinancialRows(currency: period.currency, rows: [
            (L10n.text("总资产"), period.assets, true),
            (L10n.text("总负债"), period.liabilities, false),
            (L10n.text("股东权益"), period.equity, true),
            (L10n.text("现金及等价物"), period.cash, true),
            (L10n.text("有息债务"), period.debt, false),
        ])
    }

    private func cashFlowRows(_ period: CashFlowStatementPeriod) -> some View {
        FinancialRows(currency: period.currency, rows: [
            (L10n.text("经营现金流"), period.operatingCashFlow, true),
            (L10n.text("资本开支"), period.capitalExpenditure, false),
            (L10n.text("自由现金流"), period.freeCashFlow, true),
            (L10n.text("投资现金流"), period.investingCashFlow, false),
            (L10n.text("融资现金流"), period.financingCashFlow, false),
        ])
    }

    private var loadingState: some View {
        VStack(spacing: 14) {
            ProgressView()
            Text(L10n.text("正在读取 SEC Company Facts…"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 360)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(L10n.text("暂未读取到财务数据"), systemImage: "chart.bar.xaxis")
        } description: {
            Text(L10n.message(errorMessage ?? L10n.text("SEC 没有返回可用的 10-K / 10-Q 数据")))
        } actions: {
            Button(L10n.text("重新读取")) { Task { await load(forceRefresh: true) } }
        }
        .frame(minHeight: 360)
    }

    private var missingPeriodState: some View {
        ContentUnavailableView(
            L10n.text("这个周期暂无数据"),
            systemImage: "doc.text.magnifyingglass",
            description: Text(L10n.text("可以切换年度或季度；非美国证券会在 SEC 无覆盖时尝试使用已配置的 FMP。"))
        )
        .frame(minHeight: 320)
    }

    private func sourceFooter(_ data: CompanyFinancialsData) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(L10n.message(data.source), systemImage: "building.columns")
                .font(.caption.weight(.semibold))
            Text(L10n.text("同一报告期存在重述时取最新申报值。金额保留报表原币种，不按持仓展示币种换算。"))
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(data.warnings, id: \.self) { warning in
                Text(L10n.message(warning))
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
            onAvailability(financials?.hasUsableStatements == true ? .available : .empty)
        } catch {
            errorMessage = error.localizedDescription
            onAvailability(error as? CompanyFinancialsError == .noStatements ? .empty : .failed)
        }
    }
}

private struct IncomeFlowView: View {
    @Environment(\.locale) private var appLocale
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
    @Environment(\.locale) private var appLocale
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
    @Environment(\.locale) private var appLocale
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

    /// Figures in the node's colour, a step darker where the bar would be
    /// too faint to read as text.
    var textColor: Color {
        switch tone {
        case .inflow: CatfolioPalette.statementInflowText
        case .outflow: CatfolioPalette.statementOutflowText
        }
    }

    /// The ribbon's own tint, not a faded bar.
    var ribbonColor: Color {
        switch tone {
        case .inflow: CatfolioPalette.statementInflowRibbon
        case .outflow: CatfolioPalette.statementOutflowRibbon
        }
    }
}

private struct FinancialFlowDiagram: View {
    @Environment(\.locale) private var appLocale
    let currency: String
    let left: FlowNode
    let middleTop: FlowNode
    let middleBottom: FlowNode
    let rightTop: FlowNode
    let rightBottom: FlowNode

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let revenueFlows = pairedFlowThickness(middleTop.value, middleBottom.value, span: 112)
            let grossThickness = revenueFlows.first
            let costThickness = revenueFlows.second
            let grossFlows = pairedFlowThickness(rightTop.value, rightBottom.value, span: grossThickness)
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
                Group {
                    let x0: CGFloat = 48
                    let x1 = width * 0.50
                    let x2 = width - 48
                    FinancialRibbon(from: CGPoint(x: x0, y: grossSourceCenter), to: CGPoint(x: x1, y: grossCenter), thickness: grossThickness, color: middleTop.ribbonColor)
                    FinancialRibbon(from: CGPoint(x: x0, y: costSourceCenter), to: CGPoint(x: x1, y: costCenter), thickness: costThickness, color: middleBottom.ribbonColor)
                    FinancialRibbon(from: CGPoint(x: x1, y: operatingSourceCenter), to: CGPoint(x: x2, y: 90), thickness: operatingThickness, color: rightTop.ribbonColor)
                    FinancialRibbon(from: CGPoint(x: x1, y: expenseSourceCenter), to: CGPoint(x: x2, y: 181), thickness: expenseThickness, color: rightBottom.ribbonColor)
                    FinancialFlowBar(x: x0, y: sourceTop, height: grossThickness + costThickness, color: left.color)
                    FinancialFlowBar(x: x1, y: grossTop, height: grossThickness, color: middleTop.color)
                    FinancialFlowBar(x: x1, y: costCenter - costThickness / 2, height: costThickness, color: middleBottom.color)
                    FinancialFlowBar(x: x2, y: 90 - operatingThickness / 2, height: operatingThickness, color: rightTop.color)
                    FinancialFlowBar(x: x2, y: 181 - expenseThickness / 2, height: expenseThickness, color: rightBottom.color)
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
    @Environment(\.locale) private var appLocale
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
                Group {
                    let x0: CGFloat = 54
                    let x1 = width - 54
                    FinancialRibbon(from: CGPoint(x: x0, y: upperSourceCenter), to: CGPoint(x: x1, y: 108), thickness: upperThickness, color: upper.ribbonColor)
                    FinancialRibbon(from: CGPoint(x: x0, y: lowerSourceCenter), to: CGPoint(x: x1, y: 218), thickness: lowerThickness, color: lower.ribbonColor)
                    FinancialFlowBar(x: x0, y: sourceTop, height: upperThickness + lowerThickness, color: source.color)
                    FinancialFlowBar(x: x1, y: 108 - upperThickness / 2, height: upperThickness, color: upper.color)
                    FinancialFlowBar(x: x1, y: 218 - lowerThickness / 2, height: lowerThickness, color: lower.color)
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

/// Each ribbon keeps the same Shape identity between reports. SwiftUI
/// interpolates its four boundary heights, so both Bézier edges deform in
/// place rather than cross-fading two Canvas renderings.
private struct FinancialRibbonShape: Shape {
    let fromX: CGFloat
    let toX: CGFloat
    var sourceTop: CGFloat
    var sourceBottom: CGFloat
    var targetTop: CGFloat
    var targetBottom: CGFloat

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(AnimatablePair(sourceTop, sourceBottom), AnimatablePair(targetTop, targetBottom)) }
        set {
            sourceTop = newValue.first.first
            sourceBottom = newValue.first.second
            targetTop = newValue.second.first
            targetBottom = newValue.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let control = max(34, abs(toX - fromX) * 0.42)
        var path = Path()
        path.move(to: CGPoint(x: fromX, y: sourceTop))
        path.addCurve(to: CGPoint(x: toX, y: targetTop),
                      control1: CGPoint(x: fromX + control, y: sourceTop),
                      control2: CGPoint(x: toX - control, y: targetTop))
        path.addLine(to: CGPoint(x: toX, y: targetBottom))
        path.addCurve(to: CGPoint(x: fromX, y: sourceBottom),
                      control1: CGPoint(x: toX - control, y: targetBottom),
                      control2: CGPoint(x: fromX + control, y: sourceBottom))
        path.closeSubpath()
        return path
    }
}

private enum FinancialFlowMotion {
    static let animation = Animation.easeInOut(duration: 0.45)
}

private struct FinancialRibbon: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let from: CGPoint
    let to: CGPoint
    let thickness: CGFloat
    let color: Color

    var body: some View {
        let shape = FinancialRibbonShape(fromX: from.x, toX: to.x,
            sourceTop: from.y - thickness / 2, sourceBottom: from.y + thickness / 2,
            targetTop: to.y - thickness / 2, targetBottom: to.y + thickness / 2)
        shape.fill(color)
            .animation(reduceMotion ? nil : FinancialFlowMotion.animation, value: shape.animatableData)
    }
}

private struct FinancialFlowBar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let x: CGFloat
    let y: CGFloat
    let height: CGFloat
    let color: Color

    var body: some View {
        RoundedRectangle(cornerRadius: 5)
            .fill(color)
            .frame(width: 14, height: height)
            .position(x: x, y: y + height / 2)
            .animation(reduceMotion ? nil : FinancialFlowMotion.animation, value: AnimatablePair(y, height))
    }
}

private func nodeLabel(_ node: FlowNode, currency: String) -> some View {
    VStack(spacing: 3) {
        Text(node.title)
            .font(.caption.weight(.semibold))
            .multilineTextAlignment(.center)
        Text(FinancialAmountFormatter.string(node.value, currency: currency))
            .currencyFont(.caption1, weight: .bold)
            .foregroundStyle(node.textColor)
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
    context.fill(path, with: .color(color))
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

/// Revenue on the left, split into its segments on the right: the same bars
/// and ribbons as the statement diagrams, with a label beside each segment
/// instead of above it, since there can be many.
struct SegmentFlowDiagram: View {
    let period: RevenueSegmentCatalog.Period

    struct Row {
        let title: String
        let value: Double
        let isUnallocated: Bool
    }

    /// Largest first, the long tail folded into one row so every label fits.
    static func rows(for period: RevenueSegmentCatalog.Period, limit: Int = 7) -> [Row] {
        var rows = period.items.map { Row(title: $0.name, value: $0.value, isUnallocated: false) }
        if rows.count > limit {
            let tail = rows[(limit - 1)...]
            rows = Array(rows[..<(limit - 1)])
            rows.append(Row(title: L10n.text("其他 \(tail.count) 项"), value: tail.reduce(0) { $0 + $1.value },
                            isUnallocated: false))
        }
        if let unallocated = period.unallocated, unallocated > 0 {
            rows.append(Row(title: L10n.text("未归入分部"), value: unallocated, isUnallocated: true))
        }
        return rows
    }

    /// Each row's share of `span`, none thinner than `minimum`; what the
    /// thin ones borrow comes out of the others in proportion.
    static func thicknesses(_ values: [Double], span: CGFloat, minimum: CGFloat = 3) -> [CGFloat] {
        let total = values.reduce(0) { $0 + max(0, $1) }
        guard total > 0, !values.isEmpty else { return values.map { _ in span / CGFloat(max(values.count, 1)) } }
        var result = values.map { span * CGFloat(max(0, $0) / total) }
        let thin = result.indices.filter { result[$0] < minimum }
        guard !thin.isEmpty, thin.count < result.count else { return result }
        let borrowed = thin.reduce(CGFloat(0)) { $0 + (minimum - result[$1]) }
        let thickTotal = result.indices.filter { !thin.contains($0) }.reduce(CGFloat(0)) { $0 + result[$1] }
        for index in result.indices {
            result[index] = thin.contains(index) ? minimum : result[index] - borrowed * result[index] / thickTotal
        }
        return result
    }

    var body: some View {
        let rows = Self.rows(for: period)
        let base = period.base
        let currency = period.currency ?? "USD"
        let span: CGFloat = 220
        let thickness = Self.thicknesses(rows.map(\.value), span: span)
        let gap: CGFloat = 8
        // A name long enough to wrap takes a second line above its figures.
        let heights = rows.indices.map { index in
            max(thickness[index], rows[index].title.count > 22 ? 56 : 40)
        }
        let column = heights.reduce(0, +) + gap * CGFloat(max(0, rows.count - 1))
        let top: CGFloat = 62
        let sourceTop = top + max(0, (column - span) / 2)
        let columnTop = top + max(0, (span - column) / 2)
        let centers = heights.indices.map { index in
            columnTop + heights[..<index].reduce(0, +) + gap * CGFloat(index) + heights[index] / 2
        }

        GeometryReader { proxy in
            let width = proxy.size.width
            let x0: CGFloat = 48
            let x1 = width * 0.46
            let labelWidth = max(80, width - x1 - 20)
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    var sourceY = sourceTop
                    for (index, row) in rows.enumerated() {
                        let t = thickness[index]
                        let node = FlowNode(row.title, row.value, row.isUnallocated ? .outflow : .inflow)
                        // Neighbouring ribbons alternate in depth so they
                        // stay apart where they cross.
                        let ribbonColor = node.ribbonColor.opacity(index.isMultiple(of: 2) ? 1 : 0.7)
                        ribbon(context: &context, from: CGPoint(x: x0, y: sourceY + t / 2),
                               to: CGPoint(x: x1, y: centers[index]), thickness: t, color: ribbonColor)
                        bar(context: &context, x: x1, y: centers[index] - t / 2, height: t, color: node.color)
                        sourceY += t
                    }
                    bar(context: &context, x: x0, y: sourceTop, height: span, color: CatfolioPalette.statementInflow)
                }
                nodeLabel(FlowNode(L10n.text("营业收入"), period.revenue ?? base, .inflow), currency: currency)
                    .position(x: x0, y: sourceTop - 30)
                ForEach(rows.indices, id: \.self) { index in
                    let row = rows[index]
                    let node = FlowNode(row.title, row.value, row.isUnallocated ? .outflow : .inflow)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.title)
                            .font(.caption.weight(.semibold))
                            .lineLimit(2)
                            .minimumScaleFactor(0.85)
                        Text("\(FinancialAmountFormatter.string(row.value, currency: currency)) · \(DisplayFormat.percent(row.value / base * 100, signed: false))")
                            .currencyFont(.caption1, weight: .bold)
                            .foregroundStyle(node.textColor)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .frame(width: labelWidth, alignment: .leading)
                    .position(x: x1 + 14 + labelWidth / 2, y: centers[index])
                }
            }
        }
        .frame(height: top + max(column, span) + 12)
        .accessibilityElement(children: .combine)
    }
}

private struct SegmentRows: View {
    let period: RevenueSegmentCatalog.Period

    var body: some View {
        let rows = SegmentFlowDiagram.rows(for: period, limit: .max)
        let base = period.base
        let currency = period.currency ?? "USD"
        VStack(spacing: 0) {
            ForEach(rows.indices, id: \.self) { index in
                let row = rows[index]
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(row.title)
                        .foregroundStyle(row.isUnallocated ? .secondary : .primary)
                        .lineLimit(2)
                    Spacer(minLength: 16)
                    Text(DisplayFormat.percent(row.value / base * 100, signed: false))
                        .appNumber(.callout)
                        .foregroundStyle(.secondary)
                    Text(FinancialAmountFormatter.string(row.value, currency: currency))
                        .appNumber(.subheading)
                        .frame(minWidth: 84, alignment: .trailing)
                }
                .padding(.vertical, 15)
                if index < rows.count - 1 { Divider() }
            }
        }
    }
}

private struct FinancialRows: View {
    @Environment(\.locale) private var appLocale
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
