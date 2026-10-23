import SwiftUI

struct SnapTradeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismissPage
    @Environment(\.accountFlowClose) private var accountFlowClose
    let context: AccountConnectorContext
    var isFirstLaunchSetup = false
    @State var setupNavigation = AccountSetupNavigation()
    @State private var clientID = ""
    @State private var consumerKey = ""
    @State private var accounts: [SnapTradeAccount] = []
    @State private var selectedID = ""
    @State private var preview: SnapTradeSnapshot?
    @State private var previewCredentials: SnapTradeCredentials?
    @State private var operation = SnapTradeOperation()
    @State private var status = ""
    @State private var confirmsSync = false
    @State private var confirmsRemoval = false
    @State private var hasPrepared = false

    private var busy: Bool { operation.isRunning }
    private var hasCredentials: Bool { !clientID.isEmpty && !consumerKey.isEmpty }
    private var allowedAccounts: [SnapTradeAccount] {
        accounts.filter { account in
            if let current = context.account { return account.id == current.accountID }
            return !model.accounts.contains { $0.source == "SnapTrade" && $0.accountID == account.id }
        }
    }

    /// Inside 添加账户 this closes the whole flow; on its own, the page.
    private func dismiss() {
        if let accountFlowClose { accountFlowClose() } else { dismissPage() }
    }

    var body: some View {
        AccountFlowStack { page(context.isCreating ? 1 : flowStep) }
            .accountFlowBrand(.snaptrade)
    }

    private func page(_ flowStep: Int) -> some View {
        let showsPreparation = context.isCreating && flowStep == 1
        let preview = !context.isCreating || flowStep == 4 ? self.preview : nil
        return AccountFlowPage(showsNext: Binding(
            get: { context.isCreating && self.flowStep > flowStep },
            set: { shown in
                guard !shown, self.flowStep > flowStep else { return }
                operation.cancel()
                while self.flowStep > flowStep { goBack() }
            })) {
            OnboardingPage(scrollReset: flowStep, isAccountPreparation: true) {
                AccountConnectionHeader(provider: .snaptrade, title: preview != nil ? L10n.text("确认持仓") : L10n.text("连接其他券商"),
                    subtitle: flowStep <= 2 ? L10n.text("填入个人 API 凭证，直接读取已关联的券商账户。")
                        : L10n.text("选择账户，预览后同步持仓。"))
                Group {
                    if showsPreparation {
                        BrokerPreparationInstructions(provider: .snaptrade)
                    } else {
                        if flowStep == 2 { credentialsForm }
                        if (!context.isCreating || flowStep == 3) && !allowedAccounts.isEmpty {
                            SettingsSection(L10n.text("选择账户")) {
                                ForEach(allowedAccounts) { account in
                                    SettingsButtonRow(icon: .symbol(selectedID == account.id ? "checkmark.circle.fill" : "circle"),
                                                      title: account.displayName, showsChevron: false) { selectedID = account.id }
                                }
                            }
                        }
                        if let preview {
                            SettingsSection(L10n.text("持仓预览")) {
                                SettingsValueRow(title: L10n.text("数据时间"), value: preview.asOf.formatted(date: .abbreviated, time: .shortened), valueIsNumeric: false)
                                SettingsValueRow(title: L10n.text("持仓"), value: String(preview.positions.count))
                                SettingsValueRow(title: L10n.text("交易记录"), value: String(preview.transactions.count))
                                ForEach(preview.positions.prefix(10), id: \.ticker) { position in
                                    SettingsValueRow(title: position.ticker, value: DisplayFormat.shares(position.shares))
                                }
                            }
                            if preview.positions.count > 10 {
                                SettingsFootnote(L10n.text("仅显示前 10 项；同步处理全部持仓。"))
                            }
                            ForEach(preview.warnings, id: \.self) { warning in
                                SettingsFootnote(warning)
                            }
                        }
                        SettingsFootnote(L10n.text("同步股票和基金持仓及买卖记录，用于图表买卖点和交易明细。交易历史范围由券商决定，通常每日更新；不含现金流水。"))
                        if !status.isEmpty { StatusNotice(text: status) }
                        if busy { SettingsFootnote(L10n.text("停止等待不会撤销已确认的更新。")) }
                        DisclosureGroup(L10n.text("连接管理")) {
                            VStack(alignment: .leading, spacing: 16) {
                                if flowStep > 2 {
                                    Button(L10n.text("更改凭证")) { resetCredentialsPreview() }
                                }
                                Button(L10n.text("读取账户列表")) { perform { try await loadAccounts() } }
                                    .disabled(!hasCredentials)
                                Button(L10n.text("保存凭证")) {
                                    perform {
                                        try credentials().save(accountID: context.account?.accountID)
                                        status = L10n.text("凭证已保存。")
                                    }
                                }.disabled(!hasCredentials)
                            }
                            .padding(.top, 16)
                        }
                        if !context.isCreating {
                            SettingsCard {
                                SettingsButtonRow(icon: .symbol("trash"), title: L10n.text("移除本机 SnapTrade 凭证"),
                                                  showsChevron: false, role: .destructive) { confirmsRemoval = true }
                            }
                        }
                    }
                }
                .disabled(busy)
            } actions: { flowActions(flowStep) }
            .accountConnectionTutorial(.snaptrade)
            .toolbar {
                if !context.isCreating {
                    ToolbarItem(placement: .confirmationAction) {
                        AppModalDoneButton { stopWaiting(); dismiss() }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if busy {
                        Button(L10n.text("停止等待")) { stopWaiting() }
                    }
                }
            }
            .onDisappear { if !context.isCreating || self.flowStep == flowStep { operation.cancel() } }
            .task {
                guard !hasPrepared else { return }
                hasPrepared = true
                if let saved = SnapTradeCredentials.load(accountID: context.account?.accountID) {
                    clientID = saved.clientID; consumerKey = saved.consumerKey
                }
            }
            .onChange(of: clientID) { _, _ in resetCredentialsPreview() }
            .onChange(of: consumerKey) { _, _ in resetCredentialsPreview() }
            .onChange(of: selectedID) { _, _ in self.preview = nil; previewCredentials = nil }
            .confirmationDialog(L10n.text("确认同步 SnapTrade 账户？"), isPresented: $confirmsSync, titleVisibility: .visible) {
                Button(L10n.text("同步并更新")) { perform { try await commit() } }
                Button(L10n.text("取消"), role: .cancel) {}
            } message: {
                Text(preview?.positions.isEmpty == true
                    ? L10n.text("此账户当前没有持仓。确认后将清空此账户的旧持仓，保留历史记录。")
                    : L10n.text("更新此账户的持仓并合并买卖记录；其他账户与已有交易历史保留。"))
            }
            .confirmationDialog(L10n.text("移除本机 SnapTrade 凭证？"), isPresented: $confirmsRemoval, titleVisibility: .visible) {
                Button(L10n.text("移除"), role: .destructive) {
                    perform {
                        try KeychainStore.set("", for: SnapTradeCredentials.key(accountID: context.account?.accountID))
                        consumerKey = ""; clientID = ""
                        status = L10n.text("已移除本机凭证。券商授权可在 SnapTrade Dashboard 中管理。")
                    }
                }
            }
        } next: { AnyView(page(flowStep + 1)) }
    }

    private var showsPreparation: Bool { context.isCreating && setupNavigation.step.isTutorial }
    private var flowStep: Int { showsPreparation ? 1 : (preview != nil ? 4 : (!allowedAccounts.isEmpty ? 3 : 2)) }



    private func goBack() {
        if preview != nil {
            preview = nil
            previewCredentials = nil
            status = ""
        } else if !allowedAccounts.isEmpty {
            resetCredentialsPreview()
            status = ""
        } else {
            setupNavigation.step = .prepare
        }
    }

    private var credentialsForm: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 16) {
                AccountCredentialRow(title: "Client ID", text: $clientID, accessibilityIdentifier: "snaptrade.client-id", isSecret: false)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                AccountCredentialRow(title: "Consumer Key", text: $consumerKey, accessibilityIdentifier: "snaptrade.consumer-key")
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            }
            SettingsFootnote(L10n.text("在 Dashboard 开启双重验证并创建个人 API Key；凭证仅存于此 iPhone。"))
        }
    }

    @ViewBuilder private func flowActions(_ flowStep: Int) -> some View {
        let showsPreparation = context.isCreating && flowStep == 1
        let preview = !context.isCreating || flowStep == 4 ? self.preview : nil
        if showsPreparation {
            AccountPreparationNextButton(action: setupNavigation.showCredentials)
        } else if preview != nil {
            OnboardingPrimaryButton(title: context.isCreating ? L10n.text("创建账户") : L10n.text("同步并更新"),
                isBusy: busy) { confirmsSync = true }
        } else if (!context.isCreating || flowStep == 3) && !allowedAccounts.isEmpty {
            OnboardingPrimaryButton(title: L10n.text("预览持仓"), isDisabled: selectedID.isEmpty,
                isBusy: busy) { perform { try await loadPreview() } }
        } else {
            OnboardingPrimaryButton(title: L10n.text("读取账户列表"), isDisabled: !hasCredentials,
                isBusy: busy) { perform { try await loadAccounts() } }
        }
    }

    private func loadPreview() async throws {
        preview = nil
        let saved = try credentials()
        let result = try await SnapTradeClient().snapshot(accountID: selectedID, credentials: saved)
        try Task.checkCancellation()
        try result.validate(context: context, existing: model.accounts)
        previewCredentials = saved
        preview = result
        status = ""
    }

    private func credentials() throws -> SnapTradeCredentials { try .init(clientID: clientID, consumerKey: consumerKey) }
    private func resetCredentialsPreview() {
        preview = nil; previewCredentials = nil; accounts = []; selectedID = ""
    }
    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        guard !busy, !model.isFakeDataMode, !model.isPublicInvestorMode else { return }
        status = ""
        operation.start(action, onError: { status = $0.localizedDescription })
    }

    private func stopWaiting() {
        operation.cancel()
        preview = nil
        previewCredentials = nil
        status = ""
    }

    private func loadAccounts() async throws {
        preview = nil; previewCredentials = nil
        let saved = try credentials()
        let fetched = try await SnapTradeClient().accounts(credentials: saved)
        try Task.checkCancellation()
        try saved.save(accountID: context.account?.accountID)
        accounts = fetched
        selectedID = allowedAccounts.first?.id ?? ""
        if allowedAccounts.isEmpty {
            status = fetched.isEmpty
                ? L10n.text("此 Key 下没有已关联的券商账户。请先在 SnapTrade Dashboard 关联账户，再回来读取。")
                : L10n.text("没有可添加的新账户；已有账户请从账户详情同步。")
        }
    }

    private func commit() async throws {
        guard let preview, let saved = previewCredentials, saved == (try credentials()) else { throw SnapTradeError.expired }
        try preview.validate(context: context, existing: model.accounts)
        try Task.checkCancellation()
        try saved.save(accountID: preview.account.id)
        _ = try await model.importSnapTrade(preview, context: context, nickname: model.suggestedAccountNickname())
        try Task.checkCancellation()
        if context.isCreating { try? KeychainStore.set("", for: SnapTradeCredentials.key(accountID: nil)) }
        dismiss()
    }
}

/// Owns one modal operation. A cancelled request may still finish; its error
/// and cleanup must not overwrite a newer operation's UI state.
@MainActor @Observable
final class SnapTradeOperation {
    private(set) var isRunning = false
    @ObservationIgnored private var task: Task<Void, Never>?
    private var generation = UUID()

    @discardableResult
    func start(_ action: @escaping @MainActor () async throws -> Void,
               onError: @escaping @MainActor (Error) -> Void) -> Task<Void, Never>? {
        guard !isRunning else { return nil }
        let id = UUID()
        generation = id
        isRunning = true
        let next = Task { @MainActor [weak self] in
            defer {
                if self?.generation == id {
                    self?.isRunning = false
                    self?.task = nil
                }
            }
            do {
                try Task.checkCancellation()
                try await action()
            } catch {
                guard !Task.isCancelled, self?.generation == id,
                      !(error is CancellationError), (error as? URLError)?.code != .cancelled else { return }
                onError(error)
            }
        }
        task = next
        return next
    }

    func cancel() {
        generation = UUID()
        task?.cancel()
        task = nil
        isRunning = false
    }
}
