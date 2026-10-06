import SwiftUI
import UIKit

enum LocalServiceProvider: String, CaseIterable, Identifiable, Hashable {
    case massive
    case fmp
    case deepSeek
    case openRouter
    case finnhub
    case jev

    var id: String { rawValue }

    var title: String {
        switch self {
        case .massive: "Massive"
        case .fmp: "Financial Modeling Prep"
        case .deepSeek: "DeepSeek"
        case .openRouter: "OpenRouter"
        case .finnhub: "Finnhub"
        case .jev: "Jev (Cloudflare)"
        }
    }

    var shortTitle: String {
        switch self {
        case .fmp: "FMP"
        case .jev: "Jev"
        default: title
        }
    }

    var purpose: String {
        switch self {
        case .massive: L10n.text("美股成交量与历史行情")
        case .fmp: L10n.text("估值矩阵与行情备用")
        case .deepSeek: L10n.text("云端问答与自动回退")
        case .openRouter: L10n.text("用一个 Key 调用多家模型")
        case .finnhub: L10n.text("美股公司新闻")
        case .jev: L10n.text("JEV 今日关注的买卖判断")
        }
    }

    var detail: String {
        switch self {
        case .massive:
            L10n.text("读取美股价格和成交量。")
        case .fmp:
            L10n.text("读取估值数据，备用历史行情。")
        case .deepSeek:
            L10n.text("组合摘要和问题会发送给 DeepSeek。")
        case .openRouter:
            L10n.text("组合摘要和问题会经 OpenRouter 发送给所选模型。")
        case .finnhub:
            L10n.text("仅发送股票代码，读取公司新闻。")
        case .jev:
            L10n.text("发送行情、仓位占比和盈亏比例；不发送账户、股数或金额。")
        }
    }

    var keychainKey: String {
        switch self {
        case .massive: LocalServiceKeys.massive
        case .fmp: LocalServiceKeys.fmp
        case .deepSeek: LocalServiceKeys.deepSeek
        case .openRouter: LocalServiceKeys.openRouter
        case .finnhub: LocalServiceKeys.finnhub
        case .jev: LocalServiceKeys.cloudflareAIToken
        }
    }

    var iconName: String {
        switch self {
        case .massive: "chart.bar.xaxis"
        case .fmp: "chart.xyaxis.line"
        case .deepSeek: "sparkles"
        case .openRouter: "arrow.triangle.branch"
        case .finnhub: "newspaper"
        case .jev: "bolt.fill"
        }
    }

    var tint: Color {
        switch self {
        case .massive: CatfolioTheme.accent
        case .fmp: CatfolioTheme.warning
        case .deepSeek, .openRouter: CatfolioTheme.services
        case .finnhub: CatfolioTheme.accent
        case .jev: CatfolioTheme.services
        }
    }

    func validate(apiKey: String) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                try await performValidation(apiKey: apiKey)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 35_000_000_000)
                throw LocalServiceError.remote(L10n.text("验证超时，请检查网络后重试"))
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw LocalServiceError.invalidResponse
            }
            return result
        }
    }

    private func performValidation(apiKey: String) async throws -> String {
        switch self {
        case .massive:
            let sessions = try await LocalMarketDataClient().testMassiveConnection(apiKey: apiKey)
            return L10n.text("连接成功，已读取 AAPL 的 \(sessions) 个交易日")
        case .fmp:
            return try await LocalReturnsAnalyticsClient().testFMPValuationConnection(apiKey: apiKey)
        case .deepSeek:
            try await LocalAIClient().testDeepSeekConnection(apiKey: apiKey)
            return L10n.text("连接成功，DeepSeek 模型列表可用")
        case .openRouter:
            try await LocalAIClient().testOpenRouterConnection(apiKey: apiKey)
            return L10n.text("连接成功，OpenRouter Key 可用")
        case .finnhub:
            let items = try await FinnhubNewsProvider.companyNews(symbol: "AAPL", days: 7, apiKey: apiKey)
            return L10n.text("连接成功，已读取 AAPL 的 \(items.count) 条新闻")
        case .jev:
            try await JEVClient(provider: .cloudflare, apiToken: apiKey).test()
            return L10n.text("连接成功，Jev 可用")
        }
    }
}

