import SwiftUI

extension EnvironmentValues {
    @Entry var isServiceAPISetupGuide = false
}

/// Launch policy is separate from presentation and does not store credentials.
enum ServiceAPIOnboardingPolicy {
    static let seenKey = "catfolio.service-api-guide.seen.v1"

    static func shouldPresent(hasSeen: Bool, hasAnyAPIKey: Bool, hasConnectedAI: Bool) -> Bool {
        !hasSeen && !hasAnyAPIKey && !hasConnectedAI
    }
}

struct ServiceAPIOnboardingPresenter: ViewModifier {
    @AppStorage(ServiceAPIOnboardingPolicy.seenKey) private var hasSeen = false
    @State private var showsGuide = false
    @State private var hasEvaluated = false
    private let setup = ServiceAPISetupState.shared

    func body(content: Content) -> some View {
        content
            .fullScreenCover(isPresented: $showsGuide) {
                ServiceAPIOnboardingView()
                    .onAppear { hasSeen = true }
            }
            .task {
                guard !hasEvaluated else { return }
                hasEvaluated = true
                #if DEBUG
                // Tests and explicit preview routes keep their original destination.
                guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
                      !LaunchArguments.all.contains(where: { $0.hasPrefix("--") }) else { return }
                #endif
                let hasKey = LocalServiceProvider.allCases.contains {
                    !(KeychainStore.string(for: $0.keychainKey)?
                        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                }
                showsGuide = setup.isPresented || ServiceAPIOnboardingPolicy.shouldPresent(
                    hasSeen: hasSeen, hasAnyAPIKey: hasKey,
                    hasConnectedAI: CodexOAuthClient.cachedConnected)
                if !showsGuide { hasSeen = true }
            }
    }
}

struct ServiceAPIOnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Bindable var setup: ServiceAPISetupState
    private let drafts: ServiceAPIKeyDrafts
    private let trading212SetupStore: Trading212SetupStore
    @State private var showsServices = false

    init(setup: ServiceAPISetupState = .shared, drafts: ServiceAPIKeyDrafts = .shared,
         trading212SetupStore: Trading212SetupStore = .shared) {
        self.setup = setup
        self.drafts = drafts
        self.trading212SetupStore = trading212SetupStore
    }

    var body: some View {
        NavigationStack(path: $setup.path) {
            OnboardingPage(scrollReset: setup.started, progress: OnboardingProgress(step: setup.started ? 2 : 1, total: 3)) {
                if !setup.started {
                    OnboardingHeader(title: L10n.text("欢迎使用 Catfolio"),
                                     subtitle: L10n.text("在一处看清持仓与收益。"))
                    OnboardingFeature(symbol: "chart.pie", title: L10n.text("连接账户"),
                                      detail: L10n.text("导入券商持仓，也可以手动添加。"))
                    OnboardingFeature(symbol: "key.horizontal", title: L10n.text("按需连接服务"),
                                      detail: L10n.text("行情、新闻和 AI，选你需要的就好。"))
                    OnboardingFeature(symbol: "lock", title: L10n.text("密钥由你掌握"),
                                      detail: L10n.text("保存在本机钥匙串，随时可以移除。"))
                } else {
                    OnboardingHeader(title: L10n.text("连接你的账户"),
                                     subtitle: L10n.text("选择券商连接，或通过 CSV 导入。"))
                    VStack(spacing: 20) {
                        ForEach(AddAccountProvider.allCases) { provider in
                            accountLink(provider)
                        }
                    }
                    DisclosureGroup(L10n.text("行情与 AI（可选）"), isExpanded: $showsServices) {
                        VStack(alignment: .leading, spacing: 28) {
                            group(L10n.text("行情与估值"), providers: [.massive, .fmp])
                            group("AI", providers: [.openRouter, .deepSeek, .jev])
                            group(L10n.text("新闻"), providers: [.finnhub])
                            Text(L10n.text("服务商的额度、功能和费用以其账户方案为准。"))
                                .appText(.footnote).foregroundStyle(SettingsTemplate.secondaryText)
                        }
                        .padding(.top, 20)
                    }
                    .appText(.callout, weight: .medium)
                    Text(L10n.text("也可以稍后在账户和设置中继续。"))
                        .appText(.footnote).foregroundStyle(SettingsTemplate.secondaryText)
                }
            } actions: {
                if !setup.started {
                    OnboardingPrimaryButton(title: L10n.text("继续")) { setup.started = true }
                }
                Button(L10n.text("稍后设置")) { setup.isPresented = false; dismiss() }
                    .appText(.callout, weight: .medium)
                if !setup.started {
                    Link(L10n.text("隐私政策"), destination: privacyURL)
                        .appText(.footnote).foregroundStyle(SettingsTemplate.secondaryText)
                }
            }
            .toolbar {
                if setup.started {
                    ToolbarItem(placement: .cancellationAction) {
                        Button {
                            setup.started = false
                        } label: {
                            Label(L10n.text("上一步"), systemImage: "chevron.left")
                        }
                        .accessibilityIdentifier("service-onboarding-back")
                    }
                }
            }
            .navigationDestination(for: ServiceAPISetupState.Step.self) { step in
                if let provider = step.accountProvider {
                    AddAccountDestination(provider: provider, setupStore: trading212SetupStore, isFirstLaunchSetup: true)
                        .environment(\.accountFlowClose, { setup.finish(); dismiss() })
                } else {
                    switch step {
                    case .guide(let provider), .key(let provider):
                        ServiceAPISetupDestination(provider: provider, setup: setup, drafts: drafts,
                            chooseAnother: { setup.path = [] }, finish: { setup.finish(); dismiss() })
                    case .trading212, .ibkr, .account: EmptyView()
                    }
                }
            }
        }
        .tint(CatfolioTheme.primaryText)
        .environment(\.isServiceAPISetupGuide, true)
        .onChange(of: setup.path, initial: true) { _, path in
            switch path.last {
            case .guide, .key: showsServices = true
            default: break
            }
        }
        .onAppear { setup.isPresented = true }
        .onDisappear {
            if scenePhase == .active { setup.isPresented = false }
        }
    }

