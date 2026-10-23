import SwiftUI
import SafariServices

struct MoomooOAuthView: View {
    @Environment(\.locale) private var appLocale
    @Environment(\.dismiss) private var dismissPage
    @Environment(\.accountFlowClose) private var accountFlowClose
    @Environment(AppModel.self) private var model
    @StateObject private var authorizationSession = MoomooAuthorizationSession()

    let context: AccountConnectorContext
    private let isFirstLaunchSetup: Bool

    @State private var snapshot: MoomooSnapshot?
    @State private var status: MoomooViewStatus = .idle
    @State private var isWorking = false
    @State private var previewTask: Task<Void, Never>?
    @State private var isConnected = false
    @State private var showsDisconnectConfirmation = false
    @State private var showsSyncConfirmation = false
    @State private var hasCreatedAccount = false
    @State private var nickname = ""
    @State private var nicknameEdited = false

    init(context: AccountConnectorContext = .create, isFirstLaunchSetup: Bool = false) {
        self.context = context
        self.isFirstLaunchSetup = isFirstLaunchSetup
    }

    /// Inside 添加账户 this closes the whole flow; on its own, the page.
    private func dismiss() {
        if let accountFlowClose { accountFlowClose() } else { dismissPage() }
    }

    var body: some View {
        AccountFlowStack { page(1) }
            .accountFlowBrand(.moomoo)
    }

