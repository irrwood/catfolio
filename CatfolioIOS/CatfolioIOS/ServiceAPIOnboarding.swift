import SwiftUI

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
                showsGuide = ServiceAPIOnboardingPolicy.shouldPresent(
                    hasSeen: hasSeen, hasAnyAPIKey: hasKey,
                    hasConnectedAI: CodexOAuthClient.cachedConnected)
                if !showsGuide { hasSeen = true }
            }
    }
}

struct ServiceAPIOnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var path: [LocalServiceProvider] = []
    @State private var started = false

    var body: some View {
        NavigationStack(path: $path) {
            SettingsPage(title: L10n.text("配置行情与 AI"), bottomInset: 32) {
                if !started {
                    SettingsCard {
                        SettingsRowContainer {
                            VStack(alignment: .leading, spacing: 16) {
                                Image(systemName: "key.horizontal").font(.largeTitle)
                                    .accessibilityHidden(true)
                                Text(L10n.text("让 Catfolio 连接你需要的服务"))
                                    .font(.title2.weight(.bold))
                                Text(L10n.text("API Key 是服务商提供的访问密钥。添加后，可以使用对应的行情、新闻或 AI 功能。"))
                                    .appText(.subheading)
                                Text(L10n.text("按需配置一个即可，不必一次填完。也可以稍后在设置 › 服务商中继续。"))
                                    .appText(.label).foregroundStyle(SettingsTemplate.secondaryText)
                            }
                        }
                    }
                    GlassPrimaryButton(title: L10n.text("开始配置"), systemImage: "arrow.right") {
                        started = true
                    }
                } else {
                    SettingsFootnote(L10n.text("选择需要的功能，再获取对应服务商的 Key。"))
                    group(L10n.text("行情与估值"), providers: [.massive, .fmp])
                    group("AI", providers: [.openRouter, .deepSeek, .jev])
                    group(L10n.text("新闻"), providers: [.finnhub])
                    SettingsFootnote(L10n.text("服务商的额度、功能和费用以其账户方案为准。"))
                }
            }
            .navigationDestination(for: LocalServiceProvider.self) { provider in
                APIKeySetupGuide(title: provider.title, purpose: provider.purpose,
                                 detail: provider.detail, consoleURL: provider.setupURL,
                                 extraInstruction: provider == .jev
                                    ? L10n.text("Cloudflare 需要 Workers AI 的 API Token 和 Account ID，请一并准备。") : nil) {
                    ServiceAPISetupDestination(provider: provider, chooseAnother: { path = [] }, finish: { dismiss() })
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.text("稍后设置")) { dismiss() }
                }
            }
        }
        .tint(CatfolioTheme.accent)
    }

    private func group(_ title: String, providers: [LocalServiceProvider]) -> some View {
        SettingsSection(title) {
            ForEach(providers) { provider in
                NavigationLink(value: provider) {
                    SettingsRowContainer {
                        HStack(spacing: 12) {
                            Image(systemName: provider.iconName).frame(width: 24)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(provider.title).appText(.subheading)
                                Text(provider.purpose).appText(.label)
                                    .foregroundStyle(SettingsTemplate.secondaryText)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        }
                    }
                }
                .buttonStyle(SettingsRowButtonStyle())
            }
        }
    }
}

/// Reusable explanation and acquisition steps. The caller supplies its existing form.
struct APIKeySetupGuide<Destination: View>: View {
    let title: String
    let purpose: String
    let detail: String
    let consoleURL: URL
    var extraInstruction: String? = nil
    @ViewBuilder let destination: () -> Destination

    var body: some View {
        SettingsPage(title: title, bottomInset: 32) {
            SettingsSectionHeader(L10n.text("1 · 了解用途"))
            SettingsCard {
                SettingsRowContainer {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(purpose).appText(.subheading, weight: .semibold)
                        Text(detail).appText(.label).foregroundStyle(SettingsTemplate.secondaryText)
                    }
                }
            }
            SettingsSectionHeader(L10n.text("2 · 获取 API Key"))
            SettingsCard {
                SettingsRowContainer {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(L10n.text("打开服务商官网，登录或注册后，在控制台的 API Keys 页面创建或复制密钥。"))
                        if let extraInstruction { Text(extraInstruction) }
                        Text(L10n.text("复制后回到 Catfolio。无需填写服务商登录密码。"))
                    }
                    .appText(.subheading)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Link(destination: consoleURL) {
                    SettingsRowContainer {
                        Label(L10n.text("打开服务商官网"), systemImage: "arrow.up.right.square")
                    }
                }
                .buttonStyle(SettingsRowButtonStyle())
            }
            SettingsSectionHeader(L10n.text("3 · 填写并验证"))
            SettingsFootnote(L10n.text("下一步粘贴 Key，选择保存并验证。验证失败时可以修改重试，或选择仅保存。密钥保存在此 iPhone 的 Keychain 中。"))
            NavigationLink(destination: destination) {
                Text(L10n.text("已有 Key，继续填写"))
                    .frame(maxWidth: .infinity).padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

private struct ServiceAPISetupDestination: View {
    let provider: LocalServiceProvider
    let chooseAnother: () -> Void
    let finish: () -> Void
    @State private var status: LocalServiceStatus = .unconfigured

    var body: some View {
        LocalServiceDetailView(provider: provider) { status = $0 }
            .safeAreaInset(edge: .bottom) {
                if status != .unconfigured {
                    VStack(spacing: 10) {
                        Text(status == .verified ? L10n.text("验证通过，可以开始使用") : L10n.text("已保存，连接尚未验证"))
                            .appText(.label)
                        GlassPrimaryButton(title: L10n.text("完成配置"), action: finish)
                        Button(L10n.text("继续配置其他服务"), action: chooseAnother)
                    }
                    .padding(16)
                    .background(SettingsTemplate.pageBackground)
                }
            }
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
