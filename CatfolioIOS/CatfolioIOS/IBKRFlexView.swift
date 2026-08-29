import SwiftUI

struct IBKRFlexView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel

    @State private var token = ""
    @State private var queryID = ""
    @State private var snapshot: IBKRFlexSnapshot?
    @State private var snapshotCredentials: IBKRFlexCredentials?
    @State private var status: FlexViewStatus = .idle
    @State private var isWorking = false
    @State private var showsClearConfirmation = false

    private static let tokenKey = "ibkr.flex.token"
    private static let queryIDKey = "ibkr.flex.query-id"

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("Flex Token", text: $token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())

                    TextField("Query ID", text: $queryID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.numberPad)
                        .font(.body.monospaced())

                    Label("凭证仅存于此 iPhone Keychain，不会发送到 Catfolio 服务端。", systemImage: "lock.shield")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Flex 凭证")
                } footer: {
                    Text("Flex Query 输出格式请选择 XML，并加入 Open Positions → Summary、Symbol、Description、Quantity、Currency、Cost Basis Price、Position Value、Report Date。")
                }

                Section("连接") {
                    Button {
                        Task { await testFlex() }
                    } label: {
                        Label(isWorking ? "正在请求报表" : "测试并预览", systemImage: "checkmark.shield")
                    }
                    .disabled(isWorking)

                    GlassPrimaryButton(
                        title: isWorking ? "正在同步" : "同步到 Catfolio",
                        systemImage: "arrow.triangle.2.circlepath",
                        isDisabled: isWorking
                    ) {
                        Task { await syncFlex() }
                    }

                    statusView

                    Link(destination: URL(string: "https://www.ibkrguides.com/advisorportal/ug/flex-web-service.htm")!) {
                        Label("查看 IBKR Flex 配置说明", systemImage: "arrow.up.right.square")
                    }
                }

                if let snapshot {
                    Section {
                        LabeledContent("报表日期", value: snapshot.reportDate ?? "最新")
                        LabeledContent("Open Positions", value: "\(snapshot.positions.count) 项")

                        ForEach(snapshot.positions.prefix(10)) { position in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(position.symbol)
                                        .font(.body.weight(.semibold))
                                    Text(position.name)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(position.quantity.formatted(.number.precision(.fractionLength(0...4))))
                                        .font(.body.monospacedDigit())
                                    if let marketValue = position.marketValue {
                                        Text(DisplayFormat.money(marketValue, currency: position.currency))
                                            .font(.caption.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    } header: {
                        Text("Flex 预览")
                    } footer: {
                        if snapshot.positions.count > 10 {
                            Text("仅预览前 10 项；同步会处理全部可导入股票持仓。")
                        }
                    }
                }

                if !token.isEmpty || !queryID.isEmpty {
                    Section {
                        Button("移除本机 Flex 凭证", role: .destructive) {
                            showsClearConfirmation = true
                        }
                    }
                }
            }
            .navigationTitle("IBKR Flex")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("完成") { dismiss() }
                }
            }
            .task { loadCredentials() }
            .onChange(of: token) { _, _ in invalidatePreview() }
            .onChange(of: queryID) { _, _ in invalidatePreview() }
            .confirmationDialog(
                "移除 Flex 凭证？",
                isPresented: $showsClearConfirmation,
                titleVisibility: .visible
            ) {
                Button("移除", role: .destructive) { clearCredentials() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("只会删除此 iPhone Keychain 中的 Token 和 Query ID。")
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

    private func loadCredentials() {
        token = KeychainStore.string(for: Self.tokenKey) ?? ""
        queryID = KeychainStore.string(for: Self.queryIDKey) ?? ""
    }

    private func credentials() throws -> IBKRFlexCredentials {
        let credentials = try IBKRFlexCredentials(token: token, queryID: queryID)
        try KeychainStore.set(credentials.token, for: Self.tokenKey)
        try KeychainStore.set(credentials.queryID, for: Self.queryIDKey)
        return credentials
    }

    private func testFlex() async {
        isWorking = true
        status = .working("正在请求 IBKR Flex 报表…")
        defer { isWorking = false }
        do {
            let credentials = try credentials()
            let result = try await IBKRFlexClient().fetchOpenPositions(credentials: credentials)
            snapshot = result
            snapshotCredentials = credentials
            status = .success("Flex 连接成功，读取 \(result.positions.count) 项持仓")
        } catch {
            status = .failure(error.localizedDescription)
        }
    }

    private func syncFlex() async {
        isWorking = true
        status = .working("正在读取并转换 Flex 持仓…")
        defer { isWorking = false }
        do {
            let credentials = try credentials()
            let currentSnapshot: IBKRFlexSnapshot
            if let snapshot, snapshotCredentials == credentials {
                currentSnapshot = snapshot
            } else {
                currentSnapshot = try await IBKRFlexClient().fetchOpenPositions(credentials: credentials)
                snapshot = currentSnapshot
                snapshotCredentials = credentials
            }
            status = .working("Flex 已读取，正在保存到本机…")
            let result = try await model.importIBKR(currentSnapshot)
            let warningText = result.warnings.isEmpty ? "" : "，跳过 \(result.warnings.count) 项"
            status = .success("已同步 \(result.holdingsCount) 个持仓\(warningText)")
        } catch {
            status = .failure(error.localizedDescription)
        }
    }

    private func invalidatePreview() {
        guard !isWorking else { return }
        snapshot = nil
        snapshotCredentials = nil
        status = .idle
    }

    private func clearCredentials() {
        try? KeychainStore.set("", for: Self.tokenKey)
        try? KeychainStore.set("", for: Self.queryIDKey)
        token = ""
        queryID = ""
        snapshot = nil
        snapshotCredentials = nil
        status = .idle
    }
}

private enum FlexViewStatus {
    case idle
    case working(String)
    case success(String)
    case failure(String)
}
