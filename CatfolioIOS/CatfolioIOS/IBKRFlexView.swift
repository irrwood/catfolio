import SwiftUI

struct IBKRFlexView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme

    let context: AccountConnectorContext

    @State private var token = ""
    @State private var queryID = ""
    @State private var snapshot: IBKRFlexSnapshot?
    @State private var snapshotCredentials: IBKRFlexCredentials?
    @State private var status: FlexViewStatus = .idle
    @State private var isWorking = false
    @State private var showsClearConfirmation = false
    @State private var showsSyncConfirmation = false
    @State private var nickname = ""
    @State private var usesLegacyCredentials = false

    private static let legacyTokenKey = "ibkr.flex.token"
    private static let legacyQueryIDKey = "ibkr.flex.query-id"

    init(context: AccountConnectorContext = .create) {
        self.context = context
    }

    private static func tokenKey(accountID: String) -> String {
        "ibkr.flex.account.\(accountID).token"
    }

    private static func queryIDKey(accountID: String) -> String {
        "ibkr.flex.account.\(accountID).query-id"
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
                        Text("用于区分多个 Interactive Brokers 账户，创建后仍可在账户详情中修改。")
                    }
                }

                Section {
                    SecureField("Flex Token", text: $token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())

                    TextField("Query ID", text: $queryID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.numberPad)
                        .font(.body.monospaced())

                    Label("凭证仅存于此 iPhone Keychain，不会发送到 Catfolio 服务端。", systemImage: "lock.shield")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Flex 凭证")
                } footer: {
                    Text("Flex Query 输出请选择 XML，并加入 Account Information → Base Currency、Open Positions → Summary，以及 Trades → Executions、Trade ID、Buy/Sell、Quantity、Trade Price、Trade Date、Currency、FX Rate to Base。成交时间范围需覆盖当前持仓的建仓记录。")
                }

                Section("连接") {
                    if let snapshot {
                        Button {
                            Task { await testFlex() }
                        } label: {
                            Label("重新读取持仓", systemImage: "arrow.clockwise")
                        }
                        .disabled(isWorking)

                        GlassPrimaryButton(
                            title: isWorking
                                ? (context.isCreating ? "正在创建" : "正在同步")
                                : (context.isCreating ? "创建 IBKR 账户" : "同步 \(snapshot.positions.count) 项到 Catfolio"),
                            systemImage: "tray.and.arrow.down.fill",
                            isDisabled: isWorking || !hasValidNickname
                        ) {
                            showsSyncConfirmation = true
                        }
                    } else {
                        GlassPrimaryButton(
                            title: isWorking ? "正在读取" : "读取并预览持仓",
                            systemImage: "arrow.down.circle",
                            isDisabled: isWorking
                        ) {
                            Task { await testFlex() }
                        }
                    }

                    statusView

                    Link(destination: URL(string: "https://www.ibkrguides.com/advisorportal/ug/flex-web-service.htm")!) {
                        Label("查看 IBKR Flex 配置说明", systemImage: "arrow.up.right.square")
                    }
                }

                if let snapshot {
                    Section {
                        LabeledContent("报表日期", value: snapshot.reportDate ?? "最新")
                        LabeledContent("Open Positions", value: "\(snapshot.positions.count) 项")
                        LabeledContent("成交明细", value: "\(snapshot.transactions.count) 笔")

                        ForEach(snapshot.positions.prefix(10)) { position in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(position.symbol)
                                        .font(.body.weight(.semibold))
                                    Text(position.name)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(DisplayFormat.shares(position.quantity))
                                        .font(.body.monospacedDigit())
                                    if let marketValue = position.marketValue {
                                        Text(DisplayFormat.money(marketValue, currency: position.currency))
                                            .font(.caption.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    } header: {
                        Text("Flex 预览")
                    } footer: {
                        if snapshot.positions.count > 10 {
                            Text("仅预览前 10 项；同步会处理全部可导入股票持仓。")
                        }
                    }
                }

                if (!token.isEmpty || !queryID.isEmpty) && !context.isCreating {
                    Section {
                        Button("移除本机 Flex 凭证", role: .destructive) {
                            showsClearConfirmation = true
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(CatfolioTheme.pageBackground(for: colorScheme))
            .navigationTitle(context.isCreating ? "新建 IBKR 账户" : "IBKR Flex")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("完成") { dismiss() }
                }
            }
            .task { prepareAccount() }
            .onChange(of: token) { _, _ in invalidatePreview() }
            .onChange(of: queryID) { _, _ in invalidatePreview() }
            .confirmationDialog(
                "移除 Flex 凭证？",
                isPresented: $showsClearConfirmation,
                titleVisibility: .visible
            ) {
                Button("移除", role: .destructive) { clearCredentials() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("只会删除此 iPhone Keychain 中的 Token 和 Query ID。")
            }
            .confirmationDialog(
                context.isCreating ? "创建 IBKR 账户？" : "更新 IBKR 账户？",
                isPresented: $showsSyncConfirmation,
                titleVisibility: .visible
            ) {
                Button(context.isCreating ? "创建账户" : "同步并更新") {
                    Task { await syncFlex() }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text(context.isCreating
                    ? "将使用预览中的数据创建新账户；现有账户不受影响。"
                    : "将更新当前 IBKR 账户持仓；其他账户不受影响。")
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

    private func prepareAccount() {
        if let account = context.account {
            nickname = AccountNaming.nickname(from: account.displayName, provider: "IBKR")
            if let accountID = account.accountID,
               let savedToken = KeychainStore.string(for: Self.tokenKey(accountID: accountID)),
               let savedQueryID = KeychainStore.string(for: Self.queryIDKey(accountID: accountID)) {
                token = savedToken
                queryID = savedQueryID
            } else {
                token = KeychainStore.string(for: Self.legacyTokenKey) ?? ""
                queryID = KeychainStore.string(for: Self.legacyQueryIDKey) ?? ""
                usesLegacyCredentials = !token.isEmpty || !queryID.isEmpty
            }
        } else {
            nickname = model.suggestedAccountNickname()
        }
    }

    private func credentials() throws -> IBKRFlexCredentials {
        try IBKRFlexCredentials(token: token, queryID: queryID)
    }

    private func saveCredentials(_ credentials: IBKRFlexCredentials, accountIDs: Set<String>) throws {
        for accountID in accountIDs where !accountID.isEmpty {
            try KeychainStore.set(credentials.token, for: Self.tokenKey(accountID: accountID))
            try KeychainStore.set(credentials.queryID, for: Self.queryIDKey(accountID: accountID))
        }
        usesLegacyCredentials = false
    }

    private func testFlex() async {
        isWorking = true
        status = .working("正在请求 IBKR Flex 报表…")
        defer { isWorking = false }
        do {
            let credentials = try credentials()
            let fetched = try await IBKRFlexClient().fetchOpenPositions(credentials: credentials)
            let result = snapshotForContext(fetched)
            guard !result.positions.isEmpty else {
                status = .failure(context.isCreating
                    ? "Flex 报表中没有可新建的 IBKR 账户。"
                    : "当前账户没有可导入持仓。")
                return
            }
            if context.isCreating,
               AccountNaming.generatedNicknames.contains(nickname),
               let detectedName = result.accountNames.values.sorted().first {
                nickname = model.suggestedAccountNickname(detectedName: detectedName)
            }
            try saveCredentials(credentials, accountIDs: resultAccountIDs(result))
            snapshot = result
            snapshotCredentials = credentials
            status = .success("Flex 连接成功，读取 \(result.positions.count) 项持仓")
        } catch {
            status = .failure(error.localizedDescription)
        }
    }

    private func syncFlex() async {
        isWorking = true
        status = .working("正在读取并转换 Flex 持仓…")
        defer { isWorking = false }
        do {
            let credentials = try credentials()
            let currentSnapshot: IBKRFlexSnapshot
            if let snapshot, snapshotCredentials == credentials {
                currentSnapshot = snapshot
            } else {
                let fetched = try await IBKRFlexClient().fetchOpenPositions(credentials: credentials)
                currentSnapshot = snapshotForContext(fetched)
                snapshot = currentSnapshot
                snapshotCredentials = credentials
            }
            guard !currentSnapshot.positions.isEmpty else {
                status = .failure(context.isCreating
                    ? "Flex 报表中没有可新建的 IBKR 账户。"
                    : "当前账户没有可导入持仓。")
                return
            }
            try saveCredentials(credentials, accountIDs: resultAccountIDs(currentSnapshot))
            status = .working("Flex 已读取，正在保存到本机…")
            let accountIDs = resultAccountIDs(currentSnapshot).sorted()
            let accountNames = model.accountNames(
                source: "IBKR Flex",
                accountIDs: accountIDs,
                preferredNickname: nickname,
                targetAccountID: context.account?.accountID
            )
            let result = try await model.importIBKR(
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

    private func invalidatePreview() {
        guard !isWorking else { return }
        snapshot = nil
        snapshotCredentials = nil
        status = .idle
    }

    private func clearCredentials() {
        if let accountID = context.account?.accountID {
            try? KeychainStore.set("", for: Self.tokenKey(accountID: accountID))
            try? KeychainStore.set("", for: Self.queryIDKey(accountID: accountID))
        }
        if usesLegacyCredentials {
            try? KeychainStore.set("", for: Self.legacyTokenKey)
            try? KeychainStore.set("", for: Self.legacyQueryIDKey)
        }
        token = ""
        queryID = ""
        snapshot = nil
        snapshotCredentials = nil
        status = .idle
    }

    private func resultAccountIDs(_ snapshot: IBKRFlexSnapshot) -> Set<String> {
        Set(snapshot.positions.map(\.accountID))
            .union(snapshot.transactions.map(\.accountID))
    }

    private func snapshotForContext(_ snapshot: IBKRFlexSnapshot) -> IBKRFlexSnapshot {
        let availableIDs = Set(snapshot.positions.map(\.accountID))
            .union(snapshot.transactions.map(\.accountID))
        let allowedIDs: Set<String>
        if let accountID = context.account?.accountID {
            allowedIDs = [accountID]
        } else if context.isCreating {
            let existingIDs = Set(model.accounts
                .filter { $0.source == "IBKR Flex" }
                .compactMap(\.accountID))
            allowedIDs = availableIDs.subtracting(existingIDs)
        } else {
            return snapshot
        }
        return IBKRFlexSnapshot(
            positions: snapshot.positions.filter { allowedIDs.contains($0.accountID) },
            transactions: snapshot.transactions.filter { allowedIDs.contains($0.accountID) },
            accountCurrencies: snapshot.accountCurrencies.filter { allowedIDs.contains($0.key) },
            accountNames: snapshot.accountNames.filter { allowedIDs.contains($0.key) },
            reportDate: snapshot.reportDate
        )
    }
}

private enum FlexViewStatus {
    case idle
    case working(String)
    case success(String)
    case failure(String)
}
