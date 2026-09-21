import SwiftUI
import SafariServices

struct MoomooOAuthView: View {
    @Environment(\.locale) private var appLocale
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    @StateObject private var authorizationSession = MoomooAuthorizationSession()

    let context: AccountConnectorContext

    @State private var snapshot: MoomooSnapshot?
    @State private var status: MoomooViewStatus = .idle
    @State private var isWorking = false
    @State private var isConnected = false
    @State private var showsDisconnectConfirmation = false
    @State private var showsSyncConfirmation = false
    @State private var nickname = ""
    @State private var nicknameEdited = false

    init(context: AccountConnectorContext = .create) {
        self.context = context
    }

    var body: some View {
        NavigationStack {
            SettingsPage(bottomInset: 32) {
                if context.isCreating, snapshot != nil {
                    SettingsSectionHeader(L10n.text("账户昵称"))
                    SettingsCard {
                        AccountNicknameField(nickname: $nickname, edited: $nicknameEdited)
                            .disabled(isWorking)
                    }
                    SettingsFootnote(L10n.text("用于区分多个 Moomoo 账户，创建后仍可在账户详情中修改。"))
                }

                SettingsSectionHeader("Moomoo OAuth")
                SettingsCard {
                    SettingsRowContainer {
                        SettingsRowLabel(
                            icon: .symbol(isConnected ? "checkmark.shield" : "person.crop.circle.badge.questionmark"),
                            title: isConnected ? L10n.text("已授权 Moomoo") : L10n.text("尚未连接"),
                            titleColor: isConnected ? CatfolioTheme.positive : SettingsTemplate.secondaryText
                        )
                    }

                    SettingsRowContainer {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(L10n.text("通过系统浏览器完成 OAuth 2.1 + PKCE 授权。无需 OpenD，也不需要输入 API Key。"))
                            Text(L10n.text("授权页只需允许 trade:read，用于读取账户、持仓与历史成交。"))
                            Text(L10n.text("Access Token 与 Refresh Token 仅保存在此 iPhone Keychain。"))
                        }
                        .appText(.label, weight: .regular)
                        .foregroundStyle(SettingsTemplate.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }

                SettingsSectionHeader(L10n.text("连接"))
                SettingsCard {
                    if isConnected {
                        SettingsButtonRow(
                            icon: .symbol("person.badge.key"),
                            title: L10n.text("重新授权 Moomoo"),
                            showsChevron: false
                        ) {
                            Task { await connect() }
                        }
                        .disabled(isWorking)

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
                                        : (context.isCreating ? L10n.text("创建 Moomoo 账户") : L10n.text("同步 \(snapshot.positions.count) 项到 Catfolio")),
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
                    } else {
                        SettingsRowContainer {
                            GlassPrimaryButton(
                                title: isWorking ? L10n.text("正在连接") : L10n.text("登录 Moomoo"),
                                systemImage: "person.badge.key",
                                isBusy: isWorking
                            ) {
                                Task { await connect() }
                            }
                        }
                    }

                    if status.isPresented {
                        SettingsRowContainer { statusView }
                    }

                    Link(destination: URL(string: "https://open.moomoo.com/zh-cn/api/overview/getting-started")!) {
                        SettingsRowContainer {
                            SettingsRowLabel(
                                icon: .symbol("arrow.up.right.square"),
                                title: L10n.text("查看 Moomoo OpenAPI 说明")
                            )
                        }
                    }
                    .buttonStyle(SettingsRowButtonStyle())
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
                                        Text(DisplayFormat.shares(position.quantityValue))
                                            .appNumber(.subheading)
                                        if let marketValue = position.marketValueValue {
                                            Text(DisplayFormat.money(marketValue, currency: position.currency))
                                                .appNumber(.label, weight: .regular, monospaced: false)
                                                .foregroundStyle(SettingsTemplate.secondaryText)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    SettingsFootnote({
                        let preview = snapshot.positions.count > 10
                            ? L10n.text("仅预览前 10 项；同步会处理全部账户。")
                            : L10n.text("已读取全部授权账户。")
                        let warning = snapshot.historyWarnings.isEmpty
                            ? ""
                            : " \(snapshot.historyWarnings.joined(separator: L10n.clauseSeparator))"
                        return preview + warning
                    }())
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
            }
            .softTopScrollEdge()
            .navigationTitle(context.isCreating ? L10n.text("新建 Moomoo 账户") : "Moomoo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.text("完成")) { dismiss() }
                }
            }
            .task { prepareNickname() }
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
        }
        .tint(CatfolioTheme.accent)
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
            status = .failure(error.localizedDescription)
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
