import SwiftUI
import SafariServices

struct SnapTradeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let context: AccountConnectorContext
    @State private var clientID = ""
    @State private var consumerKey = ""
    @State private var nickname = ""
    @State private var nicknameEdited = false
    @State private var accounts: [SnapTradeAccount] = []
    @State private var selectedID = ""
    @State private var preview: SnapTradeSnapshot?
    @State private var previewCredentials: SnapTradeCredentials?
    @State private var operation = SnapTradeOperation()
    @State private var status = ""
    @State private var portal: Portal?
    @State private var confirmsSync = false
    @State private var confirmsRemoval = false

    private struct Portal: Identifiable { let id = UUID(); let url: URL }
    private var busy: Bool { operation.isRunning }
    private var hasCredentials: Bool { !clientID.isEmpty && !consumerKey.isEmpty }
    private var allowedAccounts: [SnapTradeAccount] {
        accounts.filter { account in
            if let current = context.account { return account.id == current.accountID }
            return !model.accounts.contains { $0.source == "SnapTrade" && $0.accountID == account.id }
        }
    }

    var body: some View {
        NavigationStack {
            SettingsPage(bottomInset: 32) {
                Group {
                    if context.isCreating {
                        SettingsSectionHeader(L10n.text("账户昵称"))
                        SettingsCard {
                            SettingsRowContainer { AccountNicknameField(nickname: $nickname, edited: $nicknameEdited) }
                        }
                    }
                    SettingsSectionHeader(L10n.text("SnapTrade 个人 API"))
                    SettingsCard {
                        SettingsFieldRow("Client ID", text: $clientID, isMonospaced: true)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        SettingsFieldRow("Consumer Key", text: $consumerKey, isSecure: true, isMonospaced: true)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        SettingsButtonRow(icon: .symbol("key"), title: L10n.text("保存凭证"), showsChevron: false) {
                            perform {
                                try credentials().save(accountID: context.account?.accountID)
                                status = L10n.text("凭证已保存。")
                            }
                        }.disabled(!hasCredentials)
                    }
                    SettingsFootnote(L10n.text("在 Dashboard 开启双重验证并创建个人 API Key；凭证仅存于此 iPhone。"))
                    SettingsCard {
                        Link(destination: URL(string: "https://dashboard.snaptrade.com")!) {
                            SettingsRowContainer {
                                SettingsRowLabel(icon: .symbol("arrow.up.right.square"), title: L10n.text("打开 SnapTrade Dashboard"))
                            }
                        }.buttonStyle(SettingsRowButtonStyle())
                        SettingsButtonRow(icon: .symbol("link"), title: L10n.text("连接或重新授权券商"), showsChevron: false) {
                            perform {
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
                                portal = Portal(url: url)
                            }
                        }.disabled(!hasCredentials)
                        SettingsButtonRow(icon: .symbol("arrow.clockwise"), title: L10n.text("读取账户列表"), showsChevron: false) {
                            perform { try await loadAccounts() }
                        }.disabled(!hasCredentials)
                    }
                    SettingsFootnote(L10n.text("授权后关闭网页并读取账户；仅同步股票和基金持仓，不含现金或交易流水。"))

                    if !allowedAccounts.isEmpty {
                        SettingsSectionHeader(L10n.text("选择账户"))
                        SettingsCard {
                            ForEach(allowedAccounts) { account in
                                SettingsButtonRow(icon: .symbol(selectedID == account.id ? "checkmark.circle.fill" : "circle"),
                                                  title: account.displayName, showsChevron: false) { selectedID = account.id }
                            }
                            SettingsButtonRow(icon: .symbol("eye"), title: L10n.text("预览持仓"), showsChevron: false) {
                                perform {
                                    preview = nil
                                    let saved = try credentials()
                                    let result = try await SnapTradeClient().snapshot(accountID: selectedID, credentials: saved)
                                    try Task.checkCancellation()
                                    try result.validate(context: context, existing: model.accounts)
                                    previewCredentials = saved
                                    preview = result
                                    status = ""
                                }
                            }.disabled(selectedID.isEmpty)
                        }
                    }
                    if let preview {
                        SettingsSectionHeader(L10n.text("持仓预览"))
                        SettingsCard {
                            SettingsValueRow(title: L10n.text("数据时间"), value: preview.asOf.formatted(date: .abbreviated, time: .shortened), valueIsNumeric: false)
                            SettingsValueRow(title: L10n.text("持仓"), value: String(preview.positions.count))
                            ForEach(preview.positions.prefix(10), id: \.ticker) { position in
                                SettingsValueRow(title: position.ticker, value: DisplayFormat.shares(position.shares))
                            }
                            SettingsRowContainer {
                                GlassPrimaryButton(title: context.isCreating ? L10n.text("创建账户") : L10n.text("同步并更新"),
                                    systemImage: "tray.and.arrow.down", isDisabled: nickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                                    isBusy: busy) { confirmsSync = true }
                            }
                        }
                    }
                    if busy {
                        ProgressView().frame(maxWidth: .infinity).accessibilityLabel(L10n.text("正在读取"))
                        SettingsFootnote(L10n.text("停止等待不会撤销已确认的更新。"))
                    }
                    if !status.isEmpty { StatusNotice(text: status) }
                    if !context.isCreating {
                        SettingsCard {
                            SettingsButtonRow(icon: .symbol("trash"), title: L10n.text("移除本机 SnapTrade 凭证"),
                                              showsChevron: false, role: .destructive) { confirmsRemoval = true }
                        }
                    }
                }
                .disabled(busy)
            }
            .navigationTitle("SnapTrade")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    AppModalDoneButton { stopWaiting(); dismiss() }
                }
                ToolbarItem(placement: .cancellationAction) {
                    if busy {
                        Button(L10n.text("停止等待")) { stopWaiting() }
                    }
                }
            }
            .onDisappear { operation.cancel() }
            .task {
                nickname = context.account?.name ?? model.suggestedAccountNickname()
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
        }.tint(CatfolioTheme.accent)
    }

    private func credentials() throws -> SnapTradeCredentials { try .init(clientID: clientID, consumerKey: consumerKey) }
    private func resetCredentialsPreview() { preview = nil; previewCredentials = nil; accounts = []; selectedID = "" }
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
        _ = try await model.importSnapTrade(preview, context: context, nickname: nickname)
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
