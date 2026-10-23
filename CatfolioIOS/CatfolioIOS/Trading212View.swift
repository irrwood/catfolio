import SwiftUI

struct Trading212View: View {
    @Environment(\.locale) private var appLocale
    @Environment(\.dismiss) private var dismissPage
    @Environment(\.accountFlowClose) private var accountFlowClose
    @Environment(\.scenePhase) private var scenePhase
    @Environment(AppModel.self) private var model

    let context: AccountConnectorContext
    private let setupStore: Trading212SetupStore
    private let isFirstLaunchSetup: Bool
    private let credentialValues: () -> [String: String]

    @State private var setupNavigation: AccountSetupNavigation
    private var guideStep: Trading212GuideStep {
        get { setupNavigation.step }
        nonmutating set { setupNavigation.step = newValue }
    }
    @State private var apiKey = ""
    @State private var apiSecret = ""
    @State private var accountSlot = 1
    @State private var nickname = ""
    @State private var nicknameEdited = false
    @State private var snapshot: Trading212Snapshot?
    @State private var snapshotRequest: Trading212RequestConfiguration?
    @State private var status: Trading212ViewStatus = .idle
    @State private var operation = Trading212Operation()
    @State private var showsClearConfirmation = false
    @State private var showsSyncConfirmation = false
    @State private var historyRetryTask: Task<Void, Never>?
    @State private var hasPrepared = false

    private var isWorking: Bool { operation.isRunning }

    init(context: AccountConnectorContext = .create, setupStore: Trading212SetupStore = .shared,
         isFirstLaunchSetup: Bool = false, setupNavigation: AccountSetupNavigation? = nil,
         credentialValues: @escaping () -> [String: String] = BrokerCredentialPrefill.storedValues) {
        self.context = context
        self.setupStore = setupStore
        self.isFirstLaunchSetup = isFirstLaunchSetup
        self.credentialValues = credentialValues
        _setupNavigation = State(initialValue: setupNavigation ?? AccountSetupNavigation(
            startsAtCredentials: !context.isCreating))
    }



    private static func apiKeyKey(slot: Int) -> String { "trading212.account-\(slot).api-key" }
    private static func apiSecretKey(slot: Int) -> String { "trading212.account-\(slot).api-secret" }

    /// Inside 添加账户 this closes the whole flow; on its own, the page.
    private func dismiss() {
        if context.isCreating { setupStore.setCreationPresented(false) }
        if let accountFlowClose { accountFlowClose() } else { dismissPage() }
    }

    var body: some View {
        AccountFlowStack { page(context.isCreating ? .prepare : .credentials) }
            .accountFlowBrand(.trading212)
    }

