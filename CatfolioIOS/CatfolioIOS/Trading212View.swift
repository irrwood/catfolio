import SwiftUI

struct Trading212View: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel

    @State private var environment: Trading212Environment = .live
    @State private var apiKey1 = ""
    @State private var apiSecret1 = ""
    @State private var apiKey2 = ""
    @State private var apiSecret2 = ""
    @State private var snapshot: Trading212Snapshot?
    @State private var snapshotAccounts: [Trading212AccountCredentials]?
    @State private var snapshotEnvironment: Trading212Environment?
    @State private var status: Trading212ViewStatus = .idle
    @State private var isWorking = false
    @State private var showsClearConfirmation = false

    private static let environmentKey = "trading212.environment"
    private static let apiKey1Key = "trading212.account-1.api-key"
    private static let apiSecret1Key = "trading212.account-1.api-secret"
    private static let apiKey2Key = "trading212.account-2.api-key"
    private static let apiSecret2Key = "trading212.account-2.api-secret"

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("环境", selection: $environment) {
                        ForEach(Trading212Environment.allCases) { item in
                            Text(item.displayName).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)

                    Label("API Key 与 Secret 仅存于此 iPhone Keychain，不会发送到 Catfolio 服务端。", systemImage: "lock.shield")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Trading 212 API")
                } footer: {
                    Text("仅使用读取持仓接口。建议在 Trading 212 创建只有账户与持仓读取权限的专用 Key。")
                }

                credentialsSection(
                    title: "账户 1",
                    apiKey: $apiKey1,
                    apiSecret: $apiSecret1,
                    optional: false
                )

                credentialsSection(
                    title: "账户 2",
                    apiKey: $apiKey2,
                    apiSecret: $apiSecret2,
                    optional: true
                )

                Section("连接") {
                    Button {
                        Task { await preview() }
                    } label: {
                        Label(isWorking ? "正在读取" : "测试并预览", systemImage: "checkmark.shield")
                    }
                    .disabled(isWorking)

                    GlassPrimaryButton(
                        title: isWorking ? "正在同步" : "同步到 Catfolio",
                        systemImage: "arrow.triangle.2.circlepath",
                        isDisabled: isWorking
                    ) {
                        Task { await sync() }
                    }

                    statusView

                    Link(destination: URL(string: "https://helpcentre.trading212.com/hc/en-us/articles/14584770928157-Trading-212-API-key")!) {
                        Label("查看 API Key 设置说明", systemImage: "arrow.up.right.square")
                    }
                }

                if let snapshot {
                    Section {
                        LabeledContent("账户", value: "\(snapshot.accountCount) 个")
                        LabeledContent("持仓", value: "\(snapshot.positions.count) 项")

                        ForEach(snapshot.positions.prefix(10)) { position in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(position.ticker)
                                            .font(.body.weight(.semibold))
                                        if snapshot.accountCount > 1 {
                                            Text("账户 \(position.accountSlot)")
                                                .font(.caption2.weight(.semibold))
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Text(position.name)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(position.quantity.formatted(.number.precision(.fractionLength(0...4))))
                                        .font(.body.monospacedDigit())
                                    if let currentPrice = position.currentPrice {
                                        Text(DisplayFormat.money(position.quantity * currentPrice, currency: position.currency))
                                            .font(.caption.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    } header: {
                        Text("持仓预览")
                    } footer: {
                        Text(snapshot.positions.count > 10 ? "仅预览前 10 项；同步会合并两个账户的全部可导入持仓。" : "同步时会合并已配置账户的持仓。")
                    }
                }

                if hasCredentials {
                    Section {
                        Button("移除本机 Trading 212 凭证", role: .destructive) {
                            showsClearConfirmation = true
                        }
                    }
                }
            }
            .navigationTitle("Trading 212")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("完成") { dismiss() }
                }
            }
            .task { loadCredentials() }
            .onChange(of: environment) { _, _ in invalidatePreview() }
            .onChange(of: apiKey1) { _, _ in invalidatePreview() }
            .onChange(of: apiSecret1) { _, _ in invalidatePreview() }
            .onChange(of: apiKey2) { _, _ in invalidatePreview() }
            .onChange(of: apiSecret2) { _, _ in invalidatePreview() }
            .confirmationDialog(
                "移除 Trading 212 凭证？",
                isPresented: $showsClearConfirmation,
                titleVisibility: .visible
            ) {
                Button("移除", role: .destructive) { clearCredentials() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("只会删除此 iPhone Keychain 中的两组 API Key 与 Secret。")
            }
        }
    }

    private func credentialsSection(
        title: String,
        apiKey: Binding<String>,
        apiSecret: Binding<String>,
        optional: Bool
    ) -> some View {
        Section {
            SecureField("API Key", text: apiKey)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.body.monospaced())
                .privacySensitive()

            SecureField("API Secret", text: apiSecret)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.body.monospaced())
                .privacySensitive()
        } header: {
            Text(optional ? "\(title)（可选）" : title)
        } footer: {
            if optional {
                Text("如需合并第二个账户，请同时填写这一组 Key 与 Secret。")
            }
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch status {
        case .idle:
            EmptyView()
        case let .working(message):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(message)
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        case let .success(message):
            Label(message, systemImage: "checkmark.circle.fill")
                .font(.footnote)
                .foregroundStyle(CatfolioStyle.green)
        case let .failure(message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(CatfolioStyle.red)
        }
    }

    private var hasCredentials: Bool {
        !apiKey1.isEmpty || !apiSecret1.isEmpty || !apiKey2.isEmpty || !apiSecret2.isEmpty
    }

    private func loadCredentials() {
        if let rawEnvironment = UserDefaults.standard.string(forKey: Self.environmentKey),
           let savedEnvironment = Trading212Environment(rawValue: rawEnvironment) {
            environment = savedEnvironment
        }
        apiKey1 = KeychainStore.string(for: Self.apiKey1Key) ?? ""
        apiSecret1 = KeychainStore.string(for: Self.apiSecret1Key) ?? ""
        apiKey2 = KeychainStore.string(for: Self.apiKey2Key) ?? ""
        apiSecret2 = KeychainStore.string(for: Self.apiSecret2Key) ?? ""
    }

    private func accountCredentials() throws -> [Trading212AccountCredentials] {
        let primary = try Trading212Credentials(apiKey: apiKey1, apiSecret: apiSecret1)
        var accounts = [Trading212AccountCredentials(slot: 1, credentials: primary)]
        let hasSecondKey = !apiKey2.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasSecondSecret = !apiSecret2.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard hasSecondKey == hasSecondSecret else { throw Trading212Error.incompleteSecondAccount }
        if hasSecondKey {
            let secondary = try Trading212Credentials(apiKey: apiKey2, apiSecret: apiSecret2)
            accounts.append(Trading212AccountCredentials(slot: 2, credentials: secondary))
        }
        return accounts
    }

    private func saveCredentials(_ accounts: [Trading212AccountCredentials]) throws {
        let primary = accounts[0].credentials
        try KeychainStore.set(primary.apiKey, for: Self.apiKey1Key)
        try KeychainStore.set(primary.apiSecret, for: Self.apiSecret1Key)
        if let secondary = accounts.first(where: { $0.slot == 2 })?.credentials {
            try KeychainStore.set(secondary.apiKey, for: Self.apiKey2Key)
            try KeychainStore.set(secondary.apiSecret, for: Self.apiSecret2Key)
        } else {
            try KeychainStore.set("", for: Self.apiKey2Key)
            try KeychainStore.set("", for: Self.apiSecret2Key)
        }
        UserDefaults.standard.set(environment.rawValue, forKey: Self.environmentKey)
    }

    private func preview() async {
        isWorking = true
        status = .working("正在读取 Trading 212 持仓…")
        defer { isWorking = false }
        do {
            let accounts = try accountCredentials()
            try saveCredentials(accounts)
            let result = try await Trading212Client().fetchSnapshot(accounts: accounts, environment: environment)
            snapshot = result
            snapshotAccounts = accounts
            snapshotEnvironment = environment
            status = .success("读取成功：\(result.accountCount) 个账户，\(result.positions.count) 项持仓")
        } catch {
            status = .failure(error.localizedDescription)
        }
    }

    private func sync() async {
        isWorking = true
        status = .working("正在读取并转换 Trading 212 持仓…")
        defer { isWorking = false }
        do {
            let accounts = try accountCredentials()
            try saveCredentials(accounts)
            let currentSnapshot: Trading212Snapshot
            if let snapshot, snapshotAccounts == accounts, snapshotEnvironment == environment {
                currentSnapshot = snapshot
            } else {
                currentSnapshot = try await Trading212Client().fetchSnapshot(accounts: accounts, environment: environment)
                snapshot = currentSnapshot
                snapshotAccounts = accounts
                snapshotEnvironment = environment
            }
            status = .working("Trading 212 已读取，正在保存到本机…")
            let result = try await model.importTrading212(currentSnapshot)
            let warningText = result.warnings.isEmpty ? "" : "，跳过 \(result.warnings.count) 项"
            status = .success("已同步 \(result.holdingsCount) 个持仓\(warningText)")
        } catch {
            status = .failure(error.localizedDescription)
        }
    }

    private func invalidatePreview() {
        guard !isWorking else { return }
        snapshot = nil
        snapshotAccounts = nil
        snapshotEnvironment = nil
        status = .idle
    }

    private func clearCredentials() {
        for key in [Self.apiKey1Key, Self.apiSecret1Key, Self.apiKey2Key, Self.apiSecret2Key] {
            try? KeychainStore.set("", for: key)
        }
        apiKey1 = ""
        apiSecret1 = ""
        apiKey2 = ""
        apiSecret2 = ""
        snapshot = nil
        snapshotAccounts = nil
        snapshotEnvironment = nil
        status = .idle
    }
}

private enum Trading212ViewStatus {
    case idle
    case working(String)
    case success(String)
    case failure(String)
}
