import SwiftUI
import UIKit

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let showsCloseButton: Bool
    @AppStorage("catfolio.haptics") private var hapticsEnabled = true
    @AppStorage(AppAppearance.preferenceKey) private var appearanceRawValue = AppAppearance.system.rawValue
    @AppStorage(DisplayCurrency.preferenceKey) private var displayCurrencyRawValue = DisplayCurrency.usd.rawValue
    @AppStorage(CompanyNameDisplay.preferenceKey) private var companyNameDisplayRawValue = CompanyNameDisplay.original.rawValue
    @State private var showsCSVImport = false
    @State private var showsTrading212 = false
    @State private var showsIBKRFlex = false
    @State private var showsMoomooOAuth = false
    @State private var showsLocalServices = false
    @State private var showsPortfolioResetConfirmation = false
    @State private var isResettingPortfolio = false
    @State private var portfolioResetError: String?
    #if DEBUG
    @State private var showsScreenerPreview = ProcessInfo.processInfo.arguments.contains("--show-screener")
    @State private var showsHistoryPreview = ProcessInfo.processInfo.arguments.contains("--show-history-preview")
    @State private var showsResearchPreview = ProcessInfo.processInfo.arguments.contains("--preview-research-analysis")
    #endif

    init(showsCloseButton: Bool = false) {
        self.showsCloseButton = showsCloseButton
    }

    var body: some View {
        Form {
                if !model.accounts.isEmpty {
                    Section("账户范围") {
                        allAccountsRow
                        ForEach(model.accounts) { account in
                            accountScopeRow(account)
                        }
                    }

                    Section("账户活动") {
                        NavigationLink {
                            HistoryView()
                                .environment(model)
                        } label: {
                            nativeSettingsLabel(
                                title: "History",
                                detail: "跨账户资产活动流水",
                                icon: "clock.arrow.circlepath",
                                tint: CatfolioTheme.services
                            )
                        }
                    }
                }

                Section("新建账户") {
                    connector("Trading 212", detail: "使用只读 API 创建账户", icon: "chart.line.uptrend.xyaxis", tint: CatfolioTheme.trading212) {
                        showsTrading212 = true
                    }
                    connector("Moomoo", detail: "通过 OAuth 授权创建账户", icon: "person.badge.key.fill", tint: CatfolioTheme.moomoo) {
                        showsMoomooOAuth = true
                    }
                    connector("Interactive Brokers", detail: "使用 Flex Web Service 创建账户", icon: "doc.text.fill", tint: CatfolioTheme.interactiveBrokers) {
                        showsIBKRFlex = true
                    }
                    connector("CSV 导入", detail: "从交易记录创建账户", icon: "doc.badge.plus", tint: CatfolioTheme.csvImport) {
                        showsCSVImport = true
                    }
                }

                Section("行情与 AI") {
                    NavigationLink {
                        ResearchView()
                    } label: {
                        nativeSettingsLabel(
                            title: "研究",
                            icon: "chart.xyaxis.line",
                            tint: CatfolioTheme.accent
                        )
                    }
                    NavigationLink {
                        StockScreenerView()
                    } label: {
                        nativeSettingsLabel(
                            title: "选股器",
                            icon: "line.3.horizontal.decrease",
                            tint: CatfolioTheme.preference
                        )
                    }
                    connector("服务商", detail: "行情、估值与 AI 密钥", icon: "key.fill", tint: CatfolioTheme.services) {
                        showsLocalServices = true
                    }
                }

                Section {
                    Toggle(isOn: $hapticsEnabled) {
                        nativeSettingsLabel(
                            title: "触控反馈",
                            icon: "hand.tap.fill",
                            tint: CatfolioTheme.warning
                        )
                    }

                    settingsPickerRow(
                        title: "外观",
                        icon: "circle.lefthalf.filled",
                        tint: CatfolioTheme.accent,
                        selection: $appearanceRawValue
                    ) {
                        ForEach(AppAppearance.allCases) { appearance in
                            Text(appearance.title).tag(appearance.rawValue)
                        }
                    }

                    settingsPickerRow(
                        title: "公司名称",
                        icon: "character.bubble.fill",
                        tint: CatfolioTheme.preference,
                        selection: $companyNameDisplayRawValue
                    ) {
                        ForEach(CompanyNameDisplay.allCases) { display in
                            Text(display.rawValue).tag(display.rawValue)
                        }
                    }

                    settingsPickerRow(
                        title: "数据货币",
                        icon: "globe",
                        tint: CatfolioTheme.services,
                        selection: $displayCurrencyRawValue
                    ) {
                        ForEach(DisplayCurrency.allCases) { currency in
                            Text(currency.title).tag(currency.rawValue)
                        }
                    }
                } header: {
                    Text("偏好设置")
                } footer: {
                    Text(LocalPortfolioEngine.fxStatus)
                }

                Section("本机数据") {
                    settingsValueRow(
                        title: "数据来源",
                        value: model.localSource,
                        icon: "iphone.gen3",
                        tint: CatfolioTheme.localData
                    )
                    settingsValueRow(
                        title: "持仓",
                        value: "\(model.holdings.count) 项",
                        icon: "chart.pie.fill",
                        tint: CatfolioTheme.services
                    )
                    if let updatedAt = model.localUpdatedAt {
                        settingsValueRow(
                            title: "行情更新",
                            value: compactDate(updatedAt),
                            icon: "clock.fill",
                            tint: CatfolioTheme.warning
                        )
                    }
                    Toggle(isOn: Binding(
                        get: { model.isFakeDataMode },
                        set: { enabled in
                            Task { await model.setFakeDataMode(enabled) }
                        }
                    )) {
                        nativeSettingsLabel(
                            title: "假数据模式",
                            icon: "eye.slash.fill",
                            tint: CatfolioTheme.accent
                        )
                    }
                    .disabled(model.isPortfolioLoading)
                    .accessibilityHint("开启后仅显示独立合成的标的、账户、交易和收益曲线")

                    if let error = model.fakeDataModeError {
                        Label(error, systemImage: "exclamationmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(CatfolioTheme.danger)
                    }
                }

                Section {
                    Button("重置本机组合数据", systemImage: "trash", role: .destructive) {
                        showsPortfolioResetConfirmation = true
                    }
                    .disabled(isResettingPortfolio || model.isPortfolioLoading || model.isReturnsLoading)
                } header: {
                    Text("本机组合数据")
                } footer: {
                    if let notice = model.portfolioRecoveryNotice {
                        Text(notice)
                            .textSelection(.enabled)
                    }
                }

                Section("关于") {
                    settingsValueRow(
                        title: "版本",
                        value: appVersion,
                        icon: "info.circle.fill",
                        tint: CatfolioTheme.neutralIcon
                    )
                }
        }
        .formStyle(.grouped)
            #if DEBUG
            .navigationDestination(isPresented: $showsScreenerPreview) { StockScreenerView() }
            .navigationDestination(isPresented: $showsHistoryPreview) { HistoryView().environment(model) }
            .navigationDestination(isPresented: $showsResearchPreview) { ResearchView().environment(model) }
            #endif
            .toolbar {
                if showsCloseButton {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("关闭", systemImage: "xmark") { dismiss() }
                            .labelStyle(.iconOnly)
                            .accessibilityLabel("关闭设置")
                    }
                }
            }
            .task {
                let arguments = ProcessInfo.processInfo.arguments
                showsCSVImport = arguments.contains("--show-csv")
                showsTrading212 = arguments.contains("--show-trading212")
                showsIBKRFlex = arguments.contains("--show-flex")
                showsMoomooOAuth = arguments.contains("--show-moomoo")
                showsLocalServices = arguments.contains("--show-local-services")
                    || arguments.contains { $0.hasPrefix("--show-local-service-") }
                if model.overview == nil { await model.refreshPortfolio() }
            }
            .confirmationDialog("重置本机组合数据？", isPresented: $showsPortfolioResetConfirmation, titleVisibility: .visible) {
                Button("备份并重置", role: .destructive) {
                    isResettingPortfolio = true
                    Task {
                        defer { isResettingPortfolio = false }
                        do { try await model.resetLocalPortfolio() }
                        catch { portfolioResetError = error.localizedDescription }
                    }
                }
            } message: {
                Text("将清空当前持仓、交易和历史快照，并保留一份本机备份。券商授权、API 密钥及 AI 对话会保留。")
            }
            .alert("无法重置组合", isPresented: Binding(
                get: { portfolioResetError != nil },
                set: { if !$0 { portfolioResetError = nil } }
            )) {
                Button("好", role: .cancel) { portfolioResetError = nil }
            } message: {
                Text(portfolioResetError ?? "")
            }
            .sheet(isPresented: $showsCSVImport) {
                CSVImportView(context: .create).environment(model)
                    .presentationDetents([.large]).presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showsTrading212) {
                Trading212View(context: .create).environment(model)
                    .presentationDetents([.large]).presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showsIBKRFlex) {
                IBKRFlexView(context: .create).environment(model)
                    .presentationDetents([.large]).presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showsMoomooOAuth) {
                MoomooOAuthView(context: .create).environment(model)
                    .presentationDetents([.large]).presentationDragIndicator(.visible)
            }
        .sheet(isPresented: $showsLocalServices) {
            LocalServicesSettingsView()
                .presentationDetents([.large]).presentationDragIndicator(.visible)
        }
        .tint(CatfolioTheme.accent)
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    private func compactDate(_ date: Date) -> String {
        date.formatted(
            .dateTime
                .year()
                .month(.abbreviated)
                .day()
                .hour()
                .minute()
                .locale(Locale(identifier: "zh_CN"))
        )
    }

    private func nativeSettingsLabel(
        title: String,
        detail: String? = nil,
        icon: String,
        tint: Color
    ) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundStyle(.primary)
                if let detail {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        } icon: {
            SettingsGlyph(symbol: icon, tint: tint)
        }
    }

    private var allAccountsRow: some View {
        HStack(spacing: 0) {
            accountSelectionButton(
                selected: model.selectedAccountKeys.count == model.accounts.count,
                label: "全部账户",
                selectedAccessibilityLabel: "全部账户已计入"
            ) {
                if model.selectedAccountKeys.count != model.accounts.count {
                    Task { await model.selectAllAccounts() }
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("全部账户")
                    .font(.body)
                    .foregroundStyle(.primary)
                Text("\(model.accounts.count) 个账户 · \(DisplayFormat.money(allAccountsMarketValueUSD))")
                    .appNumber(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var allAccountsMarketValueUSD: Double {
        model.accounts.reduce(0) { total, account in
            total + account.marketValueUSD
        }
    }

    private func accountScopeRow(_ account: PortfolioAccount) -> some View {
        let isSelected = model.selectedAccountKeys.contains(account.id)
        return HStack(spacing: 0) {
            accountSelectionButton(selected: isSelected, label: account.displayName) {
                Task { await model.toggleAccount(account.id) }
            }

            NavigationLink {
                AccountDetailView(accountID: account.id, initialAccount: account)
                    .environment(model)
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(account.displayName)
                            .font(.body)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(account.awaitsFirstSync
                            ? "等待首次同步"
                            : "\(account.positionCount) 项 · \(DisplayFormat.money(account.marketValueUSD))")
                            .appNumber(.callout)
                            .foregroundStyle(account.awaitsFirstSync ? CatfolioTheme.accent : .secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .accessibilityHint("进入账户详情")
        }
    }

    private func accountSelectionButton(
        selected: Bool,
        label: String,
        selectedAccessibilityLabel: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Group {
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, CatfolioTheme.accent)
                } else {
                    Image(systemName: "circle")
                        .foregroundStyle(.secondary)
                }
            }
                .imageScale(.large)
                .frame(width: 36)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(selected ? (selectedAccessibilityLabel ?? "不计入\(label)") : "计入\(label)")
        .accessibilityValue(selected ? "已选择" : "未选择")
        .accessibilityHint("只更改全局组合的账户范围")
    }

    private func connector(
        _ title: String,
        detail: String,
        icon: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                nativeSettingsLabel(title: title, detail: detail, icon: icon, tint: tint)
                Spacer(minLength: 8)
                Image(systemName: "chevron.forward")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func settingsValueRow(
        title: String,
        value: String?,
        icon: String,
        tint: Color
    ) -> some View {
        LabeledContent {
            if let value {
                Text(value)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        } label: {
            nativeSettingsLabel(title: title, icon: icon, tint: tint)
        }
    }

    private func settingsPickerRow<SelectionValue: Hashable, Options: View>(
        title: String,
        icon: String,
        tint: Color,
        selection: Binding<SelectionValue>,
        @ViewBuilder options: () -> Options
    ) -> some View {
        Picker(selection: selection, content: options) {
            nativeSettingsLabel(title: title, icon: icon, tint: tint)
        }
        .pickerStyle(.menu)
    }
}

private enum AccountManagementSheet: String, Identifiable {
    case trading212
    case moomoo
    case ibkr
    case csv
    case manualTransaction

    var id: String { rawValue }
}

private struct AccountNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

private struct AccountDetailView: View {
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
    @State private var dataMatchStatus = "无异常"

    private var account: PortfolioAccount {
        model.accounts.first(where: { $0.id == accountID }) ?? initialAccount
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(account.displayName)
                        .font(.largeTitle.bold())
                        .lineLimit(2)
                    Text(DisplayFormat.money(account.marketValueUSD))
                        .appNumber(.title, weight: .bold)
                    Text("\(account.positionCount) 个持仓")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 6)

                if model.isFakeDataMode {
                    Label("这里是独立演示账户，与真实持仓无关。", systemImage: "eye.slash.fill")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            CatfolioTheme.surface(for: colorScheme),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                        )
                }

                SettingsSectionBlock(title: "账户信息") {
                    SettingsGroupCard {
                        Button {
                            accountNameDraft = account.displayName
                            showsRenamePrompt = true
                        } label: {
                            detailActionRow(title: "账户名称", detail: account.displayName)
                        }
                        .buttonStyle(.plain)
                        .disabled(model.isFakeDataMode)

                        Divider()
                        detailValueRow(title: "账户类型", value: account.accountType)
                        Divider()
                        detailValueRow(title: "基础币种", value: account.baseCurrency)
                        Divider()
                        detailValueRow(title: "Broker", value: account.brokerName)
                    }
                }

                SettingsSectionBlock(title: "数据来源") {
                    SettingsGroupCard {
                        Button { activeSheet = syncSheet } label: {
                            detailActionRow(
                                title: primarySourceTitle,
                                detail: primarySourceStatus
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(model.isFakeDataMode)

                        if account.source != "CSV" {
                            Divider()
                            Button { activeSheet = .csv } label: {
                                detailActionRow(title: "CSV 导入", detail: csvImportStatus)
                            }
                            .buttonStyle(.plain)
                            .disabled(model.isFakeDataMode)
                        }

                        Divider()
                        Button { activeSheet = .manualTransaction } label: {
                            detailActionRow(title: "手动补充", detail: "\(manualTransactionCount) 笔")
                        }
                        .buttonStyle(.plain)
                        .disabled(model.isFakeDataMode)
                    }
                }

                SettingsSectionBlock(title: "数据记录") {
                    SettingsGroupCard {
                        NavigationLink {
                            HistoryView(initialAccountIDs: [account.id])
                                .environment(model)
                        } label: {
                            detailActionRow(
                                title: "History",
                                detail: "\(account.transactionCount) 笔交易记录"
                            )
                        }
                        .buttonStyle(.plain)

                        Divider()
                        Button { deduplicateTransactions() } label: {
                            detailActionRow(
                                title: "数据匹配与去重",
                                detail: isWorking ? nil : dataMatchStatus,
                                showsProgress: isWorking
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(isWorking || model.isFakeDataMode)
                    }
                }

                SettingsSectionBlock(title: "账户设置") {
                    SettingsGroupCard {
                        Button(role: .destructive) {
                            showsDeleteConfirmation = true
                        } label: {
                            HStack {
                                Text("删除账户")
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(CatfolioTheme.danger)
                                Spacer()
                            }
                            .padding(.vertical, 13)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(model.isFakeDataMode)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 40)
        }
        .background(CatfolioTheme.pageBackground(for: colorScheme))
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .alert("编辑账户名称", isPresented: $showsRenamePrompt) {
            TextField("账户名称", text: $accountNameDraft)
            Button("取消", role: .cancel) {}
            Button("保存") { renameAccount() }
                .disabled(accountNameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("名称只保存在这台 iPhone 上。")
        }
        .alert("删除账户？", isPresented: $showsDeleteConfirmation) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) { deleteAccount() }
        } message: {
            Text("将删除 \(account.displayName) 的持仓、交易和历史快照，此操作无法撤销。")
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
            Button("好", role: .cancel) { notice = nil }
        } message: { notice in
            Text(notice.message)
        }
        .sheet(item: $activeSheet) { sheet in
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
        case "IBKR Flex": .ibkr
        default: .csv
        }
    }

    private var primarySourceTitle: String {
        switch account.source {
        case "Trading 212": "Trading 212 同步"
        case "Moomoo": "Moomoo 同步"
        case "IBKR Flex": "IBKR 同步"
        case "CSV": "CSV 导入"
        case "假数据": "本机演示数据"
        default: account.syncedSourceTitle
        }
    }

    private var primarySourceStatus: String {
        if account.source == "假数据" { return "已启用" }
        let connection = account.source == "CSV" ? "已导入" : "已连接"
        guard let updatedAt = model.localUpdatedAt else { return connection }
        let interval = max(0, Date().timeIntervalSince(updatedAt))
        if interval < 60 { return "\(connection) · 刚刚同步" }
        if interval < 3_600 { return "\(connection) · \(max(1, Int(interval / 60))) 分钟前" }
        if interval < 86_400 { return "\(connection) · \(max(1, Int(interval / 3_600))) 小时前" }
        return "\(connection) · \(updatedAt.formatted(.dateTime.month().day()))"
    }

    private var csvImportStatus: String {
        account.hasCSVImport ? "已导入" : "未导入"
    }

    private var manualTransactionCount: Int {
        account.manualTransactionCount
    }

    private func detailValueRow(title: String, value: String) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.body.weight(.medium))
                .foregroundStyle(.primary)
            Spacer(minLength: 16)
            Text(value)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 13)
    }

    private func detailActionRow(
        title: String,
        detail: String? = nil,
        showsProgress: Bool = false
    ) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.body.weight(.medium))
                .foregroundStyle(.primary)
            Spacer(minLength: 8)
            if let detail {
                Text(detail)
                    .appNumber(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if showsProgress {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "chevron.forward")
                    .font(.caption.bold())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 13)
        .contentShape(Rectangle())
    }

    private func renameAccount() {
        let name = accountNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                try await model.renameAccount(accountID, to: name)
            } catch {
                notice = AccountNotice(title: "无法保存名称", message: error.localizedDescription)
            }
        }
    }

    private func deduplicateTransactions() {
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                let removed = try await model.deduplicateTransactions(for: accountID)
                dataMatchStatus = removed == 0 ? "无异常" : "已处理 \(removed) 笔"
                notice = AccountNotice(
                    title: "数据去重完成",
                    message: removed == 0 ? "未发现重复交易。" : "已移除 \(removed) 笔重复交易。"
                )
            } catch {
                dataMatchStatus = "检查失败"
                notice = AccountNotice(title: "去重失败", message: error.localizedDescription)
            }
        }
    }

    private func deleteAccount() {
        Task {
            do {
                try await model.deleteAccount(accountID)
                dismiss()
            } catch {
                notice = AccountNotice(title: "无法删除账户", message: error.localizedDescription)
            }
        }
    }
}