enum LocalServiceStatus: Equatable {
    case unconfigured
    case configured
    case verified

    var title: String {
        switch self {
        case .unconfigured: L10n.text("未配置")
        case .configured: L10n.text("已配置")
        case .verified: L10n.text("验证通过")
        }
    }

    var iconName: String {
        switch self {
        case .unconfigured: "circle"
        case .configured: "checkmark.circle"
        case .verified: "checkmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .unconfigured: .secondary
        case .configured, .verified: CatfolioTheme.positive
        }
    }
}

/// Connection state belongs beside the entire provider description, aligned
/// with the disclosure arrow. At accessibility sizes it gets its own line.
struct LocalServiceRowLabel: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let iconName: String
    let title: String
    let subtitle: String
    let status: String
    let statusColor: Color
    /// Configured or connected: a check stands in for the words, which the
    /// row still gives VoiceOver.
    var isReady = false

    @ViewBuilder private var statusText: some View {
        if isReady {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(statusColor)
                .accessibilityLabel(status)
        } else {
            Text(status)
                .appText(.subheading)
                .foregroundStyle(statusColor)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: true)
        }
    }

    var body: some View {
        SettingsRowContainer {
            HStack(alignment: .center, spacing: SettingsTemplate.iconSpacing) {
                VStack(alignment: .leading, spacing: SettingsTemplate.subtitleSpacing) {
                    SettingsRowLabel(icon: .symbol(iconName), title: title,
                        subtitle: subtitle, subtitleSpacing: 2)
                    if dynamicTypeSize.isAccessibilitySize {
                        statusText.padding(.leading, SettingsTemplate.iconSize + SettingsTemplate.iconSpacing)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if !dynamicTypeSize.isAccessibilitySize {
                    statusText
                }
                SettingsChevron()
            }
        }
    }
}

struct LocalServicesSettingsView: View {
    @Environment(\.locale) private var appLocale
    @AppStorage(AIProviderPreference.storageKey) private var aiProviderRaw = AIProviderPreference.automatic.rawValue
    @AppStorage(CodexOAuthClient.connectedStorageKey) private var codexConnected = false
    /// A provider opened by launch argument rather than a tap.
    @State private var routedProvider: LocalServiceProvider?
    @State private var statuses: [LocalServiceProvider: LocalServiceStatus] = [:]
    @State private var hasAppliedLaunchRoute = false

    @State private var showsAPISetupGuide = false

    /// A page of Settings' own stack, not a modal with a stack of its own.
    var body: some View {
            SettingsPage(
                title: L10n.text("服务商"),
                bottomInset: 32
            ) {
                SettingsCard {
                    SettingsButtonRow(icon: .symbol("list.number"), title: L10n.text("API 配置引导")) {
                        showsAPISetupGuide = true
                    }
                }

                SettingsSection(L10n.text("行情与估值")) {
                    providerLink(.massive)
                    providerLink(.fmp)
                }

                SettingsSection(L10n.text("新闻")) {
                    providerLink(.finnhub)
                }

                SettingsSectionHeader("AI")
                SettingsCard {
                    // The one row on these pages that is not a row: choosing a
                    // model is a choice between five — too many to segment on
                    // a phone — so the choice is a menu at the row's trailing
                    // edge. It sits on the card's own 20/16 padding so it
                    // lines up with every row under it.
                    SettingsRowContainer(minHeight: 0) {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text(L10n.text("默认模型"))
                                    .appText(.label, weight: .medium)
                                    .foregroundStyle(SettingsTemplate.sectionHeader)
                                Spacer(minLength: 12)
                                Picker(L10n.text("默认模型"), selection: $aiProviderRaw) {
                                    ForEach(AIProviderPreference.allCases) { provider in
                                        Text(L10n.label(provider.title)).tag(provider.rawValue)
                                    }
                                }
                                .pickerStyle(.menu)
                                .labelsHidden()
                                .padding(.trailing, -12)
                            }

                            Text(selectedAIProvider.detail)
                                .appText(.label, weight: .regular)
                                .foregroundStyle(SettingsTemplate.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)

                            if selectedAIProvider == .automatic || selectedAIProvider == .apple {
                                Text(LocalAIClient.appleModelStatus.message)
                                    .appText(.label, weight: .medium)
                                    .foregroundStyle(
                                        LocalAIClient.appleModelStatus.isAvailable
                                            ? CatfolioTheme.positive
                                            : SettingsTemplate.secondaryText
                                    )
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }

                    codexLink
                    providerLink(.openRouter)
                    providerLink(.deepSeek)
                    providerLink(.jev)
                }
            }
            .sheet(isPresented: $showsAPISetupGuide, onDismiss: refreshStatuses) {
                ServiceAPIOnboardingView()
            }
            .navigationDestination(item: $routedProvider) { provider in detail(provider) }
            .hidesTabBarWhenPushed()
            .onAppear {
                refreshStatuses()
                applyLaunchRouteIfNeeded()
            }
            .tint(CatfolioTheme.accent)
    }

    private func detail(_ provider: LocalServiceProvider) -> some View {
        LocalServiceDetailView(provider: provider) { status in
            statuses[provider] = status
        }
        .hidesTabBarWhenPushed()
    }

    private var selectedAIProvider: AIProviderPreference {
        AIProviderPreference(rawValue: aiProviderRaw) ?? .automatic
    }

    private var codexLink: some View {
        NavigationLink {
            CodexOAuthSettingsView()
                .hidesTabBarWhenPushed()
        } label: {
            LocalServiceRowLabel(iconName: "bubble.left.and.text.bubble.right",
                title: "ChatGPT Codex", subtitle: L10n.text("使用 ChatGPT 订阅进行组合问答"),
                status: codexConnected ? L10n.text("已连接") : L10n.text("未连接"),
                statusColor: codexConnected ? CatfolioTheme.positive : SettingsTemplate.readOnlyValue,
                isReady: codexConnected)
        }
        .buttonStyle(SettingsRowButtonStyle())
        .accessibilityLabel(L10n.text("ChatGPT Codex，使用 ChatGPT 订阅进行组合问答"))
        .accessibilityValue(codexConnected ? L10n.text("已连接") : L10n.text("未连接"))
    }

    private func providerLink(_ provider: LocalServiceProvider) -> some View {
        let status = statuses[provider] ?? .unconfigured
        return NavigationLink {
            detail(provider)
        } label: {
            LocalServiceRowLabel(iconName: provider.iconName,
                title: provider.shortTitle, subtitle: provider.purpose,
                status: status.title,
                statusColor: status == .unconfigured ? SettingsTemplate.readOnlyValue : status.color,
                isReady: status != .unconfigured)
        }
        .buttonStyle(SettingsRowButtonStyle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.text("\(provider.title)，\(provider.purpose)"))
        .accessibilityValue(status.title)
        .accessibilityHint(L10n.text("打开服务商设置"))
    }

    private func refreshStatuses() {
        for provider in LocalServiceProvider.allCases {
            let key = KeychainStore.string(for: provider.keychainKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if statuses[provider] != .verified {
                statuses[provider] = key.isEmpty ? .unconfigured : .configured
            }
        }
    }

    private func applyLaunchRouteIfNeeded() {
        guard !hasAppliedLaunchRoute else { return }
        hasAppliedLaunchRoute = true
        let arguments = LaunchArguments.all
        if arguments.contains("--show-local-service-massive") {
            routedProvider = .massive
        } else if arguments.contains("--show-local-service-fmp") {
            routedProvider = .fmp
        } else if arguments.contains("--show-local-service-deepseek") {
            routedProvider = .deepSeek
        } else if arguments.contains("--show-local-service-openrouter") {
            routedProvider = .openRouter
        } else if arguments.contains("--show-local-service-finnhub") {
            routedProvider = .finnhub
        } else if arguments.contains("--show-local-service-jev") {
            routedProvider = .jev
        }
    }
}

struct CodexOAuthSettingsView: View {
    @Environment(\.locale) private var appLocale
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL
    @AppStorage(CodexOAuthClient.connectedStorageKey) private var connected = false
    @AppStorage(CodexOAuthClient.accountEmailStorageKey) private var accountEmail = ""
    @AppStorage(CodexOAuthClient.accountPlanStorageKey) private var accountPlan = ""
    @AppStorage(CodexOAuthClient.modelStorageKey) private var codexModel = ""
    @State private var showsModelPicker = false

    @State private var loginSession: CodexLoginSession?
    @State private var isWorking = false
    @State private var feedback: LocalServiceFeedback?
    @State private var pollingTask: Task<Void, Never>?
    @State private var didCopyCode = false

    var body: some View {
        SettingsPage(
            title: "ChatGPT Codex",
            bottomInset: 32
        ) {
            SettingsSectionHeader(L10n.text("连接状态"))
            SettingsCard {
                SettingsRowContainer {
                    HStack(spacing: SettingsTemplate.iconSpacing) {
                        SettingsRowIcon(.symbol("bubble.left.and.text.bubble.right"))
                        VStack(alignment: .leading, spacing: SettingsTemplate.subtitleSpacing) {
                            Text(connected ? L10n.text("已连接 ChatGPT") : L10n.text("尚未连接"))
                                .appText(.subheading)
                                .foregroundStyle(CatfolioTheme.primaryText)
                            if connected && (!accountEmail.isEmpty || !planLabel.isEmpty) {
                                Text([accountEmail, planLabel].filter { !$0.isEmpty }.joined(separator: " · "))
                                    .appText(.label, weight: .regular)
                                    .foregroundStyle(SettingsTemplate.secondaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                }
            }

            if connected {
                SettingsSectionHeader(L10n.text("模型"))
                SettingsCard {
                    SettingsButtonRow(icon: .symbol("cpu"), title: L10n.text("选择模型"),
                                      value: codexModel.isEmpty ? L10n.text("默认") : codexModel) {
                        showsModelPicker = true
                    }
                }
                SettingsFootnote(L10n.text("列表来自你的 ChatGPT 账户。所选模型下线时，会自动换成可用的模型。"))
            }

            if let loginSession {
                SettingsSectionHeader(L10n.text("一次性验证码"))
                SettingsCard {
                    SettingsRowContainer {
                        HStack(spacing: SettingsTemplate.iconSpacing) {
                            Text(loginSession.userCode)
                                .font(.title2.monospaced().weight(.bold))
                                .textSelection(.enabled)
                            Spacer(minLength: 8)
                            Button(didCopyCode ? L10n.text("已复制") : L10n.text("复制")) {
                                UIPasteboard.general.string = loginSession.userCode
                                didCopyCode = true
                                UINotificationFeedbackGenerator().notificationOccurred(.success)
                                Task {
                                    try? await Task.sleep(for: .seconds(1.4))
                                    didCopyCode = false
                                }
                            }
                            .appText(.subheading)
                            .foregroundStyle(didCopyCode ? CatfolioTheme.positive : CatfolioTheme.accent)
                        }
                    }
                }

                Button(L10n.text("打开 ChatGPT 登录页"), systemImage: "safari") {
                    openURL(loginSession.verificationURL)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.roundedRectangle(radius: SettingsTemplate.cardRadius))
                .controlSize(.large)
                .frame(maxWidth: .infinity)
            }

            if let feedback {
                StatusNotice(text: feedback.text, kind: feedback.kind)
            }

            if connected {
                SettingsCard {
                    SettingsButtonRow(
                        icon: .symbol("rectangle.portrait.and.arrow.right"),
                        title: isWorking ? L10n.text("正在断开…") : L10n.text("退出 ChatGPT"),
                        showsChevron: false,
                        showsProgress: isWorking,
                        role: .destructive,
                        action: logout
                    )
                    .disabled(isWorking)
                }
            } else {
                Button(action: startLogin) {
                    HStack(spacing: 8) {
                        if isWorking { ProgressView().tint(.white) }
                        Text(isWorking ? L10n.text("等待网页授权…") : L10n.text("登录 ChatGPT"))
                            .appText(.subheading, weight: .semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 54)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.roundedRectangle(radius: SettingsTemplate.cardRadius))
                .disabled(isWorking)
            }
        }
        .task { await refreshStatus() }
        .onDisappear {
            pollingTask?.cancel()
            pollingTask = nil
        }
        .appSheet(isPresented: $showsModelPicker) {
            AIModelPickerView(provider: nil, loader: { try await CodexOAuthClient().availableModels() },
                              key: nil, defaultModel: CodexOAuthClient.defaultModel, selection: $codexModel)
        }
    }

    private var planLabel: String {
        guard !accountPlan.isEmpty else { return "" }
        return accountPlan == "plus" ? "Plus" : accountPlan.capitalized
    }

    private func startLogin() {
        pollingTask?.cancel()
        isWorking = true
        feedback = nil
        pollingTask = Task {
            do {
                let client = CodexOAuthClient()
                let session = try await client.startLogin()
                guard !Task.isCancelled else { return }
                loginSession = session
                UIPasteboard.general.string = session.userCode
                openURL(session.verificationURL)
                try await waitForLogin(client: client, session: session)
            } catch is CancellationError {
                isWorking = false
            } catch {
                isWorking = false
                feedback = LocalServiceFeedback(text: error.localizedDescription, kind: .error)
            }
            pollingTask = nil
        }
    }

    private func refreshStatus() async {
        do {
            let client = CodexOAuthClient()
            let status = try await client.status()
            connected = status.connected
            if status.pending,
               pollingTask == nil,
               let session = try client.pendingLoginSession() {
                loginSession = session
                resumeLogin(client: client, session: session)
            }
        } catch {
            connected = false
        }
    }

    private func resumeLogin(client: CodexOAuthClient, session: CodexLoginSession) {
        pollingTask?.cancel()
        isWorking = true
        feedback = LocalServiceFeedback(text: L10n.text("正在确认网页授权…"), kind: .info)
        pollingTask = Task {
            do {
                try await waitForLogin(client: client, session: session, pollImmediately: true)
            } catch is CancellationError {
                isWorking = false
            } catch {
                isWorking = false
                feedback = LocalServiceFeedback(text: error.localizedDescription, kind: .error)
            }
            pollingTask = nil
        }
    }

    private func waitForLogin(
        client: CodexOAuthClient,
        session: CodexLoginSession,
        pollImmediately: Bool = false
    ) async throws {
        for attempt in 0..<150 {
            if !pollImmediately || attempt > 0 {
                try await Task.sleep(for: .seconds(session.intervalSeconds))
            }
            let status: CodexConnectionStatus
            do {
                status = try await client.status(loginID: session.loginID)
            } catch let error where CodexOAuthClient.isTransientNetworkError(error) {
                continue
            }
            guard !Task.isCancelled else { throw CancellationError() }
            if status.connected {
                connected = true
                loginSession = nil
                isWorking = false
                feedback = LocalServiceFeedback(text: L10n.text("ChatGPT 已连接"), kind: .success)
                return
            }
            if let error = status.error, !status.pending {
                throw LocalServiceError.remote(error)
            }
        }
        throw LocalServiceError.remote(L10n.text("登录等待超时，请重新开始"))
    }

    private func logout() {
        isWorking = true
        feedback = nil
        Task {
            do {
                try await CodexOAuthClient().logout()
                connected = false
                loginSession = nil
                feedback = LocalServiceFeedback(text: L10n.text("已退出 ChatGPT"), kind: .success)
            } catch {
                feedback = LocalServiceFeedback(text: error.localizedDescription, kind: .error)
            }
            isWorking = false
        }
    }
}

struct LocalServiceFeedback {
    let text: String
    let kind: StatusNotice.Kind
}

struct LocalServiceDetailView: View {
    @Environment(\.locale) private var appLocale
    @Environment(\.colorScheme) private var colorScheme
    let provider: LocalServiceProvider
    let onStatusChanged: (LocalServiceStatus) -> Void

    @State private var apiKey = ""
    @State private var originalKey = ""
    @State private var revealsKey = false
    @State private var isTesting = false
    @State private var feedback: LocalServiceFeedback?
    @State private var showsRemoveConfirmation = false
    @State private var hasLoaded = false
    @State private var validationTask: Task<Void, Never>?
    @AppStorage(LocalServiceKeys.openRouterModel) private var openRouterModel = ""
    @AppStorage(LocalServiceKeys.deepSeekModel) private var deepSeekModel = ""
    @State private var showsModelPicker = false
    @AppStorage(LocalServiceKeys.cloudflareAccountIDKey) private var cloudflareAccountID = ""

    private var trimmedKey: String {
        apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var modelBinding: Binding<String> {
        provider == .deepSeek ? $deepSeekModel : $openRouterModel
    }

    private var defaultModel: String {
        provider == .deepSeek ? LocalServiceKeys.defaultDeepSeekModel : LocalServiceKeys.defaultOpenRouterModel
    }

    private var keyPlaceholder: String {
        provider == .jev ? L10n.text("输入 Cloudflare API Token") : L10n.text("输入 \(provider.shortTitle) API Key")
    }

    var body: some View {
        SettingsPage(title: provider.shortTitle, bottomInset: 32) {
            SettingsSectionHeader(L10n.text("服务用途"))
            SettingsCard {
                SettingsRowContainer {
                    HStack(alignment: .top, spacing: SettingsTemplate.iconSpacing) {
                        SettingsRowIcon(.symbol(provider.iconName))
                        VStack(alignment: .leading, spacing: SettingsTemplate.subtitleSpacing) {
                            Text(provider.title)
                                .appText(.subheading)
                                .foregroundStyle(CatfolioTheme.primaryText)
                            Text(provider.detail)
                                .appText(.label, weight: .regular)
                                .foregroundStyle(SettingsTemplate.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }

            SettingsSectionHeader(L10n.text("API 密钥"))
            SettingsCard {
                SettingsRowContainer {
                    HStack(spacing: SettingsTemplate.iconSpacing) {
                        Group {
                            if revealsKey {
                                TextField(keyPlaceholder, text: $apiKey)
                            } else {
                                SecureField(keyPlaceholder, text: $apiKey)
                            }
                        }
                        .font(.body.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.password)
                        .submitLabel(.done)

                        // On the icon artboard and in the row's own greys, so
                        // the control reads as part of the row rather than a
                        // tinted button dropped into it.
                        Button {
                            revealsKey.toggle()
                        } label: {
                            SettingsRowIcon(.symbol(revealsKey ? "eye.slash" : "eye"))
                                .foregroundStyle(SettingsTemplate.secondaryText)
                                .padding(.vertical, SettingsTemplate.rowVerticalPadding)
                                .contentShape(Rectangle())
                                .padding(.vertical, -SettingsTemplate.rowVerticalPadding)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(revealsKey ? L10n.text("隐藏 API 密钥") : L10n.text("显示 API 密钥"))
                    }
                }
                .disabled(isTesting)
            }
            SettingsFootnote(L10n.text("仅保存在此 iPhone 的 Keychain"))

            if provider == .jev {
                SettingsSectionHeader("Account ID")
                SettingsCard {
                    SettingsRowContainer {
                        TextField(L10n.text("Cloudflare Account ID"), text: $cloudflareAccountID)
                            .font(.body.monospaced())
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.done)
                    }
                }
                SettingsFootnote(L10n.text("Account ID 和 API Token 可在 Cloudflare 控制台获取。"))
            }

            if AIModelCatalog.supports(provider) {
                SettingsSectionHeader(L10n.text("模型"))
                SettingsCard {
                    SettingsButtonRow(icon: .symbol("list.bullet.rectangle"), title: L10n.text("获取模型"),
                                      value: modelBinding.wrappedValue.isEmpty ? L10n.text("默认") : modelBinding.wrappedValue) {
                        showsModelPicker = true
                    }
                    .accessibilityIdentifier("local-service.model-picker")
                    SettingsRowContainer {
                        TextField(defaultModel, text: modelBinding)
                            .font(.body.monospaced())
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .submitLabel(.done)
                    }
                }
                SettingsFootnote(L10n.text("从服务商读取可用模型后选择，也可直接填写模型 ID；留空使用 \(defaultModel)。"))
            }

            if let feedback {
                StatusNotice(text: feedback.text, kind: feedback.kind)
            }

            VStack(spacing: 12) {
                Button {
                    startValidation()
                } label: {
                    HStack(spacing: 9) {
                        if isTesting {
                            ProgressView()
                                .tint(.white)
                        }
                        Text(isTesting ? L10n.text("正在验证…") : L10n.text("保存并验证"))
                            .appText(.subheading, weight: .semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 54)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.roundedRectangle(radius: SettingsTemplate.cardRadius))
                .tint(CatfolioTheme.accent)
                .disabled(trimmedKey.isEmpty || isTesting || (provider == .jev && cloudflareAccountID.trimmingCharacters(in: .whitespaces).isEmpty))
                .accessibilityLabel(isTesting ? L10n.text("正在验证") : L10n.text("保存并验证"))
                .accessibilityHint(L10n.text("保存 API 密钥并验证连接"))

                Button {
                    saveWithoutValidation()
                } label: {
                    Text(L10n.text("仅保存，不验证"))
                        .appText(.subheading, weight: .semibold)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 52)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.roundedRectangle(radius: SettingsTemplate.cardRadius))
                .tint(CatfolioTheme.accent)
                .disabled(trimmedKey.isEmpty || isTesting)
                .accessibilityLabel(L10n.text("仅保存，不验证"))
                .accessibilityHint(L10n.text("保存 API 密钥但不验证连接"))
            }

            if !originalKey.isEmpty {
                SettingsCard {
                    SettingsButtonRow(
                        icon: .symbol("trash"),
                        title: L10n.text("移除此密钥"),
                        showsChevron: false,
                        role: .destructive
                    ) {
                        showsRemoveConfirmation = true
                    }
                    .disabled(isTesting)
                }
            }
        }
        .onAppear { loadKeyIfNeeded() }
        .onDisappear {
            validationTask?.cancel()
            validationTask = nil
        }
        .onChange(of: apiKey) { _, newValue in
            let edited = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if edited != originalKey { feedback = nil }
        }
        .appSheet(isPresented: $showsModelPicker) {
            AIModelPickerView(provider: provider, key: trimmedKey.isEmpty ? nil : trimmedKey,
                              defaultModel: defaultModel, selection: modelBinding)
        }
        .confirmationDialog(
            L10n.text("移除 \(provider.title) 密钥？"),
            isPresented: $showsRemoveConfirmation,
            titleVisibility: .visible
        ) {
            Button(L10n.text("移除密钥"), role: .destructive) { removeKey() }
            Button(L10n.text("取消"), role: .cancel) {}
        } message: {
            Text(L10n.text("移除后，依赖此服务的数据可能无法加载。"))
        }
    }

    private func loadKeyIfNeeded() {
        guard !hasLoaded else { return }
        hasLoaded = true
        let saved = KeychainStore.string(for: provider.keychainKey) ?? ""
        apiKey = saved
        originalKey = saved
    }

    @MainActor
    private func saveAndValidate() async {
        guard !trimmedKey.isEmpty else { return }
        let candidate = trimmedKey
        isTesting = true
        feedback = nil
        defer { isTesting = false }

        do {
            let message = try await provider.validate(apiKey: candidate)
            try Task.checkCancellation()
            do {
                try KeychainStore.set(candidate, for: provider.keychainKey)
            } catch {
                let saveMessage = L10n.text("连接已验证，但无法保存到 Keychain：\(error.localizedDescription)")
                feedback = LocalServiceFeedback(text: saveMessage, kind: .error)
                announce(saveMessage)
                return
            }
            originalKey = candidate
            if provider == .fmp {
                await LocalReturnsAnalyticsClient.resetFailedFundamentalAttempts()
            }
            feedback = LocalServiceFeedback(text: message, kind: .success)
            onStatusChanged(.verified)
            announce(message)
            ToastCenter.shared.show(L10n.text("已验证并保存"))
        } catch is CancellationError {
            return
        } catch {
            let suffix = originalKey.isEmpty ? L10n.text("未保存这次输入。") : L10n.text("原密钥未更改。")
            let message = "\(error.localizedDescription) \(suffix)"
            feedback = LocalServiceFeedback(text: message, kind: .error)
            announce(L10n.text("验证失败。\(message)"))
            ToastCenter.shared.show(L10n.text("验证失败"), kind: .error)
        }
    }

    private func startValidation() {
        guard !isTesting else { return }
        validationTask?.cancel()
        validationTask = Task { await saveAndValidate() }
    }

    private func saveWithoutValidation() {
        guard !trimmedKey.isEmpty else { return }
        do {
            try KeychainStore.set(trimmedKey, for: provider.keychainKey)
            originalKey = trimmedKey
            feedback = LocalServiceFeedback(text: L10n.text("已安全保存到此 iPhone"), kind: .success)
            onStatusChanged(.configured)
            if provider == .fmp {
                Task { await LocalReturnsAnalyticsClient.resetFailedFundamentalAttempts() }
            }
            ToastCenter.shared.show(L10n.text("密钥已保存"))
        } catch {
            feedback = LocalServiceFeedback(text: error.localizedDescription, kind: .error)
            announce(L10n.text("保存失败。\(error.localizedDescription)"))
            ToastCenter.shared.show(L10n.text("保存失败"), kind: .error)
        }
    }

    private func removeKey() {
        do {
            try KeychainStore.set("", for: provider.keychainKey)
            apiKey = ""
            originalKey = ""
            revealsKey = false
            feedback = LocalServiceFeedback(text: L10n.text("密钥已从此 iPhone 移除"), kind: .info)
            onStatusChanged(.unconfigured)
            if provider == .fmp {
                Task { await LocalReturnsAnalyticsClient.resetFailedFundamentalAttempts() }
            }
            ToastCenter.shared.show(L10n.text("密钥已移除"), kind: .info)
        } catch {
            feedback = LocalServiceFeedback(text: error.localizedDescription, kind: .error)
            announce(L10n.text("移除失败。\(error.localizedDescription)"))
        }
    }

    private func announce(_ message: String) {
        UIAccessibility.post(notification: .announcement, argument: message)
    }
}

/// The tinted rounded-square an iOS settings row puts its symbol in.
///
/// The rows previously drew a bare tinted glyph, which left each symbol a
/// different optical weight and width — a `globe` outline and a
/// `chart.pie.fill` next to each other read as two different kinds of
/// control. Boxing them equalises that: the tile is the constant, the symbol
/// varies inside it, and the row's text starts at the same x every time.

/// The provider's current models, read when the sheet opens, searchable;
/// a tap picks one and closes.
struct AIModelPickerView: View {
    @Environment(\.dismiss) private var dismiss
    let provider: LocalServiceProvider?
    /// Reads the list itself, for a provider with its own sign-in (Codex).
    var loader: (() async throws -> [AIModelOption])? = nil
    /// The key typed on the page, before it is saved; else the stored one.
    let key: String?
    let defaultModel: String
    @Binding var selection: String
    @State private var models: [AIModelOption] = []
    @State private var query = ""
    @State private var isLoading = true
    @State private var error: String?

    private var filtered: [AIModelOption] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return models }
        return models.filter { $0.id.localizedCaseInsensitiveContains(text) || $0.name.localizedCaseInsensitiveContains(text) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    row(id: "", title: L10n.text("默认（\(defaultModel)）"), subtitle: nil)
                }
                if isLoading {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text(L10n.text("正在获取模型…")).foregroundStyle(.secondary)
                    }
                } else if let error {
                    Section {
                        Text(L10n.message(error)).foregroundStyle(.secondary)
                        Button(L10n.text("重试")) { Task { await load() } }
                    }
                } else {
                    Section(L10n.text("\(models.count) 个模型")) {
                        ForEach(filtered) { model in
                            row(id: model.id, title: model.name, subtitle: model.name == model.id ? nil : model.id)
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: L10n.text("搜索模型"))
            .navigationTitle(L10n.text("选择模型"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { AppModalDoneButton { dismiss() } }
            }
            .task { await load() }
        }
    }

    private func row(id: String, title: String, subtitle: String?) -> some View {
        Button {
            selection = id
            dismiss()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(CatfolioTheme.primaryText)
                    if let subtitle {
                        Text(subtitle).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                if selection.trimmingCharacters(in: .whitespacesAndNewlines) == id {
                    Image(systemName: "checkmark").foregroundStyle(CatfolioTheme.accent)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func load() async {
        isLoading = true
        error = nil
        do {
            if let loader {
                models = try await loader()
            } else if let provider {
                let storedKey = KeychainStore.string(for: provider.keychainKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
                models = try await AIModelCatalog.fetch(provider, key: key ?? storedKey)
            }
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }
}
