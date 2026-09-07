import SwiftUI
import SafariServices

struct MoomooOAuthView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var authorizationSession = MoomooAuthorizationSession()

    let context: AccountConnectorContext

    @State private var snapshot: MoomooSnapshot?
    @State private var status: MoomooViewStatus = .idle
    @State private var isWorking = false
    @State private var isConnected = false
    @State private var showsDisconnectConfirmation = false
    @State private var showsSyncConfirmation = false
    @State private var nickname = ""

    init(context: AccountConnectorContext = .create) {
        self.context = context
    }

    var body: some View {
        NavigationStack {
            Form {
                if context.isCreating {
                    Section {
                        TextField("账户昵称", text: $nickname)
                            .textInputAutocapitalization(.words)
                            .autocorrectionDisabled()
                    } header: {
                        Text("账户昵称")
                    } footer: {
                        Text("用于区分多个 Moomoo 账户，创建后仍可在账户详情中修改。")
                    }
                }

                Section {
                    Label(
                        isConnected ? "已授权 Moomoo" : "尚未连接",
                        systemImage: isConnected ? "checkmark.shield.fill" : "person.crop.circle.badge.questionmark"
                    )
                    .foregroundStyle(isConnected ? CatfolioTheme.positive : .secondary)

                    Text("通过系统浏览器完成 OAuth 2.1 + PKCE 授权。无需 OpenD，也不需要输入 API Key。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Text("授权页只需允许 trade:read，用于读取账户、持仓与历史成交。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Label("Access Token 与 Refresh Token 仅保存在此 iPhone Keychain。", systemImage: "lock.shield")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Moomoo OAuth")
                }

                Section("连接") {
                    if isConnected {
                        Button {
                            Task { await connect() }
                        } label: {
                            Label("重新授权 Moomoo", systemImage: "person.badge.key")
                        }
                        .disabled(isWorking)

                        if let snapshot {
                            Button {
                                Task { await preview() }
                            } label: {
                                Label("重新读取持仓", systemImage: "arrow.clockwise")
                            }
                            .disabled(isWorking)

                            GlassPrimaryButton(
                                title: isWorking
                                    ? (context.isCreating ? "正在创建" : "正在同步")
                                    : (context.isCreating ? "创建 Moomoo 账户" : "同步 \(snapshot.positions.count) 项到 Catfolio"),
                                systemImage: "tray.and.arrow.down.fill",
                                isDisabled: !hasValidNickname,
                                isBusy: isWorking
                            ) {
                                showsSyncConfirmation = true
                            }
                        } else {
                            GlassPrimaryButton(
                                title: isWorking ? "正在读取" : "读取并预览持仓",
                                systemImage: "arrow.down.circle",
                                isBusy: isWorking
                            ) {
                                Task { await preview() }
                            }
                        }
                    } else {
                        GlassPrimaryButton(
                            title: isWorking ? "正在连接" : "登录 Moomoo",
                            systemImage: "person.badge.key",
                            isBusy: isWorking
                        ) {
                            Task { await connect() }
                        }
                    }

                    statusView

                    Link(destination: URL(string: "https://open.moomoo.com/zh-cn/api/overview/getting-started")!) {
                        Label("查看 Moomoo OpenAPI 说明", systemImage: "arrow.up.right.square")
                    }
                }

                if let snapshot {
                    Section {
                        LabeledContent("授权账户", value: "\(snapshot.accounts.count) 个")
                        LabeledContent("持仓", value: "\(snapshot.positions.count) 项")
                        LabeledContent("历史成交", value: "\(snapshot.fills.count) 笔")

                        ForEach(snapshot.positions.prefix(10)) { position in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(position.code)
                                        .font(.body.weight(.semibold))
                                    Text(position.stockName)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(DisplayFormat.shares(position.quantityValue))
                                        .appNumber(.subheading)
                                    if let marketValue = position.marketValueValue {
                                        Text(DisplayFormat.money(marketValue, currency: position.currency))
                                            .appNumber(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    } header: {
                        Text("账户预览")
                    } footer: {
                        let preview = snapshot.positions.count > 10
                            ? "仅预览前 10 项；同步会处理全部账户。"
                            : "已读取全部授权账户。"
                        let warning = snapshot.historyWarnings.isEmpty
                            ? ""
                            : " \(snapshot.historyWarnings.joined(separator: "；"))"
                        Text(preview + warning)
                    }
                }

                if isConnected && !context.isCreating {
                    Section {
                        Button("断开 Moomoo", role: .destructive) {
                            showsDisconnectConfirmation = true
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(CatfolioTheme.pageBackground(for: colorScheme))
            .navigationTitle(context.isCreating ? "新建 Moomoo 账户" : "Moomoo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("完成") { dismiss() }
                }
            }
            .task { prepareNickname() }
            .confirmationDialog(
                "断开 Moomoo？",
                isPresented: $showsDisconnectConfirmation,
                titleVisibility: .visible
            ) {
                Button("断开", role: .destructive) { disconnect() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("将删除此 iPhone Keychain 中的 Moomoo Access Token 与 Refresh Token。")
            }
            .confirmationDialog(
                context.isCreating ? "创建 Moomoo 账户？" : "更新 Moomoo 账户？",
                isPresented: $showsSyncConfirmation,
                titleVisibility: .visible
            ) {
                Button(context.isCreating ? "创建账户" : "同步并更新") {
                    Task { await sync() }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text(context.isCreating
                    ? "将使用预览中的数据创建新账户；现有账户不受影响。"
                    : "将更新当前 Moomoo 账户持仓；其他账户不受影响。")
            }
            .fullScreenCover(item: $authorizationSession.authorizationPage) { page in
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
            .font(.footnote)
            .foregroundStyle(.secondary)
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
        status = .working("正在打开 Moomoo 授权页…")
        defer { isWorking = false }
        do {
            let tokenSet = try await authorizationSession.authorize(accountID: context.account?.accountID)
            isConnected = true
            status = .success(tokenSet.scope.contains("trade:read") ? "授权成功" : "授权成功；请确认已授予 trade:read")
        } catch {
            status = .failure(error.localizedDescription)
        }
    }

    private func preview() async {
        isWorking = true
        status = .working("正在读取全部授权账户…")
        defer { isWorking = false }
        do {
            let fetched = try await MoomooOpenAPIClient(
                credentialAccountID: context.account?.accountID
            ).fetchSnapshot(
                reportingCurrency: DisplayCurrency.current.rawValue
            )
            let result = snapshotForContext(fetched)
            guard !result.positions.isEmpty else {
                status = .failure(context.isCreating
                    ? "当前授权中没有可新建的 Moomoo 账户。"
                    : "当前账户没有可导入持仓。")
                return
            }
            try persistCredentials(for: result.accounts.map(\.accountID))
            snapshot = result
            status = .success("读取成功：\(result.accounts.count) 个账户，\(result.positions.count) 项持仓")
        } catch {
            status = .failure(error.localizedDescription)
        }
    }

    private func sync() async {
        isWorking = true
        status = .working("正在读取并转换 Moomoo 持仓…")
        defer { isWorking = false }
        do {
            let fetched = try await MoomooOpenAPIClient(
                credentialAccountID: context.account?.accountID
            ).fetchSnapshot(
                reportingCurrency: DisplayCurrency.current.rawValue
            )
            let currentSnapshot = snapshotForContext(fetched)
            guard !currentSnapshot.positions.isEmpty else {
                status = .failure(context.isCreating
                    ? "当前授权中没有可新建的 Moomoo 账户。"
                    : "当前账户没有可导入持仓。")
                return
            }
            try persistCredentials(for: currentSnapshot.accounts.map(\.accountID))
            snapshot = currentSnapshot
            status = .working("Moomoo 已读取，正在保存到本机…")
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
            let warningText = result.warnings.isEmpty ? "" : "，\(result.warnings.count) 条提示"
            status = .success(context.isCreating
                ? "已创建账户，导入 \(result.holdingsCount) 个持仓\(warningText)"
                : "已同步 \(result.holdingsCount) 个持仓\(warningText)")
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
    case working(String)
    case success(String)
    case failure(String)
}