private struct AccountTransactionsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    let account: PortfolioAccount
    @State private var transactions: [LocalTransactionRecord] = []
    @State private var errorMessage: String?
    @State private var isSyncingHistory = false
    @State private var syncMessage: String?

    var body: some View {
        Group {
            if let errorMessage {
                ContentUnavailableView(
                    "无法读取交易",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage)
                )
            } else if transactions.isEmpty {
                ContentUnavailableView(
                    "暂无交易记录",
                    systemImage: "list.bullet.rectangle",
                    description: Text("可以通过同步、CSV 导入或手动补充添加历史交易。")
                )
            } else {
                List(transactions) { transaction in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(transaction.ticker)
                                .font(.body.weight(.semibold))
                            Spacer()
                            Text(actionTitle(transaction.action))
                                .font(.caption.weight(.bold))
                                .foregroundStyle(
                                    transaction.action.uppercased() == "SELL"
                                        ? CatfolioTheme.danger
                                        : CatfolioTheme.positive
                                )
                        }
                        HStack {
                            Text(transaction.date)
                            Spacer()
                            Text(transactionDetail(transaction))
                                .appNumber(.caption)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .background(CatfolioTheme.pageBackground(for: colorScheme))
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if isSyncingHistory, let syncMessage {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(syncMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial)
            }
        }
        .background(CatfolioTheme.pageBackground(for: colorScheme))
        .tint(CatfolioTheme.accent)
        .navigationTitle("交易记录")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: account.id) {
            await loadLocalTransactions()
            await synchronizeTrading212History()
        }
        .refreshable { await synchronizeTrading212History() }
    }

    private func actionTitle(_ action: String) -> String {
        switch action.uppercased() {
        case "BUY": "买入"
        case "SELL": "卖出"
        case "DIVIDEND": "股息"
        case "INTEREST": "利息"
        default: action
        }
    }

    private func transactionDetail(_ transaction: LocalTransactionRecord) -> String {
        if transaction.action.uppercased() == "DIVIDEND"
            || transaction.action.uppercased() == "INTEREST" {
            return "+\(DisplayFormat.money(transaction.quantity * transaction.price, currency: transaction.currency))"
        }
        return "\(DisplayFormat.shares(transaction.quantity)) × \(DisplayFormat.money(transaction.price, currency: transaction.currency))"
    }

    private func loadLocalTransactions() async {
        do {
            transactions = try await model.transactions(for: account.id)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func synchronizeTrading212History() async {
        guard account.source == "Trading 212",
              !isSyncingHistory,
              let accountID = account.accountID,
              let slot = Int(accountID.replacingOccurrences(of: "account-", with: "")),
              let apiKey = KeychainStore.string(for: "trading212.account-\(slot).api-key"),
              let apiSecret = KeychainStore.string(for: "trading212.account-\(slot).api-secret"),
              !apiKey.isEmpty,
              !apiSecret.isEmpty else { return }

        isSyncingHistory = true
        syncMessage = "正在补齐 Trading 212 成交、分红与利息…"
        defer { isSyncingHistory = false }

        do {
            let credentials = try Trading212Credentials(apiKey: apiKey, apiSecret: apiSecret)
            let environment = UserDefaults.standard.string(forKey: "trading212.environment")
                .flatMap(Trading212Environment.init(rawValue:)) ?? .live
            while !Task.isCancelled {
                let snapshot = try await Trading212Client().fetchSnapshot(
                    accounts: [Trading212AccountCredentials(slot: slot, credentials: credentials)],
                    environment: environment
                )
                _ = try await model.importTrading212(
                    snapshot,
                    accountNames: [accountID: account.name],
                    replacingAccountsOnly: true
                )
                await loadLocalTransactions()
                if snapshot.hasCompleteTransactionHistory {
                    syncMessage = nil
                    return
                }
                syncMessage = snapshot.transactionHistoryStatus
                    ?? "历史记录较多，正在等待下一批…"
                try await Task.sleep(for: .seconds(62))
            }
        } catch is CancellationError {
            return
        } catch {
            syncMessage = "同步失败：\(error.localizedDescription)"
        }
    }
}

private struct ManualTransactionView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
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
            Form {
                Section {
                    LabeledContent("账户", value: account.displayName)
                    DatePicker("交易日期", selection: $date, displayedComponents: .date)
                    Picker("交易类型", selection: $action) {
                        Text("买入").tag("BUY")
                        Text("卖出").tag("SELL")
                    }
                }

                Section("交易内容") {
                    TextField("代码，如 AAPL", text: $ticker)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    TextField("数量", text: $quantity)
                        .keyboardType(.decimalPad)
                    TextField("成交价", text: $price)
                        .keyboardType(.decimalPad)
                    Picker("币种", selection: $currency) {
                        ForEach(DisplayCurrency.allCases) { currency in
                            Text(currency.rawValue).tag(currency)
                        }
                    }
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.circle.fill")
                            .foregroundStyle(CatfolioTheme.danger)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(CatfolioTheme.pageBackground(for: colorScheme))
            .navigationTitle("补充历史交易")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
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

private struct SettingsSectionBlock<Content: View>: View {
    let title: String
    let footer: String?
    @ViewBuilder let content: Content

    init(
        title: String,
        footer: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.title3.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)

            content

            if let footer {
                Text(footer)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }
        }
    }
}

private struct SettingsGroupCard<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @ViewBuilder let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .padding(.horizontal, 18)
        .background(
            CatfolioTheme.surface(for: colorScheme),
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
    }
}

