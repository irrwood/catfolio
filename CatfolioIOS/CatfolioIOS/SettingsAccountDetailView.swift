import SwiftUI
import UIKit

enum AccountManagementSheet: String, Identifiable {
    case robinhood
    case snaptrade
    case trading212
    case moomoo
    case ibkr
    case csv
    case manualTransaction

    var id: String { rawValue }
}

struct AccountNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

struct AccountDetailView: View {
    @Environment(\.locale) private var appLocale
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    let accountID: String
    let initialAccount: PortfolioAccount

    @State private var activeSheet: AccountManagementSheet?
    @State private var showsRenamePrompt = false
    @State private var showsDeleteConfirmation = false
    @State private var accountNameDraft = ""
    @State private var notice: AccountNotice?
    @State private var isWorking = false
    @State private var dataMatchStatus = L10n.text("无异常")

    private var account: PortfolioAccount {
        model.accounts.first(where: { $0.id == accountID }) ?? initialAccount
    }

    var body: some View {
        SettingsPage(
            // The account names the screen and the holding count sits under
            // it, so both fold into the small two-line title on scroll. The
            // value stays in the page, where it is the largest thing on it.
            title: account.localizedDisplayName,
            subtitle: L10n.text("\(account.positionCount) 个持仓"),
            bottomInset: 24
        ) {
            CatfolioDisplayAmountText(text: DisplayFormat.money(account.marketValueUSD), size: 34, symbolSize: 22)
                .frame(maxWidth: .infinity, alignment: .leading)

            if model.isFakeDataMode {
                SettingsFootnote(L10n.text("这里是独立演示账户，与真实持仓无关。"))
            }

            SettingsSection(L10n.text("账户信息")) {
                SettingsButtonRow(
                    title: L10n.text("账户名称"),
                    value: account.localizedDisplayName
                ) {
                    accountNameDraft = account.displayName
                    showsRenamePrompt = true
                }
                .disabled(model.isFakeDataMode || model.isPublicInvestorMode)

                // Trading 212's API cannot say whether an account is an ISA, so
                // this is the one type the person states rather than the app
                // reading it; every other broker's type stays a value.
                if account.source == "Trading 212" {
                    SettingsMenuRow(
                        title: L10n.text("账户类型"),
                        value: L10n.label(account.accountType),
                        selection: accountTypeSelection
                    ) {
                        ForEach(Trading212AccountType.allCases) { type in
                            Text(type.displayName).tag(Optional(type))
                        }
                    }
                    .disabled(model.isFakeDataMode || model.isPublicInvestorMode)
                } else {
                    SettingsValueRow(title: L10n.text("账户类型"), value: L10n.label(account.accountType), valueIsNumeric: false)
                }
                SettingsValueRow(title: L10n.text("基础币种"), value: account.baseCurrency, valueIsNumeric: false)
                SettingsValueRow(title: L10n.text("Broker"), value: L10n.label(account.brokerName), valueIsNumeric: false)
            }

            SettingsSection(L10n.text("数据来源")) {
                SettingsButtonRow(title: primarySourceTitle, value: primarySourceStatus) {
                    activeSheet = syncSheet
                }
                .disabled(model.isFakeDataMode || model.isPublicInvestorMode)

                if account.source != "CSV" {
                    SettingsButtonRow(title: L10n.text("CSV 导入"), value: csvImportStatus) {
                        activeSheet = .csv
                    }
                    .disabled(model.isFakeDataMode || model.isPublicInvestorMode)
                }

                SettingsButtonRow(title: L10n.text("手动补充"), value: L10n.text("\(manualTransactionCount) 笔")) {
                    activeSheet = .manualTransaction
                }
                .disabled(model.isFakeDataMode || model.isPublicInvestorMode)
            }

            SettingsSection(L10n.text("数据记录")) {
                SettingsNavigationRow(
                    title: L10n.text("History"),
                    value: L10n.text("\(account.transactionCount) 笔交易记录")
                ) {
                    HistoryView(initialAccountIDs: [account.id])
                        .environment(model)
                }

                SettingsButtonRow(
                    title: L10n.text("数据匹配与去重"),
                    showsChevron: !isWorking,
                    value: isWorking ? nil : dataMatchStatus,
                    showsProgress: isWorking
                ) {
                    deduplicateTransactions()
                }
                .disabled(isWorking || model.isFakeDataMode || model.isPublicInvestorMode)
            }

            SettingsSection(L10n.text("账户设置")) {
                SettingsButtonRow(
                    icon: .symbol("trash"),
                    title: L10n.text("删除账户"),
                    showsChevron: false,
                    role: .destructive
                ) {
                    showsDeleteConfirmation = true
                }
                .disabled(model.isFakeDataMode || model.isPublicInvestorMode)
            }
        }
        .hidesTabBarWhenPushed()
        // A sheet rather than a text-field alert: the alert insets its title
        // to the field's text, not its edge, and the two never line up.
        .appSheet(isPresented: $showsRenamePrompt) {
            AccountRenameSheet(name: $accountNameDraft) { renameAccount() }
        }
        .alert(L10n.text("删除账户？"), isPresented: $showsDeleteConfirmation) {
            Button(L10n.text("取消"), role: .cancel) {}
            Button(L10n.text("删除"), role: .destructive) { deleteAccount() }
        } message: {
            Text(L10n.text("将删除 \(account.localizedDisplayName) 的持仓、交易和历史快照，此操作无法撤销。"))
        }
        .alert(
            Text(notice?.title ?? ""),
            isPresented: Binding(
                get: { notice != nil },
                set: { isPresented in
                    if !isPresented { notice = nil }
                }
            ),
            presenting: notice
        ) { _ in
            Button(L10n.text("好"), role: .cancel) { notice = nil }
        } message: { notice in
            Text(L10n.message(notice.message))
        }
        .appSheet(item: $activeSheet) { sheet in
            accountSheet(sheet)
                .environment(model)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
    }

    @ViewBuilder
    private func accountSheet(_ sheet: AccountManagementSheet) -> some View {
        switch sheet {
        case .trading212:
            Trading212View(context: .manage(account))
        case .moomoo:
            MoomooOAuthView(context: .manage(account))
        case .robinhood:
            RobinhoodConnectionView(context: .manage(account))
        case .snaptrade:
            SnapTradeView(context: .manage(account))
        case .ibkr:
            IBKRFlexView(context: .manage(account))
        case .csv:
            CSVImportView(context: .manage(account))
        case .manualTransaction:
            ManualTransactionView(account: account)
        }
    }

    private var syncSheet: AccountManagementSheet {
        switch account.source {
        case "Trading 212": .trading212
        case "Moomoo": .moomoo
        case "Robinhood": .robinhood
        case "SnapTrade": .snaptrade
        case "IBKR Flex": .ibkr
        default: .csv
        }
    }

    private var primarySourceTitle: String {
        switch account.source {
        case "Trading 212": L10n.text("Trading 212 同步")
        case "Moomoo": L10n.text("Moomoo 同步")
        case "Robinhood": L10n.text("Robinhood 同步")
        case "SnapTrade": L10n.text("SnapTrade 同步")
        case "IBKR Flex": L10n.text("IBKR 同步")
        case "CSV": L10n.text("CSV 导入")
        case "假数据": L10n.text("本机演示数据")
        default: account.syncedSourceTitle
        }
    }

    private var primarySourceStatus: String {
        if account.source == "假数据" { return L10n.text("已启用") }
        let connection = account.source == "CSV" ? L10n.text("已导入") : L10n.text("已连接")
        guard let updatedAt = model.localUpdatedAt else { return connection }
        let interval = max(0, Date().timeIntervalSince(updatedAt))
        if interval < 60 { return L10n.text("\(connection) · 刚刚同步") }
        if interval < 3_600 { return L10n.text("\(connection) · \(max(1, Int(interval / 60))) 分钟前") }
        if interval < 86_400 { return L10n.text("\(connection) · \(max(1, Int(interval / 3_600))) 小时前") }
        return "\(connection) · \(updatedAt.formatted(.dateTime.month().day()))"
    }

    private var csvImportStatus: String {
        account.hasCSVImport ? L10n.text("已导入") : L10n.text("未导入")
    }

    private var manualTransactionCount: Int {
        account.manualTransactionCount
    }

    private func renameAccount() {
        let name = accountNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                try await model.renameAccount(accountID, to: name)
            } catch {
                notice = AccountNotice(title: L10n.text("无法保存名称"), message: error.localizedDescription)
            }
        }
    }

    /// Trading 212's API reports an account number and a currency, never the
    /// product, so the type is chosen here and saved on its own.
    private var accountTypeSelection: Binding<Trading212AccountType?> {
        Binding(
            get: { account.chosenAccountType },
            set: { type in
                guard let type else { return }
                Task {
                    do {
                        try await model.setTrading212AccountType(type, for: accountID)
                    } catch {
                        notice = AccountNotice(title: L10n.text("无法保存账户类型"), message: error.localizedDescription)
                    }
                }
            }
        )
    }

    private func deduplicateTransactions() {
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                let removed = try await model.deduplicateTransactions(for: accountID)
                dataMatchStatus = removed == 0 ? L10n.text("无异常") : L10n.text("已处理 \(removed) 笔")
                notice = AccountNotice(
                    title: L10n.text("数据去重完成"),
                    message: removed == 0 ? L10n.text("未发现重复交易。") : L10n.text("已移除 \(removed) 笔重复交易。")
                )
            } catch {
                dataMatchStatus = L10n.text("检查失败")
                notice = AccountNotice(title: L10n.text("去重失败"), message: error.localizedDescription)
            }
        }
    }

    private func deleteAccount() {
        Task {
            do {
                try await model.deleteAccount(accountID)
                dismiss()
            } catch {
                notice = AccountNotice(title: L10n.text("无法删除账户"), message: error.localizedDescription)
            }
        }
    }
}

