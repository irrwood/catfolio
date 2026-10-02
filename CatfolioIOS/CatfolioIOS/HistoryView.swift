import SwiftUI
import UniformTypeIdentifiers

struct PortfolioActivityLedger: Equatable {
    let accounts: [PortfolioAccount]
    let transactions: [LocalTransactionRecord]
    let securityNames: [String: String]
}

enum HistoryCategory: String, CaseIterable, Identifiable {
    case all = "All"
    case orders = "Orders"
    case dividends = "Dividends"
    case interest = "Interest"
    /// Not an activity. The ledger records what was traded; a fund's charge
    /// is a property of holding it, and it is the one cost in this app that
    /// accrues without ever appearing as a transaction.
    case fees = "Fees"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .all: "tray.full"
        case .orders: "arrow.up.arrow.down"
        case .dividends: "banknote.fill"
        case .interest: "percent"
        case .fees: "creditcard"
        }
    }

    func includes(_ kind: PortfolioActivityKind) -> Bool {
        switch self {
        case .all: true
        case .orders: kind == .buy || kind == .sell
        case .dividends: kind == .dividend
        case .fees: false
        case .interest: kind == .interest
        }
    }
}

enum PortfolioActivityKind: Equatable {
    case buy
    case sell
    case dividend
    case deposit
    case withdrawal
    case transfer
    case interest
    case other

    init(action: String) {
        let normalized = action
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")

        if normalized.contains("DIVIDEND") {
            self = .dividend
        } else if normalized.contains("INTEREST") {
            self = .interest
        } else if ["BUY", "BUY_BACK"].contains(normalized) {
            self = .buy
        } else if ["SELL", "SELL_SHORT"].contains(normalized) {
            self = .sell
        } else if ["DEPOSIT", "CASH_DEPOSIT", "FUNDING", "TRANSFER_IN"].contains(normalized) {
            self = .deposit
        } else if ["WITHDRAW", "WITHDRAWAL", "CASH_WITHDRAWAL", "TRANSFER_OUT"].contains(normalized) {
            self = .withdrawal
        } else if normalized.contains("TRANSFER") || normalized.contains("CURRENCY_EXCHANGE") {
            self = .transfer
        } else {
            self = .other
        }
    }

    var title: String {
        switch self {
        case .buy: L10n.text("Buy")
        case .sell: L10n.text("Sell")
        case .dividend: L10n.text("Dividend")
        case .deposit: L10n.text("Deposit")
        case .withdrawal: L10n.text("Withdrawal")
        case .transfer: L10n.text("Transfer")
        case .interest: L10n.text("Interest")
        case .other: L10n.text("Account activity")
        }
    }

    var systemImage: String {
        switch self {
        case .buy: "arrow.down.left"
        case .sell: "arrow.up.right"
        case .dividend: "banknote.fill"
        case .deposit: "arrow.down.to.line.compact"
        case .withdrawal: "arrow.up.from.line.compact"
        case .transfer: "arrow.left.arrow.right"
        case .interest: "percent"
        case .other: "clock.arrow.circlepath"
        }
    }

    var isCashTransfer: Bool {
        self == .deposit || self == .withdrawal || self == .transfer
    }
}

struct PortfolioActivity: Identifiable {
    let transaction: LocalTransactionRecord
    let securityName: String
    let kind: PortfolioActivityKind

    init(transaction: LocalTransactionRecord, securityName: String) {
        self.transaction = transaction
        self.securityName = securityName
        kind = PortfolioActivityKind(action: transaction.action)
    }

    var id: String { transaction.id }

    var nativeAmount: Double {
        let amount = transaction.quantity * transaction.price
        return switch kind {
        case .buy, .withdrawal:
            -abs(amount)
        case .sell, .deposit:
            abs(amount)
        default:
            amount
        }
    }

    var amountUSD: Double {
        nativeAmount * (LocalPortfolioEngine.usdRate(for: transaction.currency) ?? .nan)
    }

    var title: String {
        switch kind {
        case .interest:
            L10n.text("Interest on cash")
        case .deposit:
            L10n.text("Cash deposit")
        case .withdrawal:
            L10n.text("Cash withdrawal")
        case .transfer:
            transaction.ticker == "CASH" ? L10n.text("Cash transfer") : transaction.ticker
        case .other:
            transaction.ticker == "CASH" ? L10n.text("Account activity") : transaction.ticker
        default:
            securityName.isEmpty ? transaction.ticker : securityName
        }
    }