    private func page(_ guideStep: Trading212GuideStep) -> some View {
        AccountFlowPage(showsNext: Binding(
            get: { context.isCreating && !self.guideStep.isTutorial && self.guideStep.rawValue > guideStep.rawValue },
            set: { shown in
                guard !shown, self.guideStep.rawValue > guideStep.rawValue else { return }
                stopWaiting()
                if guideStep == .prepare || guideStep == .credentials { invalidatePreview() }
                self.guideStep = guideStep
            })) {
            OnboardingPage(scrollReset: guideStep, isAccountPreparation: true) {
                if !context.isCreating || guideStep.isTutorial || guideStep == .credentials {
                    AccountConnectionHeader(provider: .trading212, title: L10n.text("连接 Trading 212"),
                                            subtitle: guideStep.isTutorial ? L10n.text("通过 API 连接") : L10n.text("只开启读取权限"))
                } else {
                    AccountConnectionHeader(provider: .trading212, title: guideStep.title, subtitle: guideStep.subtitle)
                }
                if context.isCreating && guideStep.isTutorial {
                    Trading212GuideLesson(step: guideStep) {
                        setupNavigation.showCredentials()
                    }
                } else if context.isCreating && guideStep == .complete {
                    completionContent
                } else {
                    VStack(alignment: .leading, spacing: 16) { connectionContent(guideStep) }
                }
            } actions: { flowActions(guideStep) }
            .disabled(isWorking)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !context.isCreating {
                    ToolbarItem(placement: .confirmationAction) {
                        AppModalDoneButton { stopWaiting(); dismiss() }
                    }
                }
            }
            .accountConnectionTutorial(.trading212)
            .task { prepareAccount() }
            .onAppear {
                if context.isCreating, accountFlowClose == nil, guideStep != .complete {
                    setupStore.setCreationPresented(true)
                }
            }
            .onDisappear {
                persistDraft()
                guard scenePhase == .active else { return }
                if !context.isCreating || self.guideStep == guideStep { stopWaiting() }
                if context.isCreating, accountFlowClose == nil, self.guideStep == guideStep { setupStore.setCreationPresented(false) }
            }
            .onChange(of: draft) { _, _ in persistDraft() }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { persistDraft() }
            }
            .onChange(of: apiKey) { _, _ in invalidatePreview() }
            .onChange(of: apiSecret) { _, _ in invalidatePreview() }
            .confirmationDialog(
                L10n.text("移除 Trading 212 凭证？"),
                isPresented: $showsClearConfirmation,
                titleVisibility: .visible
            ) {
                Button(L10n.text("移除"), role: .destructive) { clearCredentials() }
                Button(L10n.text("取消"), role: .cancel) {}
            } message: {
                Text(L10n.text("将删除当前账户的 API Key 与 Secret；开启或重新开启密钥同步后，删除也会同步到其他设备。"))
            }
            .confirmationDialog(
                context.isCreating ? L10n.text("创建 Trading 212 账户？") : L10n.text("更新 Trading 212 账户？"),
                isPresented: $showsSyncConfirmation,
                titleVisibility: .visible
            ) {
                Button(context.isCreating ? L10n.text("创建账户") : L10n.text("同步并更新")) {
                    perform(.sync)
                }
                Button(L10n.text("取消"), role: .cancel) {}
            } message: {
                Text(context.isCreating
                    ? L10n.text("将使用预览中的数据创建新账户；现有账户不受影响。")
                    : L10n.text("将更新当前 Trading 212 账户持仓；其他账户不受影响。"))
            }
        } next: {
            AnyView(page(guideStep.isTutorial ? .credentials : (guideStep == .credentials ? .review : .complete)))
        }
    }

    @ViewBuilder
    private func flowActions(_ guideStep: Trading212GuideStep) -> some View {
        let snapshot = !context.isCreating || guideStep == .review ? self.snapshot : nil
        if context.isCreating && guideStep.isTutorial {
            Trading212GuideLesson(step: guideStep) {
                setupNavigation.showCredentials()
            }.actions
        } else if context.isCreating && guideStep == .complete {
            OnboardingPrimaryButton(title: L10n.text("完成")) { stopWaiting(); dismiss() }
        } else if let snapshot {
            OnboardingPrimaryButton(
                title: isWorking
                    ? (context.isCreating ? L10n.text("正在创建") : L10n.text("正在同步"))
                    : (context.isCreating ? L10n.text("创建 Trading 212 账户") : L10n.text("同步 \(snapshot.positions.count) 项到 Catfolio")),
                isDisabled: !hasValidNickname,
                isBusy: isWorking
            ) {
                showsSyncConfirmation = true
            }
        } else {
            OnboardingPrimaryButton(
                title: isWorking ? L10n.text("正在读取") : L10n.text("读取"),
                isDisabled: !credentialsReady,
                isBusy: isWorking,
                usesGlass: true
            ) {
                perform(.preview)
            }
        }
    }

    @ViewBuilder
    private func connectionContent(_ guideStep: Trading212GuideStep) -> some View {
        let snapshot = !context.isCreating || guideStep == .review ? self.snapshot : nil
        if context.isCreating, snapshot != nil {
            SettingsSectionHeader(L10n.text("账户昵称"))
            SettingsCard {
                AccountNicknameField(nickname: $nickname, edited: $nicknameEdited)
                    .disabled(isWorking)
            }
        }

        if !context.isCreating || guideStep == .credentials {
            credentialsSection

        }

        if status.isPresented { statusView }
        if snapshot != nil {
            Button(L10n.text("重新读取持仓")) { perform(.preview) }
                .appText(.callout).disabled(isWorking)
        }

        if let snapshot {
            SettingsSectionHeader(L10n.text("持仓预览"))
            SettingsCard {
                SettingsValueRow(title: L10n.text("账户"), value: L10n.text("\(snapshot.accountCount) 个"))
                SettingsValueRow(title: L10n.text("持仓"), value: L10n.text("\(snapshot.positions.count) 项"))
                if let account = context.account {
                    SettingsValueRow(
                        title: L10n.text("账户类型"),
                        value: L10n.label(account.accountType),
                        valueIsNumeric: false
                    )
                }

                ForEach(snapshot.positions.prefix(10)) { position in
                    SettingsRowContainer {
                        HStack {
                            VStack(alignment: .leading, spacing: SettingsTemplate.subtitleSpacing) {
                                HStack(spacing: 6) {
                                    Text(position.ticker)
                                        .appText(.subheading, weight: .semibold)
                                    if snapshot.accountCount > 1 {
                                        Text(L10n.text("账户 \(position.accountSlot)"))
                                            .appText(.label, weight: .medium)
                                            .foregroundStyle(SettingsTemplate.secondaryText)
                                    }
                                }
                                Text(position.name)
                                    .appText(.label, weight: .regular)
                                    .foregroundStyle(SettingsTemplate.secondaryText)
                                    .lineLimit(1)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: SettingsTemplate.subtitleSpacing) {
                                FinancialText(DisplayFormat.shares(position.quantity))
                                    .appNumber(.subheading)
                                if let currentPrice = position.currentPrice {
                                    FinancialText(DisplayFormat.money(position.quantity * currentPrice, currency: position.currency))
                                        .appNumber(.label, weight: .regular, monospaced: false)
                                        .foregroundStyle(SettingsTemplate.secondaryText)
                                }
                            }
                        }
                    }
                }
            }
            if snapshot.positions.count > 10 {
                SettingsFootnote(L10n.text("仅显示前 10 项；保存全部可导入持仓。"))
            }
        }

        if hasCredentials && !context.isCreating {
            SettingsCard {
                SettingsButtonRow(
                    icon: .symbol("trash"),
                    title: L10n.text("移除本机 Trading 212 凭证"),
                    showsChevron: false,
                    role: .destructive
                ) {
                    showsClearConfirmation = true
                }
            }
        }
    }

    private var credentialsReady: Bool {
        (try? accountCredentials()) != nil
    }

    private var completionContent: some View {
        SettingsCard {
            SettingsRowContainer {
                VStack(alignment: .leading, spacing: 16) {
                    Label(L10n.text("账户已添加"), systemImage: "checkmark.circle")
                        .appText(.subheading, weight: .semibold)
                    Text(nickname).appText(.subheading)
                    statusView
                }
            }
        }
    }

    @ViewBuilder
    private var credentialsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            AccountCredentialRow(title: "API Key", text: $apiKey, accessibilityIdentifier: "trading212.api-key", isSecret: false)
            AccountCredentialRow(title: "API Secret", text: $apiSecret, accessibilityIdentifier: "trading212.api-secret")
        }
        AccountCredentialFootnote()
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
            Label(message, systemImage: "checkmark.circle")
                .appText(.label, weight: .regular)
                .foregroundStyle(CatfolioTheme.positive)
        case let .failure(message):
            StatusNotice(text: message)
        }
    }

    private var hasCredentials: Bool {
        !apiKey.isEmpty || !apiSecret.isEmpty
    }

    private var hasValidNickname: Bool {
        !context.isCreating || !nickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func prepareAccount() {
        // SwiftUI can run the appearance task again after another app or a
        // sheet covers this page. Initialisation must not replace live edits.
        guard !hasPrepared else { return }
        defer { hasPrepared = true }
        if let saved = setupStore.load(for: context) {
            guideStep = !context.isCreating ? .credentials : saved.restoredStep
            apiKey = saved.apiKey
            apiSecret = saved.apiSecret
            accountSlot = context.isCreating ? availableAccountSlot(preferred: saved.accountSlot) : saved.accountSlot
            nickname = saved.nickname
            nicknameEdited = saved.nicknameEdited
            return
        }
        let stored = credentialValues()
        if let account = context.account {
            if let slot = account.accountID.flatMap({ Int($0.replacingOccurrences(of: "account-", with: "")) }) {
                accountSlot = slot
            }
            apiKey = stored[Self.apiKeyKey(slot: accountSlot)] ?? ""
            apiSecret = stored[Self.apiSecretKey(slot: accountSlot)] ?? ""
            nickname = AccountNaming.nickname(from: account.displayName, provider: "Trading 212")
            return
        }

        accountSlot = availableAccountSlot()
        if let credentials = BrokerCredentialPrefill.trading212(slot: accountSlot, values: stored) {
            apiKey = credentials.apiKey
            apiSecret = credentials.apiSecret
        }
        nickname = model.suggestedAccountNickname()
    }

    private func availableAccountSlot(preferred: Int = 1) -> Int {
        let usedSlots = Set(model.accounts
            .filter { $0.source == "Trading 212" }
            .compactMap { $0.accountID }
            .compactMap { Int($0.replacingOccurrences(of: "account-", with: "")) })
        var availableSlot = max(1, preferred)
        while usedSlots.contains(availableSlot) { availableSlot += 1 }
        return availableSlot
    }

    private var draft: Trading212SetupDraft {
        .init(step: guideStep, environment: .live, apiKey: apiKey, apiSecret: apiSecret,
              accountSlot: accountSlot, nickname: nickname, nicknameEdited: nicknameEdited)
    }

    private func persistDraft() {
        guard hasPrepared, guideStep != .complete else { return }
        do { try setupStore.save(draft, for: context) }
        catch { status = .failure(error.localizedDescription) }
    }

    private func accountCredentials() throws -> [Trading212AccountCredentials] {
        let credentials = try Trading212Credentials(apiKey: apiKey, apiSecret: apiSecret)
        return [Trading212AccountCredentials(slot: accountSlot, credentials: credentials)]
    }

    private func saveCredentials(_ request: Trading212RequestConfiguration) throws {
        guard let account = request.accounts.first else { return }
        try KeychainStore.set(account.credentials.apiKey, for: Self.apiKeyKey(slot: account.slot))
        try KeychainStore.set(account.credentials.apiSecret, for: Self.apiSecretKey(slot: account.slot))
    }

    private func perform(_ action: Trading212HistoryRetryAction) {
        guard !isWorking, !model.isFakeDataMode, !model.isPublicInvestorMode else { return }
        historyRetryTask?.cancel()
        historyRetryTask = nil
        do {
            // Keep the response tied to the exact environment and credentials
            // that produced it, even if the draft changes during suspension.
            let request = Trading212RequestConfiguration(accounts: try accountCredentials(), environment: .live)
            try saveCredentials(request)
            let cached = action == .sync && snapshotRequest == request && snapshot?.hasCompleteTransactionHistory == true
                ? snapshot : nil
            if action == .preview {
                snapshot = nil
                snapshotRequest = nil
            }
            status = .working(action == .preview
                ? L10n.text("正在读取 Trading 212 持仓与历史成交…")
                : L10n.text("正在同步 Trading 212 持仓与历史数据…"))
            operation.start(request: request, fetch: { request in
                if let cached { return cached }
                return try await Trading212Client().fetchSnapshot(accounts: request.accounts, environment: request.environment)
            }, apply: { request, result in
                switch action {
                case .preview: applyPreview(result, request: request)
                case .sync: try await sync(result, request: request)
                }
            }, onError: { error in
                status = .failure(error.localizedDescription)
            })
        } catch {
            status = .failure(error.localizedDescription)
        }
    }

    private func applyPreview(_ result: Trading212Snapshot, request: Trading212RequestConfiguration) {
        if context.isCreating, !nicknameEdited {
            // The current API snapshot supplies an account label, not a personal name.
            nickname = result.syncedAccounts.first?.name ?? "Trading 212"
        }
        snapshot = result
        snapshotRequest = request
        if context.isCreating { guideStep = .review }
        let historyText = result.transactionHistoryStatus.map { L10n.clauseSeparator + L10n.message($0) } ?? ""
        status = .success(L10n.text("读取成功：\(result.accountCount) 个账户，\(result.positions.count) 项持仓\(historyText)"))
        if !result.hasCompleteTransactionHistory {
            scheduleHistoryRetry(.preview)
        }
    }

    private func sync(_ currentSnapshot: Trading212Snapshot, request: Trading212RequestConfiguration) async throws {
        snapshot = currentSnapshot
        snapshotRequest = request
        status = .working(L10n.text("Trading 212 已读取，正在保存到本机…"))
        let accountID = "account-\(accountSlot)"
        let accountNames = model.accountNames(
            source: "Trading 212",
            accountIDs: [accountID],
            preferredNickname: nickname,
            targetAccountID: context.account?.accountID
        )
        let result = try await model.importTrading212(
            currentSnapshot,
            accountNames: accountNames,
            replacingAccountsOnly: true
        )
        // Cancellation cannot roll back a completed local import, but a
        // dismissed sheet must not publish stale state or start a retry.
        try Task.checkCancellation()
        let warningText = result.warnings.isEmpty ? "" : L10n.text("，跳过 \(result.warnings.count) 项")
        let historyText = currentSnapshot.transactionHistoryStatus.map { L10n.clauseSeparator + L10n.message($0) } ?? ""
        status = .success(context.isCreating
            ? L10n.text("已创建账户，导入 \(result.holdingsCount) 个持仓\(warningText)\(historyText)")
            : L10n.text("已同步 \(result.holdingsCount) 个持仓\(warningText)\(historyText)"))
        if context.isCreating { guideStep = .complete }
        try? setupStore.clear(for: context)
        if !currentSnapshot.hasCompleteTransactionHistory {
            scheduleHistoryRetry(.sync)
        }
    }

    private func invalidatePreview() {
        stopWaiting()
        snapshot = nil
        snapshotRequest = nil
        status = .idle
    }

    private func stopWaiting() {
        operation.cancel()
        historyRetryTask?.cancel()
        historyRetryTask = nil
    }

    private func scheduleHistoryRetry(_ action: Trading212HistoryRetryAction) {
        historyRetryTask?.cancel()
        historyRetryTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(62))
            guard !Task.isCancelled else { return }
            historyRetryTask = nil
            perform(action)
        }
    }

    private func clearCredentials() {
        for key in [Self.apiKeyKey(slot: accountSlot), Self.apiSecretKey(slot: accountSlot)] {
            try? KeychainStore.set("", for: key)
        }
        apiKey = ""
        apiSecret = ""
        snapshot = nil
        snapshotRequest = nil
        historyRetryTask?.cancel()
        historyRetryTask = nil
        status = .idle
    }
}