private struct SettingsDivider: View {
    var body: some View {
        Divider()
            .padding(.leading, 66)
    }
}

private struct SettingsIcon: View {
    let systemName: String
    let tint: Color

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 36, height: 36)
            .background(tint, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .frame(width: 50, height: 36)
            .accessibilityHidden(true)
    }
}

private enum LocalServiceProvider: String, CaseIterable, Identifiable, Hashable {
    case massive
    case fmp
    case deepSeek

    var id: String { rawValue }

    var title: String {
        switch self {
        case .massive: "Massive"
        case .fmp: "Financial Modeling Prep"
        case .deepSeek: "DeepSeek"
        }
    }

    var shortTitle: String {
        switch self {
        case .fmp: "FMP"
        default: title
        }
    }

    var purpose: String {
        switch self {
        case .massive: "美股成交量与历史行情"
        case .fmp: "估值矩阵与行情备用"
        case .deepSeek: "云端问答与自动回退"
        }
    }

    var detail: String {
        switch self {
        case .massive:
            "读取美股日线价格与成交量，用于计算成交量分布、VAH、POC 和 VAL。"
        case .fmp:
            "读取估值矩阵需要的 P/E、EPS 与营收成长数据，并作为历史行情备用。"
        case .deepSeek:
            "选择 DeepSeek 或自动模式需要回退时，组合摘要和问题会直接发送给 DeepSeek，不经过 Mac 或 Catfolio 服务端。"
        }
    }