    var displayTitle: String {
        guard usesAssetLogo else { return title }
        if transaction.source == PublicInvestorAccountAdapter.source {
            return PublicDisclosureFormat.securityName(ticker: transaction.ticker, name: title)
        }
        return CompanyNameCatalog.displayName(ticker: transaction.ticker, fallback: title)
    }

    var usesAssetLogo: Bool {
        [.buy, .sell, .dividend].contains(kind)
            && !transaction.ticker.isEmpty
            && transaction.ticker.uppercased() != "CASH"
    }
}

private struct HistorySummaryMetric: Identifiable {
    let title: String
    let value: String
    let color: Color

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
                ContentUnavailableView(
                    L10n.text("Unable to load History"),
                    systemImage: "exclamationmark.triangle",
                    description: Text(L10n.message(errorMessage))
                )
            } else {
                HistoryPagingView(selection: $category, contentID: HistoryPageContentID(
                    ledger: preparedLedger.contentID, basis: taxYearBasisRaw,
                    year: selectedTaxYear, forecast: dividendForecastUSD, gains: buyGains.count
                )) { pageCategory in
                    AnyView(historyList(for: pageCategory))
                }
                .ignoresSafeArea(.container, edges: [.top, .bottom])
            }
        }
        // Cover the home-indicator safe area, not just the list's safe frame.
        .background { SettingsTemplate.pageBackground.ignoresSafeArea() }
        .navigationTitle(ticker.map { "\($0) · \(L10n.text("History"))" } ?? L10n.text("History"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarVisibility(.visible, for: .navigationBar)
        .toolbarVisibility(.hidden, for: .tabBar)
        // The pager supplies one continuous material behind the native title
        // and category row. The navigation bar must not paint a second layer.
        .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
        .toolbarVisibility(.hidden, for: .bottomBar)
        .accessibilityIdentifier("page.history")
        .overlay(alignment: .bottomLeading) {
            if ledger.accounts.count > 1 {
                floatingAccountFilter
                    .disabled(isLoading)
                    .tint(.primary)
                    .buttonBorderShape(.circle)
                    .controlSize(.large)
                    .padding(.leading, 26)
                    .padding(.bottom, 10)
            }
        }
        .toolbar {
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

    private func historyList(for pageCategory: HistoryCategory) -> some View {
        let page = preparedLedger.page(category: pageCategory, basis: taxYearBasis, year: selectedTaxYear)
        return List {
            if pageCategory == .fees {
                feeSections
            } else {
                if pageCategory == .dividends, !page.dividendBreakdown.rows.isEmpty {
                    dividendContributionSection(page)
                } else {
                    Section {
                        ForEach(summaryMetrics(for: pageCategory)) { metric in
                            summaryRow(metric)
                        }
                    } footer: {
                        if let explanation = realisedExplanation(for: pageCategory) {
                            Text(explanation)
                        }
                    }
                }

                if page.activities.isEmpty {
                    Section {
                        ContentUnavailableView(
                            emptyTitle(for: pageCategory),
                            systemImage: emptySystemImage,
                            description: Text(emptyDescription)
                        )
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                    }
                } else {
                    ForEach(page.groups) { group in
                        Section {
                            ForEach(group.activities) { activity in
                                activityRow(activity)
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
        .listStyle(.insetGrouped)
        // The list draws its own grouped grey, which is #F2F2F7 and reads as a
        // seam against the template's #F7F7F7 under the chip row.
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 0, for: .scrollContent)
        // Space to scroll the last row clear of the floating scope control,
        // without reserving an opaque toolbar-sized viewport at the bottom.
        .contentMargins(.bottom, 76, for: .scrollContent)
        .accessibilityIdentifier("history-list")
        .refreshable {
            await synchronizeTrading212History()
            await loadLedger(showLoading: false)
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
                ContentUnavailableView(
                    L10n.text("没有可计费的基金"),
                    systemImage: "creditcard",
                    description: Text(scopedHoldings.isEmpty
                        ? L10n.text("所选账户暂无持仓。")
                        : L10n.text("所选账户的持仓里没有找到已公布费率的基金。个股不收管理费。"))
                )
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            }
        } else {
            let total = charges.reduce(0) { $0 + $1.annual }
            let fundValue = charges.reduce(0) { $0 + $1.holding.marketValue }
            Section {
                LabeledContent(L10n.text("年费用合计")) {
                    Text(DisplayFormat.money(total, fractionDigits: 2))
                        .appNumber(.body, weight: .semibold)
                }
                LabeledContent(L10n.text("基金市值")) {
                    Text(DisplayFormat.money(fundValue))
                        .appNumber(.body)
                }
                LabeledContent(L10n.text("加权费率")) {
                    Text(fundValue > 0
                         ? (total / fundValue * 100).formatted(.number.precision(.fractionLength(2...3))) + "%"
                         : "—")
                        .appNumber(.body)
                }
            } footer: {
                Text(L10n.text("按当前市值和公布的年费率估算的运行成本，不是已扣除的金额。基金费用在基金内部按日计提，不会出现在交易流水里，也已经反映在净值中——不要再从收益里减一次。"))
            }

            Section(L10n.text("按持仓")) {
                ForEach(charges, id: \.holding.id) { charge in
                    feeRow(charge)
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
                Text(DisplayFormat.money(charge.annual, fractionDigits: 2))
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
        case .fees: []
        case .all:
            [
                HistorySummaryMetric(title: L10n.text("Activity"), value: "\(preparedLedger.page(category: .all, basis: taxYearBasis, year: selectedTaxYear).activities.count)", color: .primary),
                HistorySummaryMetric(title: L10n.text("Accounts"), value: "\(selectedAccounts.count)", color: .secondary),
            ]
        case .orders:
            realisedSummaryMetrics
        case .dividends:
            [
                HistorySummaryMetric(
                    title: L10n.text("Total dividends"),
                    value: DisplayFormat.money(totalUSD(for: .dividend)),
                    color: CatfolioTheme.positive
                )
            ] + (dividendForecastUSD.map {
                [HistorySummaryMetric(title: L10n.text("今年预计"), value: DisplayFormat.money($0), color: .secondary)]
            } ?? [])
        case .interest:
            [
                HistorySummaryMetric(
                    title: L10n.text("Total interest"),
                    value: DisplayFormat.money(totalUSD(for: .interest)),
                    color: CatfolioTheme.positive
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
            Picker(L10n.text("口径"), selection: $taxYearBasisRaw) {
                ForEach(TaxYearBasis.allCases) { Text($0.title).tag($0.rawValue) }
            }
            Divider()
            Button {
                selectedTaxYear = nil
            } label: {
                Label(L10n.text("全部年份"), systemImage: selectedTaxYear == nil ? "checkmark" : "infinity")
            }
            ForEach(realisedByTaxYear, id: \.label) { entry in
                Button {
                    selectedTaxYear = entry.label
                } label: {
                    Label(entry.label, systemImage: selectedTaxYear == entry.label ? "checkmark" : "calendar")
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

    private var realisedSummaryMetrics: [HistorySummaryMetric] {
        let calculation = realisedCalculation
        guard calculation.saleCount > 0 else {
            let title = selectedTaxYear.map { L10n.text("\($0) · 没有卖出记录") } ?? L10n.text("已实现盈亏 · 暂无卖出")
            return [HistorySummaryMetric(title: title, value: "—", color: .secondary)]
        }
        let total = calculation.saleCount
        let valued = calculation.brokerCount + calculation.estimatedCount
        var metrics: [HistorySummaryMetric] = []

        let scope = selectedTaxYear.map { "\($0) · " } ?? ""
        if valued > 0 {
            // The estimate and missing-basis counts get their own rows below,
            // so repeating them here only pushed the amount onto a second line.
            // An unconvertible currency has no row of its own, so it stays.
            let suffix = calculation.unconvertibleCurrencies.isEmpty
                ? ""
                : L10n.text("（\(calculation.unconvertibleCurrencies.sorted().joined(separator: "/")) 未计入）")
            metrics.append(HistorySummaryMetric(
                title: L10n.text("\(scope)已实现盈亏\(selectedTaxYear == nil ? L10n.text(" · 合计") : "")\(suffix)"),
                value: DisplayFormat.money(calculation.combinedUSD, signed: true),
                color: calculation.combinedUSD >= 0 ? CatfolioTheme.positive : CatfolioTheme.danger))
        }

        if !calculation.brokerTotals.isEmpty {
            let values = calculation.brokerTotals.keys.sorted().map { currency in
                DisplayFormat.money(
                    NSDecimalNumber(decimal: calculation.brokerTotals[currency]!).doubleValue,
                    currency: currency, signed: true, fractionDigits: 2)
            }.joined(separator: " · ")
            metrics.append(HistorySummaryMetric(
                title: L10n.text("券商 Result · \(calculation.brokerCount)/\(total) 笔 · 原币"),
                value: values, color: .secondary))
        }

        if calculation.estimatedCount > 0 {
            metrics.append(HistorySummaryMetric(
                title: L10n.text("本地估算 · \(calculation.estimatedCount)/\(total) 笔 · 按当前汇率"),
                value: DisplayFormat.money(calculation.estimatedUSD, signed: true),
                color: .secondary))
        }

        if calculation.unavailableCount > 0 {
            metrics.append(HistorySummaryMetric(
                title: L10n.text("缺买入成本 · \(calculation.unavailableCount)/\(total) 笔"),
                value: "—", color: .secondary))
        }

        return metrics
    }

    private func summaryRow(_ metric: HistorySummaryMetric) -> some View {
        LabeledContent(metric.title) {
            Text(metric.value)
                .appNumber(.body, weight: .semibold)
                .foregroundStyle(metric.color)
        }
    }

    @ViewBuilder
    private var floatingAccountFilter: some View {
        if #available(iOS 26.0, *) {
            accountFilter.buttonStyle(.glass)
        } else {
            accountFilter.buttonStyle(.bordered)
        }
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
            Label(accountFilterTitle, systemImage: "person.2")
                .labelStyle(.iconOnly)
        }
        .menuActionDismissBehavior(.disabled)
        .accessibilityLabel(L10n.text("Account filter"))
        .accessibilityValue(accountFilterTitle)
        .accessibilityIdentifier("history-accounts")
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
    private func activityRow(_ activity: PortfolioActivity) -> some View {
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
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if let disposal = matchedDisposals[activity.transaction.id] {
                    matchingNote(disposal)
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 4) {
                Text(presentation.amount)
                    .appNumber(.subheading, weight: .semibold)
                    .foregroundStyle(isOrder ? CatfolioTheme.primaryText : amountColor(activity.nativeAmount))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)

                if let gain {
                    Text(gain.text)
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
            Text(matchingText(sameDay: sameDay, later: later))
                .fixedSize(horizontal: false, vertical: true)
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
                    .stroke(Color(uiColor: .systemBackground), lineWidth: 1.5)
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

    private var emptySystemImage: String {
        effectiveAccountIDs.isEmpty ? "person.2.slash" : "tray"
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
        let worker = Task.detached(priority: .userInitiated) {
            try HistoryPreparedLedger.build(ledger: ledger, accountIDs: accountIDs, locale: locale, ticker: ticker)
        }
        async let scopedPositions = model.holdings(forAccounts: accountIDs)
        do {
            let prepared = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: { worker.cancel() }
            try Task.checkCancellation()
            let allHoldings = (try? await scopedPositions) ?? []
            let holdings = allHoldings.filter { ticker == nil || $0.ticker.uppercased() == ticker }
            try Task.checkCancellation()
            let activities = prepared.page(category: .orders, basis: .calendar, year: nil).activities
            let (charges, gains) = await Task.detached(priority: .userInitiated) {
                (HistoryFeeCharge.build(holdings: holdings),
                 HistoryRowGain.purchaseGains(activities, holdings: holdings))
            }.value
            try Task.checkCancellation()
            preparedLedger = prepared
            if isLoading {
                // The lists are built once the push has landed, and fade in:
                // swapped in part-way through, they caught the animation.
                let settle = Duration.milliseconds(450) - appearedAt.duration(to: .now)
                if settle > .zero { try await Task.sleep(for: settle) }
                try Task.checkCancellation()
            }
            scopedHoldings = holdings
            feeCharges = charges
            buyGains = gains
            withAnimation(.easeOut(duration: 0.2)) { isLoading = false }
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
            let environment = UserDefaults.standard.string(forKey: "trading212.environment")
                .flatMap(Trading212Environment.init(rawValue:)) ?? .live
            let snapshot = try await Trading212Client().fetchSnapshot(
                accounts: credentials,
                environment: environment
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

struct ActivityDateGroup: Identifiable {
    let id: String
    let title: String
    let activities: [PortfolioActivity]
}

struct HistoryHeaderPosition: Equatable {
    let pullDown: CGFloat
    let materialOpacity: Double

    private init(pullDown: CGFloat, materialOpacity: Double) {
        self.pullDown = pullDown
        self.materialOpacity = materialOpacity
    }

    static func interpolated(from: Self, to: Self, fraction: CGFloat) -> Self {
        let t = min(1, max(0, fraction))
        return Self(pullDown: from.pullDown + (to.pullDown - from.pullDown) * t,
                    materialOpacity: from.materialOpacity + (to.materialOpacity - from.materialOpacity) * Double(t))
    }

    init(scrollOffset: CGFloat) {
        pullDown = max(0, -scrollOffset)
        let progress = min(1, max(0, scrollOffset / 16))
        materialOpacity = Double(progress * progress * (3 - 2 * progress))
    }
}

private struct HistoryPreparationKey: Hashable {
    let revision: Int
    let accountIDs: Set<String>
    let locale: String
}

struct HistoryActivityPage {
    var activities: [PortfolioActivity] = []
    var groups: [ActivityDateGroup] = []
    var totalUSD: Double = 0
    var dividendBreakdown = HistoryDividendBreakdown()
}

/// Figma 322:2262: one summary card, with an interactive stacked contribution bar.
struct HistoryDividendCard: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedTicker: String?
    let breakdown: HistoryDividendBreakdown
    let totalUSD: Double
    /// This calendar year's expected dividends; nil until known.
    var forecastUSD: Double? = nil

    private var selectedRow: HistoryDividendBreakdown.Row? {
        breakdown.rows.first { $0.id == selectedTicker } ?? breakdown.rows.first
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.text("股息总计")).appText(.subheading, weight: .medium)
                Spacer(minLength: 12)
                Text(breakdown.isComplete ? DisplayFormat.money(totalUSD) : "—")
                    .appNumber(.subheading)
                    .foregroundStyle(totalUSD < 0
                                     ? CatfolioTheme.loss(for: colorScheme)
                                     : CatfolioTheme.gain(for: colorScheme))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            if let forecastUSD, forecastUSD.isFinite {
                Divider()
                HStack {
                    Text(L10n.text("今年预计")).appText(.subheading, weight: .medium)
                    Spacer(minLength: 12)
                    Text(DisplayFormat.money(forecastUSD))
                        .appNumber(.subheading)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .accessibilityElement(children: .combine)
            }
            Divider()
            VStack(spacing: 13) {
                HStack(spacing: 12) {
                    Text(L10n.text("比例")).appText(.subheading, weight: .medium)
                    Spacer(minLength: 0)
                    Menu {
                        ForEach(breakdown.rows) { row in
                            Button {
                                selectedTicker = row.id
                            } label: {
                                Label(selectionDescription(row), systemImage: row.id == selectedRow?.id ? "checkmark" : "circle")
                            }
                        }
                    } label: {
                        if let row = selectedRow {
                            HStack(spacing: 4) {
                                Text(CompanyNameCatalog.displayName(ticker: row.ticker, fallback: row.name))
                                    .appText(.subheading).lineLimit(1)
                                Text(percentage(row)).appNumber(.subheading, weight: .regular)
                                    .opacity(0.5).fixedSize()
                            }
                            .foregroundStyle(CatfolioPalette.dividendSelection)
                        }
                    }
                    .accessibilityLabel(L10n.text("股息来源占比"))
                    .accessibilityIdentifier("dividend-contribution-selection")
                }
                GeometryReader { geometry in
                    HStack(spacing: 0) {
                        ForEach(Array(breakdown.rows.enumerated().reversed()), id: \.element.id) { index, row in
                            Rectangle()
                                .fill(CatfolioPalette.dividendSeries[index % CatfolioPalette.dividendSeries.count])
                                .frame(width: geometry.size.width * CGFloat(breakdown.share(for: row) ?? 0))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(CatfolioTheme.subtleFill)
                    .overlay {
                        if breakdown.isComplete, breakdown.positiveTotalUSD > 0 {
                            ContributionStripePattern(color: .white)
                                .scaleEffect(x: -1, y: 1)
                                .blendMode(.overlay)
                                .opacity(0.3)
                        }
                    }
                    .compositingGroup()
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .contentShape(Rectangle())
                    .onTapGesture { location in
                        if let row = breakdown.row(at: Double(location.x / max(1, geometry.size.width))) {
                            selectedTicker = row.id
                        }
                    }
                }
                .frame(height: 40)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(L10n.text("股息来源占比"))
                .accessibilityValue(selectedRow.map(selectionDescription) ?? "—")
                .accessibilityAdjustableAction { direction in
                    guard let row = selectedRow,
                          let index = breakdown.rows.firstIndex(where: { $0.id == row.id }) else { return }
                    switch direction {
                    case .increment: selectedTicker = breakdown.rows[min(index + 1, breakdown.rows.count - 1)].id
                    case .decrement: selectedTicker = breakdown.rows[max(index - 1, 0)].id
                    @unknown default: break
                    }
                }
                .accessibilityIdentifier("dividend-contribution-bar")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .background(SettingsTemplate.card, in: RoundedRectangle(cornerRadius: 24))
    }

    private func percentage(_ row: HistoryDividendBreakdown.Row) -> String {
        breakdown.share(for: row).map { DisplayFormat.percent($0 * 100, signed: false) } ?? "—"
    }

    private func selectionDescription(_ row: HistoryDividendBreakdown.Row) -> String {
        "\(CompanyNameCatalog.displayName(ticker: row.ticker, fallback: row.name)) · \(row.ticker) · \(percentage(row)) · \(row.amountUSD.map { DisplayFormat.money($0) } ?? "—")"
    }
}

/// Uses the same account/year scope and USD conversion as the ledger total.
/// Built with the page indexes, never while scrolling or swiping categories.
struct HistoryDividendBreakdown {
    struct Row: Identifiable {
        let ticker: String
        let name: String
        let amountUSD: Double?
        var id: String { ticker }
    }

    var rows: [Row] = []
    var positiveTotalUSD: Double = 0
    var isComplete = true
    var hasNegativeTotals: Bool { rows.contains { ($0.amountUSD ?? 0) < 0 } }

    func share(for row: Row) -> Double? {
        guard isComplete, positiveTotalUSD.isFinite, positiveTotalUSD > 0,
              let amount = row.amountUSD, amount >= 0 else { return nil }
        return min(1, max(0, amount / positiveTotalUSD))
    }

    /// Hit testing follows the exact displayed (reversed) order; zero and
    /// unavailable values occupy no width and cannot steal a neighbouring tap.
    func row(at fraction: Double) -> Row? {
        guard fraction.isFinite, (0...1).contains(fraction) else { return nil }
        let visible = rows.reversed().filter { (share(for: $0) ?? 0) > 0 }
        var edge = 0.0
        for row in visible {
            edge += share(for: row) ?? 0
            if fraction < edge { return row }
        }
        return visible.last
    }

    static func build(_ activities: [PortfolioActivity]) -> Self {
        let grouped = Dictionary(grouping: activities.filter { $0.kind == .dividend }) {
            let ticker = $0.transaction.ticker.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            return ticker.isEmpty ? "CASH" : ticker
        }
        let rows = grouped.map { ticker, entries in
            let amounts = entries.map(\.amountUSD)
            let sum = amounts.reduce(0, +)
            let amount = amounts.allSatisfy(\.isFinite) && sum.isFinite ? sum : nil
            let name = ticker == "CASH" ? L10n.text("未识别标的") : (entries.first?.displayTitle ?? ticker)
            return Row(ticker: ticker, name: name, amountUSD: amount)
        }.sorted {
            if $0.amountUSD != $1.amountUSD {
                return ($0.amountUSD ?? -.infinity) > ($1.amountUSD ?? -.infinity)
            }
            return $0.ticker < $1.ticker
        }
        let total = rows.reduce(0) { $0 + max(0, $1.amountUSD ?? 0) }
        return Self(rows: rows, positiveTotalUSD: total,
                    isComplete: rows.allSatisfy { $0.amountUSD != nil } && total.isFinite)
    }
}

/// Immutable UI indexes, rebuilt off the main actor only when the ledger or
/// account scope changes. A category tap or a scroll never runs FIFO, parses
/// the catalogues, sorts transactions, or regroups a whole history.
/// Prepared once alongside the ledger, rather than formatting on row reuse.
struct HistoryRowPresentation {
    let title: String
    let amount: String
    let quantity: String

    init(_ activity: PortfolioActivity) {
        let isOrder = activity.kind == .buy || activity.kind == .sell
        title = activity.displayTitle
        amount = DisplayFormat.money(isOrder ? abs(activity.nativeAmount) : activity.nativeAmount,
                                     currency: activity.transaction.currency, signed: !isOrder)
        quantity = isOrder ? L10n.text("\(DisplayFormat.shares(activity.transaction.quantity)) shares") : ""
    }
}

/// What an order has made or lost, ready to print under its amount.
struct HistoryRowGain: Equatable, Sendable {
    let text: String
    /// Only the sign is read: it picks the colour.
    let value: Double

    init(text: String, value: Double) {
        self.text = text
        self.value = value
    }

    /// The broker's own figure stays in its own currency.
    init?(_ outcome: RealisedSale.Outcome) {
        switch outcome {
        case let .broker(value, currency, _):
            let amount = NSDecimalNumber(decimal: value).doubleValue
            self.init(text: DisplayFormat.money(amount, currency: currency, signed: true, fractionDigits: 2), value: amount)
        case let .estimated(usd):
            guard usd.isFinite else { return nil }
            self.init(text: DisplayFormat.money(usd, signed: true, fractionDigits: 2), value: usd)
        case .unavailable:
            return nil
        }
    }

    /// Each purchase at today's quote, on today's share basis, in USD.
    /// Skipped when the security is no longer held or either side lacks a rate.
    static func purchaseGains(_ activities: [PortfolioActivity], holdings: [Holding]) -> [String: Double] {
        let quotes = Dictionary(holdings.map { ($0.ticker.uppercased(), $0) }, uniquingKeysWith: { first, _ in first })
        let splits = try? StockSplitCatalog.bundled.get()
        var gains: [String: Double] = [:]
        for activity in activities where activity.kind == .buy {
            let transaction = activity.transaction
            guard let holding = quotes[transaction.ticker.uppercased()], holding.quotePrice > 0,
                  let quoteRate = LocalPortfolioEngine.usdRate(for: holding.quoteCurrency ?? transaction.currency),
                  let costRate = LocalPortfolioEngine.usdRate(for: transaction.currency) else { continue }
            let split = splits?.adjustment(ticker: transaction.ticker, from: transaction.date) ?? 1
            guard split > 0 else { continue }
            let quantity = abs(transaction.quantity) * split
            let cost = transaction.price / split
            let gain = (holding.quotePrice * quoteRate - cost * costRate) * quantity
            if gain.isFinite { gains[activity.id] = gain }
        }
        return gains
    }
}

private struct HistoryPageContentID: Hashable {
    let ledger: UUID
    let basis: String
    let year: String?
    let forecast: Double?
    let gains: Int
}

struct HistoryPreparedLedger {
    let contentID = UUID()
    private struct Period: Hashable {
        var basis: TaxYearBasis = .calendar
        var year: String?
    }

    private var pages: [Period: [HistoryCategory: HistoryActivityPage]] = [:]
    var realisedTotal = RealisedProfitSummary()
    var realisedByTaxYear: [TaxYearBasis: [(label: String, summary: RealisedProfitSummary)]] = [:]
    var matchedDisposals: [String: UKShareMatching.Disposal] = [:]
    var rowPresentations: [String: HistoryRowPresentation] = [:]
    var saleGains: [String: HistoryRowGain] = [:]

    func page(category: HistoryCategory, basis: TaxYearBasis, year: String?) -> HistoryActivityPage {
        let period = year.map { Period(basis: basis, year: $0) } ?? Period()
        return pages[period]?[category] ?? HistoryActivityPage()
    }

    static func build(
        ledger: PortfolioActivityLedger, accountIDs: Set<String>, locale: Locale, ticker: String? = nil
    ) throws -> Self {
        try Task.checkCancellation()
        let symbol = ticker?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let activities = ledger.transactions.compactMap { transaction -> PortfolioActivity? in
            guard accountIDs.contains(transaction.accountKey),
                  symbol == nil || transaction.ticker.uppercased() == symbol else { return nil }
            let activity = PortfolioActivity(
                transaction: transaction,
                securityName: ledger.securityNames[transaction.ticker.uppercased()] ?? transaction.ticker
            )
            return activity.kind.isCashTransfer ? nil : activity
        }
        // Keep the calculator's existing whole-history inputs and algorithms.
        // The year filters apply to its results, never to acquisition lots.
        let transactions = activities.map(\.transaction)
        var result = Self()
        for activity in activities {
            try Task.checkCancellation()
            result.rowPresentations[activity.id] = HistoryRowPresentation(activity)
        }
        let sales = RealisedProfitCalculator.sales(transactions: transactions)
        result.realisedTotal = RealisedProfitCalculator.summarize(sales: sales)
        for sale in sales {
            guard let id = sale.transactionID, let gain = HistoryRowGain(sale.outcome) else { continue }
            result.saleGains[id] = gain
        }
        for basis in TaxYearBasis.allCases {
            try Task.checkCancellation()
            result.realisedByTaxYear[basis] = RealisedProfitCalculator
                .summarize(transactions: transactions, basis: basis)
                .filter { $0.summary.saleCount > 0 }
        }
        let splits = try? StockSplitCatalog.bundled.get()
        let tickers = Set(transactions.filter { $0.action.uppercased() == "SELL" }.map { $0.ticker.uppercased() })
        for ticker in tickers {
            try Task.checkCancellation()
            for disposal in UKShareMatching.disposals(ticker: ticker, transactions: transactions, splits: splits)
            where !disposal.isFullyFromPool {
                result.matchedDisposals[disposal.sourceID] = disposal
            }
        }

        let titles = Dictionary(uniqueKeysWithValues: Set(activities.map { $0.transaction.date }).map {
            ($0, dateGroupTitle($0, locale: locale))
        })
        result.pages[Period()] = makePages(activities, titles: titles)
        for basis in TaxYearBasis.allCases {
            let groups = Dictionary(grouping: activities) { basis.label(for: $0.transaction.date) }
            for (year, entries) in groups {
                try Task.checkCancellation()
                guard let year else { continue }
                result.pages[Period(basis: basis, year: year)] = makePages(entries, titles: titles)
            }
        }
        return result
    }

    private static func makePages(
        _ activities: [PortfolioActivity], titles: [String: String]
    ) -> [HistoryCategory: HistoryActivityPage] {
        let sorted = activities.sorted {
            if $0.transaction.date == $1.transaction.date { return $0.id > $1.id }
            return $0.transaction.date > $1.transaction.date
        }
        return Dictionary(uniqueKeysWithValues: HistoryCategory.allCases.map { category in
            let filtered = sorted.filter { category.includes($0.kind) }
            let grouped = Dictionary(grouping: filtered) { $0.transaction.date }
            let groups = grouped.keys.sorted(by: >).map {
                ActivityDateGroup(id: $0, title: titles[$0] ?? $0, activities: grouped[$0] ?? [])
            }
            return (category, HistoryActivityPage(
                activities: filtered, groups: groups,
                // Sum in the original ledger order, as the previous display did.
                totalUSD: activities.filter { category.includes($0.kind) }.reduce(0) { $0 + $1.amountUSD },
                dividendBreakdown: category == .dividends ? HistoryDividendBreakdown.build(filtered) : .init()
            ))
        })
    }

    private static func dateGroupTitle(_ text: String, locale: Locale) -> String {
        let values = text.split(separator: "-").compactMap { Int($0) }
        guard values.count == 3,
              let date = Calendar.current.date(from: DateComponents(year: values[0], month: values[1], day: values[2]))
        else { return text }
        if Calendar.current.isDateInToday(date) { return L10n.text("Today") }
        if Calendar.current.isDateInYesterday(date) { return L10n.text("Yesterday") }
        return date.formatted(.dateTime.month(.wide).day().year().locale(locale))
    }
}

struct HistoryFeeCharge {
    let holding: Holding
    let rate: Double
    let annual: Double
    let isVerified: Bool

    static func build(holdings: [Holding]) -> [Self] {
        guard let catalog = try? FundFeeCatalog.bundled.get() else { return [] }
        return holdings.compactMap { holding in
            guard let fee = catalog.fee(brokerSymbol: holding.ticker) else { return nil }
            return Self(holding: holding, rate: fee.rate,
                        annual: holding.marketValue * fee.rate, isVerified: fee.isVerified)
        }.sorted { $0.annual > $1.annual }
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
