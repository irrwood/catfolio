import SwiftUI

struct DirectBrokerAccountView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismissPage
    @Environment(\.accountFlowClose) private var closeFlow
    let broker: DirectBroker
    let context: AccountConnectorContext
    var isFirstLaunchSetup = false
    @State var setupNavigation = AccountSetupNavigation()
    @State private var key = ""
    @State private var secret = ""
    @State private var token = ""
    @State private var environment = AlpacaEnvironment.live
    @State private var nickname = ""
    @State private var nicknameEdited = false
    @State private var prepared = false
    @State private var preview: DirectBrokerSnapshot?
    @State private var previewCredentials: DirectBrokerCredentials?
    @State private var operation = SnapTradeOperation()
    @State private var status = ""
    @State private var confirmsSync = false
    @State private var confirmsRemoval = false

    private var provider: AddAccountProvider { broker == .longbridge ? .longbridge : .alpaca }
    private var credentials: DirectBrokerCredentials {
        .init(broker: broker, key: key, secret: secret, token: token, environment: environment)
    }
    private var showsPreparation: Bool { context.isCreating && setupNavigation.step.isTutorial }
    private var step: Int { showsPreparation ? 1 : (preview == nil ? 2 : 3) }
    private var busy: Bool { operation.isRunning }

    private func dismiss() { if let closeFlow { closeFlow() } else { dismissPage() } }

    var body: some View {
        AccountFlowStack { page(context.isCreating ? 1 : 2) }
            .accountFlowBrand(provider)
    }

    private func page(_ page: Int) -> some View {
        let showsPreparation = context.isCreating && page == 1
        let preview = !context.isCreating || page == 3 ? self.preview : nil
        return AccountFlowPage(showsNext: Binding(
            get: { context.isCreating && self.step > page },
            set: { shown in
                guard !shown, self.step > page else { return }
                operation.cancel()
                resetPreview()
                if page == 1 { setupNavigation.step = .prepare }
            })) {
            OnboardingPage(scrollReset: page, isAccountPreparation: true) {
                AccountConnectionHeader(provider: provider, title: preview == nil ? L10n.text("连接 \(broker.title)") : L10n.text("确认持仓"),
                    subtitle: L10n.text("只开启读取权限"))
                Group {
                    if showsPreparation {
                        BrokerPreparationInstructions(provider: provider)
                    } else {
                        if let preview {
                            previewSection(preview)
                            Button(L10n.text("更改凭证")) { resetPreview() }
                        } else {
                            credentialsForm
                        }
                        SettingsFootnote(L10n.text("仅同步股票和 ETF 多头持仓，不含现金、场外基金和交易流水。Catfolio 不发送交易指令。"))
                        if broker == .longbridge {
                            SettingsFootnote(L10n.text("长桥账户下的股票持仓合并显示；行情权限沿用该账户的 OpenAPI 权限。"))
                        }
                        if !status.isEmpty { StatusNotice(text: status) }
                        if !context.isCreating {
                            Button(L10n.text("移除本机账户凭证"), role: .destructive) { confirmsRemoval = true }
                        }
                    }
                }
                .disabled(busy)
            } actions: {
                if showsPreparation {
                    AccountPreparationNextButton(action: setupNavigation.showCredentials)
                } else if preview != nil {
                    OnboardingPrimaryButton(title: context.isCreating ? L10n.text("创建账户") : L10n.text("同步并更新"),
                        isBusy: busy) { confirmsSync = true }
                } else {
                    OnboardingPrimaryButton(title: L10n.text("预览持仓"), isDisabled: !credentials.isComplete,
                        isBusy: busy) { perform { try await loadPreview() } }
                }
            }
            .accountConnectionTutorial(provider)
            .toolbar {
                if !context.isCreating {
                    ToolbarItem(placement: .confirmationAction) { AppModalDoneButton { operation.cancel(); dismiss() } }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if busy { Button(L10n.text("停止等待")) { operation.cancel(); resetPreview() } }
                }
            }
            .task { prepare() }
            .onDisappear { if !context.isCreating || self.step == page { operation.cancel() } }
            .onChange(of: credentials) { _, _ in operation.cancel(); resetPreview() }
            .confirmationDialog(L10n.text("确认同步券商持仓？"), isPresented: $confirmsSync, titleVisibility: .visible) {
                Button(context.isCreating ? L10n.text("创建账户") : L10n.text("同步并更新")) { perform { try await commit() } }
                Button(L10n.text("取消"), role: .cancel) {}
            } message: {
                Text(preview?.positions.isEmpty == true
                    ? L10n.text("此账户当前没有持仓。确认后将清空此账户的旧持仓，保留历史记录。")
                    : L10n.text("仅更新预览中的账户持仓；其他账户与已有交易历史保留。"))
            }
            .confirmationDialog(L10n.text("移除本机账户凭证？"), isPresented: $confirmsRemoval, titleVisibility: .visible) {
                Button(L10n.text("移除"), role: .destructive) {
                    perform {
                        guard let id = context.account?.accountID else { return }
                        try KeychainStore.set("", for: DirectBrokerCredentials.storageKey(broker: broker, accountID: id))
                        key = ""; secret = ""; token = ""; resetPreview()
                    }
                }
            }
        } next: {
            AnyView(self.page(page + 1))
        }
    }

    private var credentialsForm: some View {
        VStack(alignment: .leading, spacing: 16) {
            if broker == .alpaca {
                SettingsSection(L10n.text("账户环境")) {
                    SettingsRowContainer {
                        Picker(L10n.text("账户环境"), selection: $environment) {
                            ForEach(AlpacaEnvironment.allCases) { Text($0.title).tag($0) }
                        }.pickerStyle(.segmented)
                            .accessibilityIdentifier("alpaca.environment")
                            .disabled(!context.isCreating)
                    }
                }
                SettingsFootnote(L10n.text("实盘和模拟盘使用不同凭证，账户与持仓分别保存。"))
            }
            VStack(alignment: .leading, spacing: 16) {
                AccountCredentialRow(title: broker == .longbridge ? "App Key" : "API Key", text: $key,
                                     accessibilityIdentifier: "broker-account.key")
                AccountCredentialRow(title: broker == .longbridge ? "App Secret" : "Secret Key", text: $secret,
                                     accessibilityIdentifier: "broker-account.secret")
                if broker == .longbridge {
                    AccountCredentialRow(title: "Access Token", text: $token, accessibilityIdentifier: "broker-account.token")
                }
            }
            SettingsFootnote(L10n.text("凭证保存在本机钥匙串；更换设备后需重新填写。"))

        }
    }
    private func previewSection(_ snapshot: DirectBrokerSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsSection(L10n.text("持仓预览")) {
                SettingsValueRow(title: L10n.text("账户"), value: snapshot.accountLabel, valueIsNumeric: false)
                SettingsValueRow(title: L10n.text("读取时间"), value: snapshot.fetchedAt.formatted(date: .abbreviated, time: .shortened), valueIsNumeric: false)
                SettingsValueRow(title: L10n.text("持仓"), value: String(snapshot.positions.count))
                ForEach(snapshot.positions.prefix(10), id: \.ticker) { position in
                    SettingsValueRow(title: position.ticker, value: DisplayFormat.shares(position.shares))
                }
            }
            if snapshot.positions.count > 10 { SettingsFootnote(L10n.text("仅显示前 10 项；同步处理全部持仓。")) }
            if context.isCreating { AccountNicknameField(nickname: $nickname, edited: $nicknameEdited) }
        }
    }
    private func prepare() {
        guard !prepared else { return }
        prepared = true
        nickname = model.suggestedAccountNickname()
        if let account = context.account, broker == .alpaca {
            environment = account.accountID?.hasPrefix("paper:") == true ? .paper : .live
        }
        if let saved = DirectBrokerCredentials.load(broker: broker, accountID: context.account?.accountID) {
            key = saved.key; secret = saved.secret; token = saved.token; environment = saved.environment
        }
    }
    private func resetPreview() { preview = nil; previewCredentials = nil; status = "" }
    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        guard !model.isFakeDataMode, !model.isPublicInvestorMode, !busy else { return }
        status = ""
        operation.start(action, onError: { status = $0.localizedDescription })
    }
    private func loadPreview() async throws {
        resetPreview()
        let saved = credentials
        let snapshot: DirectBrokerSnapshot
        switch broker {
        case .longbridge: snapshot = try await LongbridgeAccountClient().snapshot(credentials: saved)
        case .alpaca: snapshot = try await AlpacaAccountClient().snapshot(credentials: saved)
        }
        try Task.checkCancellation()
        guard saved == credentials else { throw DirectBrokerError.expired }
        try snapshot.validate(context: context, existing: model.accounts)
        previewCredentials = saved; preview = snapshot
    }
    private func commit() async throws {
        guard let preview, let saved = previewCredentials, saved == credentials else { throw DirectBrokerError.expired }
        try preview.validate(context: context, existing: model.accounts)
        try Task.checkCancellation()
        try saved.save(accountID: preview.accountID)
        _ = try await model.importDirectBroker(preview, context: context, nickname: nickname)
        try Task.checkCancellation()
        dismiss()
    }
}
