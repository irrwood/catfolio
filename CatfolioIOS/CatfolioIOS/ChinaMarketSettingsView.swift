import SwiftUI
import Observation

@MainActor @Observable
final class ChinaMarketSetup {
    var appKey = ""
    var appSecret = ""
    var accessToken = ""
    var message: String?
    var testing = false
    var failed = false
    var credentials: LongbridgeCredentials {
        .init(appKey: appKey.trimmingCharacters(in: .whitespacesAndNewlines),
              appSecret: appSecret.trimmingCharacters(in: .whitespacesAndNewlines),
              accessToken: accessToken.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    func load(_ stored: LongbridgeCredentials?) {
        appKey = stored?.appKey ?? ""; appSecret = stored?.appSecret ?? ""; accessToken = stored?.accessToken ?? ""
    }
    func save(using persist: (LongbridgeCredentials) throws -> Void = { try $0.save() }) {
        do {
            guard credentials.isComplete else { throw ChinaMarketError.missingCredentials }
            try persist(credentials)
            failed = false; message = L10n.text("长桥凭据已保存在本机")
        } catch { failed = true; message = error.localizedDescription }
    }
    func test(using fetch: ((LongbridgeCredentials) async throws -> ChinaMarketQuote)? = nil) async {
        guard !testing else { return }
        testing = true; message = nil
        defer { testing = false }
        do {
            guard credentials.isComplete else { throw ChinaMarketError.missingCredentials }
            let quote: ChinaMarketQuote
            if let fetch { quote = try await fetch(credentials) }
            else { quote = try await LongbridgeMarketDataClient(credentials: credentials).quote(ChinaSecurity("600519.SH")!) }
            try Task.checkCancellation()
            failed = false
            message = L10n.text("长桥验证成功，已读取贵州茅台报价") + "\n"
                + quote.observedAt.formatted(date: .abbreviated, time: .shortened)
        } catch is CancellationError { message = nil }
        catch { failed = true; message = error.localizedDescription }
    }
}

struct ChinaMarketSettingsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(ChinaMarketSource.preferenceKey) private var source = ChinaMarketSource.automatic.rawValue
    @State private var setup = ChinaMarketSetup()
    @State private var testingTask: Task<Void, Never>?
    @State private var publicMessage: String?
    @State private var testingPublic = false

    var body: some View {
        SettingsPage(title: L10n.text("A 股行情"), titleDisplayMode: .inline) {
            SettingsSection(L10n.text("数据源")) {
                SettingsRowContainer {
                VStack(alignment: .leading, spacing: 14) {
                Picker(L10n.text("数据源"), selection: $source) {
                    ForEach(ChinaMarketSource.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.menu)
                .tint(SettingsTemplate.readOnlyValue)
                .accessibilityIdentifier("china-market.source")
                Text(L10n.text("自动模式优先使用已配置的长桥，失败时使用 AKShare 来源。"))
                    .appText(.footnote).foregroundStyle(SettingsTemplate.secondaryText)
                }
                }
            }
            SettingsSection("Longbridge") {
                SettingsRowContainer {
                VStack(alignment: .leading, spacing: 14) {
                Text(L10n.text("填写长桥 OpenAPI 控制台的三项凭据。凭据仅保存在本机钥匙串。"))
                    .appText(.footnote).foregroundStyle(SettingsTemplate.secondaryText)
                credentialField("App Key", text: $setup.appKey)
                    .accessibilityIdentifier("china-market.app-key")
                credentialField("App Secret", text: $setup.appSecret)
                    .accessibilityIdentifier("china-market.app-secret")
                credentialField("Access Token", text: $setup.accessToken)
                    .accessibilityIdentifier("china-market.access-token")
                HStack {
                    Button(L10n.text("保存")) { setup.save() }
                        .disabled(!setup.credentials.isComplete || setup.testing)
                    Button(setup.testing ? L10n.text("验证中…") : L10n.text("测试连接")) {
                        testingTask = Task { await setup.test() }
                    }
                    .disabled(!setup.credentials.isComplete || setup.testing || testingPublic)
                }
                .buttonStyle(.bordered)
                if let message = setup.message {
                    Text(message).appText(.footnote)
                        .foregroundStyle(setup.failed ? CatfolioTheme.loss(for: colorScheme) : SettingsTemplate.secondaryText)
                }
                Link(L10n.text("打开长桥 OpenAPI 控制台"), destination: URL(string: "https://open.longbridge.com/account")!)
                    .appText(.label)
                Text(L10n.text("长桥 A 股行情在中国大陆以外的 IP 下延迟 15 分钟；权限以 OpenAPI 账户为准。"))
                    .appText(.footnote).foregroundStyle(SettingsTemplate.secondaryText)
                Button(L10n.text("移除长桥凭据"), role: .destructive) {
                    do {
                        try KeychainStore.set("", for: LongbridgeCredentials.keychainKey)
                        ChinaMarketConfiguration.credentialsChanged()
                        setup.load(nil); setup.message = L10n.text("长桥凭据已移除"); setup.failed = false
                    } catch { setup.message = error.localizedDescription; setup.failed = true }
                }
                .disabled(setup.testing)
                }
                }
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            SettingsSection(L10n.text("AKShare 来源")) {
                SettingsRowContainer {
                VStack(alignment: .leading, spacing: 14) {
                Text(L10n.text("iPhone 直连腾讯行情，东方财富作为备用并提供搜索。两者均为 AKShare 使用的公开来源，无需 API Key 或服务器。"))
                    .appText(.footnote).foregroundStyle(SettingsTemplate.secondaryText)
                Text(L10n.text("支持沪深股票与 ETF、中文或代码搜索、日线与分时。公开接口不可用时会保留已有图表。"))
                    .appText(.footnote).foregroundStyle(SettingsTemplate.secondaryText)
                Button(testingPublic ? L10n.text("验证中…") : L10n.text("测试公开行情")) {
                    testingPublic = true
                    testingTask = Task {
                        defer { testingPublic = false }
                        do {
                            let quote = try await AKShareMarketDataClient().quote(ChinaSecurity("600519.SH")!)
                            try Task.checkCancellation()
                            publicMessage = L10n.text("公开行情可用，已读取贵州茅台报价") + "\n"
                                + quote.observedAt.formatted(date: .abbreviated, time: .shortened)
                        } catch is CancellationError { }
                        catch { publicMessage = error.localizedDescription }
                    }
                }
                .buttonStyle(.bordered)
                .disabled(testingPublic || setup.testing)
                if let publicMessage { Text(publicMessage).appText(.footnote).foregroundStyle(SettingsTemplate.secondaryText) }
                }
                }
            }
        }
        .onAppear { setup.load(LongbridgeCredentials.stored) }
        .onDisappear { testingTask?.cancel() }
    }

    private func credentialField(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).appText(.label).foregroundStyle(SettingsTemplate.secondaryText)
            SecureField(title, text: text)
                .font(.body.monospaced())
                .textFieldStyle(.roundedBorder)
                .disabled(setup.testing)
        }
    }
}