    private var privacyURL: URL {
        let suffix = AppLanguage.currentIdentifier == "zh-Hans" ? "-zh" : ""
        return URL(string: "https://catfolio-app.vercel.app/privacy\(suffix)")!
    }

    private func accountLink(_ provider: AddAccountProvider) -> some View {
        NavigationLink(value: ServiceAPISetupState.Step.account(provider)) {
            HStack(spacing: 16) {
                AddAccountProviderIcon(provider: provider)
                VStack(alignment: .leading, spacing: 6) {
                    Text(provider.title).appText(.subheading, weight: .semibold)
                    Text(provider.connectionSummary).appText(.body).foregroundStyle(SettingsTemplate.secondaryText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right").appText(.label)
                    .foregroundStyle(SettingsTemplate.secondaryText)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("onboarding-account-\(provider.rawValue)")
    }

    private func group(_ title: String, providers: [LocalServiceProvider]) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(title).appText(.label).foregroundStyle(SettingsTemplate.secondaryText)
            ForEach(providers) { provider in
                NavigationLink(value: ServiceAPISetupState.Step.key(provider)) {
                    HStack(spacing: 12) {
                        OnboardingFeature(symbol: provider.iconName, title: provider.title, detail: provider.purpose)
                        Image(systemName: "chevron.right").appText(.label)
                            .foregroundStyle(SettingsTemplate.secondaryText)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct ServiceAPISetupDestination: View {
    let provider: LocalServiceProvider
    let setup: ServiceAPISetupState
    let drafts: ServiceAPIKeyDrafts
    let chooseAnother: () -> Void
    let finish: () -> Void
    var body: some View {
        LocalServiceDetailView(provider: provider, setup: setup, drafts: drafts,
                               onFinish: finish, onChooseAnother: chooseAnother) { _ in }
    }
}

extension LocalServiceProvider {
    var setupURL: URL {
        let address: String
        switch self {
        case .massive: address = "https://massive.com/dashboard"
        case .fmp: address = "https://site.financialmodelingprep.com/developer/docs"
        case .deepSeek: address = "https://platform.deepseek.com/api_keys"
        case .openRouter: address = "https://openrouter.ai/keys"
        case .finnhub: address = "https://finnhub.io/dashboard"
        case .jev: address = "https://developers.cloudflare.com/workers-ai/get-started/rest-api/"
        }
        return URL(string: address)!
    }
}
