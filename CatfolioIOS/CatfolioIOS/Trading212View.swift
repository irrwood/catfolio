import SwiftUI

struct Trading212View: View {
    @Environment(\.locale) private var appLocale
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model

    let context: AccountConnectorContext

    @State private var environment: Trading212Environment = .live
    @State private var apiKey = ""
    @State private var apiSecret = ""
    @State private var accountSlot = 1
    @State private var nickname = ""
    @State private var nicknameEdited = false
    @State private var snapshot: Trading212Snapshot?
    @State private var snapshotAccounts: [Trading212AccountCredentials]?
    @State private var snapshotEnvironment: Trading212Environment?
    @State private var status: Trading212ViewStatus = .idle
    @State private var isWorking = false
    @State private var showsClearConfirmation = false
    @State private var showsSyncConfirmation = false
    @State private var historyRetryTask: Task<Void, Never>?

    private static let environmentPreferenceName = "trading212.environment"

    init(context: AccountConnectorContext = .create) {
        self.context = context
    }

    private static func apiKeyKey(slot: Int) -> String { "trading212.account-\(slot).api-key" }
    private static func apiSecretKey(slot: Int) -> String { "trading212.account-\(slot).api-secret" }

    var body: some View {
        NavigationStack {
            SettingsPage(bottomInset: 32) {
                SettingsSectionHeader("Trading 212 API")
                SettingsCard {
                    SettingsRowContainer {
                        Picker(L10n.text("环境"), selection: $environment) {
                            ForEach(Trading212Environment.allCases) { item in
                                Text(item.displayName).tag(item)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }

                    SettingsRowContainer {
                        Text(L10n.text("API Key 与 Secret 仅存于此 iPhone Keychain，不会发送到 Catfolio 服务端。"))
                            .appText(.label, weight: .regular)
                            .foregroundStyle(SettingsTemplate.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                SettingsFootnote(L10n.text("只使用账户、持仓和历史数据的读取权限。建议创建专用的只读 Key。"))

                if context.isCreating, snapshot != nil {
                    SettingsSectionHeader(L10n.text("账户昵称"))
                    SettingsCard {
                        AccountNicknameField(nickname: $nickname, edited: $nicknameEdited)
                            .disabled(isWorking)
                    }
                    SettingsFootnote(L10n.text("用于区分多个 Trading 212 账户，创建后仍可在账户详情中修改。"))
                }

                credentialsSection

                SettingsSectionHeader(L10n.text("连接"))
                SettingsCard {
                    if let snapshot {
                        SettingsButtonRow(
                            icon: .symbol("arrow.clockwise"),
                            title: L10n.text("重新读取持仓"),
                            showsChevron: false
                        ) {
                            Task { await preview() }
                        }
                        .disabled(isWorking)

                        SettingsRowContainer {
                            GlassPrimaryButton(
                                title: isWorking
                                    ? (context.isCreating ? L10n.text("正在创建") : L10n.text("正在同步"))
                                    : (context.isCreating ? L10n.text("创建 Trading 212 账户") : L10n.text("同步 \(snapshot.positions.count) 项到 Catfolio")),
                                systemImage: "tray.and.arrow.down.fill",
                                isDisabled: !hasValidNickname,
                                isBusy: isWorking
                            ) {
                                showsSyncConfirmation = true
                            }
                        }
                    } else {
                        SettingsRowContainer {
                            GlassPrimaryButton(
                                title: isWorking ? L10n.text("正在读取") : L10n.text("读取并预览持仓"),
                                systemImage: "arrow.down.circle",
                                isBusy: isWorking
                            ) {
                                Task { await preview() }
                            }
                        }
                    }

                    if status.isPresented {
                        SettingsRowContainer { statusView }
                    }

                    Link(destination: URL(string: "https://helpcentre.trading212.com/hc/en-us/articles/14584770928157-Trading-212-API-key")!) {
                        SettingsRowContainer {
                            HStack(spacing: SettingsTemplate.iconSpacing) {
                                SettingsRowLabel(
                                    icon: .symbol("arrow.up.right.square"),
                                    title: L10n.text("查看 API Key 设置说明")
                                )
                            }
                        }
                    }
                    .buttonStyle(SettingsRowButtonStyle())
                }

                if let snapshot {
                    SettingsSectionHeader(L10n.text("持仓预览"))
                    SettingsCard {
                        SettingsValueRow(title: L10n.text("账户"), value: L10n.text("\(snapshot.accountCount) 个"))
                        SettingsValueRow(title: L10n.text("持仓"), value: L10n.text("\(snapshot.positions.count) 项"))

                        ForEach(snapshot.positions.prefix(10)) { position in
                            SettingsRowContainer {
                                HStack {
                                    VStack(alignment: .leading, spacing: SettingsTemplate.subtitleSpacing) {
                                        HStack(spacing: 6) {
                                            Text(position.ticker)
                                                .appText(.subheading, weight: .semibold)
                                            if snapshot.accountCount > 1 {
                                                Text(L10n.text("账户 \(position.accountSlot)"))
                                                    .appText(.label, weight: .medium)
                                                    .foregroundStyle(SettingsTemplate.secondaryText)
                                            }
                                        }
                                        Text(position.name)
                                            .appText(.label, weight: .regular)
                                            .foregroundStyle(SettingsTemplate.secondaryText)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    VStack(alignment: .trailing, spacing: SettingsTemplate.subtitleSpacing) {
                                        Text(DisplayFormat.shares(position.quantity))
                                            .appNumber(.subheading)
                                        if let currentPrice = position.currentPrice {
                                            Text(DisplayFormat.money(position.quantity * currentPrice, currency: position.currency))
                                                .appNumber(.label, weight: .regular, monospaced: false)
                                                .foregroundStyle(SettingsTemplate.secondaryText)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    SettingsFootnote(snapshot.positions.count > 10
                        ? L10n.text("仅预览前 10 项；保存时会处理该账户的全部可导入持仓。")
                        : L10n.text("只处理当前 Trading 212 账户。"))
                }

                if hasCredentials && !context.isCreating {
                    SettingsCard {
                        SettingsButtonRow(
                            icon: .symbol("trash"),
                            title: L10n.text("移除本机 Trading 212 凭证"),
                            showsChevron: false,
                            role: .destructive
                        ) {
                            showsClearConfirmation = true
                        }
                    }
                }
            }
            .softTopScrollEdge()
            .navigationTitle(context.isCreating ? L10n.text("新建 Trading 212 账户") : "Trading 212")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L10n.text("完成")) { dismiss() }
                }
            }
            .task { prepareAccount() }
            .onDisappear {
                historyRetryTask?.cancel()
                historyRetryTask = nil
            }
            .onChange(of: environment) { _, _ in invalidatePreview() }
            .onChange(of: apiKey) { _, _ in invalidatePreview() }
            .onChange(of: apiSecret) { _, _ in invalidatePreview() }
            .confirmationDialog(
                L10n.text("移除 Trading 212 凭证？"),
                isPresented: $showsClearConfirmation,
                titleVisibility: .visible
            ) {
                Button(L10n.text("移除"), role: .destructive) { clearCredentials() }
                Button(L10n.text("取消"), role: .cancel) {}
            } message: {
                Text(L10n.text("只会删除当前账户保存在此 iPhone Keychain 中的 API Key 与 Secret。"))
            }
            .confirmationDialog(
                context.isCreating ? L10n.text("创建 Trading 212 账户？") : L10n.text("更新 Trading 212 账户？"),
                isPresented: $showsSyncConfirmation,
                titleVisibility: .visible
            ) {
                Button(context.isCreating ? L10n.text("创建账户") : L10n.text("同步并更新")) {
                    Task { await sync() }
                }
                Button(L10n.text("取消"), role: .cancel) {}
            } message: {
                Text(context.isCreating
                    ? L10n.text("将使用预览中的数据创建新账户；现有账户不受影响。")
                    : L10n.text("将更新当前 Trading 212 账户持仓；其他账户不受影响。"))
            }
        }
        .tint(CatfolioTheme.accent)
    }

    @ViewBuilder
    private var credentialsSection: some View {
        SettingsSectionHeader(L10n.text("只读凭证"))
        SettingsCard {
            SettingsFieldRow("API Key", text: $apiKey, isSecure: true, isMonospaced: true)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .privacySensitive()

            SettingsFieldRow("API Secret", text: $apiSecret, isSecure: true, isMonospaced: true)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .privacySensitive()
        }
        SettingsFootnote(L10n.text("每次只创建或更新一个 Trading 212 账户。"))
    }

    @ViewBuilder
    private var statusView: some View {
        switch status {
        case .idle:
            EmptyView()
        case let .working(message):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(message)
            }
            .appText(.label, weight: .regular)
            .foregroundStyle(SettingsTemplate.secondaryText)
        case let .success(message):
            Label(message, systemImage: "checkmark.circle")
                .appText(.label, weight: .regular)
                .foregroundStyle(CatfolioTheme.positive)
        case let .failure(message):
            StatusNotice(text: message)
        }
    }

    private var hasCredentials: Bool {
        !apiKey.isEmpty || !apiSecret.isEmpty
    }

    private var hasValidNickname: Bool {
        !context.isCreating || !nickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func prepareAccount() {
        if let rawEnvironment = UserDefaults.standard.string(forKey: Self.environmentPreferenceName),
           let savedEnvironment = Trading212Environment(rawValue: rawEnvironment) {
            environment = savedEnvironment
        }

        if let account = context.account {
            if let slot = account.accountID.flatMap({ Int($0.replacingOccurrences(of: "account-", with: "")) }) {
                accountSlot = slot
            }
            apiKey = KeychainStore.string(for: Self.apiKeyKey(slot: accountSlot)) ?? ""
            apiSecret = KeychainStore.string(for: Self.apiSecretKey(slot: accountSlot)) ?? ""
            nickname = AccountNaming.nickname(from: account.displayName, provider: "Trading 212")
            return
        }

        let usedSlots = Set(model.accounts
            .filter { $0.source == "Trading 212" }
            .compactMap { $0.accountID }
            .compactMap { Int($0.replacingOccurrences(of: "account-", with: "")) })
        var availableSlot = 1
        while usedSlots.contains(availableSlot) { availableSlot += 1 }
        accountSlot = availableSlot
        nickname = model.suggestedAccountNickname()
    }

    private func accountCredentials() throws -> [Trading212AccountCredentials] {
        let credentials = try Trading212Credentials(apiKey: apiKey, apiSecret: apiSecret)
        return [Trading212AccountCredentials(slot: accountSlot, credentials: credentials)]
    }

    private func saveCredentials(_ accounts: [Trading212AccountCredentials]) throws {
        guard let account = accounts.first else { return }
        try KeychainStore.set(account.credentials.apiKey, for: Self.apiKeyKey(slot: account.slot))
        try KeychainStore.set(account.credentials.apiSecret, for: Self.apiSecretKey(slot: account.slot))
        UserDefaults.standard.set(environment.rawValue, forKey: Self.environmentPreferenceName)
    }

    private func preview() async {
        isWorking = true
        status = .working(L10n.text("正在读取 Trading 212 持仓与历史成交…"))
        defer { isWorking = false }
        do {
            let accounts = try accountCredentials()
            try saveCredentials(accounts)
            let result = try await Trading212Client().fetchSnapshot(accounts: accounts, environment: environment)
            if context.isCreating, !nicknameEdited {
                // The current API snapshot supplies an account label, not a personal name.
                nickname = result.syncedAccounts.first?.name ?? "Trading 212"
            }
            snapshot = result
            snapshotAccounts = accounts
            snapshotEnvironment = environment
            let historyText = result.transactionHistoryStatus.map { "；\($0)" } ?? ""
            status = .success(L10n.text("读取成功：\(result.accountCount) 个账户，\(result.positions.count) 项持仓\(historyText)"))
            if !result.hasCompleteTransactionHistory {
                scheduleHistoryRetry(.preview)
            }
        } catch {
            status = .failure(error.localizedDescription)
        }
    }

    private func sync() async {
        isWorking = true
        status = .working(L10n.text("正在同步 Trading 212 持仓与历史数据…"))
        defer { isWorking = false }
        do {
            let accounts = try accountCredentials()
            try saveCredentials(accounts)
            let currentSnapshot: Trading212Snapshot
            if let snapshot,
               snapshotAccounts == accounts,
               snapshotEnvironment == environment,
               snapshot.hasCompleteTransactionHistory {
                currentSnapshot = snapshot
            } else {
                currentSnapshot = try await Trading212Client().fetchSnapshot(accounts: accounts, environment: environment)
                snapshot = currentSnapshot
                snapshotAccounts = accounts
                snapshotEnvironment = environment
            }
            status = .working(L10n.text("Trading 212 已读取，正在保存到本机…"))
            let accountID = "account-\(accountSlot)"
            let accountNames = model.accountNames(
                source: "Trading 212",
                accountIDs: [accountID],
                preferredNickname: nickname,
                targetAccountID: context.account?.accountID
            )
            let result = try await model.importTrading212(
                currentSnapshot,
                accountNames: accountNames,
                replacingAccountsOnly: true
            )
            let warningText = result.warnings.isEmpty ? "" : L10n.text("，跳过 \(result.warnings.count) 项")
            let historyText = currentSnapshot.transactionHistoryStatus.map { "；\($0)" } ?? ""
            status = .success(context.isCreating
                ? L10n.text("已创建账户，导入 \(result.holdingsCount) 个持仓\(warningText)\(historyText)")
                : L10n.text("已同步 \(result.holdingsCount) 个持仓\(warningText)\(historyText)"))
            if !currentSnapshot.hasCompleteTransactionHistory {
                scheduleHistoryRetry(.sync)
            }
        } catch {
            status = .failure(error.localizedDescription)
        }
    }

    private func invalidatePreview() {
        guard !isWorking else { return }
        historyRetryTask?.cancel()
        historyRetryTask = nil
        snapshot = nil
        snapshotAccounts = nil
        snapshotEnvironment = nil
        status = .idle
    }

    private func scheduleHistoryRetry(_ action: Trading212HistoryRetryAction) {
        historyRetryTask?.cancel()
        historyRetryTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(62))
            guard !Task.isCancelled else { return }
            switch action {
            case .preview:
                await preview()
            case .sync:
                await sync()
            }
        }
    }

    private func clearCredentials() {
        for key in [Self.apiKeyKey(slot: accountSlot), Self.apiSecretKey(slot: accountSlot)] {
            try? KeychainStore.set("", for: key)
        }
        apiKey = ""
        apiSecret = ""
        snapshot = nil
        snapshotAccounts = nil
        snapshotEnvironment = nil
        historyRetryTask?.cancel()
        historyRetryTask = nil
        status = .idle
    }
}

private enum Trading212ViewStatus {
    case idle

    /// Whether the connection card should give the status a row of its own.
    var isPresented: Bool {
        if case .idle = self { false } else { true }
    }
    case working(String)
    case success(String)
    case failure(String)
}

private enum Trading212HistoryRetryAction {
    case preview
    case sync
}
