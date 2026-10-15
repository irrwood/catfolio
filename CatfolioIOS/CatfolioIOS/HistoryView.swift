import SwiftUI
import Charts
import UniformTypeIdentifiers

private struct HistorySummaryMetric: Identifiable {
    let title: String
    let value: String
    let color: Color
    var icon: SettingsIconSource? = nil

    var id: String { title }
}

struct HistoryView: View {
    @Environment(\.locale) private var appLocale
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme

    private let initialAccountIDs: Set<String>?
    private let ticker: String?
    #if DEBUG
    private var usesPreviewLedger = false
    #endif
    @State private var ledger = PortfolioActivityLedger(accounts: [], transactions: [], securityNames: [:])
    @State private var selectedAccountIDs: Set<String>?
    @State private var category: HistoryCategory = .all
    @State private var ledgerRevision = 0
    @State private var preparedLedger = HistoryPreparedLedger()
    @AppStorage("history.taxYearBasis") private var taxYearBasisRaw = TaxYearBasis.calendar.rawValue
    /// Dividends listed under each security rather than by date.
    @AppStorage("history.dividendsByStock") private var dividendsByStock = false
    @AppStorage("history.ordersByStock") private var ordersByStock = false
    @State private var selectedTaxYear: String?

    private var taxYearBasis: TaxYearBasis {
        TaxYearBasis(rawValue: taxYearBasisRaw) ?? .calendar
    }

    @State private var scopedHoldings: [Holding] = []
    @State private var feeCharges: [HistoryFeeCharge] = []
    /// Purchase id → value now less cost, USD. Waits for the scoped holdings.
    @State private var buyGains: [String: Double] = [:]
    /// This calendar year's dividends: received so far, plus what today's
    /// holdings paid over the rest of the year last year.
    @State private var dividendForecastUSD: Double?
    @State private var isLoading = true
    /// When the page appeared, so the first lists wait for the push to end.
    @State private var appearedAt = ContinuousClock.Instant.now
    @State private var isSyncing = false
    @State private var errorMessage: String?
    @State private var exportDocument = HistoryCSVDocument(data: Data())
    @State private var showsExporter = false
    @State private var exportError: String?

    init(initialAccountIDs: Set<String>? = nil, initialCategory: HistoryCategory = .all, ticker: String? = nil) {
        self.ticker = ticker?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        self.initialAccountIDs = initialAccountIDs
        _selectedAccountIDs = State(initialValue: initialAccountIDs)
        _category = State(initialValue: initialCategory)

        #if DEBUG
        if LaunchArguments.contains("--verify-history-orders") {
            _category = State(initialValue: .orders)
        }
        #endif
    }

