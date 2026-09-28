import SwiftUI

/// Connection and read-only inspection. Portfolio snapshots do not create
/// synthetic transactions or overwrite Catfolio's cost-basis ledger.
struct RobinhoodConnectionView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    let context: AccountConnectorContext
    @State private var accounts: [RobinhoodAccount] = []
    @State private var selectedID = ""
    @State private var preview: RobinhoodAccountSnapshot?
    @State private var nickname = ""
    @State private var nicknameEdited = false
    @State private var confirmsSync = false
    @State private var operationTask: Task<Void, Never>?

    init(context: AccountConnectorContext = .create) { self.context = context }

    private var allowedAccounts: [RobinhoodAccount] {
        accounts.filter { account in
            if let current = context.account { return current.source == "Robinhood" && current.accountID == account.id }
            return !model.accounts.contains { $0.source == "Robinhood" && $0.accountID == account.id }
        }
    }
    @State private var connected = false
    @State private var working = false
    @State private var authorizationURL: URL?
    @State private var callback = ""
    @State private var message: String?
    @State private var symbols = "AAPL"
    @State private var accountNumber = ""
    @State private var instrumentIDs = ""
    @State private var available = Set<String>()
    @State private var rows: [RobinhoodDataRow] = []
    @State private var resultTitle = ""

    var body: some View {
        NavigationStack {
            SettingsPage(bottomInset: 32) {
                SettingsSection(L10n.text("连接")) {
                    SettingsValueRow(title: "Robinhood", value: connected ? L10n.text("已连接") : L10n.text("尚未连接"), valueIsNumeric: false)
                    SettingsButtonRow(icon: .symbol("person.badge.key"), title: L10n.text("生成桌面登录链接"), showsChevron: false) {
                        run {
                            authorizationURL = try await RobinhoodMCPClient.shared.beginAuthorization()
                            callback = ""
                        }
                    }
                    if let authorizationURL {
                        ShareLink(item: authorizationURL) {
                            Label(L10n.text("将登录链接发送到电脑"), systemImage: "square.and.arrow.up")
                                .padding(20)
                        }
                    }
                    SettingsRowContainer {
                        TextField(L10n.text("粘贴电脑浏览器的完整回调链接"), text: $callback)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .keyboardType(.URL).privacySensitive()
                    }
                    SettingsButtonRow(icon: .symbol("checkmark.shield"), title: L10n.text("完成 Robinhood 连接"), showsChevron: false) {
                        run {
                            try await RobinhoodMCPClient.shared.finishAuthorization(callback: callback)
                            callback = ""
                            authorizationURL = nil
                            connected = true
                            accounts = []
                            preview = nil
                            selectedID = ""
                            available = Set(try await RobinhoodMCPClient.shared.availableTools())
                            try await loadAccounts()
                        }
                    }
                    .disabled(callback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                SettingsFootnote(L10n.text("在电脑打开登录链接并授权。跳转至 localhost 后页面可能无法打开，请复制地址栏的完整链接并粘贴到这里。请在 30 分钟内完成。"))
                SettingsFootnote(L10n.text("实验性连接：尚未完成真实账号联调，部分数据可能暂不可用。"))
                SettingsFootnote(L10n.text("令牌仅存于此 iPhone 的 Keychain。Catfolio 仅调用读取工具；Robinhood 授权页可能包含交易权限。"))

                if connected {
                    SettingsSection(L10n.text("账户与组合")) {
                        SettingsButtonRow(icon: .symbol("arrow.down.circle"), title: L10n.text("读取 Robinhood 账户"), showsChevron: false) {
                            run { try await loadAccounts() }
                        }
                        if !allowedAccounts.isEmpty {
                            SettingsRowContainer {
                                Picker(L10n.text("选择 Robinhood 账户"), selection: $selectedID) {
                                    ForEach(allowedAccounts) { account in
                                        Text(account.displayName).tag(account.id)
                                    }
                                }
                            }
                            if context.isCreating {
                                SettingsRowContainer { AccountNicknameField(nickname: $nickname, edited: $nicknameEdited) }
                            }
                            SettingsButtonRow(icon: .symbol("tray.and.arrow.down"), title: L10n.text("预览 Robinhood 股票持仓"), showsChevron: false) {
                                run {
                                    preview = nil
                                    guard let account = allowedAccounts.first(where: { $0.id == selectedID }) else {
                                        throw RobinhoodAccountError.wrongAccount
                                    }
                                    let snapshot = try await RobinhoodMCPClient.shared.snapshot(account: account)
                                    try snapshot.validate(context: context, existing: model.accounts)
                                    preview = snapshot
                                }
                            }
                        }
                        readButton(L10n.text("读取组合快照"), tool: "get_portfolio", arguments: accountArguments)
                        readButton(L10n.text("读取股票持仓"), tool: "get_equity_positions", arguments: accountArguments)
                        readButton(L10n.text("读取期权持仓"), tool: "get_option_positions", arguments: accountArguments)
                    }
                    SettingsFootnote(L10n.text("仅同步股票/ETF 持仓，不含现金、期权和历史交易。历史收益可能不完整。"))
                    if let preview {
                        SettingsSection(L10n.text("Robinhood 持仓预览")) {
                            SettingsValueRow(title: L10n.text("账户"), value: preview.account.displayName, valueIsNumeric: false)
                            ForEach(preview.positions, id: \.ticker) { position in
                                VStack(spacing: 0) {
                                    SettingsValueRow(title: position.ticker, value: position.shares.formatted(), valueIsNumeric: true)
                                    SettingsValueRow(title: L10n.text("平均成本"), value: position.averageCost.formatted(.currency(code: "USD")), valueIsNumeric: true)
                                    SettingsValueRow(title: L10n.text("报价"), value: position.quotePrice.formatted(.currency(code: "USD")), valueIsNumeric: true)
                                }
                            }
                            if preview.positions.isEmpty {
                                SettingsFootnote(L10n.text("此账户没有股票持仓；确认同步将清空该账户已导入的股票持仓。"))
                            }
                            SettingsButtonRow(icon: .symbol("checkmark.circle"),
                                title: context.isCreating ? L10n.text("创建 Robinhood 账户") : L10n.text("同步 Robinhood 持仓"), showsChevron: false) {
                                confirmsSync = true
                            }
                        }
                        .privacySensitive()
                    }
                    SettingsSection(L10n.text("行情")) {
                        field("股票代码，以逗号分隔", text: $symbols)
                        readButton(L10n.text("实时股票报价"), tool: "get_equity_quotes", arguments: ["symbols": values(symbols)])
                        readButton(L10n.text("Level 2 盘口"), tool: "get_equity_price_book", arguments: ["symbols": values(symbols)])
                        readButton(L10n.text("期权链"), tool: "get_option_chains", arguments: ["symbols": values(symbols)])
                        field("期权合约 ID，以逗号分隔", text: $instrumentIDs)
                        readButton(L10n.text("实时期权报价"), tool: "get_option_quotes", arguments: ["instrument_ids": values(instrumentIDs, uppercase: false)])
                    }
                    SettingsFootnote(L10n.text("持仓刷新优先尝试 Robinhood 美股报价；缺失、过期或权限不足时使用原有行情源。"))
                    if !rows.isEmpty {
                        SettingsSection(resultTitle) {
                            ForEach(rows) { row in
                                SettingsValueRow(title: row.label, value: row.value, valueIsNumeric: false)
                            }
                        }
                        .privacySensitive()
                    }
                    SettingsSection(L10n.text("连接管理")) {
                        SettingsButtonRow(icon: .symbol("arrow.clockwise"), title: L10n.text("检查可用数据"), showsChevron: false) {
                            run { available = Set(try await RobinhoodMCPClient.shared.availableTools()) }
                        }
                        SettingsButtonRow(icon: .symbol("link.badge.plus"), title: L10n.text("断开 Robinhood"), showsChevron: false) {
                            run {
                                try await RobinhoodMCPClient.shared.disconnect()
                                connected = false
                                available = []
                                rows = []
                                accounts = []
                                preview = nil
                                selectedID = ""
                                accountNumber = ""
                                instrumentIDs = ""
                                callback = ""
                                authorizationURL = nil
                            }
                        }
                    }
                }
                if working { ProgressView().frame(maxWidth: .infinity) }
                if let message { SettingsFootnote(message) }
                Link(L10n.text("Robinhood 官方连接说明"), destination: URL(string: "https://robinhood.com/us/en/support/articles/agentic-trading-overview/")!)
                    .padding(.horizontal, 20)
            }
            .disabled(working)
            .onDisappear { operationTask?.cancel() }
            .onChange(of: selectedID) { _, value in
                preview = nil
                rows = []
                accountNumber = value
            }
            .confirmationDialog(L10n.text("确认导入 Robinhood 股票持仓？"), isPresented: $confirmsSync, titleVisibility: .visible) {
                Button(L10n.text("确认同步")) {
                    run {
                        guard let preview, preview.account.id == selectedID else { throw RobinhoodAccountError.expired }
                        try Task.checkCancellation()
                        _ = try await model.importRobinhood(preview, context: context, nickname: nickname)
                        dismiss()
                    }
                }
                Button(L10n.text("取消"), role: .cancel) {}
            } message: {
                Text(L10n.text("仅更新所选 Robinhood 账户的股票持仓；不导入现金、期权或历史成交。"))
            }
            .navigationTitle("Robinhood")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.text("完成")) { dismiss() } } }
            .task {
                connected = await RobinhoodMCPClient.shared.isConnected()
                if connected {
                    do { available = Set(try await RobinhoodMCPClient.shared.availableTools()) }
                    catch { message = error.localizedDescription }
                }
            }
        }
    }

    private func loadAccounts() async throws {
        preview = nil
        accounts = []
        selectedID = ""
        let loaded = try await RobinhoodMCPClient.shared.accounts()
        try Task.checkCancellation()
        accounts = loaded
        selectedID = allowedAccounts.first?.id ?? ""
        accountNumber = selectedID
        if allowedAccounts.isEmpty {
            message = L10n.text("没有可用的新账户，请先完成券商授权；已有账户请从账户详情同步。")
        }
    }

    private var accountArguments: [String: Any] {
        let account = accountNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        return account.isEmpty ? [:] : ["account_number": account]
    }
    private func values(_ text: String, uppercase: Bool = true) -> [String] {
        // The server validates maximum counts; never silently drop requested symbols.
        text.split(separator: ",").map {
            let value = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return uppercase ? value.uppercased() : value
        }.filter { !$0.isEmpty }
    }
    private func field(_ title: String, text: Binding<String>) -> some View {
        SettingsRowContainer {
            TextField(L10n.label(title), text: text).textInputAutocapitalization(.never)
                .autocorrectionDisabled().privacySensitive()
        }
    }
    private func readButton(_ title: String, tool: String, arguments: [String: Any] = [:]) -> some View {
        SettingsButtonRow(icon: .symbol("arrow.down.circle"), title: title, showsChevron: false) {
            run {
                rows = []
                let payload = try await RobinhoodMCPClient.shared.read(tool, arguments: arguments)
                rows = RobinhoodDataRow.flatten(payload)
                resultTitle = title
                if rows.isEmpty { message = L10n.text("暂无数据") }
            }
        }
        .disabled(!available.contains(tool))
    }
    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !working else { return }
        working = true
        message = nil
        operationTask = Task { @MainActor in
            defer { working = false }
            do {
                try Task.checkCancellation()
                try await operation()
            } catch is CancellationError {
                // Dismissing the connection flow cancels pending work.
            } catch { if !Task.isCancelled { message = error.localizedDescription } }
        }
    }
}

struct RobinhoodDataRow: Identifiable {
    let id: String
    let label: String
    let value: String

    static func flatten(_ payload: Any, path: String = "", depth: Int = 0) -> [Self] {
        guard depth < 8 else { return [] }
        if let object = payload as? [String: Any] {
            return object.keys.sorted().flatMap { key in
                flatten(object[key]!, path: path.isEmpty ? key : "\(path) · \(key)", depth: depth + 1)
            }
        }
        if let list = payload as? [Any] {
            return list.enumerated().flatMap { index, item in
                flatten(item, path: "\(path) [\(index + 1)]", depth: depth + 1)
            }
        }
        if payload is NSNull { return [] }
        return [.init(id: path, label: path.replacingOccurrences(of: "_", with: " "), value: String(describing: payload))]
    }
}