/// The account's name, edited on its own small sheet.
struct AccountRenameSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var name: String
    let onSave: () -> Void
    @FocusState private var focused: Bool

    private var canSave: Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        NavigationStack {
            SettingsPage(bottomInset: 24, topInset: SettingsTemplate.sectionSpacing) {
                SettingsCard {
                    TextField(L10n.text("账户名称"), text: $name)
                        .appText(.body)
                        .focused($focused)
                        .submitLabel(.done)
                        .onSubmit(save)
                        .padding(.horizontal, SettingsTemplate.rowHorizontalPadding)
                        .frame(minHeight: SettingsTemplate.rowMinHeight)
                }
                SettingsFootnote(L10n.text("名称只保存在这台 iPhone 上。"))
            }
            .navigationTitle(L10n.text("编辑账户名称"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.text("取消")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    AppModalDoneButton(action: save).disabled(!canSave)
                }
            }
        }
        .presentationDetents([.height(250)])
        .presentationDragIndicator(.visible)
        .onAppear { focused = true }
    }

    private func save() {
        guard canSave else { return }
        onSave()
        dismiss()
    }
}

struct ManualTransactionView: View {
    @Environment(\.locale) private var appLocale
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let account: PortfolioAccount

    @State private var date = Date()
    @State private var action = "BUY"
    @State private var ticker = ""
    @State private var quantity = ""
    @State private var price = ""
    @State private var currency: DisplayCurrency = .usd
    @State private var isSaving = false
    @State private var errorMessage: String?