    #if DEBUG
    /// Deterministic native navigation tests without touching stored accounts.
    init(previewLedger: PortfolioActivityLedger, prepared: HistoryPreparedLedger) {
        initialAccountIDs = nil
        ticker = nil
        usesPreviewLedger = true
        _ledger = State(initialValue: previewLedger)
        _preparedLedger = State(initialValue: prepared)
        _isLoading = State(initialValue: false)
    }
    #endif

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage {
                CatfolioEmptyState(title: L10n.text("Unable to load History"),
                                   message: L10n.message(errorMessage),
                                   icon: Image(systemName: "exclamationmark.triangle.fill"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HistoryPagingView(selection: $category, categories: visibleCategories, contentID: HistoryPageContentID(
                    ledger: preparedLedger.contentID, basis: taxYearBasisRaw,
                    year: selectedTaxYear, forecast: dividendForecastUSD, gains: buyGains.count,
                    dividendsByStock: dividendsByStock, ordersByStock: ordersByStock
                )) { pageCategory in
                    AnyView(historyList(for: pageCategory))
                }
                .ignoresSafeArea(.container, edges: [.top, .bottom])
                // A different set of tabs is a different pager.
                .id(visibleCategories)
            }
        }
        // Cover the home-indicator safe area, not just the list's safe frame.
        .background { SettingsTemplate.pageBackground.ignoresSafeArea() }
        .navigationTitle(ticker.map { "\($0) · \(L10n.text("History"))" } ?? L10n.text("History"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarVisibility(.visible, for: .navigationBar)
        // The bar and the category row are one solid surface: white by day,
        // black at night (`systemBackground`, as the category bar uses).
        .toolbarBackground(Color(uiColor: .systemBackground), for: .navigationBar)
        .toolbarBackgroundVisibility(.visible, for: .navigationBar)
        .toolbarVisibility(.hidden, for: .bottomBar)
        .accessibilityIdentifier("page.history")
        .toolbar {
            ToolbarItem(placement: .principal) {
                accountFilter
                    .disabled(isLoading)
                    .tint(.primary)
            }
            ToolbarItem(id: "history-scope", placement: .topBarTrailing) {
                taxYearPicker
                    .disabled(isLoading)
                    .tint(.primary)
            }
            if #available(iOS 26.0, *) {
                ToolbarSpacer(.fixed, placement: .topBarTrailing)
            }
            ToolbarItem(id: "history-export", placement: .topBarTrailing) {
                Button(L10n.text("Download History"), systemImage: "arrow.down.doc") {
                    prepareExport()
                }
                .labelStyle(.iconOnly)
                .tint(.primary)
                .disabled(filteredActivities.isEmpty)
            }
        }
        .fileExporter(
            isPresented: $showsExporter,
            document: exportDocument,
            contentType: .commaSeparatedText,
            defaultFilename: exportFilename
        ) { result in
            if case let .failure(error) = result {
                exportError = error.localizedDescription
            }
        }
        .alert(L10n.text("Unable to export History"), isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button(L10n.text("OK"), role: .cancel) { exportError = nil }
        } message: {
            Text(L10n.message(exportError ?? ""))
        }
        .task(id: HistoryPreparationKey(
            revision: ledgerRevision, accountIDs: effectiveAccountIDs, locale: appLocale.identifier
        )) {
            guard ledgerRevision > 0 else { return }
            await prepareLedger()
        }
        .onChange(of: effectiveAccountIDs) {
            // Do not show the previous account's amounts under the new scope.
            isLoading = true
        }
        .task {
            #if DEBUG
            if usesPreviewLedger { return }
            #endif
            appearedAt = .now
            await loadLedger()
            await synchronizeTrading212History()
            // Trading 212 builds activity reports asynchronously and allows
            // report-status checks only once per minute. Continue advancing
            // the persisted yearly report queue while History stays visible;
            // SwiftUI cancels this task automatically when the screen closes.
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(65))
                } catch {
                    break
                }
                await synchronizeTrading212History()
            }
        }
    }

    /// On a security's own history, only the tabs with something in them:
    /// a share pays no interest, and most have no fund charge. The whole
    /// ledger keeps its tabs too, except interest for an account that has
    /// never earned any.
    private var visibleCategories: [HistoryCategory] {
        guard ticker != nil else {
            return HistoryCategory.allCases.filter { category in
                category != .interest
                    || !preparedLedger.page(category: .interest, basis: taxYearBasis, year: nil).activities.isEmpty
            }
        }
        return HistoryCategory.allCases.filter { category in
            switch category {
            case .all: true
            case .fees: !feeCharges.isEmpty
            default: !preparedLedger.page(category: category, basis: taxYearBasis, year: nil).activities.isEmpty
            }
        }
    }

    private func historyList(for pageCategory: HistoryCategory) -> some View {
        let page = preparedLedger.page(category: pageCategory, basis: taxYearBasis, year: selectedTaxYear)
        return List {
            if pageCategory == .fees {
                feeSections
            } else {
                if pageCategory == .all {
                    incomeSummarySection
                } else if pageCategory == .orders {
                    Section {
                        HistoryRealisedSummaryCard(calculation: realisedCalculation,
                            ordersBreakdown: page.ordersBreakdown)
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    } footer: {
                        if !page.ordersBreakdown.isComplete {
                            Text(L10n.text("部分卖出缺少成本或汇率，暂不显示占比。"))
                        } else if page.ordersBreakdown.hasLosses {
                            Text(L10n.text("占比按各股票已实现盈亏的绝对值计算，金额保留正负。"))
                        }
                        if let explanation = realisedExplanation(for: pageCategory) {
                            Text(explanation)
                        }
                    }
                } else if pageCategory == .dividends {
                    dividendContributionSection(page)
                } else {
                    Section {
                        SettingsCard {
                            ForEach(summaryMetrics(for: pageCategory)) { metric in
                                HistorySummaryRow(title: metric.title, icon: metric.icon,
                                    value: metric.value, valueColor: metric.color)
                            }
                        }
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }
                }

                if page.activities.isEmpty {
                    Section {
                        CatfolioEmptyState(title: emptyTitle(for: pageCategory), message: emptyDescription)
                            .padding(.vertical, 56)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                } else {
                    if pageCategory == .dividends || pageCategory == .orders {
                        Section {
                            Picker(L10n.text("分组"), selection: pageCategory == .orders ? $ordersByStock : $dividendsByStock) {
                                Text(L10n.text("按日期")).tag(false)
                                Text(L10n.text("按股票")).tag(true)
                            }
                            .pickerStyle(.segmented)
                            .accessibilityIdentifier(pageCategory == .orders ? "history-orders-grouping" : "history-dividends-grouping")
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                        }
                    }
                    if pageCategory == .orders && ordersByStock {
                        orderSecuritySection(page.ordersBreakdown)
                    } else if pageCategory == .dividends && dividendsByStock {
                        let securities = HistoryDividendSecurityGroup.build(page.activities, locale: appLocale)
                        Section {
                            ForEach(Array(securities.enumerated()), id: \.element.id) { index, group in
                                NavigationLink {
                                    HistoryDividendSecurityPage(group: group) { activity in
                                        AnyView(activityRow(activity))
                                    }
                                } label: {
                                    HStack(spacing: 12) {
                                        AssetLogo(ticker: group.id, logoSymbol: group.id, size: 42)
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(group.security.name).appText(.body, weight: .semibold)
                                            Text(group.id).appText(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer(minLength: 8)
                                        FinancialText(group.security.amountUSD.map {
                                            DisplayFormat.money($0, fractionDigits: 2)
                                        } ?? DisplayFormat.money(.nan))
                                            .appNumber(.subheading, weight: .semibold)
                                    }
                                }
                                .accessibilityIdentifier("history-dividend-stock-\(group.id)")
                                .settingsListRow(isFirst: index == 0, isLast: index == securities.count - 1)
                            }
                        }
                    } else {
                    ForEach(page.groups) { group in
                        Section {
                            ForEach(Array(group.activities.enumerated()), id: \.element.id) { index, activity in
                                activityRow(activity, compactLabels: pageCategory == .all)
                                    .settingsListRow(isFirst: index == 0, isLast: index == group.activities.count - 1)
                            }
                        } header: {
                            Text(group.title)
                                .textCase(nil)
                        }
                        .headerProminence(.increased)
                    }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .hardTopScrollEdge()
        .listSectionSpacing(SettingsTemplate.sectionSpacing)
        .contentMargins(.horizontal, SettingsTemplate.pageInset, for: .scrollContent)
        // The list draws its own grouped grey, which is #F2F2F7 and reads as a
        // seam against the template's #F3F3F3 under the chip row.
        .scrollContentBackground(.hidden)
        .contentMargins(.top, SettingsTemplate.pageInset, for: .scrollContent)
        // Space to scroll the last row clear of the floating scope control,
        // without reserving an opaque toolbar-sized viewport at the bottom.
        .contentMargins(.bottom, 76, for: .scrollContent)
        .accessibilityIdentifier("history-list")
        .refreshable {
            await synchronizeTrading212History()
            await loadLedger(showLoading: false)
        }
    }

    private var incomeSummarySection: some View {
        let summary = preparedLedger.incomeSummary(basis: taxYearBasis, year: selectedTaxYear)
        return Section {
            HistoryIncomeSummaryCard(summary: summary)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        } footer: {
            let qualifier = !summary.isComplete
                ? (summary.amountUSD == nil ? L10n.text("部分数据缺失") : L10n.text("仅含已知金额"))
                : summary.realised.estimatedCount > 0 ? L10n.text("含本地估算") : nil
            Text(L10n.text("已实现盈亏 + 股息") + (qualifier.map { " · " + $0 } ?? ""))
        }
    }

    private func orderSecuritySection(_ breakdown: HistoryOrdersBreakdown) -> some View {
        Section {
            ForEach(Array(breakdown.rows.enumerated()), id: \.element.id) { index, group in
                NavigationLink {
                    HistoryOrdersSecurityPage(group: group) { activity in
                        AnyView(activityRow(activity))
                    }
                } label: {
                    HStack(spacing: 12) {
                        AssetLogo(ticker: group.id, logoSymbol: group.id, size: 42)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(group.name).appText(.body, weight: .semibold)
                            Text(group.id + " · " + L10n.text("\(group.orderCount) 笔订单"))
                                .appText(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        FinancialText(group.amountUSD.map {
                            DisplayFormat.money($0, signed: true, fractionDigits: 2)
                        } ?? "—")
                            .appNumber(.subheading, weight: .semibold)
                            .foregroundStyle(group.amountUSD.map(amountColor) ?? .secondary)
                    }
                }
                .accessibilityIdentifier("history-orders-stock-\(group.id)")
                .settingsListRow(isFirst: index == 0, isLast: index == breakdown.rows.count - 1)
            }
        }
    }

    /// Funds held in the selected accounts, and what they charge.
    ///
    /// Every other tab here reads the ledger. This one cannot: a fund's
    /// charge never appears as a transaction — it is taken inside the fund,
    /// out of the price — so the only way to see it is to price the holding
    /// against a published rate. That is also why it is worth showing: it is
    /// the one cost in this app that is never itemised anywhere else.
    @ViewBuilder
    private var feeSections: some View {
        let charges = feeCharges
        if charges.isEmpty {
            Section {
                CatfolioEmptyState(title: L10n.text("没有可计费的基金"),
                                   message: scopedHoldings.isEmpty
                                       ? L10n.text("所选账户暂无持仓。")
                                       : L10n.text("所选账户的持仓里没有找到已公布费率的基金。个股不收管理费。"))
                    .padding(.vertical, 56)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        } else {
            let total = charges.reduce(0) { $0 + $1.annual }
            let fundValue = charges.reduce(0) { $0 + $1.holding.marketValue }
            Section {
                SettingsCard {
                    HistorySummaryRow(title: L10n.text("年费用合计"), icon: .asset("HistoryFee"),
                        value: DisplayFormat.money(total, fractionDigits: 2))
                    HistorySummaryRow(title: L10n.text("基金市值"), value: DisplayFormat.money(fundValue),
                        valueColor: SettingsTemplate.secondaryText)
                    HistorySummaryRow(title: L10n.text("加权费率"), value: fundValue > 0
                        ? (total / fundValue * 100).formatted(.number.precision(.fractionLength(2...3))) + "%"
                        : "—", valueColor: SettingsTemplate.secondaryText)
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            } footer: {
                Text(L10n.text("按当前市值和公布的年费率估算的运行成本，不是已扣除的金额。基金费用在基金内部按日计提，不会出现在交易流水里，也已经反映在净值中——不要再从收益里减一次。"))
            }

            Section(L10n.text("按持仓")) {
                ForEach(Array(charges.enumerated()), id: \.element.holding.id) { index, charge in
                    feeRow(charge).settingsListRow(isFirst: index == 0, isLast: index == charges.count - 1)
                }
            }
        }
    }

    private func feeRow(
        _ charge: HistoryFeeCharge
    ) -> some View {
        HStack(spacing: 12) {
            AssetLogo(
                ticker: charge.holding.ticker,
                logoSymbol: charge.holding.logoSymbol,
                size: 34
            )
            VStack(alignment: .leading, spacing: 4) {
                Text(charge.holding.shortName)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                HStack(spacing: 7) {
                    Text(charge.holding.ticker)
                    Text((charge.rate * 100)
                        .formatted(.number.precision(.fractionLength(2...4))) + "%")
                    // A published figure and an estimate are not the same
                    // claim, and the package distinguishes them.
                    if !charge.isVerified { Text(L10n.text("估算")) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                FinancialText(DisplayFormat.money(charge.annual, fractionDigits: 2))
                    .appNumber(.subheading, weight: .semibold)
                    .lineLimit(1)
                Text(L10n.text("每年"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func summaryMetrics(for category: HistoryCategory) -> [HistorySummaryMetric] {
        switch category {
        // Fees have their own section rather than a metric strip: they are a
        // rate applied to a holding, not a count of things that happened.
        case .fees, .all, .orders: []
        case .dividends:
            [
                HistorySummaryMetric(
                    title: L10n.text("Total dividends"),
                    value: DisplayFormat.money(totalUSD(for: .dividend)),
                    color: CatfolioTheme.positive,
                    icon: .asset("HistoryDividend")
                )
            ] + (dividendForecastUSD.map {
                [HistorySummaryMetric(title: L10n.text("今年预计"), value: DisplayFormat.money($0),
                    color: SettingsTemplate.secondaryText, icon: .asset("HistoryBrokerCalculator"))]
            } ?? [])
        case .interest:
            [
                HistorySummaryMetric(
                    title: L10n.text("Total interest"),
                    value: DisplayFormat.money(totalUSD(for: .interest)),
                    color: CatfolioTheme.positive,
                    icon: .symbol("building.columns.circle.fill")
                )
            ]
        }
    }

    /// A single total in the user's display currency, with its composition
    /// spelled out beneath it.
    ///
    /// The total has to convert, so it is approximate by construction: every
    /// sale is valued at today's rate regardless of when it settled. The
    /// broker's own exact figures are therefore still shown unconverted, in
    /// their own currency, rather than being replaced by the converted total.
    private var taxYearPicker: some View {
        Menu {
            Picker(L10n.text("口径"), selection: Binding(get: { taxYearBasisRaw }, set: { raw in
                guard let basis = TaxYearBasis(rawValue: raw) else { return }
                selectedTaxYear = basis.equivalentLabel(selectedTaxYear)
                taxYearBasisRaw = raw
            })) {
                ForEach(TaxYearBasis.allCases) { Text($0.title).tag($0.rawValue) }
            }
            Divider()
            Button {
                selectedTaxYear = nil
            } label: {
                Label(L10n.text("全部年份"), systemImage: selectedTaxYear == nil ? "checkmark" : "infinity")
            }
            ForEach(preparedLedger.yearLabels[taxYearBasis] ?? [], id: \.self) { year in
                Button {
                    selectedTaxYear = year
                } label: {
                    Label(year, systemImage: selectedTaxYear == year ? "checkmark" : "calendar")
                }
            }
        } label: {
            if let selectedTaxYear {
                Label(selectedTaxYear, systemImage: "calendar")
                    .font(.subheadline)
            } else {
                Label(L10n.text("统计范围"), systemImage: "calendar")
                    .labelStyle(.iconOnly)
            }
        }
        .accessibilityLabel(L10n.text("统计范围"))
        .accessibilityValue(selectedTaxYear ?? L10n.text("全部年份"))
    }

    /// Explains how the rows relate, rather than restating their counts.
    ///
    /// The per-currency broker row is the exact record; the combined total
    /// converts it at today's rate and so will not tie out to what was
    /// actually received. Nothing above says that, and for an account whose
    /// disposals are entirely broker-reported, recounting them here would add
    /// nothing at all.
    private func realisedExplanation(for category: HistoryCategory) -> String? {
        guard category == .orders else { return nil }
        let calculation = realisedCalculation
        guard calculation.saleCount > 0 else { return nil }
        var parts: [String] = []
        if !calculation.brokerTotals.isEmpty {
            parts.append(L10n.text("原币那行是券商记录的精确值；合计按当前汇率折算，不等于成交当时的金额"))
        }
        if calculation.estimatedCount > 0 {
            parts.append(L10n.text("估算部分由本地 FIFO 重建，不适合直接用于报税"))
        }
        if calculation.unavailableCount > 0 {
            parts.append(L10n.text("缺买入成本的 \(calculation.unavailableCount) 笔未计入任何合计"))
        }
        if !calculation.unconvertibleCurrencies.isEmpty {
            let names = calculation.unconvertibleCurrencies.sorted().joined(separator: "/")
            parts.append(L10n.text("\(names) 缺汇率，只出现在原币行"))
        }
        return parts.isEmpty ? nil : L10n.sentences(parts)
    }

    private var accountFilter: some View {
        Menu {
            Button {
                selectedAccountIDs = nil
            } label: {
                Label(L10n.text("All Accounts"), systemImage: isAllAccountsSelected ? "checkmark" : "person.2")
            }

            Divider()

            ForEach(ledger.accounts) { account in
                Button {
                    toggleAccount(account.id)
                } label: {
                    Label(
                        "\(accountNickname(account)) · \(account.brokerName)",
                        systemImage: effectiveAccountIDs.contains(account.id) ? "checkmark" : "circle"
                    )
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text(accountFilterTitle)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .accessibilityHidden(true)
            }
        }
        .buttonStyle(.plain)
        .menuActionDismissBehavior(.disabled)
        .accessibilityLabel(L10n.text("Account filter"))
        .accessibilityValue(accountFilterTitle)
        .accessibilityIdentifier("history-accounts")
    }

    /// One section per security, the largest payer first, each headed with
    /// its total; inside, the payments newest first.
    static func groupsByStock(_ activities: [PortfolioActivity]) -> [ActivityDateGroup] {
        let bySecurity = Dictionary(grouping: activities) { $0.transaction.ticker.uppercased() }
        return bySecurity.map { ticker, payments -> (ActivityDateGroup, Double) in
            let total = payments.reduce(0) { $0 + ($1.amountUSD.isFinite ? $1.amountUSD : 0) }
            let name = payments.first?.securityName.isEmpty == false ? payments[0].securityName : ticker
            let sorted = payments.sorted { $0.transaction.date > $1.transaction.date }
            return (ActivityDateGroup(id: "stock-\(ticker)",
                                      title: "\(name) · \(DisplayFormat.money(total, fractionDigits: 2))",
                                      activities: sorted), total)
        }
        .sorted { $0.1 > $1.1 }
        .map(\.0)
    }

    private func dividendContributionSection(_ page: HistoryActivityPage) -> some View {
        let breakdown = page.dividendBreakdown
        return Section {
            HistoryDividendCard(breakdown: breakdown, totalUSD: page.totalUSD, forecastUSD: dividendForecastUSD)
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
        } footer: {
            if !breakdown.isComplete {
                Text(L10n.text("部分股息金额或汇率缺失，暂不显示占比。"))
            } else if breakdown.hasNegativeTotals {
                Text(L10n.text("冲正已按标的抵扣；占比按净股息为正的标的合计计算，净扣款不计入占比。"))
            }
        }
    }

    /// Logo and name; "买入 · 10 股 · 账户" beneath. The amount on the right,
    /// with what the order has made or lost beneath it.
    private func activityRow(_ activity: PortfolioActivity, compactLabels: Bool = false) -> some View {
        let presentation = preparedLedger.rowPresentations[activity.id] ?? HistoryRowPresentation(activity)
        let isOrder = activity.kind == .buy || activity.kind == .sell
        let gain = rowGain(activity)
        return HStack(spacing: 12) {
            activityIcon(activity)

            VStack(alignment: .leading, spacing: 4) {
                Text(presentation.title)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)

                Text(subtitle(activity, presentation: presentation))
                    .font(compactLabels ? .caption2 : .caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if let disposal = matchedDisposals[activity.transaction.id] {
                    matchingNote(disposal)
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 4) {
                FinancialText(presentation.amount)
                    .appNumber(.subheading, weight: .semibold)
                    .foregroundStyle(isOrder ? CatfolioTheme.primaryText : amountColor(activity.nativeAmount))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)

                if let gain {
                    FinancialText(gain.text, isDirectional: activity.kind == .buy)
                        .appNumber(.caption, weight: .medium)
                        .foregroundStyle(amountColor(gain.value))
                        .lineLimit(1)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func subtitle(_ activity: PortfolioActivity, presentation: HistoryRowPresentation) -> String {
        var parts = [activity.kind.title]
        if !presentation.quantity.isEmpty { parts.append(presentation.quantity) }
        if let account = account(for: activity.transaction.accountKey) {
            parts.append(accountTagTitle(account))
        } else if let name = activity.transaction.accountName, !name.isEmpty {
            parts.append(name)
        }
        return parts.joined(separator: " · ")
    }

    /// A sale's realised result; for a purchase, what it is worth now against
    /// what it cost.
    private func rowGain(_ activity: PortfolioActivity) -> HistoryRowGain? {
        switch activity.kind {
        case .sell: preparedLedger.saleGains[activity.id]
        case .buy: buyGains[activity.id].map {
            HistoryRowGain(text: DisplayFormat.money($0, signed: true), value: $0)
        }
        default: nil
        }
    }

    /// States which acquisitions a disposal was matched against.
    ///
    /// A statement about what the rule did to transactions that already
    /// happened — not a suggestion about what to do next. The window runs
    /// forward from the sale, so this can appear on a row that was correct
    /// when it was written and matched weeks later by a repurchase.
    @ViewBuilder
    private func matchingNote(_ disposal: UKShareMatching.Disposal) -> some View {
        let sameDay = disposal.matches.filter { $0.rule == .sameDay }.reduce(0) { $0 + $1.quantity }
        let later = disposal.matches.compactMap { match -> (String, Double)? in
            guard case .thirtyDay(let acquired) = match.rule else { return nil }
            return (acquired, match.quantity)
        }
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.caption2)
            Text(L10n.text("英国配对"))
                .accessibilityLabel(matchingText(sameDay: sameDay, later: later))
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private func matchingText(sameDay: Double, later: [(String, Double)]) -> String {
        var parts: [String] = []
        if sameDay > 0 {
            parts.append(L10n.text("\(DisplayFormat.shares(sameDay)) 股与当日买入配对"))
        }
        for (date, quantity) in later {
            parts.append(L10n.text("\(DisplayFormat.shares(quantity)) 股与 \(shortDate(date)) 的买入配对"))
        }
        return parts.joined(separator: L10n.clauseSeparator) + L10n.text("（英国 30 天规则，未计入 Section 104 池）")
    }

    private func shortDate(_ iso: String) -> String {
        guard let date = DayDateFormatter.shared.date(from: String(iso.prefix(10))) else { return iso }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    @ViewBuilder
    private func activityIcon(_ activity: PortfolioActivity) -> some View {
        if activity.usesAssetLogo {
            AssetLogo(ticker: activity.transaction.ticker, logoSymbol: activity.transaction.ticker, size: 42)
                .overlay(alignment: .bottomTrailing) {
                    if activity.kind == .buy || activity.kind == .sell {
                        orderDirectionBadge(activity.kind)
                            .offset(x: 3, y: 3)
                    }
                }
        } else {
            Image(systemName: activity.kind.systemImage)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(iconColor(activity.kind))
                .frame(width: 42, height: 42)
                .background(Color(uiColor: .quaternarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityHidden(true)
        }
    }

    private func orderDirectionBadge(_ kind: PortfolioActivityKind) -> some View {
        Image(systemName: kind.systemImage)
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 17, height: 17)
            .background(kind == .buy ? CatfolioTheme.positive : CatfolioTheme.accent, in: Circle())
            .overlay {
                Circle()
                    .stroke(SettingsTemplate.card, lineWidth: 1.5)
            }
            .accessibilityHidden(true)
    }

    private var currentPage: HistoryActivityPage {
        preparedLedger.page(category: category, basis: taxYearBasis, year: selectedTaxYear)
    }

    private var filteredActivities: [PortfolioActivity] {
        currentPage.activities
    }

    private var selectedAccounts: [PortfolioAccount] {
        ledger.accounts.filter { effectiveAccountIDs.contains($0.id) }
    }

    private var allAccountIDs: Set<String> {
        Set(ledger.accounts.map(\.id))
    }

    private var effectiveAccountIDs: Set<String> {
        (selectedAccountIDs ?? allAccountIDs).intersection(allAccountIDs)
    }

    private var isAllAccountsSelected: Bool {
        effectiveAccountIDs == allAccountIDs
    }

    private var accountFilterTitle: String {
        if isAllAccountsSelected { return L10n.text("All Accounts") }
        let accounts = selectedAccounts
        guard let first = accounts.first else { return L10n.text("No Accounts") }
        if accounts.count == 1 { return accountNickname(first) }
        return "\(accountNickname(first)) + \(accounts.count - 1)"
    }

    private func emptyTitle(for category: HistoryCategory) -> String {
        effectiveAccountIDs.isEmpty ? L10n.text("No accounts selected") : L10n.text("No \(L10n.label(category.rawValue))")
    }

    private var emptyDescription: String {
        if effectiveAccountIDs.isEmpty { return L10n.text("Choose at least one account from the account filter.") }
        return L10n.text("Activity appears here after a broker sync, CSV import, or manual entry.")
    }

    private func totalUSD(for kind: PortfolioActivityKind) -> Double {
        let category: HistoryCategory = kind == .dividend ? .dividends : .interest
        return preparedLedger.page(category: category, basis: taxYearBasis, year: selectedTaxYear).totalUSD
    }

    private var matchedDisposals: [String: UKShareMatching.Disposal] {
        preparedLedger.matchedDisposals
    }

    private var realisedByTaxYear: [(label: String, summary: RealisedProfitSummary)] {
        preparedLedger.realisedByTaxYear[taxYearBasis] ?? []
    }

    private var realisedCalculation: RealisedProfitSummary {
        guard let year = selectedTaxYear else {
            return preparedLedger.realisedTotal
        }
        return realisedByTaxYear.first { $0.label == year }?.summary ?? RealisedProfitSummary()
    }

    private func account(for id: String) -> PortfolioAccount? {
        ledger.accounts.first { $0.id == id }
    }

    private func toggleAccount(_ id: String) {
        var next = effectiveAccountIDs
        if next.contains(id) {
            next.remove(id)
        } else {
            next.insert(id)
        }
        selectedAccountIDs = next
    }

    private func accountNickname(_ account: PortfolioAccount) -> String {
        AccountNaming.nickname(from: account.localizedDisplayName, provider: AccountNaming.providerName(for: account.source))
    }

    private func accountTagTitle(_ account: PortfolioAccount) -> String {
        let nickname = accountNickname(account)
        let duplicates = selectedAccounts.filter { accountNickname($0) == nickname }
        guard duplicates.count > 1 else { return nickname }
        return "\(shortBrokerName(account)) · \(nickname)"
    }

    private func shortBrokerName(_ account: PortfolioAccount) -> String {
        switch account.source {
        case "Trading 212": "212"
        case "IBKR Flex": "IBKR"
        default: account.brokerName
        }
    }

    private func amountColor(_ amount: Double) -> Color {
        if amount > 0 { return CatfolioTheme.positive }
        if amount < 0 { return CatfolioTheme.danger }
        return .primary
    }

    private func iconColor(_ kind: PortfolioActivityKind) -> Color {
        switch kind {
        case .dividend, .deposit, .interest: CatfolioTheme.positive
        case .withdrawal: CatfolioTheme.danger
        default: CatfolioTheme.neutralIcon
        }
    }

    @MainActor
    private func loadLedger(showLoading: Bool = true) async {
        if showLoading { isLoading = true }
        do {
            let loaded = try await model.activityLedger()
            guard !Task.isCancelled else { return }
            // Unchanged since the page opened on it: nothing to rebuild, and
            // rebuilding would re-render every list for the same rows.
            if !isLoading, ledgerRevision > 0, loaded == ledger {
                errorMessage = nil
                return
            }
            ledger = loaded
            ledgerRevision += 1
            errorMessage = nil
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    /// Positions as the selected accounts hold them.
    ///
    /// Re-derived per scope rather than filtered from the whole portfolio,
    /// because market value and weight depend on the scope they are computed
    /// in — and the fee figures are money, so an apportioned number would be
    /// wrong rather than approximate.
    private func prepareLedger() async {
        let ledger = ledger
        let accountIDs = effectiveAccountIDs
        let locale = appLocale
        let ticker = ticker
        async let scopedPositions = model.holdings(forAccounts: accountIDs)
        do {
            let prepared = try await model.historyPreparationCache.prepared(
                ledger: ledger, accountIDs: accountIDs, locale: locale, ticker: ticker)
            try Task.checkCancellation()
            preparedLedger = prepared
            if isLoading {
                // A new scope cannot show the previous account's market figures.
                // Same-scope refreshes retain their figures while updating.
                scopedHoldings = []
                feeCharges = []
                buyGains = [:]
                dividendForecastUSD = nil
                let settle = Duration.milliseconds(450) - appearedAt.duration(to: .now)
                if settle > .zero { try await Task.sleep(for: settle) }
                try Task.checkCancellation()
            }
            withAnimation(.easeOut(duration: 0.2)) { isLoading = false }

            let allHoldings = (try? await scopedPositions) ?? []
            try Task.checkCancellation()
            let holdings = allHoldings.filter { ticker == nil || $0.ticker.uppercased() == ticker }
            let activities = prepared.page(category: .orders, basis: .calendar, year: nil).activities
            let (charges, gains) = await Task.detached(priority: .userInitiated) {
                (HistoryFeeCharge.build(holdings: holdings),
                 HistoryRowGain.purchaseGains(activities, holdings: holdings))
            }.value
            try Task.checkCancellation()
            scopedHoldings = holdings
            feeCharges = charges
            buyGains = gains
            // After the lists are up: the schedules are a request per
            // holding, the first time each day.
            let year = String(DayDateCodec.string(from: Date()).prefix(4))
            let received = prepared.page(category: .dividends, basis: .calendar, year: year).totalUSD
            let remaining = await LocalMarketDataClient().remainingDividends(for: holdings)
            try Task.checkCancellation()
            dividendForecastUSD = remaining.covered > 0 || received > 0 ? received + remaining.usd : nil
        } catch {
            // Superseded scopes and a popped page must not publish old results.
        }
    }

    @MainActor
    private func synchronizeTrading212History() async {
        guard !isSyncing, !Task.isCancelled else { return }
        let targetIDs = initialAccountIDs ?? Set(ledger.accounts.map(\.id))
        let targetAccounts = ledger.accounts.filter {
            targetIDs.contains($0.id) && $0.source == "Trading 212"
        }
        let credentials = targetAccounts.compactMap { account -> Trading212AccountCredentials? in
            guard let accountID = account.accountID,
                  let slot = Int(accountID.replacingOccurrences(of: "account-", with: "")),
                  let apiKey = KeychainStore.string(for: "trading212.account-\(slot).api-key"),
                  let apiSecret = KeychainStore.string(for: "trading212.account-\(slot).api-secret"),
                  let value = try? Trading212Credentials(apiKey: apiKey, apiSecret: apiSecret) else {
                return nil
            }
            return Trading212AccountCredentials(slot: slot, credentials: value)
        }
        guard !credentials.isEmpty else { return }

        isSyncing = true
        defer { isSyncing = false }
        do {
            let snapshot = try await Trading212Client().fetchSnapshot(
                accounts: credentials,
                environment: .live
            )
            try Task.checkCancellation()
            let names = Dictionary(uniqueKeysWithValues: targetAccounts.compactMap { account in
                account.accountID.map { ($0, account.name) }
            })
            _ = try await model.importTrading212(
                snapshot,
                accountNames: names,
                replacingAccountsOnly: true
            )
            try Task.checkCancellation()
            await loadLedger(showLoading: false)
        } catch {
            // Keep the locally cached ledger visible. Pull to refresh can retry.
        }
    }

    private func prepareExport() {
        let header = ["Date", "Account", "Broker", "Type", "Name", "Ticker", "Amount", "Quantity", "Price", "Currency"]
        let rows = filteredActivities.map { activity in
            let transaction = activity.transaction
            let account = account(for: transaction.accountKey)
            return [
                transaction.date,
                account.map(accountNickname) ?? transaction.accountName ?? "",
                account?.brokerName ?? transaction.source,
                activity.kind.title,
                activity.title,
                transaction.ticker,
                String(activity.nativeAmount),
                String(transaction.quantity),
                String(transaction.price),
                transaction.currency,
            ]
        }
        let csv = ([header] + rows)
            .map { $0.map(csvField).joined(separator: ",") }
            .joined(separator: "\n")
        exportDocument = HistoryCSVDocument(data: Data(csv.utf8))
        showsExporter = true
    }

    private func csvField(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") else { return value }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private var exportFilename: String {
        "Catfolio-History-\(DayDateCodec.string(from: Date()))"
    }
}

private struct HistoryCSVDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText] }
    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
