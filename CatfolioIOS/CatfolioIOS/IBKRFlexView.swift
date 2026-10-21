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
    @Environment(\.dismiss) private var dismissPage
    @Environment(\.accountFlowClose) private var accountFlowClose
    @Environment(AppModel.self) private var model

    let context: AccountConnectorContext
    private let isFirstLaunchSetup: Bool
    private let credentialValues: () -> [String: String]

    @State private var showsSetupGuide = false
    @State private var guideStep = 0
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
    @State private var hasPrepared = false

    // Credentials are normally keyed by account ID, but that ID only arrives
    // with the first successful report — which IBKR can take minutes to
    // generate. Without somewhere to park them, everything typed is lost the
    // moment the sheet is dismissed.
    /// The IBKR account ID is only known once a report arrives, so the
    /// placeholder carries a fixed key until the first sync replaces it.
    private static let pendingAccountID = IBKRFlexKeys.pendingAccountID
    private static let pendingTokenKey = IBKRFlexKeys.pendingToken
    private static let pendingQueryIDKey = IBKRFlexKeys.pendingQueryID
    private static let legacyTokenKey = "ibkr.flex.token"
    private static let legacyQueryIDKey = "ibkr.flex.query-id"

    init(context: AccountConnectorContext = .create, isFirstLaunchSetup: Bool = false,
         credentialValues: @escaping () -> [String: String] = BrokerCredentialPrefill.storedValues) {
        self.context = context
        self.isFirstLaunchSetup = isFirstLaunchSetup
        self.credentialValues = credentialValues
        _guideStep = State(initialValue: isFirstLaunchSetup ? 1 : 0)
    }

    private static func tokenKey(accountID: String) -> String {
        IBKRFlexKeys.token(accountID: accountID)
    }

    private static func queryIDKey(accountID: String) -> String {
        IBKRFlexKeys.queryID(accountID: accountID)
    }

    /// The placeholder made by "保存并创建账户", still waiting for its first
    /// report. It has no IBKR account ID yet, so its credentials are the
    /// parked ones.
    private var isPendingAccount: Bool {
        context.account?.id == Self.pendingAccountID
    }

    /// Inside 添加账户 this closes the whole flow; on its own, the page.
    private func dismiss() {
        if let accountFlowClose { accountFlowClose() } else { dismissPage() }
    }

    var body: some View {
        AccountFlowStack {
            OnboardingPage(scrollReset: guideStep,
                           progress: context.isCreating ? OnboardingProgress(
                            step: isFirstLaunchSetup ? 3 : guideStep + 1, total: isFirstLaunchSetup ? 3 : 2) : nil) {
                if context.isCreating && guideStep < 1 {
                    IBKRSetupIntro { showsSetupGuide = true }
                } else {
                    VStack(alignment: .leading, spacing: 16) { connectionContent }
                }
            } actions: { flowActions }
            // Past the first step the guide's own 上一步 is the back button.
            .navigationBarBackButtonHidden(context.isCreating && !isFirstLaunchSetup && guideStep > 0 && snapshot == nil)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if context.isCreating && !isFirstLaunchSetup && guideStep > 0 && snapshot == nil {
                    ToolbarItem(placement: .cancellationAction) {
                        Button {
                            guideStep -= 1
                        } label: {
                            Label(L10n.text("上一步"), systemImage: "chevron.left")
                        }
                        .disabled(isWorking)
                    }
                } else if context.isCreating && snapshot == nil {
                    ToolbarItem(placement: .cancellationAction) {
                        AccountProviderBackButton().disabled(isWorking)
                    }
                }

                if !context.isCreating {
                    ToolbarItem(placement: .confirmationAction) {
                        AppModalDoneButton { dismiss() }
                    }
                }
            }
            .appSheet(isPresented: $showsSetupGuide) {
                IBKRGuideHelpView()
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
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
                Text(L10n.text("将删除 Token 和 Query ID；开启或重新开启密钥同步后，删除也会同步到其他设备。"))
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
        .tint(CatfolioTheme.primaryText)
    }

    @ViewBuilder
    private var flowActions: some View {
        if context.isCreating && guideStep < 1 {
            OnboardingPrimaryButton(title: L10n.text("填写 Token 和 Query ID")) { guideStep = 1 }
        } else if let snapshot {
            OnboardingPrimaryButton(
                title: isWorking
                    ? (context.isCreating ? L10n.text("正在创建") : L10n.text("正在同步"))
                    : (context.isCreating ? L10n.text("创建 IBKR 账户") : L10n.text("同步 \(snapshot.positions.count) 项到 Catfolio")),
                isDisabled: !hasValidNickname,
                isBusy: isWorking
            ) {
                showsSyncConfirmation = true
            }
        } else {
            OnboardingPrimaryButton(
                title: context.isCreating ? L10n.text("保存并创建账户") : L10n.text("保存凭证"),
                isDisabled: !hasCompleteCredentials || !hasValidNickname,
                isBusy: isWorking
            ) {
                Task { await saveAndClose() }
            }
            Button(isWorking ? L10n.text("正在读取") : L10n.text("现在就读取持仓")) {
                Task { await testFlex() }
            }
            .appText(.callout, weight: .medium)
            .disabled(isWorking || !hasCompleteCredentials)
        }
    }

    private func settingsLink(_ title: String, url: String) -> some View {
        Link(destination: URL(string: url)!) {
            SettingsRowContainer {
                SettingsRowLabel(icon: .symbol("arrow.up.right.square"), title: title)
            }
        }
        .buttonStyle(SettingsRowButtonStyle())
    }

    @ViewBuilder
    private var connectionContent: some View {
        IBKRConnectionIntro()
        if context.isCreating, snapshot != nil {
            SettingsSectionHeader(L10n.text("账户昵称"))
            SettingsCard {
                AccountNicknameField(nickname: $nickname, edited: $nicknameEdited)
                    .disabled(isWorking)
            }
        }

        SettingsSectionHeader(L10n.text("Flex 凭证"))
        SettingsCard {
            SettingsFieldRow("Flex Token", text: $token, isSecure: true, isMonospaced: true)
                .privacySensitive()
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            SettingsFieldRow("Query ID", text: $queryID, isMonospaced: true)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.numberPad)

            SettingsRowContainer {
                Text(L10n.text("保存在钥匙串；可在设置中开启跨设备密钥同步。"))
                    .appText(.label, weight: .regular)
                    .foregroundStyle(SettingsTemplate.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }


        if status.isPresented { statusView }
        if snapshot != nil {
            Button(L10n.text("重新读取持仓")) { Task { await testFlex() } }
                .appText(.callout).disabled(isWorking)
        }
        DisclosureGroup(L10n.text("需要帮助？")) {
            Button(L10n.text("查看详细教程")) { showsSetupGuide = true }
                .appText(.callout).padding(.vertical, 12)
                .accessibilityIdentifier("ibkr-open-setup-guide")
            SettingsFootnote(L10n.text("Query ID 在 Flex Queries 列表的查询名称旁。持仓超过一年时，请将 Period 扩至最早建仓日。"))
            SettingsButtonRow(
                icon: .symbol(didCopyBrief ? "checkmark.circle" : "doc.on.doc"),
                title: didCopyBrief ? L10n.text("已复制，去 IBKR 粘贴给它的助手") : L10n.text("复制配置提示词"),
                showsChevron: false,
                tint: didCopyBrief ? CatfolioTheme.positive : nil
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
        .appText(.callout)

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
                                FinancialText(DisplayFormat.shares(position.quantity))
                                    .appNumber(.subheading)
                                if let marketValue = position.marketValue {
                                    FinancialText(DisplayFormat.money(marketValue, currency: position.currency))
                                        .appNumber(.label, weight: .regular, monospaced: false)
                                        .foregroundStyle(SettingsTemplate.secondaryText)
                                }
                            }
                        }
                    }
                }
            }
            if snapshot.positions.count > 10 {
                SettingsFootnote(L10n.text("仅显示前 10 项；同步处理全部可导入股票持仓。"))
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

    private func prepareAccount() {
        guard !hasPrepared else { return }
        hasPrepared = true
        let stored = credentialValues()
        if isPendingAccount {
            nickname = context.account.map { AccountNaming.nickname(from: $0.displayName, provider: "IBKR") } ?? ""
            token = stored[Self.pendingTokenKey] ?? ""
            queryID = stored[Self.pendingQueryIDKey] ?? ""
            if let phase = IBKRFirstSync.shared.phase { status = Self.status(for: phase) }
        } else if let account = context.account {
            nickname = AccountNaming.nickname(from: account.displayName, provider: "IBKR")
            if let accountID = account.accountID,
               let savedToken = stored[Self.tokenKey(accountID: accountID)],
               let savedQueryID = stored[Self.queryIDKey(accountID: accountID)] {
                token = savedToken
                queryID = savedQueryID
            } else {
                token = stored[Self.legacyTokenKey] ?? ""
                queryID = stored[Self.legacyQueryIDKey] ?? ""
                usesLegacyCredentials = !token.isEmpty || !queryID.isEmpty
            }
        } else {
            nickname = model.suggestedAccountNickname()
            token = stored[Self.pendingTokenKey] ?? ""
            queryID = stored[Self.pendingQueryIDKey] ?? ""
            if let credentials = BrokerCredentialPrefill.ibkr(pendingToken: token, pendingQueryID: queryID, values: stored) {
                token = credentials.token
                queryID = credentials.queryID
            }
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
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try IBKRFlexKeys.save(try credentials(),
                                 accountID: isPendingAccount ? nil : context.account?.accountID)
        } catch {
            status = .failure(L10n.text("无法保存凭证：\(error.localizedDescription)"))
            return
        }
        if context.account?.accountID != nil && !isPendingAccount {
            // An account that has synced before keeps its credentials under
            // its own ID, not in the placeholder's slot.
            status = .success(L10n.text("凭证已保存。"))
            dismiss()
            return
        }
        guard context.isCreating else {
            // The placeholder, reopened: fetch its first report again with
            // what was just saved.
            IBKRFirstSync.shared.cancel()
            IBKRFirstSync.shared.startIfNeeded(model: model)
            dismiss()
            return
        }
        do {
            try await model.registerPendingAccount(
                id: Self.pendingAccountID,
                source: "IBKR Flex",
                name: nickname.trimmingCharacters(in: .whitespacesAndNewlines),
                baseCurrency: "USD"
            )
            // The report is fetched in the background from here, so the new
            // account shows it is being read rather than sitting silent.
            IBKRFirstSync.shared.startIfNeeded(model: model)
            dismiss()
        } catch {
            status = .failure(L10n.text("无法创建账户：\(error.localizedDescription)"))
        }
    }

    private func credentials() throws -> IBKRFlexCredentials {
        try IBKRFlexCredentials(token: token, queryID: queryID)
    }

    private func saveCredentials(_ credentials: IBKRFlexCredentials, accountIDs: Set<String>) throws {
        for accountID in accountIDs where !accountID.isEmpty {
            try IBKRFlexKeys.save(credentials, accountID: accountID)
        }
        usesLegacyCredentials = false
        try? KeychainStore.set("", for: Self.pendingTokenKey)
        try? KeychainStore.set("", for: Self.pendingQueryIDKey)
        // The real accounts have arrived under their own IBKR IDs, so the
        // placeholder that stood in for them has nothing left to represent.
        Task { try? await model.deleteAccount(Self.pendingAccountID) }
    }

    private func testFlex() async {
        if context.isCreating || isPendingAccount { IBKRFirstSync.shared.cancel() }
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
        if context.isCreating || isPendingAccount { IBKRFirstSync.shared.cancel() }
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

    private static func status(for phase: IBKRFirstSync.Phase) -> FlexViewStatus {
        switch phase {
        case let .waiting(seconds):
            return .working(L10n.text("IBKR 正在生成报表… 已等待 \(seconds) 秒"))
        case .importing:
            return .working(L10n.text("Flex 已读取，正在保存到本机…"))
        case let .failed(message):
            return .failure(message)
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
        } else if context.isCreating || isPendingAccount {
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