    private var numericQuantity: Double? { Double(quantity.replacingOccurrences(of: ",", with: ".")) }
    private var numericPrice: Double? { Double(price.replacingOccurrences(of: ",", with: ".")) }
    private var canSave: Bool {
        !ticker.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (numericQuantity ?? 0) > 0
            && (numericPrice ?? 0) > 0
            && !isSaving
    }

    var body: some View {
        NavigationStack {
            SettingsPage(bottomInset: 32) {
                SettingsCard {
                    SettingsValueRow(
                        title: L10n.text("账户"),
                        value: account.localizedDisplayName,
                        valueIsNumeric: false
                    )

                    SettingsRowContainer {
                        DatePicker(L10n.text("交易日期"), selection: $date, displayedComponents: .date)
                            .appText(.subheading)
                    }

                    // `.menu` explicitly: a `Picker` shows a menu inside a
                    // grouped Form and would pick a different style outside
                    // one, which would change how the row is operated.
                    SettingsMenuRow(
                        title: L10n.text("交易类型"),
                        value: action == "BUY" ? L10n.text("买入") : L10n.text("卖出"),
                        selection: $action
                    ) {
                        Text(L10n.text("买入")).tag("BUY")
                        Text(L10n.text("卖出")).tag("SELL")
                    }
                }

                SettingsSection(L10n.text("交易内容")) {
                    SettingsFieldRow(L10n.text("代码，如 AAPL"), text: $ticker)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    SettingsFieldRow(L10n.text("数量"), text: $quantity)
                        .keyboardType(.decimalPad)
                    SettingsFieldRow(L10n.text("成交价"), text: $price)
                        .keyboardType(.decimalPad)
                    SettingsMenuRow(
                        title: L10n.text("币种"),
                        value: currency.rawValue,
                        selection: $currency
                    ) {
                        ForEach(DisplayCurrency.allCases) { currency in
                            Text(currency.rawValue).tag(currency)
                        }
                    }
                }

                if let errorMessage {
                    SettingsFootnote(errorMessage, color: CatfolioTheme.danger)
                }
            }
            .softTopScrollEdge()
            .navigationTitle(L10n.text("补充历史交易"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.text("取消")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.text("保存")) { save() }
                        .disabled(!canSave)
                }
            }
        }
        .tint(CatfolioTheme.accent)
    }

    private func save() {
        guard let numericQuantity, let numericPrice else { return }
        isSaving = true
        errorMessage = nil
        Task {
            defer { isSaving = false }
            do {
                try await model.addHistoricalTransaction(
                    to: account,
                    date: date,
                    action: action,
                    ticker: ticker.trimmingCharacters(in: .whitespacesAndNewlines),
                    quantity: numericQuantity,
                    price: numericPrice,
                    currency: currency.rawValue
                )
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
