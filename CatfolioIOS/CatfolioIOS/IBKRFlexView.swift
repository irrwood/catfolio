import SwiftUI
import UIKit

/// A ready-made brief for IBKR's own configuration assistant.
///
/// Phrased as a description of the data wanted, not as a list of UI settings:
/// the assistant rejects a configuration spec ("please describe the specific
/// account data you need"). The three constraints that silently break the sync
/// are therefore carried as properties of the data — every individual
/// execution, position totals rather than lots, XML — rather than as switches
/// to flip.
enum IBKRFlexQueryBrief {
    static let prompt = """
    I need an Activity Flex Query covering four kinds of account data:

    - My trades: every individual execution, including the FX rate to my base     currency and the realized P/L on each one.
    - My open positions: one row per position at summary level, not broken     down into individual tax lots.
    - My account information, including the account's base currency.
    - My cash transactions, so I can see dividends and interest.

    Please deliver it as XML rather than CSV, covering the last 365 days, and     include all available fields in each of those four areas.

    When it is created, please tell me the Query ID.
    """
}

struct IBKRFlexView: View {
    @Environment(\.locale) private var appLocale
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model

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
    @State private var nicknameEdited = false
    @State private var usesLegacyCredentials = false
    @State private var didCopyBrief = false

    // Credentials are normally keyed by account ID, but that ID only arrives
    // with the first successful report — which IBKR can take minutes to
    // generate. Without somewhere to park them, everything typed is lost the
    // moment the sheet is dismissed.
    /// The IBKR account ID is only known once a report arrives, so the
    /// placeholder carries a fixed key until the first sync replaces it.
    private static let pendingAccountID = "ibkr-flex-pending"
    private static let pendingTokenKey = "ibkr.flex.pending.token"
    private static let pendingQueryIDKey = "ibkr.flex.pending.query-id"
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
            SettingsPage(bottomInset: 32) {
                if context.isCreating, snapshot != nil {
                    SettingsSectionHeader(L10n.text("账户昵称"))
                    SettingsCard {
                        AccountNicknameField(nickname: $nickname, edited: $nicknameEdited)
                            .disabled(isWorking)
                    }
                    SettingsFootnote(L10n.text("用于区分多个 Interactive Brokers 账户，创建后仍可在账户详情中修改。"))
                }

                SettingsSectionHeader(L10n.text("Flex 凭证"))
                SettingsCard {
                    SettingsFieldRow("Flex Token", text: $token, isSecure: true, isMonospaced: true)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    SettingsFieldRow("Query ID", text: $queryID, isMonospaced: true)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.numberPad)

                    SettingsRowContainer {
                        Text(L10n.text("凭证仅存于此 iPhone Keychain，不会发送到 Catfolio 服务端。"))
                            .appText(.label, weight: .regular)
                            .foregroundStyle(SettingsTemplate.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                // The two credentials come from different halves of the same
                // screen, and IBKR's own instructions for creating a query
                // never mention the ID — it only appears in the list
                // afterwards. Saying so here saves a hunt.
                SettingsFootnote([
                    L10n.text("两个凭证都在 Client Portal → Performance & Reports → Flex Queries 这一页。"),
                    L10n.text("Token：该页 Flex Web Service Configuration 区域 → 齿轮图标 → 启用后点 Generate A New Token。"),
                    L10n.text("Query ID：建好查询后回到列表，数字在查询名称旁；创建向导里不显示。"),
                    L10n.text("查询怎么配，用下面的「复制配置提示词」交给 IBKR 的助手即可。持仓超过一年的话，把 Period 改到覆盖最早的建仓日。"),
                ])

                SettingsSectionHeader(L10n.text("连接"))
                SettingsCard {
                    if let snapshot {
                        SettingsButtonRow(
                            icon: .symbol("arrow.clockwise"),
                            title: L10n.text("重新读取持仓"),
                            showsChevron: false
                        ) {
                            Task { await testFlex() }
                        }
                        .disabled(isWorking)

                        SettingsRowContainer {
                            GlassPrimaryButton(
                                title: isWorking
                                    ? (context.isCreating ? L10n.text("正在创建") : L10n.text("正在同步"))
                                    : (context.isCreating ? L10n.text("创建 IBKR 账户") : L10n.text("同步 \(snapshot.positions.count) 项到 Catfolio")),
                                systemImage: "tray.and.arrow.down.fill",
                                isDisabled: !hasValidNickname,
                                isBusy: isWorking
                            ) {
                                showsSyncConfirmation = true
                            }
                        }
                    } else {
                        // Saving no longer waits on a report IBKR may take
                        // minutes to build. The account is created now and
                        // shows as awaiting its first sync; the credentials
                        // can be revisited by opening it again.
                        SettingsRowContainer {
                            GlassPrimaryButton(
                                title: context.isCreating ? L10n.text("保存并创建账户") : L10n.text("保存凭证"),
                                systemImage: "tray.and.arrow.down.fill",
                                isDisabled: !hasCompleteCredentials || !hasValidNickname,
                                isBusy: isWorking
                            ) {
                                Task { await saveAndClose() }
                            }
                        }

                        SettingsButtonRow(
                            icon: .symbol("arrow.down.circle"),
                            title: isWorking ? L10n.text("正在读取") : L10n.text("现在就读取持仓"),
                            showsChevron: false
                        ) {
                            Task { await testFlex() }
                        }
                        .disabled(isWorking || !hasCompleteCredentials)
                    }

                    if status.isPresented {
                        SettingsRowContainer { statusView }
                    }

                    SettingsButtonRow(
                        icon: .symbol(didCopyBrief ? "checkmark.circle" : "doc.on.doc"),
                        title: didCopyBrief ? L10n.text("已复制，去 IBKR 粘贴给它的助手") : L10n.text("复制配置提示词"),
                        showsChevron: false,
                        tint: didCopyBrief ? CatfolioTheme.positive : CatfolioTheme.accent
                    ) {
                        UIPasteboard.general.string = IBKRFlexQueryBrief.prompt
                        withAnimation { didCopyBrief = true }
                        Task {
                            try? await Task.sleep(for: .seconds(2))
                            withAnimation { didCopyBrief = false }
                        }
                    }

                    settingsLink(
                        L10n.text("如何创建 Activity Flex Query"),
                        url: "https://www.ibkrguides.com/clientportal/performanceandstatements/activityflex.htm"
                    )

                    settingsLink(
                        L10n.text("如何启用 Flex Web Service 并生成 Token"),
                        url: "https://www.ibkrguides.com/clientportal/performanceandstatements/flex-web-service.htm"
                    )
                }

                if let snapshot {
                    SettingsSectionHeader(L10n.text("Flex 预览"))
                    SettingsCard {
                        SettingsValueRow(title: L10n.text("报表日期"), value: snapshot.reportDate ?? L10n.text("最新"), valueIsNumeric: false)
                        SettingsValueRow(title: "Open Positions", value: L10n.text("\(snapshot.positions.count) 项"))
                        SettingsValueRow(title: L10n.text("成交明细"), value: L10n.text("\(snapshot.transactions.count) 笔"))

                        ForEach(snapshot.positions.prefix(10)) { position in
                            SettingsRowContainer {
                                HStack {
                                    VStack(alignment: .leading, spacing: SettingsTemplate.subtitleSpacing) {
                                        Text(position.symbol)
                                            .appText(.subheading, weight: .semibold)
                                        Text(position.name)
                                            .appText(.label, weight: .regular)
                                            .foregroundStyle(SettingsTemplate.secondaryText)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    VStack(alignment: .trailing, spacing: SettingsTemplate.subtitleSpacing) {
                                        Text(DisplayFormat.shares(position.quantity))
                                            .appNumber(.subheading)
                                        if let marketValue = position.marketValue {
                                            Text(DisplayFormat.money(marketValue, currency: position.currency))
                                                .appNumber(.label, weight: .regular, monospaced: false)
                                                .foregroundStyle(SettingsTemplate.secondaryText)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    if snapshot.positions.count > 10 {
                        SettingsFootnote(L10n.text("仅预览前 10 项；同步会处理全部可导入股票持仓。"))
                    }
                }

                if (!token.isEmpty || !queryID.isEmpty) && !context.isCreating {
                    SettingsCard {
                        SettingsButtonRow(
                            icon: .symbol("trash"),
                            title: L10n.text("移除本机 Flex 凭证"),
                            showsChevron: false,
                            role: .destructive
                        ) {
                            showsClearConfirmation = true
                        }
                    }
                }
            }
            .softTopScrollEdge()
            .navigationTitle(context.isCreating ? L10n.text("新建 IBKR 账户") : "IBKR Flex")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.text("完成")) { dismiss() }
                }
            }
            .task { prepareAccount() }
            .onChange(of: token) { _, _ in invalidatePreview() }
            .onChange(of: queryID) { _, _ in invalidatePreview() }
            .confirmationDialog(
                L10n.text("移除 Flex 凭证？"),
                isPresented: $showsClearConfirmation,
                titleVisibility: .visible
            ) {
                Button(L10n.text("移除"), role: .destructive) { clearCredentials() }
                Button(L10n.text("取消"), role: .cancel) {}
            } message: {
                Text(L10n.text("只会删除此 iPhone Keychain 中的 Token 和 Query ID。"))
            }
            .confirmationDialog(
                context.isCreating ? L10n.text("创建 IBKR 账户？") : L10n.text("更新 IBKR 账户？"),
                isPresented: $showsSyncConfirmation,
                titleVisibility: .visible
            ) {
                Button(context.isCreating ? L10n.text("创建账户") : L10n.text("同步并更新")) {
                    Task { await syncFlex() }
                }
                Button(L10n.text("取消"), role: .cancel) {}
            } message: {
                Text(context.isCreating
                    ? L10n.text("将使用预览中的数据创建新账户；现有账户不受影响。")
                    : L10n.text("将更新当前 IBKR 账户持仓；其他账户不受影响。"))
            }
        }
        .tint(CatfolioTheme.accent)
    }

    /// A row that opens a web page. `Link` stays the control, so the row does
    /// not reimplement how a URL is handed to the system.
    private func settingsLink(_ title: String, url: String) -> some View {
        Link(destination: URL(string: url)!) {
            SettingsRowContainer {
                SettingsRowLabel(icon: .symbol("arrow.up.right.square"), title: title)
            }
        }
        .buttonStyle(SettingsRowButtonStyle())
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
            token = KeychainStore.string(for: Self.pendingTokenKey) ?? ""
            queryID = KeychainStore.string(for: Self.pendingQueryIDKey) ?? ""
        }
    }

    /// Parks the credentials so the report can finish generating in its own
    /// time. Nothing is synced yet; reopening this screen restores them.
    private var hasCompleteCredentials: Bool {
        !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !queryID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Stores the credentials and, when creating, puts the account on screen
    /// straight away rather than making the first report a precondition.
    private func saveAndClose() async {
        savePendingCredentials()
        guard context.isCreating else {
            status = .success(L10n.text("凭证已保存。"))
            dismiss()
            return
        }
        isWorking = true
        defer { isWorking = false }
        do {
            try await model.registerPendingAccount(
                id: Self.pendingAccountID,
                source: "IBKR Flex",
                name: nickname.trimmingCharacters(in: .whitespacesAndNewlines),
                baseCurrency: "USD"
            )
            dismiss()
        } catch {
            status = .failure(L10n.text("无法创建账户：\(error.localizedDescription)"))
        }
    }

    private func savePendingCredentials() {
        try? KeychainStore.set(token.trimmingCharacters(in: .whitespacesAndNewlines), for: Self.pendingTokenKey)
        try? KeychainStore.set(queryID.trimmingCharacters(in: .whitespacesAndNewlines), for: Self.pendingQueryIDKey)
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
        try? KeychainStore.set("", for: Self.pendingTokenKey)
        try? KeychainStore.set("", for: Self.pendingQueryIDKey)
        // The real accounts have arrived under their own IBKR IDs, so the
        // placeholder that stood in for them has nothing left to represent.
        Task { try? await model.deleteAccount(Self.pendingAccountID) }
    }

    private func testFlex() async {
        isWorking = true
        status = .working(L10n.text("正在请求 IBKR Flex 报表…"))
        defer { isWorking = false }
        do {
            let credentials = try credentials()
            let fetched = try await IBKRFlexClient().fetchOpenPositions(
                    credentials: credentials,
                    onProgress: { seconds in
                        Task { @MainActor in
                            status = .working(L10n.text("IBKR 正在生成报表… 已等待 \(seconds) 秒"))
                        }
                    }
                )
            let result = snapshotForContext(fetched)
            guard !result.syncedPositionAccountIDs.isEmpty else {
                status = .failure(context.isCreating
                    ? L10n.text("Flex 报表中没有可新建的 IBKR 账户。")
                    : L10n.text("返回数据未包含当前账户，请检查授权或报表范围。"))
                return
            }
            if context.isCreating,
               !nicknameEdited {
                nickname = model.suggestedAccountNickname(detectedName: result.accountNames.values.sorted().first ?? "IBKR")
            }
            try saveCredentials(credentials, accountIDs: resultAccountIDs(result))
            snapshot = result
            snapshotCredentials = credentials
            status = .success(L10n.text("Flex 连接成功，读取 \(result.positions.count) 项持仓"))
        } catch {
            status = .failure(error.localizedDescription)
        }
    }

    private func syncFlex() async {
        isWorking = true
        status = .working(L10n.text("正在读取并转换 Flex 持仓…"))
        defer { isWorking = false }
        do {
            let credentials = try credentials()
            let currentSnapshot: IBKRFlexSnapshot
            if let snapshot, snapshotCredentials == credentials {
                currentSnapshot = snapshot
            } else {
                let fetched = try await IBKRFlexClient().fetchOpenPositions(
                    credentials: credentials,
                    onProgress: { seconds in
                        Task { @MainActor in
                            status = .working(L10n.text("IBKR 正在生成报表… 已等待 \(seconds) 秒"))
                        }
                    }
                )
                currentSnapshot = snapshotForContext(fetched)
                snapshot = currentSnapshot
                snapshotCredentials = credentials
            }
            guard !currentSnapshot.syncedPositionAccountIDs.isEmpty else {
                status = .failure(context.isCreating
                    ? L10n.text("Flex 报表中没有可新建的 IBKR 账户。")
                    : L10n.text("返回数据未包含当前账户，请检查授权或报表范围。"))
                return
            }
            try saveCredentials(credentials, accountIDs: resultAccountIDs(currentSnapshot))
            status = .working(L10n.text("Flex 已读取，正在保存到本机…"))
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
            let warningText = result.warnings.isEmpty ? "" : L10n.text("，\(result.warnings.count) 条提示")
            status = .success(context.isCreating
                ? L10n.text("已创建账户，导入 \(result.holdingsCount) 个持仓\(warningText)")
                : L10n.text("已同步 \(result.holdingsCount) 个持仓\(warningText)"))
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
        snapshot.syncedPositionAccountIDs
            .union(snapshot.transactions.map(\.accountID))
    }

    private func snapshotForContext(_ snapshot: IBKRFlexSnapshot) -> IBKRFlexSnapshot {
        let availableIDs = snapshot.syncedPositionAccountIDs
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
            reportDate: snapshot.reportDate,
            positionAccountIDs: snapshot.positionAccountIDs.intersection(allowedIDs)
        )
    }
}

private enum FlexViewStatus {
    case idle

    /// Whether the connection card should give the status a row of its own.
    var isPresented: Bool {
        if case .idle = self { false } else { true }
    }
    case working(String)
    case success(String)
    case failure(String)
}
