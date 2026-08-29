import SwiftUI
import SafariServices

struct MoomooOAuthView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    @StateObject private var authorizationSession = MoomooAuthorizationSession()

    @State private var snapshot: MoomooSnapshot?
    @State private var status: MoomooViewStatus = .idle
    @State private var isWorking = false
    @State private var isConnected = MoomooCredentialStore.tokenSet != nil
    @State private var showsDisconnectConfirmation = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label(
                        isConnected ? "已授权 Moomoo" : "尚未连接",
                        systemImage: isConnected ? "checkmark.shield.fill" : "person.crop.circle.badge.questionmark"
                    )
                    .foregroundStyle(isConnected ? CatfolioStyle.green : .secondary)

                    Text("通过系统浏览器完成 OAuth 2.1 + PKCE 授权。无需 OpenD，也不需要输入 API Key。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Text("授权页只需允许 trade:read，用于读取账户与持仓。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Label("Access Token 与 Refresh Token 仅保存在此 iPhone Keychain。", systemImage: "lock.shield")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Moomoo OAuth")
                }

                Section("连接") {
                    GlassPrimaryButton(
                        title: isWorking ? "正在连接" : (isConnected ? "重新授权" : "登录 Moomoo"),
                        systemImage: "person.badge.key",
                        isDisabled: isWorking
                    ) {
                        Task { await connect() }
                    }

                    Button {
                        Task { await preview() }
                    } label: {
                        Label(isWorking ? "正在读取" : "测试并预览", systemImage: "checkmark.shield")
                    }
                    .disabled(isWorking || !isConnected)

                    Button {
                        Task { await sync() }
                    } label: {
                        Label(isWorking ? "正在同步" : "同步到 Catfolio", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(isWorking || !isConnected)

                    statusView

                    Link(destination: URL(string: "https://open.moomoo.com/zh-cn/api/overview/getting-started")!) {
                        Label("查看 Moomoo OpenAPI 说明", systemImage: "arrow.up.right.square")
                    }
                }

                if let snapshot {
                    Section {
                        LabeledContent("授权账户", value: "\(snapshot.accounts.count) 个")
                        LabeledContent("持仓", value: "\(snapshot.positions.count) 项")

                        ForEach(snapshot.positions.prefix(10)) { position in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(position.code)
                                        .font(.body.weight(.semibold))
                                    Text(position.stockName)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(position.quantityValue.formatted(.number.precision(.fractionLength(0...4))))
                                        .font(.body.monospacedDigit())
                                    if let marketValue = position.marketValueValue {
                                        Text(DisplayFormat.money(marketValue, currency: position.currency))
                                            .font(.caption.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    } header: {
                        Text("账户预览")
                    } footer: {
                        Text(snapshot.positions.count > 10 ? "仅预览前 10 项；同步会处理全部账户。" : "已合并读取全部授权账户。")
                    }
                }

                if isConnected {
                    Section {
                        Button("断开 Moomoo", role: .destructive) {
                            showsDisconnectConfirmation = true
                        }
                    }
                }
            }
            .navigationTitle("Moomoo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("完成") { dismiss() }
                }
            }
            .confirmationDialog(
                "断开 Moomoo？",
                isPresented: $showsDisconnectConfirmation,
                titleVisibility: .visible
            ) {
                Button("断开", role: .destructive) { disconnect() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("将删除此 iPhone Keychain 中的 Moomoo Access Token 与 Refresh Token。")
            }
            .fullScreenCover(item: $authorizationSession.authorizationPage) { page in
                MoomooSafariView(url: page.url) {
                    authorizationSession.cancel()
                }
                .ignoresSafeArea()
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

    private func connect() async {
        isWorking = true
        status = .working("正在打开 Moomoo 授权页…")
        defer { isWorking = false }
        do {
            let tokenSet = try await authorizationSession.authorize()
            isConnected = true
            status = .success(tokenSet.scope.contains("trade:read") ? "授权成功" : "授权成功；请确认已授予 trade:read")
        } catch {
            status = .failure(error.localizedDescription)
        }
    }

    private func preview() async {
        isWorking = true
        status = .working("正在读取全部授权账户…")
        defer { isWorking = false }
        do {
            let result = try await MoomooOpenAPIClient().fetchSnapshot()
            snapshot = result
            status = .success("读取成功：\(result.accounts.count) 个账户，\(result.positions.count) 项持仓")
        } catch {
            status = .failure(error.localizedDescription)
        }
    }

    private func sync() async {
        isWorking = true
        status = .working("正在读取并转换 Moomoo 持仓…")
        defer { isWorking = false }
        do {
            let currentSnapshot = try await MoomooOpenAPIClient().fetchSnapshot()
            snapshot = currentSnapshot
            status = .working("Moomoo 已读取，正在保存到本机…")
            let result = try await model.importMoomoo(currentSnapshot)
            let warningText = result.warnings.isEmpty ? "" : "，跳过 \(result.warnings.count) 项"
            status = .success("已同步 \(result.holdingsCount) 个持仓\(warningText)")
        } catch {
            status = .failure(error.localizedDescription)
        }
    }

    private func disconnect() {
        MoomooCredentialStore.clearTokens()
        isConnected = false
        snapshot = nil
        status = .idle
    }
}

private struct MoomooSafariView: UIViewControllerRepresentable {
    let url: URL
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCancel: onCancel)
    }

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let controller = SFSafariViewController(url: url)
        controller.delegate = context.coordinator
        controller.dismissButtonStyle = .cancel
        return controller
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}

    final class Coordinator: NSObject, SFSafariViewControllerDelegate {
        let onCancel: () -> Void

        init(onCancel: @escaping () -> Void) {
            self.onCancel = onCancel
        }

        func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
            onCancel()
        }
    }
}

private enum MoomooViewStatus {
    case idle
    case working(String)
    case success(String)
    case failure(String)
}