    var keychainKey: String {
        switch self {
        case .massive: LocalServiceKeys.massive
        case .fmp: LocalServiceKeys.fmp
        case .deepSeek: LocalServiceKeys.deepSeek
        }
    }

    var iconName: String {
        switch self {
        case .massive: "chart.bar.xaxis"
        case .fmp: "chart.xyaxis.line"
        case .deepSeek: "sparkles"
        }
    }

    var tint: Color {
        switch self {
        case .massive: CatfolioTheme.accent
        case .fmp: CatfolioTheme.warning
        case .deepSeek: CatfolioTheme.services
        }
    }

    func validate(apiKey: String) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                try await performValidation(apiKey: apiKey)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 35_000_000_000)
                throw LocalServiceError.remote("验证超时，请检查网络后重试")
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw LocalServiceError.invalidResponse
            }
            return result
        }
    }

    private func performValidation(apiKey: String) async throws -> String {
        switch self {
        case .massive:
            let sessions = try await LocalMarketDataClient().testMassiveConnection(apiKey: apiKey)
            return "连接成功，已读取 AAPL 的 \(sessions) 个交易日"
        case .fmp:
            return try await LocalReturnsAnalyticsClient().testFMPValuationConnection(apiKey: apiKey)
        case .deepSeek:
            try await LocalAIClient().testDeepSeekConnection(apiKey: apiKey)
            return "连接成功，DeepSeek 模型列表可用"
        }
    }
}

