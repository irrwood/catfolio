import SwiftUI
import UniformTypeIdentifiers

struct PortfolioActivityLedger {
    let accounts: [PortfolioAccount]
    let transactions: [LocalTransactionRecord]
    let securityNames: [String: String]
}

private enum HistoryCategory: String, CaseIterable, Identifiable {
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

private enum PortfolioActivityKind: Equatable {
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

private struct PortfolioActivity: Identifiable {
    let transaction: LocalTransactionRecord
    let securityName: String

    var id: String { transaction.id }

    var kind: PortfolioActivityKind {
        PortfolioActivityKind(action: transaction.action)
    }

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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var categorySelection

    private let initialAccountIDs: Set<String>?
    @State private var ledger = PortfolioActivityLedger(accounts: [], transactions: [], securityNames: [:])
    @State private var selectedAccountIDs: Set<String>?
    @State private var category: HistoryCategory = .all
    @AppStorage("history.taxYearBasis") private var taxYearBasisRaw = TaxYearBasis.calendar.rawValue
    @State private var selectedTaxYear: String?

    private var taxYearBasis: TaxYearBasis {
        TaxYearBasis(rawValue: taxYearBasisRaw) ?? .calendar
    }

    /// The scope applies to the whole page, so dividends and interest can be
    /// read a year at a time too — not just disposals.
    private func inScope(_ date: String) -> Bool {
        guard let selectedTaxYear else { return true }
        return taxYearBasis.label(for: date) == selectedTaxYear
    }
    @State private var scopedHoldings: [Holding] = []
    @State private var isLoading = true
    @State private var isSyncing = false
    @State private var errorMessage: String?
    @State private var exportDocument = HistoryCSVDocument(data: Data())
    @State private var showsExporter = false
    @State private var exportError: String?

    init(initialAccountIDs: Set<String>? = nil) {
        self.initialAccountIDs = initialAccountIDs
        _selectedAccountIDs = State(initialValue: initialAccountIDs)
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--verify-history-orders") {
            _category = State(initialValue: .orders)
        }
        #endif
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage {
                ContentUnavailableView(
                    L10n.text("Unable to load History"),
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage)
                )
            } else {
                historyList
            }
        }
        .navigationTitle(L10n.text("History"))
        .navigationBarTitleDisplayMode(.large)
        .toolbarVisibility(.visible, for: .navigationBar)
        .toolbarVisibility(.hidden, for: .tabBar)
        .toolbar {
            if model.accounts.count > 1 {
                ToolbarItem(id: "history-accounts", placement: .topBarTrailing) {
                    accountFilter
                        .disabled(isLoading)
                        .tint(.primary)
                }
                if #available(iOS 26.0, *) {
                    ToolbarSpacer(.fixed, placement: .topBarTrailing)
                }
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
            Text(exportError ?? "")
        }
        .onChange(of: selectedAccountIDs) {
            Task {
                await loadScopedHoldings()
                await loadMatchedDisposals()
            }
        }
        .task {
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

    private var historyList: some View {
        List {
            categorySection

            if category == .fees {
                feeSections
            } else {
            Section {
                ForEach(summaryMetrics) { metric in
                    summaryRow(metric)
                }
            } footer: {
                if let explanation = realisedExplanation {
                    Text(explanation)
                }
            }

            if filteredActivities.isEmpty {
                Section {
                    ContentUnavailableView(
                        emptyTitle,
                        systemImage: emptySystemImage,
                        description: Text(emptyDescription)
                    )
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                }
            } else {
                ForEach(groupedActivities) { group in
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
        .contentMargins(.top, 0, for: .scrollContent)
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
    private var feeCharges: [(holding: Holding, rate: Double, annual: Double, isVerified: Bool)] {
        guard let catalog = try? FundFeeCatalog.bundled.get() else { return [] }
        return scopedHoldings.compactMap { holding in
            guard let fee = catalog.fee(brokerSymbol: holding.ticker) else { return nil }
            return (holding, fee.rate, holding.marketValue * fee.rate, fee.isVerified)
        }.sorted { $0.annual > $1.annual }
    }

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
        _ charge: (holding: Holding, rate: Double, annual: Double, isVerified: Bool)
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

    private var summaryMetrics: [HistorySummaryMetric] {
        switch category {
        // Fees have their own section rather than a metric strip: they are a
        // rate applied to a holding, not a count of things that happened.
        case .fees: []
        case .all:
            [
                HistorySummaryMetric(title: L10n.text("Activity"), value: "\(filteredActivities.count)", color: .primary),
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
            ]
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
    private var realisedExplanation: String? {
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
        return parts.isEmpty ? nil : parts.joined(separator: "。") + "。"
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
    }

    @ViewBuilder
    private var categorySection: some View {
        let section = Section {
            categoryPicker
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 8, trailing: 0))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
        if #available(iOS 26.0, *) {
            section.listSectionMargins(.horizontal, 0)
        } else {
            section
        }
    }

    private var categoryContentInset: CGFloat {
        if #available(iOS 26.0, *) { 16 } else { 0 }
    }

    private var categoryPicker: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                Group {
                    if #available(iOS 26.0, *) {
                        GlassEffectContainer(spacing: 8) {
                            categoryButtons
                        }
                    } else {
                        categoryButtons
                    }
                }
                .padding(.vertical, 8)
            }
            .contentMargins(.horizontal, categoryContentInset, for: .scrollContent)
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .onChange(of: category) {
                withAnimation(reduceMotion ? nil : .smooth(duration: 0.22)) {
                    proxy.scrollTo(category.id)
                }
            }
        }
    }

    private var categoryButtons: some View {
        HStack(spacing: 8) {
            ForEach(HistoryCategory.allCases) { option in
                categoryButton(option)
                    .id(option.id)
            }
        }
    }

    @ViewBuilder
    private func categoryButton(_ option: HistoryCategory) -> some View {
        let isSelected = category == option
        let button = Button {
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.22)) {
                category = option
            }
        } label: {
            Text(L10n.label(option.rawValue))
                .font(.body.weight(.medium))
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .frame(minWidth: 80, minHeight: 48)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])

