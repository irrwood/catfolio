import SwiftUI

extension EnvironmentValues {
    @Entry var isServiceAPISetupGuide = false
    @Entry var hasSharedOnboardingBackground = false
    @Entry var usesPaywallOnboardingStyle = false
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var setup: ServiceAPISetupState
    private let drafts: ServiceAPIKeyDrafts
    private let trading212SetupStore: Trading212SetupStore
    private let accountSetupNavigation: AccountSetupNavigation?
    @State private var showsServices = false

    init(setup: ServiceAPISetupState = .shared, drafts: ServiceAPIKeyDrafts = .shared,
         trading212SetupStore: Trading212SetupStore = .shared,
         accountSetupNavigation: AccountSetupNavigation? = nil) {
        self.setup = setup
        self.drafts = drafts
        self.trading212SetupStore = trading212SetupStore
        self.accountSetupNavigation = accountSetupNavigation
    }

    var body: some View {
        NavigationStack(path: $setup.path) {
            ZStack {
                if setup.started {
                    introPage(started: true)
                        .transition(reduceMotion ? .identity : .move(edge: .trailing))
                } else {
                    introPage(started: false)
                        .transition(reduceMotion ? .identity : .move(edge: .leading))
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: setup.started)
            .toolbar {
                if setup.started {
                    ToolbarItem(placement: .cancellationAction) {
                        Button { setup.started = false } label: {
                            Label(L10n.text("上一步"), systemImage: "chevron.left")
                        }
                        .tint(.white)
                        .accessibilityIdentifier("service-onboarding-back")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L10n.text("跳过"), action: skip)
                        .accessibilityIdentifier("service-onboarding-skip")
                }
            }
            .environment(\.usesPaywallOnboardingStyle, true)
            .navigationDestination(for: ServiceAPISetupState.Step.self) { step in
                if let provider = step.accountProvider {
                    AddAccountDestination(provider: provider, setupStore: trading212SetupStore,
                                          isFirstLaunchSetup: true, setupNavigation: accountSetupNavigation)
                        .environment(\.accountFlowClose, { setup.finish(); dismiss() })
                        .environment(\.usesPaywallOnboardingStyle, false)
                } else {
                    switch step {
                    case .guide(let provider), .key(let provider):
                        ServiceAPISetupDestination(provider: provider, setup: setup, drafts: drafts,
                            chooseAnother: { setup.path = [] }, finish: { setup.finish(); dismiss() })
                            .environment(\.usesPaywallOnboardingStyle, true)
                            .toolbar {
                                ToolbarItem(placement: .topBarTrailing) {
                                    Button(L10n.text("跳过"), action: skip)
                                        .accessibilityIdentifier("service-onboarding-skip")
                                }
                            }
                    case .trading212, .ibkr, .account: EmptyView()
                    }
                }
            }
        }
        .transaction(value: setup.path) { transaction in
            if reduceMotion { transaction.disablesAnimations = true }
        }
        .background {
            FirstLaunchBackground(stage: backgroundStage)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: backgroundStage)
                .ignoresSafeArea()
        }
        .environment(\.hasSharedOnboardingBackground, true)
        .environment(\.accountFlowTheme, .firstLaunch)
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

    private func introPage(started: Bool) -> some View {
        OnboardingPage(scrollReset: started,
                       progress: started ? nil : OnboardingProgress(step: 1, total: 3),
                       isAccountPreparation: true, showsActions: !started) {
            if !started {
                FirstLaunchIntroHeader(title: L10n.text("欢迎使用 Catfolio"),
                                       subtitle: L10n.text("在一处看清持仓与收益。"), showsAppIcon: true)
                FirstLaunchIntroFeatures()
            } else {
                FirstLaunchIntroHeader(title: L10n.text("连接你的账户"),
                                       subtitle: L10n.text("选择券商连接，或通过 CSV 导入。"))
                VStack(spacing: SettingsTemplate.tileSpacing) {
                    AddAccountOptions { provider in
                        setup.path.append(.account(provider))
                    }
                    FirstLaunchServiceOptions(isExpanded: $showsServices)
                }
                Text(L10n.text("也可以稍后在账户和设置中继续。"))
                    .appText(.footnote).foregroundStyle(.white.opacity(0.82))
            }
        } actions: {
            if !started {
                AccountPreparationNextButton { setup.started = true }
                    .accessibilityIdentifier("service-onboarding-next")
            }
        }
    }

    private var backgroundStage: FirstLaunchBackground.Stage {
        if let provider = setup.path.last?.accountProvider { return .broker(provider) }
        switch setup.path.last {
        case .key(let provider), .guide(let provider): return .service(provider)
        default: return setup.started ? .selection : .welcome
        }
    }

    private func skip() {
        setup.isPresented = false
        dismiss()
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
        case .claude: address = "https://platform.claude.com/settings/keys"
        case .finnhub: address = "https://finnhub.io/dashboard"
        case .jev: address = "https://developers.cloudflare.com/workers-ai/get-started/rest-api/"
        }
        return URL(string: address)!
    }
}