    private func page(_ page: Int) -> some View {
        let isConnected = !context.isCreating || page >= 2 ? self.isConnected : false
        let snapshot = !context.isCreating || page >= 3 ? self.snapshot : nil
        return AccountFlowPage(showsNext: Binding(
            get: { context.isCreating && min(flowStep, 3) > page },
            set: { shown in
                guard !shown, min(flowStep, 3) > page else { return }
                previewTask?.cancel()
                self.snapshot = nil
                status = .idle
                if page == 1 { self.isConnected = false }
            })) {
            OnboardingPage(scrollReset: page, isAccountPreparation: true) {
                AccountConnectionHeader(provider: .moomoo, title: hasCreatedAccount ? L10n.text("账户已添加")
                    : (snapshot != nil ? L10n.text("确认 Moomoo 持仓") : L10n.text("连接 Moomoo")),
                    subtitle: hasCreatedAccount ? nil : (snapshot != nil ? L10n.text("检查持仓后，确认同步到账户。")
                        : L10n.text("登录并授权，然后预览你的持仓。")))

                if !isConnected {
                    BrokerPreparationInstructions(provider: .moomoo)
                } else if snapshot == nil {
                    AccountPreparationList {
                        AccountPreparationFeature(symbol: "checkmark.shield.fill", title: L10n.text("已授权 Moomoo"),
                            detail: L10n.text("先读取持仓预览，确认后再添加账户。"))
                    }
                }
                if status.isPresented { statusView }

                if context.isCreating, snapshot != nil, !hasCreatedAccount {
                    SettingsSection(L10n.text("账户昵称")) {
                        AccountNicknameField(nickname: $nickname, edited: $nicknameEdited)
                            .disabled(isWorking)
                    }
                }

                if let snapshot {
                    SettingsSectionHeader(L10n.text("账户预览"))
                    SettingsCard {
                        SettingsValueRow(title: L10n.text("授权账户"), value: L10n.text("\(snapshot.accounts.count) 个"))
                        SettingsValueRow(title: L10n.text("持仓"), value: L10n.text("\(snapshot.positions.count) 项"))
                        SettingsValueRow(title: L10n.text("历史成交"), value: L10n.text("\(snapshot.fills.count) 笔"))

                        ForEach(snapshot.positions.prefix(10)) { position in
                            SettingsRowContainer {
                                HStack {
                                    VStack(alignment: .leading, spacing: SettingsTemplate.subtitleSpacing) {
                                        Text(position.code)
                                            .appText(.subheading, weight: .semibold)
                                        Text(position.stockName)
                                            .appText(.label, weight: .regular)
                                            .foregroundStyle(SettingsTemplate.secondaryText)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    VStack(alignment: .trailing, spacing: SettingsTemplate.subtitleSpacing) {
                                        FinancialText(DisplayFormat.shares(position.quantityValue))
                                            .appNumber(.subheading)
                                        if let marketValue = position.marketValueValue {
                                            FinancialText(DisplayFormat.money(marketValue, currency: position.currency))
                                                .appNumber(.label, weight: .regular, monospaced: false)
                                                .foregroundStyle(SettingsTemplate.secondaryText)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    if snapshot.positions.count > 10 || !snapshot.historyWarnings.isEmpty {
                        SettingsFootnote({
                            let preview = snapshot.positions.count > 10
                                ? L10n.text("仅显示前 10 项；同步处理全部持仓。")
                                : ""
                            let warnings = snapshot.historyWarnings.joined(separator: L10n.clauseSeparator)
                            return [preview, warnings].filter { !$0.isEmpty }.joined(separator: " ")
                        }())
                    }
                }

                if isConnected && !hasCreatedAccount {
                    DisclosureGroup(L10n.text("连接管理")) {
                        Button(L10n.text("重新授权 Moomoo")) { Task { await connect() } }
                        if snapshot != nil {
                            Button(L10n.text("重新读取持仓")) { startPreview() }
                        }
                    }.disabled(isWorking)
                }

                if isConnected && !context.isCreating {
                    SettingsCard {
                        SettingsButtonRow(
                            icon: .symbol("trash"),
                            title: L10n.text("断开 Moomoo"),
                            showsChevron: false,
                            role: .destructive
                        ) {
                            showsDisconnectConfirmation = true
                        }
                    }
                }
            } actions: { flowActions(page) }
            .accountConnectionTutorial(.moomoo)
            .toolbar {
                if !context.isCreating || hasCreatedAccount {
                    ToolbarItem(placement: .confirmationAction) {
                        AppModalDoneButton { dismiss() }
                    }
                }
            }
            .task { prepareNickname() }
            .onDisappear {
                if !context.isCreating || min(flowStep, 3) == page { previewTask?.cancel() }
            }
            .confirmationDialog(
                L10n.text("断开 Moomoo？"),
                isPresented: $showsDisconnectConfirmation,
                titleVisibility: .visible
            ) {
                Button(L10n.text("断开"), role: .destructive) { disconnect() }
                Button(L10n.text("取消"), role: .cancel) {}
            } message: {
                Text(L10n.text("将删除此 iPhone Keychain 中的 Moomoo Access Token 与 Refresh Token。"))
            }
            .confirmationDialog(
                context.isCreating ? L10n.text("创建 Moomoo 账户？") : L10n.text("更新 Moomoo 账户？"),
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
                    : L10n.text("将更新当前 Moomoo 账户持仓；其他账户不受影响。"))
            }
            .appFullScreenCover(item: $authorizationSession.authorizationPage) { page in
                MoomooSafariView(url: page.url) {
                    authorizationSession.cancel()
                }
                .ignoresSafeArea()
            }
        } next: { AnyView(self.page(page + 1)) }
    }

    private var flowStep: Int { hasCreatedAccount ? 4 : (snapshot != nil ? 3 : (isConnected ? 2 : 1)) }

    @ViewBuilder
    private func flowActions(_ page: Int) -> some View {
        let isConnected = !context.isCreating || page >= 2 ? self.isConnected : false
        let snapshot = !context.isCreating || page >= 3 ? self.snapshot : nil
        if hasCreatedAccount {
            OnboardingPrimaryButton(title: L10n.text("完成")) { dismiss() }
        } else if isConnected, let snapshot {
            OnboardingPrimaryButton(
                title: isWorking
                    ? (context.isCreating ? L10n.text("正在创建") : L10n.text("正在同步"))
                    : (context.isCreating ? L10n.text("创建 Moomoo 账户") : L10n.text("同步 \(snapshot.positions.count) 项到 Catfolio")),
                isDisabled: !hasValidNickname,
                isBusy: isWorking
            ) {
                showsSyncConfirmation = true
            }
        } else if isConnected {
            OnboardingPrimaryButton(
                title: isWorking ? L10n.text("正在读取") : L10n.text("读取并预览持仓"),
                isBusy: isWorking
            ) {
                startPreview()
            }
        } else {
            OnboardingPrimaryButton(
                title: isWorking ? L10n.text("正在连接") : L10n.text("登录 Moomoo"),
                isBusy: isWorking
            ) {
                Task { await connect() }
            }
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch status {
        case .idle:
            EmptyView()
        case let .working(message):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(L10n.message(message))
            }
            .appText(.label, weight: .regular)
            .foregroundStyle(SettingsTemplate.secondaryText)
        case let .success(message):
            Label(message, systemImage: "checkmark.circle.fill")
                .font(.footnote)
                .foregroundStyle(CatfolioTheme.positive)
        case let .failure(message):
            StatusNotice(text: message)
        }
    }

    private var hasValidNickname: Bool {
        !context.isCreating || !nickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func prepareNickname() {
        guard nickname.isEmpty else { return }
        if let account = context.account {
            nickname = AccountNaming.nickname(from: account.displayName, provider: "Moomoo")
            isConnected = MoomooCredentialStore.tokenSet(for: account.accountID) != nil
        } else {
            nickname = model.suggestedAccountNickname()
            try? MoomooCredentialStore.migrateLegacyToken(to: model.accounts
                .filter { $0.source == "Moomoo" }
                .compactMap(\.accountID))
            isConnected = false
        }
    }

    private func connect() async {
        isWorking = true
        status = .working(L10n.text("正在打开 Moomoo 授权页…"))
        defer { isWorking = false }
        do {
            let tokenSet = try await authorizationSession.authorize(accountID: context.account?.accountID)
            isConnected = true
            status = .success(tokenSet.scope.contains("trade:read") ? L10n.text("授权成功") : L10n.text("授权成功；请确认已授予 trade:read"))
        } catch {
            status = .failure(error.localizedDescription)
        }
    }

    private func startPreview() {
        previewTask?.cancel()
        previewTask = Task { await preview() }
    }

    private func preview() async {
        isWorking = true
        status = .working(L10n.text("正在读取全部授权账户…"))
        defer { isWorking = false }
        do {
            let fetched = try await MoomooOpenAPIClient(
                credentialAccountID: context.account?.accountID
            ).fetchSnapshot(
                reportingCurrency: DisplayCurrency.current.rawValue
            )
            try Task.checkCancellation()
            let result = snapshotForContext(fetched)
            guard !result.accounts.isEmpty else {
                status = .failure(context.isCreating
                    ? L10n.text("当前授权中没有可新建的 Moomoo 账户。")
                    : L10n.text("返回数据未包含当前账户，请检查授权或报表范围。"))
                return
            }
            try persistCredentials(for: result.accounts.map(\.accountID))
            if context.isCreating, !nicknameEdited {
                let type = result.accounts.first?.accountType.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                nickname = type.isEmpty ? "Moomoo" : "Moomoo \(type)"
            }
            snapshot = result
            status = .success(L10n.text("读取成功：\(result.accounts.count) 个账户，\(result.positions.count) 项持仓"))
        } catch {
            status = Task.isCancelled ? .idle : .failure(error.localizedDescription)
        }
    }

    private func sync() async {
        isWorking = true
        status = .working(L10n.text("正在读取并转换 Moomoo 持仓…"))
        defer { isWorking = false }
        do {
            let fetched = try await MoomooOpenAPIClient(
                credentialAccountID: context.account?.accountID
            ).fetchSnapshot(
                reportingCurrency: DisplayCurrency.current.rawValue
            )
            let currentSnapshot = snapshotForContext(fetched)
            guard !currentSnapshot.accounts.isEmpty else {
                status = .failure(context.isCreating
                    ? L10n.text("当前授权中没有可新建的 Moomoo 账户。")
                    : L10n.text("返回数据未包含当前账户，请检查授权或报表范围。"))
                return
            }
            try persistCredentials(for: currentSnapshot.accounts.map(\.accountID))
            snapshot = currentSnapshot
            status = .working(L10n.text("Moomoo 已读取，正在保存到本机…"))
            let accountNames = model.accountNames(
                source: "Moomoo",
                accountIDs: currentSnapshot.accounts.map(\.accountID),
                preferredNickname: nickname,
                targetAccountID: context.account?.accountID
            )
            let result = try await model.importMoomoo(
                currentSnapshot,
                accountNames: accountNames,
                replacingAccountsOnly: true
            )
            if context.isCreating { hasCreatedAccount = true }
            let warningText = result.warnings.isEmpty ? "" : L10n.text("，\(result.warnings.count) 条提示")
            status = .success(context.isCreating
                ? L10n.text("已创建账户，导入 \(result.holdingsCount) 个持仓\(warningText)")
                : L10n.text("已同步 \(result.holdingsCount) 个持仓\(warningText)"))
        } catch {
            status = .failure(error.localizedDescription)
        }
    }

    private func disconnect() {
        MoomooCredentialStore.clearTokens(for: context.account?.accountID)
        isConnected = false
        snapshot = nil
        status = .idle
    }

    private func persistCredentials(for accountIDs: [String]) throws {
        guard let tokenSet = MoomooCredentialStore.tokenSet(for: context.account?.accountID) else {
            throw MoomooOpenAPIError.tokenMissing
        }
        for accountID in Set(accountIDs) where !accountID.isEmpty {
            try MoomooCredentialStore.save(tokenSet: tokenSet, for: accountID)
        }
    }

    private func snapshotForContext(_ snapshot: MoomooSnapshot) -> MoomooSnapshot {
        let allowedIDs: Set<String>
        if let accountID = context.account?.accountID {
            allowedIDs = [accountID]
        } else if context.isCreating {
            let existingIDs = Set(model.accounts
                .filter { $0.source == "Moomoo" }
                .compactMap(\.accountID))
            allowedIDs = Set(snapshot.accounts.map(\.accountID)).subtracting(existingIDs)
        } else {
            return snapshot
        }
        return MoomooSnapshot(
            accounts: snapshot.accounts.filter { allowedIDs.contains($0.accountID) },
            positions: snapshot.positions.filter { allowedIDs.contains($0.accountID) },
            fills: snapshot.fills.filter { allowedIDs.contains($0.accountID) },
            accountCurrencies: snapshot.accountCurrencies.filter { allowedIDs.contains($0.key) },
            historyWarnings: snapshot.historyWarnings
        )
    }
}

private struct MoomooSafariView: UIViewControllerRepresentable {
    let url: URL
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCancel: onCancel)
    }

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let controller = SFSafariViewController(url: url)
        controller.delegate = context.coordinator
        controller.dismissButtonStyle = .cancel
        return controller
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}

    final class Coordinator: NSObject, SFSafariViewControllerDelegate {
        let onCancel: () -> Void

        init(onCancel: @escaping () -> Void) {
            self.onCancel = onCancel
        }

        func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
            onCancel()
        }
    }
}

private enum MoomooViewStatus {
    case idle

    /// Whether the connection card should give the status a row of its own.
    var isPresented: Bool {
        if case .idle = self { false } else { true }
    }
    case working(String)
    case success(String)
    case failure(String)
}
