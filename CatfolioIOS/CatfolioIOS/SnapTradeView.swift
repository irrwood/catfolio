import SwiftUI
import SafariServices

struct SnapTradeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismissPage
    @Environment(\.accountFlowClose) private var accountFlowClose
    let context: AccountConnectorContext
    var isFirstLaunchSetup = false
    @State private var clientID = ""
    @State private var consumerKey = ""
    @State private var accounts: [SnapTradeAccount] = []
    @State private var selectedID = ""
    @State private var preview: SnapTradeSnapshot?
    @State private var previewCredentials: SnapTradeCredentials?
    @State private var operation = SnapTradeOperation()
    @State private var status = ""
    @State private var portal: Portal?
    @State private var confirmsSync = false
    @State private var confirmsRemoval = false
    @State private var hasOpenedPortal = false
    @State private var hasPrepared = false

    private struct Portal: Identifiable { let id = UUID(); let url: URL }
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
        AccountFlowStack {
            OnboardingPage(scrollReset: flowStep, progress: context.isCreating ? OnboardingProgress(
                step: flowStep + (isFirstLaunchSetup ? 2 : 0), total: isFirstLaunchSetup ? 5 : 3) : nil) {
                OnboardingHeader(title: preview != nil ? L10n.text("确认持仓") : L10n.text("连接其他券商"),
                    subtitle: flowStep == 1 ? L10n.text("填入 SnapTrade 凭证，然后选择券商授权。")
                        : L10n.text("选择账户，预览后同步持仓。"))
                Group {
                    if flowStep == 1 {
                        credentialsForm
                    }
                    if hasOpenedPortal && allowedAccounts.isEmpty {
                        OnboardingFeature(symbol: "checkmark.shield", title: L10n.text("完成券商授权后继续"),
                            detail: L10n.text("关闭授权网页，再读取账户列表。"))
                    }
                    if !allowedAccounts.isEmpty {
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
                            ForEach(preview.positions.prefix(10), id: \.ticker) { position in
                                SettingsValueRow(title: position.ticker, value: DisplayFormat.shares(position.shares))
                            }
                        }
                        if preview.positions.count > 10 {
                            SettingsFootnote(L10n.text("仅显示前 10 项；同步处理全部持仓。"))
                        }
                    }
                    SettingsFootnote(L10n.text("授权后关闭网页并读取账户；仅同步股票和基金持仓，不含现金或交易流水。"))
                    if !status.isEmpty { StatusNotice(text: status) }
                    if busy { SettingsFootnote(L10n.text("停止等待不会撤销已确认的更新。")) }
                    DisclosureGroup(L10n.text("需要帮助？")) {
                        VStack(alignment: .leading, spacing: 16) {
                            if flowStep > 1 {
                                Button(L10n.text("更改凭证")) { resetCredentialsPreview() }
                            }
                            Link(L10n.text("打开 SnapTrade Dashboard"), destination: URL(string: "https://dashboard.snaptrade.com")!)
                            Button(L10n.text("连接或重新授权券商")) { perform { try await connectBroker() } }
                                .disabled(!hasCredentials)
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
                .disabled(busy)
            } actions: { flowActions }
            .toolbar {
                if !context.isCreating {
                    ToolbarItem(placement: .confirmationAction) {
                        AppModalDoneButton { stopWaiting(); dismiss() }
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    if busy {
                        Button(L10n.text("停止等待")) { stopWaiting() }
                    } else if context.isCreating {
                        AccountProviderBackButton()
                    }
                }
            }
            .onDisappear { operation.cancel() }
            .task {
                guard !hasPrepared else { return }
                hasPrepared = true
                if let saved = SnapTradeCredentials.load(accountID: context.account?.accountID) {
                    clientID = saved.clientID; consumerKey = saved.consumerKey
                }
            }
            .onChange(of: clientID) { _, _ in resetCredentialsPreview() }
            .onChange(of: consumerKey) { _, _ in resetCredentialsPreview() }
            .onChange(of: selectedID) { _, _ in preview = nil; previewCredentials = nil }
            .appSheet(item: $portal) { item in SnapTradeBrowser(url: item.url).ignoresSafeArea() }
            .confirmationDialog(L10n.text("确认同步 SnapTrade 账户？"), isPresented: $confirmsSync, titleVisibility: .visible) {
                Button(L10n.text("同步并更新")) { perform { try await commit() } }
                Button(L10n.text("取消"), role: .cancel) {}
            } message: {
                Text(preview?.positions.isEmpty == true
                    ? L10n.text("此账户当前没有持仓。确认后将清空此账户的旧持仓，保留历史记录。")
                    : L10n.text("仅更新预览中的账户持仓；其他账户与已有交易历史保留。"))
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
        }
        .accountFlowBrand(.snaptrade)
    }

    private var flowStep: Int { preview != nil ? 3 : (!allowedAccounts.isEmpty || hasOpenedPortal ? 2 : 1) }

    private var credentialsForm: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsSection(L10n.text("SnapTrade 个人 API")) {
                SettingsFieldRow("Client ID", text: $clientID, isMonospaced: true)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                SettingsFieldRow("Consumer Key", text: $consumerKey, isSecure: true, isMonospaced: true)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            }
            SettingsFootnote(L10n.text("在 Dashboard 开启双重验证并创建个人 API Key；凭证仅存于此 iPhone。"))
        }
    }

    @ViewBuilder private var flowActions: some View {
        if preview != nil {
            OnboardingPrimaryButton(title: context.isCreating ? L10n.text("创建账户") : L10n.text("同步并更新"),
                isBusy: busy) { confirmsSync = true }
        } else if !allowedAccounts.isEmpty {
            OnboardingPrimaryButton(title: L10n.text("预览持仓"), isDisabled: selectedID.isEmpty,
                isBusy: busy) { perform { try await loadPreview() } }
        } else if hasOpenedPortal {
            OnboardingPrimaryButton(title: L10n.text("读取账户列表"), isDisabled: !hasCredentials,
                isBusy: busy) { perform { try await loadAccounts() } }
        } else {
            OnboardingPrimaryButton(title: L10n.text("连接券商"), isDisabled: !hasCredentials,
                isBusy: busy) { perform { try await connectBroker() } }
            Button(L10n.text("已授权，读取账户")) { perform { try await loadAccounts() } }
                .disabled(!hasCredentials || busy)
        }
    }

    private func connectBroker() async throws {
        let saved = try credentials()
        try saved.save(accountID: context.account?.accountID)
        var reconnect: String?
        if let currentID = context.account?.accountID {
            let linked = try await SnapTradeClient().accounts(credentials: saved)
            try Task.checkCancellation()
            guard let current = linked.first(where: { $0.id == currentID }) else { throw SnapTradeError.accountUnavailable }
            reconnect = current.brokerage_authorization
        }
        let url = try await SnapTradeClient().portal(credentials: saved, reconnect: reconnect)
        try Task.checkCancellation()
        hasOpenedPortal = true
        portal = Portal(url: url)
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
        preview = nil; previewCredentials = nil; accounts = []; selectedID = ""; hasOpenedPortal = false
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
        if allowedAccounts.isEmpty { status = L10n.text("没有可用的新账户，请先完成券商授权；已有账户请从账户详情同步。") }
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

private struct SnapTradeBrowser: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController { SFSafariViewController(url: url) }
    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}
