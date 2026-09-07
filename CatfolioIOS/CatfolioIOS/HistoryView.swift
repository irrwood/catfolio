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

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .all: "tray.full"
        case .orders: "arrow.up.arrow.down"
        case .dividends: "banknote.fill"
        case .interest: "percent"
        }
    }

    func includes(_ kind: PortfolioActivityKind) -> Bool {
        switch self {
        case .all: true
        case .orders: kind == .buy || kind == .sell
        case .dividends: kind == .dividend
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
        case .buy: "Buy"
        case .sell: "Sell"
        case .dividend: "Dividend"
        case .deposit: "Deposit"
        case .withdrawal: "Withdrawal"
        case .transfer: "Transfer"
        case .interest: "Interest"
        case .other: "Account activity"
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
            "Interest on cash"
        case .deposit:
            "Cash deposit"
        case .withdrawal:
            "Cash withdrawal"
        case .transfer:
            transaction.ticker == "CASH" ? "Cash transfer" : transaction.ticker
        case .other:
            transaction.ticker == "CASH" ? "Account activity" : transaction.ticker
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
                    "Unable to load History",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage)
                )
            } else {
                historyList
            }
        }
        .navigationTitle("History")
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
                Button("Download History", systemImage: "arrow.down.doc") {
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
        .alert("Unable to export History", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("OK", role: .cancel) { exportError = nil }
        } message: {
            Text(exportError ?? "")
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
        .listStyle(.insetGrouped)
        .contentMargins(.top, 0, for: .scrollContent)
        .refreshable {
            await synchronizeTrading212History()
            await loadLedger(showLoading: false)
        }
    }

    private var summaryMetrics: [HistorySummaryMetric] {
        switch category {
        case .all:
            [
                HistorySummaryMetric(title: "Activity", value: "\(filteredActivities.count)", color: .primary),
                HistorySummaryMetric(title: "Accounts", value: "\(selectedAccounts.count)", color: .secondary),
            ]
        case .orders:
            realisedSummaryMetrics
        case .dividends:
            [
                HistorySummaryMetric(
                    title: "Total dividends",
                    value: DisplayFormat.money(totalUSD(for: .dividend)),
                    color: CatfolioTheme.positive
                )
            ]
        case .interest:
            [
                HistorySummaryMetric(
                    title: "Total interest",
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
            Picker("口径", selection: $taxYearBasisRaw) {
                ForEach(TaxYearBasis.allCases) { Text($0.title).tag($0.rawValue) }
            }
            Divider()
            Button {
                selectedTaxYear = nil
            } label: {
                Label("全部年份", systemImage: selectedTaxYear == nil ? "checkmark" : "infinity")
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
                Label("统计范围", systemImage: "calendar")
                    .labelStyle(.iconOnly)
            }
        }
        .accessibilityLabel("统计范围")
        .accessibilityValue(selectedTaxYear ?? "全部年份")
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
            parts.append("原币那行是券商记录的精确值；合计按当前汇率折算，不等于成交当时的金额")
        }
        if calculation.estimatedCount > 0 {
            parts.append("估算部分由本地 FIFO 重建，不适合直接用于报税")
        }
        if calculation.unavailableCount > 0 {
            parts.append("缺买入成本的 \(calculation.unavailableCount) 笔未计入任何合计")
        }
        if !calculation.unconvertibleCurrencies.isEmpty {
            let names = calculation.unconvertibleCurrencies.sorted().joined(separator: "/")
            parts.append("\(names) 缺汇率，只出现在原币行")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "。") + "。"
    }

    private var realisedSummaryMetrics: [HistorySummaryMetric] {
        let calculation = realisedCalculation
        guard calculation.saleCount > 0 else {
            let title = selectedTaxYear.map { "\($0) · 没有卖出记录" } ?? "已实现盈亏 · 暂无卖出"
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
                : "（\(calculation.unconvertibleCurrencies.sorted().joined(separator: "/")) 未计入）"
            metrics.append(HistorySummaryMetric(
                title: "\(scope)已实现盈亏\(selectedTaxYear == nil ? " · 合计" : "")\(suffix)",
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
                title: "券商 Result · \(calculation.brokerCount)/\(total) 笔 · 原币",
                value: values, color: .secondary))
        }

        if calculation.estimatedCount > 0 {
            metrics.append(HistorySummaryMetric(
                title: "本地估算 · \(calculation.estimatedCount)/\(total) 笔 · 按当前汇率",
                value: DisplayFormat.money(calculation.estimatedUSD, signed: true),
                color: .secondary))
        }

        if calculation.unavailableCount > 0 {
            metrics.append(HistorySummaryMetric(
                title: "缺买入成本 · \(calculation.unavailableCount)/\(total) 笔",
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
                Label("All Accounts", systemImage: isAllAccountsSelected ? "checkmark" : "person.2")
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
        .accessibilityLabel("Account filter")
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
            Text(option.rawValue)
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
                    Text("\(DisplayFormat.shares(activity.transaction.quantity)) shares")
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
        if isAllAccountsSelected { return "All Accounts" }
        let accounts = selectedAccounts
        guard let first = accounts.first else { return "No Accounts" }
        if accounts.count == 1 { return accountNickname(first) }
        return "\(accountNickname(first)) + \(accounts.count - 1)"
    }

    private var emptyTitle: String {
        effectiveAccountIDs.isEmpty ? "No accounts selected" : "No \(category.rawValue.lowercased())"
    }

    private var emptySystemImage: String {
        effectiveAccountIDs.isEmpty ? "person.2.slash" : "tray"
    }

    private var emptyDescription: String {
        if effectiveAccountIDs.isEmpty { return "Choose at least one account from the account filter." }
        return "Activity appears here after a broker sync, CSV import, or manual entry."
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
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
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
        } catch {
            errorMessage = error.localizedDescription
        }
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
