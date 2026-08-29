import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("catfolio.haptics") private var hapticsEnabled = true
    @State private var selectedBroker: BrokerProvider = .trading212
    @State private var showsCSVImport = false
    @State private var showsIBKRFlex = false

    var body: some View {
        NavigationStack {
            Form {
                Section("连接") {
                    TextField("http://127.0.0.1:8000", text: $model.serverURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .font(.body.monospaced())

                    GlassPrimaryButton(title: "测试连接", systemImage: "network") {
                        Task { await model.testConnection() }
                    }

                    if let message = model.connectionMessage {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(message.hasPrefix("连接成功") ? CatfolioStyle.green : .secondary)
                    }
                }

                Section("券商 API") {
                    Picker("当前数据源", selection: $selectedBroker) {
                        ForEach(BrokerProvider.allCases) { provider in
                            Text(provider.displayName).tag(provider)
                        }
                    }
                    .disabled(model.isBrokerLoading || model.isBrokerSyncing)

                    Text("iPhone 仅调用 Catfolio API；券商连接和账户数据留在运行服务端的 Mac 上。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    brokerRow(.moomoo)
                    brokerRow(.ibkr)

                    Button {
                        showsIBKRFlex = true
                    } label: {
                        Label("IBKR Flex 直连", systemImage: "bolt.horizontal.circle")
                    }

                    Text("Flex Web Service 不需要 Gateway；Token 只保存在此 iPhone。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    GlassPrimaryButton(
                        title: model.isBrokerSyncing
                            ? "正在同步"
                            : (model.activeBroker == .ibkr ? "通过 Gateway 同步" : "同步当前券商"),
                        systemImage: "arrow.triangle.2.circlepath",
                        isDisabled: model.isBrokerSyncing || model.isBrokerLoading
                    ) {
                        Task { await model.syncActiveBroker() }
                    }

                    if let message = model.brokerMessage {
                        Label(message, systemImage: brokerMessageIcon(message))
                            .font(.footnote)
                            .foregroundStyle(brokerMessageColor(message))
                    }
                }

                Section("体验") {
                    Toggle("触控反馈", isOn: $hapticsEnabled)
                    LabeledContent("外观", value: "跟随系统")
                    LabeledContent("数据货币", value: "USD")
                }

                Section("CSV 导入") {
                    Button {
                        showsCSVImport = true
                    } label: {
                        Label("导入交易记录", systemImage: "doc.badge.plus")
                    }

                    Text("支持任意券商交易 CSV，按加权平均成本重新计算当前持仓。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("服务端设置") {
                    Text("AI Key、券商连接和数据导入继续由 Catfolio 服务端管理。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    if let settingsURL {
                        Link(destination: settingsURL) {
                            Label("打开服务端设置", systemImage: "safari")
                        }
                    }
                }

                Section("关于") {
                    LabeledContent("应用", value: "Catfolio iOS")
                    LabeledContent("界面", value: "SwiftUI + Liquid Glass")
                    LabeledContent("最低系统", value: "iOS 18")
                }
            }
            .navigationTitle("设置")
            .task {
                await model.loadBrokerStatus()
                selectedBroker = model.activeBroker ?? .trading212
                if ProcessInfo.processInfo.arguments.contains("--show-csv") {
                    showsCSVImport = true
                }
                if ProcessInfo.processInfo.arguments.contains("--show-flex") {
                    showsIBKRFlex = true
                }
            }
            .onChange(of: selectedBroker) { _, provider in
                guard provider != model.activeBroker else { return }
                Task {
                    await model.selectBroker(provider)
                    selectedBroker = model.activeBroker ?? .trading212
                }
            }
            .sheet(isPresented: $showsCSVImport) {
                CSVImportView()
                    .environmentObject(model)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showsIBKRFlex) {
                IBKRFlexView()
                    .environmentObject(model)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
        }
    }

    @ViewBuilder
    private func brokerRow(_ provider: BrokerProvider) -> some View {
        let state = model.brokerConnectionStates[provider] ?? .idle
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: provider.systemImage)
                    .font(.headline)
                    .foregroundStyle(provider == model.activeBroker ? CatfolioStyle.blue : .secondary)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(provider.displayName)
                            .font(.body.weight(.semibold))
                        if provider == model.activeBroker {
                            Text("当前")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(CatfolioStyle.blue)
                        }
                    }
                    Text(provider.setupHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                Button(state.isTesting ? "测试中" : (provider == .ibkr ? "Gateway" : "测试")) {
                    Task { await model.testBroker(provider) }
                }
                .buttonStyle(.bordered)
                .disabled(state.isTesting || model.isBrokerSyncing)
            }

            brokerStateView(state)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func brokerStateView(_ state: BrokerConnectionState) -> some View {
        switch state {
        case .idle:
            EmptyView()
        case .testing:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("正在通过服务端检查连接…")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        case let .success(message):
            Label(message, systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(CatfolioStyle.green)
        case let .failure(message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(CatfolioStyle.red)
        }
    }

    private func brokerMessageIcon(_ message: String) -> String {
        message.contains("失败") || message.contains("连接失败") ? "exclamationmark.triangle.fill" : "info.circle.fill"
    }

    private func brokerMessageColor(_ message: String) -> Color {
        message.contains("失败") || message.contains("连接失败")
            ? CatfolioStyle.red
            : Color(uiColor: .secondaryLabel)
    }

    private var settingsURL: URL? {
        URL(string: model.serverURL)?.appendingPathComponent("settings")
    }
}