private enum LocalServiceStatus: Equatable {
    case unconfigured
    case configured
    case verified

    var title: String {
        switch self {
        case .unconfigured: "未配置"
        case .configured: "已配置"
        case .verified: "验证通过"
        }
    }

    var iconName: String {
        switch self {
        case .unconfigured: "circle"
        case .configured: "checkmark.circle"
        case .verified: "checkmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .unconfigured: .secondary
        case .configured, .verified: CatfolioTheme.positive
        }
    }
}

private struct LocalServicesSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(AIProviderPreference.storageKey) private var aiProviderRaw = AIProviderPreference.automatic.rawValue
    @AppStorage(CodexOAuthClient.connectedStorageKey) private var codexConnected = false
    @State private var path: [LocalServiceProvider] = []
    @State private var statuses: [LocalServiceProvider: LocalServiceStatus] = [:]
    @State private var hasAppliedLaunchRoute = false

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    StatusNotice(
                        text: "行情密钥和 ChatGPT 登录都只保存在此 iPhone。",
                        kind: .info
                    )

                    SettingsSectionBlock(title: "行情与估值") {
                        SettingsGroupCard {
                            providerLink(.massive)
                            SettingsDivider()
                            providerLink(.fmp)
                        }

                        HStack(alignment: .top, spacing: 9) {
                            Image(systemName: "globe.americas.fill")
                                .foregroundStyle(CatfolioTheme.accent)
                                .frame(width: 20)
                            Text("Yahoo Finance 无需密钥；自动用于回撤与历史价格，也会在 Massive 不可用时补充成交量行情。")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.horizontal, 4)
                        .accessibilityElement(children: .combine)
                    }

                    SettingsSectionBlock(title: "AI") {
                        SettingsGroupCard {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("默认模型")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)

                                Picker("默认模型", selection: $aiProviderRaw) {
                                    ForEach(AIProviderPreference.allCases) { provider in
                                        Text(provider.title).tag(provider.rawValue)
                                    }
                                }
                                .pickerStyle(.segmented)

                                Text(selectedAIProvider.detail)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)

                                if selectedAIProvider == .automatic || selectedAIProvider == .apple {
                                    Label(
                                        LocalAIClient.appleModelStatus.message,
                                        systemImage: LocalAIClient.appleModelStatus.isAvailable
                                            ? "checkmark.circle.fill"
                                            : "exclamationmark.circle"
                                    )
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(
                                        LocalAIClient.appleModelStatus.isAvailable
                                            ? CatfolioTheme.positive
                                            : Color.secondary
                                    )
                                }
                            }
                            .padding(12)

                            SettingsDivider()
                            codexLink
                            SettingsDivider()
                            providerLink(.deepSeek)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 48)
            }
            .background(CatfolioTheme.pageBackground(for: colorScheme))
            .navigationTitle("服务商")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .navigationDestination(for: LocalServiceProvider.self) { provider in
                LocalServiceDetailView(provider: provider) { status in
                    statuses[provider] = status
                }
            }
            .onAppear {
                refreshStatuses()
                applyLaunchRouteIfNeeded()
            }
        }
        .tint(CatfolioTheme.accent)
    }

    private var selectedAIProvider: AIProviderPreference {
        AIProviderPreference(rawValue: aiProviderRaw) ?? .automatic
    }

    private var codexLink: some View {
        NavigationLink {
            CodexOAuthSettingsView()
        } label: {
            HStack(spacing: 12) {
                SettingsIcon(systemName: "bubble.left.and.text.bubble.right.fill", tint: CatfolioTheme.services)

                VStack(alignment: .leading, spacing: 3) {
                    Text("ChatGPT Codex")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("使用 ChatGPT 订阅进行组合问答")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                HStack(spacing: 4) {
                    Image(systemName: codexConnected ? "checkmark.circle.fill" : "circle")
                    Text(codexConnected ? "已连接" : "未连接")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(codexConnected ? CatfolioTheme.positive : Color.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    (codexConnected ? CatfolioTheme.positive : Color.secondary).opacity(0.10),
                    in: Capsule()
                )

                Image(systemName: "chevron.forward")
                    .font(.caption.bold())
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("ChatGPT Codex，使用 ChatGPT 订阅进行组合问答")
        .accessibilityValue(codexConnected ? "已连接" : "未连接")
    }

    private func providerLink(_ provider: LocalServiceProvider) -> some View {
        let status = statuses[provider] ?? .unconfigured
        return NavigationLink(value: provider) {
            HStack(spacing: 12) {
                SettingsIcon(systemName: provider.iconName, tint: provider.tint)

                VStack(alignment: .leading, spacing: 3) {
                    Text(provider.shortTitle)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(provider.purpose)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                HStack(spacing: 4) {
                    Image(systemName: status.iconName)
                    Text(status.title)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(status.color)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(status.color.opacity(0.10), in: Capsule())

                Image(systemName: "chevron.forward")
                    .font(.caption.bold())
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(provider.title)，\(provider.purpose)")
        .accessibilityValue(status.title)
        .accessibilityHint("打开服务商设置")
    }

    private func refreshStatuses() {
        for provider in LocalServiceProvider.allCases {
            let key = KeychainStore.string(for: provider.keychainKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if statuses[provider] != .verified {
                statuses[provider] = key.isEmpty ? .unconfigured : .configured
            }
        }
    }

    private func applyLaunchRouteIfNeeded() {
        guard !hasAppliedLaunchRoute else { return }
        hasAppliedLaunchRoute = true
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--show-local-service-massive") {
            path = [.massive]
        } else if arguments.contains("--show-local-service-fmp") {
            path = [.fmp]
        } else if arguments.contains("--show-local-service-deepseek") {
            path = [.deepSeek]
        }
    }
}

private struct CodexOAuthSettingsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL
    @AppStorage(CodexOAuthClient.connectedStorageKey) private var connected = false
    @AppStorage(CodexOAuthClient.accountEmailStorageKey) private var accountEmail = ""
    @AppStorage(CodexOAuthClient.accountPlanStorageKey) private var accountPlan = ""

    @State private var loginSession: CodexLoginSession?
    @State private var isWorking = false
    @State private var feedback: LocalServiceFeedback?
    @State private var pollingTask: Task<Void, Never>?
    @State private var didCopyCode = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("连接状态")
                        .font(.headline)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 14) {
                        SettingsIcon(
                            systemName: "bubble.left.and.text.bubble.right.fill",
                            tint: CatfolioTheme.services
                        )
                        VStack(alignment: .leading, spacing: 4) {
                            Text(connected ? "已连接 ChatGPT" : "尚未连接")
                                .font(.title3.weight(.bold))
                            if connected {
                                Text([accountEmail, planLabel].filter { !$0.isEmpty }.joined(separator: " · "))
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("授权令牌保存在此 iPhone 的 Keychain 中。")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(16)
                    .background(
                        CatfolioTheme.surface(for: colorScheme),
                        in: RoundedRectangle(cornerRadius: CatfolioStyle.cardRadius, style: .continuous)
                    )
                }

                if let loginSession {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("一次性验证码")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        HStack {
                            Text(loginSession.userCode)
                                .font(.title2.monospaced().weight(.bold))
                                .textSelection(.enabled)
                            Spacer()
                            Button(didCopyCode ? "已复制" : "复制") {
                                UIPasteboard.general.string = loginSession.userCode
                                didCopyCode = true
                                UINotificationFeedbackGenerator().notificationOccurred(.success)
                                Task {
                                    try? await Task.sleep(for: .seconds(1.4))
                                    didCopyCode = false
                                }
                            }
                            .buttonStyle(.bordered)
                            .foregroundStyle(didCopyCode ? CatfolioTheme.positive : CatfolioTheme.services)
                        }
                        Button("打开 ChatGPT 登录页", systemImage: "safari") {
                            openURL(loginSession.verificationURL)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    }
                    .padding(16)
                    .background(
                        CatfolioTheme.surface(for: colorScheme),
                        in: RoundedRectangle(cornerRadius: CatfolioStyle.cardRadius, style: .continuous)
                    )
                }

                if let feedback {
                    StatusNotice(text: feedback.text, kind: feedback.kind)
                }

                if connected {
                    Button(role: .destructive, action: logout) {
                        Label(isWorking ? "正在断开…" : "退出 ChatGPT", systemImage: "rectangle.portrait.and.arrow.right")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(isWorking)
                } else {
                    Button(action: startLogin) {
                        HStack(spacing: 8) {
                            if isWorking { ProgressView().tint(.white) }
                            Text(isWorking ? "等待网页授权…" : "登录 ChatGPT")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(isWorking)
                }
            }
            .padding(16)
            .padding(.bottom, 32)
        }
        .background(CatfolioTheme.pageBackground(for: colorScheme))
        .navigationTitle("ChatGPT Codex")
        .navigationBarTitleDisplayMode(.inline)
        .task { await refreshStatus() }
        .onDisappear {
            pollingTask?.cancel()
            pollingTask = nil
        }
    }

    private var planLabel: String {
        guard !accountPlan.isEmpty else { return "" }
        return accountPlan == "plus" ? "Plus" : accountPlan.capitalized
    }

    private func startLogin() {
        pollingTask?.cancel()
        isWorking = true
        feedback = nil
        pollingTask = Task {
            do {
                let client = CodexOAuthClient()
                let session = try await client.startLogin()
                guard !Task.isCancelled else { return }
                loginSession = session
                UIPasteboard.general.string = session.userCode
                openURL(session.verificationURL)
                try await waitForLogin(client: client, session: session)
            } catch is CancellationError {
                isWorking = false
            } catch {
                isWorking = false
                feedback = LocalServiceFeedback(text: error.localizedDescription, kind: .error)
            }
            pollingTask = nil
        }
    }

    private func refreshStatus() async {
        do {
            let client = CodexOAuthClient()
            let status = try await client.status()
            connected = status.connected
            if status.pending,
               pollingTask == nil,
               let session = try client.pendingLoginSession() {
                loginSession = session
                resumeLogin(client: client, session: session)
            }
        } catch {
            connected = false
        }
    }

    private func resumeLogin(client: CodexOAuthClient, session: CodexLoginSession) {
        pollingTask?.cancel()
        isWorking = true
        feedback = LocalServiceFeedback(text: "正在确认网页授权…", kind: .info)
        pollingTask = Task {
            do {
                try await waitForLogin(client: client, session: session, pollImmediately: true)
            } catch is CancellationError {
                isWorking = false
            } catch {
                isWorking = false
                feedback = LocalServiceFeedback(text: error.localizedDescription, kind: .error)
            }
            pollingTask = nil
        }
    }

    private func waitForLogin(
        client: CodexOAuthClient,
        session: CodexLoginSession,
        pollImmediately: Bool = false
    ) async throws {
        for attempt in 0..<150 {
            if !pollImmediately || attempt > 0 {
                try await Task.sleep(for: .seconds(session.intervalSeconds))
            }
            let status: CodexConnectionStatus
            do {
                status = try await client.status(loginID: session.loginID)
            } catch let error where CodexOAuthClient.isTransientNetworkError(error) {
                continue
            }
            guard !Task.isCancelled else { throw CancellationError() }
            if status.connected {
                connected = true
                loginSession = nil
                isWorking = false
                feedback = LocalServiceFeedback(text: "ChatGPT 已连接", kind: .success)
                return
            }
            if let error = status.error, !status.pending {
                throw LocalServiceError.remote(error)
            }
        }
        throw LocalServiceError.remote("登录等待超时，请重新开始")
    }

    private func logout() {
        isWorking = true
        feedback = nil
        Task {
            do {
                try await CodexOAuthClient().logout()
                connected = false
                loginSession = nil
                feedback = LocalServiceFeedback(text: "已退出 ChatGPT", kind: .success)
            } catch {
                feedback = LocalServiceFeedback(text: error.localizedDescription, kind: .error)
            }
            isWorking = false
        }
    }
}

private struct LocalServiceFeedback {
    let text: String
    let kind: StatusNotice.Kind
}

private struct LocalServiceDetailView: View {
    @Environment(\.colorScheme) private var colorScheme
    let provider: LocalServiceProvider
    let onStatusChanged: (LocalServiceStatus) -> Void

    @State private var apiKey = ""
    @State private var originalKey = ""
    @State private var revealsKey = false
    @State private var isTesting = false
    @State private var feedback: LocalServiceFeedback?
    @State private var showsRemoveConfirmation = false
    @State private var hasLoaded = false
    @State private var validationTask: Task<Void, Never>?

    private var trimmedKey: String {
        apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("服务用途")
                        .font(.headline)
                        .foregroundStyle(.secondary)

                    HStack(alignment: .top, spacing: 14) {
                        SettingsIcon(systemName: provider.iconName, tint: provider.tint)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(provider.title)
                                .font(.title3.weight(.bold))
                            Text(provider.detail)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(
                        CatfolioTheme.surface(for: colorScheme),
                        in: RoundedRectangle(cornerRadius: CatfolioStyle.cardRadius, style: .continuous)
                    )
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("API 密钥")
                        .font(.headline)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 4) {
                        Group {
                            if revealsKey {
                                TextField("输入 \(provider.shortTitle) API Key", text: $apiKey)
                            } else {
                                SecureField("输入 \(provider.shortTitle) API Key", text: $apiKey)
                            }
                        }
                        .font(.body.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.password)
                        .submitLabel(.done)

                        Button {
                            revealsKey.toggle()
                        } label: {
                            Image(systemName: revealsKey ? "eye.slash.fill" : "eye.fill")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(CatfolioTheme.accent)
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(revealsKey ? "隐藏 API 密钥" : "显示 API 密钥")
                    }
                    .padding(.leading, 16)
                    .padding(.trailing, 6)
                    .frame(minHeight: 56)
                    .background(
                        CatfolioTheme.surface(for: colorScheme),
                        in: RoundedRectangle(cornerRadius: CatfolioStyle.cardRadius, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: CatfolioStyle.cardRadius, style: .continuous)
                            .stroke(Color.primary.opacity(0.06), lineWidth: 1)
                    }
                    .disabled(isTesting)

                    Label("仅保存在此 iPhone 的 Keychain", systemImage: "lock.shield.fill")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if let feedback {
                    StatusNotice(text: feedback.text, kind: feedback.kind)
                }

                VStack(spacing: 12) {
                    Button {
                        startValidation()
                    } label: {
                        HStack(spacing: 9) {
                            if isTesting {
                                ProgressView()
                                    .tint(.white)
                            }
                            Text(isTesting ? "正在验证…" : "保存并验证")
                                .font(.headline)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 54)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.roundedRectangle(radius: CatfolioStyle.cardRadius))
                    .tint(CatfolioTheme.accent)
                    .disabled(trimmedKey.isEmpty || isTesting)
                    .accessibilityLabel(isTesting ? "正在验证" : "保存并验证")
                    .accessibilityHint("保存 API 密钥并验证连接")

                    Button {
                        saveWithoutValidation()
                    } label: {
                        Text("仅保存，不验证")
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: 52)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.roundedRectangle(radius: CatfolioStyle.cardRadius))
                    .tint(CatfolioTheme.accent)
                    .disabled(trimmedKey.isEmpty || isTesting)
                    .accessibilityLabel("仅保存，不验证")
                    .accessibilityHint("保存 API 密钥但不验证连接")
                }

                if !originalKey.isEmpty {
                    Button("移除此密钥", role: .destructive) {
                        showsRemoveConfirmation = true
                    }
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 48)
                    .disabled(isTesting)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 32)
        }
        .background(CatfolioTheme.pageBackground(for: colorScheme))
        .navigationTitle(provider.shortTitle)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { loadKeyIfNeeded() }
        .onDisappear {
            validationTask?.cancel()
            validationTask = nil
        }
        .onChange(of: apiKey) { _, newValue in
            let edited = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if edited != originalKey { feedback = nil }
        }
        .confirmationDialog(
            "移除 \(provider.title) 密钥？",
            isPresented: $showsRemoveConfirmation,
            titleVisibility: .visible
        ) {
            Button("移除密钥", role: .destructive) { removeKey() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("移除后，依赖此服务的数据可能无法加载。")
        }
    }

    private func loadKeyIfNeeded() {
        guard !hasLoaded else { return }
        hasLoaded = true
        let saved = KeychainStore.string(for: provider.keychainKey) ?? ""
        apiKey = saved
        originalKey = saved
    }

    @MainActor
    private func saveAndValidate() async {
        guard !trimmedKey.isEmpty else { return }
        let candidate = trimmedKey
        isTesting = true
        feedback = nil
        defer { isTesting = false }

        do {
            let message = try await provider.validate(apiKey: candidate)
            try Task.checkCancellation()
            do {
                try KeychainStore.set(candidate, for: provider.keychainKey)
            } catch {
                let saveMessage = "连接已验证，但无法保存到 Keychain：\(error.localizedDescription)"
                feedback = LocalServiceFeedback(text: saveMessage, kind: .error)
                announce(saveMessage)
                return
            }
            originalKey = candidate
            if provider == .fmp {
                await LocalReturnsAnalyticsClient.resetFailedFundamentalAttempts()
            }
            feedback = LocalServiceFeedback(text: message, kind: .success)
            onStatusChanged(.verified)
            announce(message)
        } catch is CancellationError {
            return
        } catch {
            let suffix = originalKey.isEmpty ? "未保存这次输入。" : "原密钥未更改。"
            let message = "\(error.localizedDescription) \(suffix)"
            feedback = LocalServiceFeedback(text: message, kind: .error)
            announce("验证失败。\(message)")
        }
    }

    private func startValidation() {
        guard !isTesting else { return }
        validationTask?.cancel()
        validationTask = Task { await saveAndValidate() }
    }

    private func saveWithoutValidation() {
        guard !trimmedKey.isEmpty else { return }
        do {
            try KeychainStore.set(trimmedKey, for: provider.keychainKey)
            originalKey = trimmedKey
            feedback = LocalServiceFeedback(text: "已安全保存到此 iPhone", kind: .success)
            onStatusChanged(.configured)
            if provider == .fmp {
                Task { await LocalReturnsAnalyticsClient.resetFailedFundamentalAttempts() }
            }
            announce("密钥已保存")
        } catch {
            feedback = LocalServiceFeedback(text: error.localizedDescription, kind: .error)
            announce("保存失败。\(error.localizedDescription)")
        }
    }

    private func removeKey() {
        do {
            try KeychainStore.set("", for: provider.keychainKey)
            apiKey = ""
            originalKey = ""
            revealsKey = false
            feedback = LocalServiceFeedback(text: "密钥已从此 iPhone 移除", kind: .info)
            onStatusChanged(.unconfigured)
            if provider == .fmp {
                Task { await LocalReturnsAnalyticsClient.resetFailedFundamentalAttempts() }
            }
            announce("密钥已移除")
        } catch {
            feedback = LocalServiceFeedback(text: error.localizedDescription, kind: .error)
            announce("移除失败。\(error.localizedDescription)")
        }
    }

    private func announce(_ message: String) {
        UIAccessibility.post(notification: .announcement, argument: message)
    }
}

/// The tinted rounded-square an iOS settings row puts its symbol in.
///
/// The rows previously drew a bare tinted glyph, which left each symbol a
/// different optical weight and width — a `globe` outline and a
/// `chart.pie.fill` next to each other read as two different kinds of
/// control. Boxing them equalises that: the tile is the constant, the symbol
/// varies inside it, and the row's text starts at the same x every time.
private struct SettingsGlyph: View {
    let symbol: String
    let tint: Color

    var body: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(tint.gradient)
            .frame(width: 29, height: 29)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }
}