private enum Trading212ViewStatus {
    case idle

    /// Whether the connection card should give the status a row of its own.
    var isPresented: Bool {
        if case .idle = self { false } else { true }
    }
    case working(String)
    case success(String)
    case failure(String)
}

private enum Trading212HistoryRetryAction: Equatable {
    case preview
    case sync
}

struct Trading212RequestConfiguration: Equatable {
    let accounts: [Trading212AccountCredentials]
    let environment: Trading212Environment
}

/// Owns a sheet request and gates its response before any local import. Some
/// network work can finish after cancellation; an old result must stay inert.
@MainActor @Observable
final class Trading212Operation {
    private(set) var isRunning = false
    @ObservationIgnored private var task: Task<Void, Never>?
    private var generation = UUID()

    @discardableResult
    func start(
        request: Trading212RequestConfiguration,
        fetch: @escaping @MainActor (Trading212RequestConfiguration) async throws -> Trading212Snapshot,
        apply: @escaping @MainActor (Trading212RequestConfiguration, Trading212Snapshot) async throws -> Void,
        onError: @escaping @MainActor (Error) -> Void
    ) -> Task<Void, Never>? {
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
                let result = try await fetch(request)
                try Task.checkCancellation()
                guard self?.generation == id else { return }
                try await apply(request, result)
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
