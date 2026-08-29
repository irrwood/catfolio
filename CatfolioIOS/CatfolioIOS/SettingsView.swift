import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("catfolio.haptics") private var hapticsEnabled = true
    @State private var showsCSVImport = false
    @State private var showsTrading212 = false
    @State private var showsIBKRFlex = false
    @State private var showsMoomooOAuth = false
    @State private var showsLocalServices = false

    var body: some View {
        NavigationStack {
            Form {
                Section("本机数据") {
                    LabeledContent("数据来源", value: model.localSource)
                    LabeledContent("持仓", value: "\(model.holdings.count) 项")
                    if let updatedAt = model.localUpdatedAt {
                        LabeledContent("最后更新", value: updatedAt.formatted(date: .abbreviated, time: .shortened))
                    }
                    Label("组合数据保存在此 iPhone，不需要 Catfolio 服务地址或 Mac 常开。", systemImage: "checkmark.shield.fill")
                        .font(.footnote)
                        .foregroundStyle(CatfolioStyle.green)
                }

                Section("券商直连") {
                    connector("Trading 212", detail: "支持两个正式或模拟账户", icon: "chart.line.uptrend.xyaxis") {
                        showsTrading212 = true
                    }
                    connector("Moomoo OAuth", detail: "OAuth 2.1 + PKCE，无需 OpenD", icon: "person.badge.key") {
                        showsMoomooOAuth = true
                    }
                    connector("Interactive Brokers", detail: "IBKR Flex Web Service，无需 Gateway", icon: "bolt.horizontal.circle") {
                        showsIBKRFlex = true
                    }
                }

                Section("CSV 导入") {
                    Button { showsCSVImport = true } label: {
                        Label("导入交易记录", systemImage: "doc.badge.plus")
                    }
                    Text("CSV 会在手机内解析，并按加权平均成本重建当前持仓。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("行情与 AI") {
                    Button { showsLocalServices = true } label: {
                        Label("配置本机服务", systemImage: "key.horizontal")
                    }
                    Text("成交量分析可直连 FMP；AI 可直连 DeepSeek。Key 只保存在本机 Keychain。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("体验") {
                    Toggle("触控反馈", isOn: $hapticsEnabled)
                    LabeledContent("外观", value: "跟随系统")
                    LabeledContent("数据货币", value: "USD")
                }

                Section("关于") {
                    LabeledContent("应用", value: "Catfolio iOS")
                    LabeledContent("运行方式", value: "完全本机")
                    LabeledContent("界面", value: "SwiftUI + Liquid Glass")
                    LabeledContent("最低系统", value: "iOS 18")
                }
            }
            .navigationTitle("设置")
            .task {
                if model.overview == nil { await model.refreshPortfolio() }
                let arguments = ProcessInfo.processInfo.arguments
                showsCSVImport = arguments.contains("--show-csv")
                showsTrading212 = arguments.contains("--show-trading212")
                showsIBKRFlex = arguments.contains("--show-flex")
                showsMoomooOAuth = arguments.contains("--show-moomoo")
            }
            .sheet(isPresented: $showsCSVImport) {
                CSVImportView().environmentObject(model)
                    .presentationDetents([.large]).presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showsTrading212) {
                Trading212View().environmentObject(model)
                    .presentationDetents([.large]).presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showsIBKRFlex) {
                IBKRFlexView().environmentObject(model)
                    .presentationDetents([.large]).presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showsMoomooOAuth) {
                MoomooOAuthView().environmentObject(model)
                    .presentationDetents([.large]).presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showsLocalServices) {
                LocalServicesSettingsView()
                    .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
            }
        }
    }

    private func connector(_ title: String, detail: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).frame(width: 25).foregroundStyle(CatfolioStyle.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(.primary)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.tertiary)
            }
        }
    }
}

private struct LocalServicesSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var fmpKey = ""
    @State private var deepSeekKey = ""
    @State private var message: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("成交量行情") {
                    SecureField("FMP API Key", text: $fmpKey)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Text("用于由 iPhone 直接下载日线与成交量，并在本机计算 VAH、POC、VAL。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("AI") {
                    SecureField("DeepSeek API Key", text: $deepSeekKey)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Text("问题与组合摘要会直接发送给 DeepSeek，不经过 Mac 或 Catfolio 服务端。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    Button("保存到 Keychain") { save() }
                    Button("清除两个 Key", role: .destructive) { clear() }
                    if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("本机服务")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .onAppear {
                fmpKey = KeychainStore.string(for: LocalServiceKeys.fmp) ?? ""
                deepSeekKey = KeychainStore.string(for: LocalServiceKeys.deepSeek) ?? ""
            }
        }
    }

    private func save() {
        do {
            try KeychainStore.set(fmpKey.trimmingCharacters(in: .whitespacesAndNewlines), for: LocalServiceKeys.fmp)
            try KeychainStore.set(deepSeekKey.trimmingCharacters(in: .whitespacesAndNewlines), for: LocalServiceKeys.deepSeek)
            message = "已安全保存到此 iPhone"
        } catch { message = error.localizedDescription }
    }

    private func clear() {
        try? KeychainStore.set("", for: LocalServiceKeys.fmp)
        try? KeychainStore.set("", for: LocalServiceKeys.deepSeek)
        fmpKey = ""
        deepSeekKey = ""
        message = "已清除"
    }
}
