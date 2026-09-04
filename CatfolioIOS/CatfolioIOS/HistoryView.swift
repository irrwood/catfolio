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
    case transactions = "Transactions"
    case interest = "Interest"

    var id: String { rawValue }

    var systemImage: String? {
        switch self {
        case .all: nil
        case .orders: "arrow.up.arrow.down"
        case .dividends: "banknote.fill"
        case .transactions: "creditcard.fill"
        case .interest: "percent"
        }
    }

    func includes(_ kind: PortfolioActivityKind) -> Bool {
        switch self {
        case .all: true
        case .orders: kind == .buy || kind == .sell
        case .dividends: kind == .dividend
        case .transactions: kind == .deposit || kind == .withdrawal || kind == .transfer
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
}

private struct PortfolioActivity: Identifiable {
    let transaction: LocalTransactionRecord
    let securityName: String

    var id: String {
        [
            transaction.accountKey,
            transaction.tradeID ?? [
                transaction.date,
                transaction.action,
                transaction.ticker,
                String(transaction.quantity),
                String(transaction.price),
            ].joined(separator: "|"),
        ].joined(separator: "|")
    }

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
        nativeAmount * (LocalPortfolioEngine.usdRate(for: transaction.currency) ?? 1)
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

private struct RealisedLot {
    var quantity: Double
    let costPerShareUSD: Double
}

private struct RealisedCalculation {
    var totalUSD = 0.0
    var hasIncompleteCostBasis = false
}

struct HistoryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    private let initialAccountIDs: Set<String>?
    @State private var ledger = PortfolioActivityLedger(accounts: [], transactions: [], securityNames: [:])
    @State private var selectedAccountIDs: Set<String>?
    @State private var category: HistoryCategory = .all
    @State private var isLoading = true
    @State private var isSyncing = false
    @State private var errorMessage: String?
    @State private var exportDocument = HistoryCSVDocument(data: Data())
    @State private var showsExporter = false
    @State private var exportError: String?

    init(initialAccountIDs: Set<String>? = nil) {
        self.initialAccountIDs = initialAccountIDs
        _selectedAccountIDs = State(initialValue: initialAccountIDs)
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
        .background(CatfolioTheme.pageBackground(for: colorScheme))
        .navigationTitle("History")
        .navigationBarTitleDisplayMode(.large)
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Back", systemImage: "xmark") {
                    dismiss()
                }
                .labelStyle(.iconOnly)
                .accessibilityLabel("Back")
            }

            ToolbarItemGroup(placement: .topBarTrailing) {
                if ledger.accounts.count > 1 {
                    accountFilter
                }

                Button("Download History", systemImage: "arrow.down.doc") {
                    prepareExport()
                }
                .labelStyle(.iconOnly)
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
            Section {
                categoryPicker
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            Section {
                summary
                    .listRowInsets(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
                    .listRowSeparator(.hidden)
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
                    Section(group.title) {
                        ForEach(group.activities) { activity in
                            activityRow(activity)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 0, for: .scrollContent)
        .refreshable {
            await synchronizeTrading212History()
            await loadLedger(showLoading: false)
        }
        .overlay(alignment: .top) {
            if isSyncing {
                Label("Updating History", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: isSyncing)
    }

    @ViewBuilder
    private var summary: some View {
        switch category {
        case .all:
            HistorySummarySurface {
                summaryMetric("ACTIVITY", value: "\(filteredActivities.count)", color: .primary)
                summaryMetric("ACCOUNTS", value: "\(selectedAccounts.count)", color: .secondary)
            }
        case .orders:
            HistorySummarySurface {
                let calculation = realisedCalculation
                let realised = calculation.totalUSD
                summaryMetric(
                    calculation.hasIncompleteCostBasis ? "REALISED P/L · PARTIAL" : "REALISED P/L",
                    value: DisplayFormat.money(realised, signed: true),
                    color: realised >= 0 ? CatfolioTheme.positive : CatfolioTheme.danger
                )
            }
        case .dividends:
            HistorySummarySurface {
                summaryMetric(
                    "TOTAL DIVIDENDS",
                    value: DisplayFormat.money(totalUSD(for: .dividend)),
                    color: CatfolioTheme.positive
                )
            }
        case .transactions:
            HistorySummarySurface {
                summaryMetric(
                    "DEPOSITS",
                    value: DisplayFormat.money(abs(totalUSD(for: .deposit))),
                    color: CatfolioTheme.positive
                )
                summaryMetric(
                    "WITHDRAWALS",
                    value: DisplayFormat.money(abs(totalUSD(for: .withdrawal))),
                    color: CatfolioTheme.danger
                )
            }
        case .interest:
            HistorySummarySurface {
                summaryMetric(
                    "TOTAL INTEREST",
                    value: DisplayFormat.money(totalUSD(for: .interest)),
                    color: CatfolioTheme.positive
                )
            }
        }
    }

    private func summaryMetric(_ title: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title2.weight(.semibold).monospacedDigit())
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

    private var categoryPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            categoryButtons
        }
        .contentMargins(.horizontal, 16, for: .scrollContent)
        .scrollTargetBehavior(.viewAligned)
        .scrollBounceBehavior(.basedOnSize)
        .accessibilityElement(children: .contain)
    }

    private var categoryButtons: some View {
        HStack(spacing: 8) {
            ForEach(HistoryCategory.allCases) { option in
                categoryButton(option)
            }
        }
        .scrollTargetLayout()
    }

    @ViewBuilder
    private func categoryButton(_ option: HistoryCategory) -> some View {
        let isSelected = category == option

        if isSelected {
            Button {
                withAnimation(.snappy) { category = option }
            } label: {
                categoryLabel(option, isSelected: isSelected)
                    .foregroundStyle(Color(uiColor: .systemBackground))
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .tint(.primary)
            .id(option.id)
            .accessibilityAddTraits(.isSelected)
        } else {
            Button {
                withAnimation(.snappy) { category = option }
            } label: {
                categoryLabel(option, isSelected: isSelected)
                    .foregroundStyle(.primary)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .tint(.secondary)
            .id(option.id)
        }
    }

    private func categoryLabel(_ option: HistoryCategory, isSelected: Bool) -> some View {
        HStack(spacing: 6) {
            if let systemImage = option.systemImage {
                Image(systemName: systemImage)
            }
            Text(option.rawValue)
                .lineLimit(1)
        }
        .font(.subheadline.weight(.semibold))
        .fixedSize(horizontal: true, vertical: false)
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
                .font(.body.weight(.semibold).monospacedDigit())
                .foregroundStyle(isOrder ? Color.primary : amountColor(activity.nativeAmount))
                .lineLimit(1)
                .minimumScaleFactor(0.72)

                if isOrder {
                    Text("\(DisplayFormat.shares(activity.transaction.quantity)) shares")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if activity.kind == .dividend, activity.transaction.ticker != "CASH" {
                    Text(activity.transaction.ticker)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 5)
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
            HStack(spacing: 4) {
                Circle()
                    .fill(accountTint(account.id))
                    .frame(width: 7, height: 7)
                Text(accountTagTitle(account))
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color(uiColor: .quaternarySystemFill), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Filter History to this account; tap again to show all accounts")
    }

    private var allActivities: [PortfolioActivity] {
        ledger.transactions.map { transaction in
            PortfolioActivity(
                transaction: transaction,
                securityName: ledger.securityNames[transaction.ticker.uppercased()] ?? transaction.ticker
            )
        }
    }

    private var filteredActivities: [PortfolioActivity] {
        allActivities
            .filter { effectiveAccountIDs.contains($0.transaction.accountKey) }
            .filter { category.includes($0.kind) }
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
            .reduce(0) { $0 + $1.amountUSD }
    }

    private var realisedProfitLossUSD: Double {
        realisedCalculation.totalUSD
    }

    /// FIFO matches each sale only against previously imported purchase lots.
    /// The sale's gross proceeds remain separate and are never treated as P/L.
    private var realisedCalculation: RealisedCalculation {
        var lotsByPosition: [String: [RealisedLot]] = [:]
        var result = RealisedCalculation()
        let orders = allActivities
            .filter {
                effectiveAccountIDs.contains($0.transaction.accountKey)
                    && ($0.kind == .buy || $0.kind == .sell)
            }
            .sorted {
                if $0.transaction.date == $1.transaction.date {
                    if $0.kind != $1.kind { return $0.kind == .buy }
                    return $0.id < $1.id
                }
                return $0.transaction.date < $1.transaction.date
            }

        for activity in orders {
            let transaction = activity.transaction
            let key = "\(transaction.accountKey)|\(transaction.ticker.uppercased())"
            let rate = LocalPortfolioEngine.usdRate(for: transaction.currency) ?? 1
            if activity.kind == .buy {
                lotsByPosition[key, default: []].append(RealisedLot(
                    quantity: abs(transaction.quantity),
                    costPerShareUSD: transaction.price * rate
                ))
                continue
            }

            let saleQuantity = abs(transaction.quantity)
            var remaining = saleQuantity
            var lots = lotsByPosition[key] ?? []
            var saleProfitLoss = 0.0
            let proceedsPerShareUSD = transaction.price * rate
            while remaining > 0.000_000_1, !lots.isEmpty {
                let matched = min(remaining, lots[0].quantity)
                saleProfitLoss += (proceedsPerShareUSD - lots[0].costPerShareUSD) * matched
                remaining -= matched
                lots[0].quantity -= matched
                if lots[0].quantity <= 0.000_000_1 {
                    lots.removeFirst()
                }
            }
            lotsByPosition[key] = lots
            if let brokerRealised = transaction.realisedProfitLoss {
                let brokerCurrency = transaction.realisedProfitLossCurrency ?? transaction.currency
                let brokerRate = LocalPortfolioEngine.usdRate(for: brokerCurrency) ?? 1
                let brokerRealisedUSD = brokerRealised * brokerRate
                result.totalUSD += brokerRealisedUSD
            } else if remaining <= max(0.000_000_1, saleQuantity * 0.000_001) {
                // Broker-reported P/L is authoritative when present. When it
                // is absent, a sale with a complete imported cost basis can be
                // calculated locally without confusing proceeds for profit.
                result.totalUSD += saleProfitLoss
            } else {
                // Never extrapolate from a partially imported purchase history.
                // Keep exact/complete sales visible and identify the total as partial.
                result.hasIncompleteCostBasis = true
            }
        }
        return result
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

    private func accountTint(_ key: String) -> Color {
        let palette: [Color] = [
            CatfolioPalette.neutral500,
            CatfolioPalette.sky700,
            CatfolioPalette.violet500,
            CatfolioPalette.clay500,
            CatfolioPalette.teal500,
        ]
        let stableValue = key.unicodeScalars.reduce(0) { ($0 &* 31) &+ Int($1.value) }
        return palette[abs(stableValue) % palette.count]
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

private struct HistorySummarySurface<Content: View>: View {
    @ViewBuilder let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            content
        }
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