        if isSelected {
            if #available(iOS 26.0, *) {
                button
                    .glassEffect(.regular.interactive(), in: .capsule)
                    .glassEffectID("category-selection", in: categorySelection)
            } else {
                button
                    .background(.thinMaterial, in: Capsule())
                    .matchedGeometryEffect(id: "category-selection", in: categorySelection)
            }
        } else {
            button
        }
    }

    private func activityRow(_ activity: PortfolioActivity) -> some View {
        HStack(spacing: 12) {
            activityIcon(activity)

            VStack(alignment: .leading, spacing: 4) {
                Text(activity.title)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)

                HStack(spacing: 7) {
                    Text(activity.kind.title)
                        .lineLimit(1)

                    if selectedAccounts.count > 1,
                       let account = account(for: activity.transaction.accountKey) {
                        accountTag(account)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if let disposal = matchedDisposals[activity.transaction.id] {
                    matchingNote(disposal)
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 4) {
                let isOrder = activity.kind == .buy || activity.kind == .sell
                Text(DisplayFormat.money(
                    isOrder ? abs(activity.nativeAmount) : activity.nativeAmount,
                    currency: activity.transaction.currency,
                    // Order values describe trade size, not cash-flow direction
                    // or profit. Keep both buys and sells unsigned and neutral.
                    signed: !isOrder
                ))
                .appNumber(.subheading, weight: .semibold)
                .foregroundStyle(isOrder ? Color.primary : amountColor(activity.nativeAmount))
                .lineLimit(1)
                .minimumScaleFactor(0.72)

                if isOrder {
                    Text(L10n.text("\(DisplayFormat.shares(activity.transaction.quantity)) shares"))
                        .appNumber(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if activity.kind == .dividend, activity.transaction.ticker != "CASH" {
                    Text(activity.transaction.ticker)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
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
        return parts.joined(separator: "；") + L10n.text("（英国 30 天规则，未计入 Section 104 池）")
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

    private func accountTag(_ account: PortfolioAccount) -> some View {
        Button {
            if effectiveAccountIDs == [account.id] {
                selectedAccountIDs = nil
            } else {
                selectedAccountIDs = [account.id]
            }
        } label: {
            Text(accountTagTitle(account))
                .lineLimit(1)
        }
        .buttonStyle(.borderless)
        .accessibilityHint("Filter History to this account; tap again to show all accounts")
    }

    private var allActivities: [PortfolioActivity] {
        ledger.transactions.compactMap { transaction in
            let activity = PortfolioActivity(
                transaction: transaction,
                securityName: ledger.securityNames[transaction.ticker.uppercased()] ?? transaction.ticker
            )
            return activity.kind.isCashTransfer ? nil : activity
        }
    }

    private var filteredActivities: [PortfolioActivity] {
        allActivities
            .filter { effectiveAccountIDs.contains($0.transaction.accountKey) }
            .filter { category.includes($0.kind) }
            .filter { inScope($0.transaction.date) }
            .sorted {
                if $0.transaction.date == $1.transaction.date { return $0.id > $1.id }
                return $0.transaction.date > $1.transaction.date
            }
    }

    private var groupedActivities: [ActivityDateGroup] {
        let groups = Dictionary(grouping: filteredActivities) { $0.transaction.date }
        return groups.keys.sorted(by: >).map { dateText in
            ActivityDateGroup(
                id: dateText,
                title: dateGroupTitle(dateText),
                activities: groups[dateText] ?? []
            )
        }
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

    private var emptyTitle: String {
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
        allActivities
            .filter { effectiveAccountIDs.contains($0.transaction.accountKey) && $0.kind == kind }
            .filter { inScope($0.transaction.date) }
            .reduce(0) { $0 + $1.amountUSD }
    }

    /// Account-scoped but never year-scoped: FIFO has to see the whole
    /// history, or a lot bought outside the selected year stops backing the
    /// sale it actually settled.
    private var accountTransactions: [LocalTransactionRecord] {
        allActivities
            .filter { effectiveAccountIDs.contains($0.transaction.accountKey) }
            .map(\.transaction)
    }

    /// Every tax year present in the ledger, newest first. FIFO runs across
    /// the whole history inside the calculator; only the results are grouped.
    /// Disposals that were matched against an acquisition rather than the
    /// pool, keyed by the ledger row they came from.
    ///
    /// Held in state and computed once per ledger, never in the body. As a
    /// computed property this ran on every row: the matcher walks the whole
    /// transaction list once per security, so rendering N rows cost N × T × X
    /// and the screen simply never finished. That is the second time this
    /// page has been given an expensive answer to a per-row question.
    @State private var matchedDisposals: [String: UKShareMatching.Disposal] = [:]

    private func loadMatchedDisposals() async {
        let transactions = accountTransactions
        matchedDisposals = await Task.detached(priority: .userInitiated) {
            let splits = try? StockSplitCatalog.bundled.get()
            let tickers = Set(
                transactions
                    .filter { $0.action.uppercased() == "SELL" }
                    .map { $0.ticker.uppercased() }
            )
            var byRow: [String: UKShareMatching.Disposal] = [:]
            for ticker in tickers {
                for disposal in UKShareMatching.disposals(
                    ticker: ticker, transactions: transactions, splits: splits
                ) where !disposal.isFullyFromPool {
                    byRow[disposal.sourceID] = disposal
                }
            }
            return byRow
        }.value
    }

    private var realisedByTaxYear: [(label: String, summary: RealisedProfitSummary)] {
        RealisedProfitCalculator.summarize(transactions: accountTransactions, basis: taxYearBasis)
            .filter { $0.summary.saleCount > 0 }
    }

    private var realisedCalculation: RealisedProfitSummary {
        guard let year = selectedTaxYear else {
            return RealisedProfitCalculator.summarize(transactions: accountTransactions)
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
        AccountNaming.nickname(from: account.displayName, provider: AccountNaming.providerName(for: account.source))
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

    private func dateGroupTitle(_ text: String) -> String {
        guard let date = localDate(from: text) else { return text }
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return L10n.text("Today") }
        if calendar.isDateInYesterday(date) { return L10n.text("Yesterday") }
        return date.formatted(.dateTime.month(.wide).day().year())
    }

    private func localDate(from text: String) -> Date? {
        let values = text.split(separator: "-").compactMap { Int($0) }
        guard values.count == 3 else { return nil }
        return Calendar.current.date(from: DateComponents(year: values[0], month: values[1], day: values[2]))
    }

    @MainActor
    private func loadLedger(showLoading: Bool = true) async {
        if showLoading { isLoading = true }
        defer { isLoading = false }
        do {
            ledger = try await model.activityLedger()
            errorMessage = nil
            await loadScopedHoldings()
            await loadMatchedDisposals()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Positions as the selected accounts hold them.
    ///
    /// Re-derived per scope rather than filtered from the whole portfolio,
    /// because market value and weight depend on the scope they are computed
    /// in — and the fee figures are money, so an apportioned number would be
    /// wrong rather than approximate.
    private func loadScopedHoldings() async {
        scopedHoldings = (try? await model.holdings(forAccounts: effectiveAccountIDs)) ?? []
    }

    @MainActor
    private func synchronizeTrading212History() async {
        guard !isSyncing else { return }
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
            let names = Dictionary(uniqueKeysWithValues: targetAccounts.compactMap { account in
                account.accountID.map { ($0, account.name) }
            })
            _ = try await model.importTrading212(
                snapshot,
                accountNames: names,
                replacingAccountsOnly: true
            )
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

private struct ActivityDateGroup: Identifiable {
    let id: String
    let title: String
    let activities: [PortfolioActivity]
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
