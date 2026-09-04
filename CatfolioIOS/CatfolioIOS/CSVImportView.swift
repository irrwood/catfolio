import SwiftUI
import UniformTypeIdentifiers

struct CSVImportView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme

    let context: AccountConnectorContext

    @State private var showsFileImporter = false
    @State private var showsImportConfirmation = false
    @State private var selectedFile: SelectedCSVFile?
    @State private var importResult: CSVImportResult?
    @State private var statusMessage: String?
    @State private var isImporting = false
    @State private var nickname = ""
    @State private var newAccountID = UUID().uuidString.lowercased()

    init(context: AccountConnectorContext = .create) {
        self.context = context
    }

    var body: some View {
        NavigationStack {
            Form {
                if context.isCreating {
                    Section {
                        TextField("账户昵称", text: $nickname)
                            .textInputAutocapitalization(.words)
                            .autocorrectionDisabled()
                    } header: {
                        Text("账户昵称")
                    } footer: {
                        Text("用于区分多个账户，创建后仍可在账户详情中修改。")
                    }
                }

                Section {
                    Button {
                        showsFileImporter = true
                    } label: {
                        Label(selectedFile == nil ? "选择 CSV 文件" : "重新选择文件", systemImage: "folder")
                    }

                    if let selectedFile {
                        LabeledContent("文件", value: selectedFile.filename)
                        LabeledContent("大小", value: selectedFile.formattedSize)
                        LabeledContent("数据行", value: "\(selectedFile.dataRowCount)")
                        LabeledContent("识别列", value: selectedFile.headers.joined(separator: " · "))
                    }
                } header: {
                    Text("交易记录")
                } footer: {
                    Text("文件只在此 iPhone 内解析和保存，不会上传。最大 50 MB。")
                }

                Section("格式") {
                    requiredColumn("Date / Time", detail: "支持 Time (UTC) 和带时分秒日期")
                    requiredColumn("Action", detail: "BUY / SELL / DIVIDEND 及 212 交易类型")
                    requiredColumn("Ticker", detail: "例如 AAPL、LLOY.L")
                    requiredColumn("Quantity", detail: "交易股数")
                    requiredColumn("Price", detail: "每股成交价")
                    LabeledContent("可选", value: "Currency · Name")
                }

                if let selectedFile {
                    Section {
                        GlassPrimaryButton(
                            title: isImporting
                                ? "正在导入"
                                : (context.isCreating ? "创建 CSV 账户" : "导入并更新账户"),
                            systemImage: "arrow.down.doc",
                            isDisabled: isImporting || (context.isCreating && nickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        ) {
                            showsImportConfirmation = true
                        }

                        if selectedFile.dataRowCount == 0 {
                            StatusNotice(text: "CSV 没有可导入的数据行。")
                        }
                    } footer: {
                        Text(context.isCreating
                            ? "导入会按交易日期重算加权平均成本，并创建一个新账户。"
                            : "导入会按交易日期重算加权平均成本，只更新当前账户。")
                    }
                }

                if let importResult {
                    Section("导入完成") {
                        Label("已导入 \(importResult.holdingsCount) 个持仓", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(CatfolioTheme.positive)
                        if let count = importResult.transactionsCount {
                            LabeledContent("有效交易", value: "\(count) 条")
                        }
                        if importResult.backupCreated == true {
                            Label("持仓已保存到此 iPhone", systemImage: "iphone.gen3")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        ForEach((importResult.holdings ?? []).prefix(8)) { holding in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(holding.ticker)
                                        .font(.body.weight(.semibold))
                                    if !holding.name.isEmpty {
                                        Text(holding.name)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(DisplayFormat.shares(holding.shares))
                                        .font(.body.monospacedDigit())
                                    Text("均价 \(DisplayFormat.money(holding.averageCost, currency: holding.currency))")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } else if let statusMessage {
                    Section {
                        StatusNotice(text: statusMessage)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(CatfolioTheme.pageBackground(for: colorScheme))
            .navigationTitle(context.isCreating ? "新建 CSV 账户" : "CSV 导入")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("完成") { dismiss() }
                }
            }
            .fileImporter(
                isPresented: $showsFileImporter,
                allowedContentTypes: [.commaSeparatedText, .plainText],
                allowsMultipleSelection: false
            ) { result in
                handleFileSelection(result)
            }
            .task {
                guard nickname.isEmpty else { return }
                if let account = context.account {
                    nickname = AccountNaming.nickname(
                        from: account.displayName,
                        provider: AccountNaming.providerName(for: account.source)
                    )
                } else {
                    nickname = model.suggestedAccountNickname()
                }
            }
            .confirmationDialog(
                context.isCreating ? "创建 CSV 账户？" : "更新当前账户？",
                isPresented: $showsImportConfirmation,
                titleVisibility: .visible
            ) {
                Button(context.isCreating ? "导入并创建" : "导入并更新") {
                    Task { await importSelectedFile() }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text(context.isCreating
                    ? "请确认 CSV 包含完整交易记录。导入会创建新账户，不影响现有账户；已平仓持仓不显示。"
                    : "请确认 CSV 包含完整交易记录。导入只更新当前账户，不影响其他账户；已平仓持仓不显示。")
            }
        }
        .tint(CatfolioTheme.accent)
    }

    private func requiredColumn(_ name: String, detail: String) -> some View {
        LabeledContent {
            Text(detail)
                .foregroundStyle(.secondary)
        } label: {
            Text(name)
                .font(.body.monospaced())
        }
    }

    private func handleFileSelection(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            let hasAccess = url.startAccessingSecurityScopedResource()
            defer {
                if hasAccess { url.stopAccessingSecurityScopedResource() }
            }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            let file = try SelectedCSVFile(url: url, data: data)
            selectedFile = file
            if context.isCreating,
               AccountNaming.generatedNicknames.contains(nickname),
               let detectedName = file.detectedAccountNickname {
                nickname = model.suggestedAccountNickname(detectedName: detectedName)
            }
            importResult = nil
            statusMessage = nil
        } catch {
            selectedFile = nil
            importResult = nil
            statusMessage = error.localizedDescription
        }
    }

    private func importSelectedFile() async {
        guard let selectedFile, selectedFile.dataRowCount > 0 else { return }
        isImporting = true
        statusMessage = nil
        importResult = nil
        defer { isImporting = false }
        do {
            let targetAccount = context.account
            let source = targetAccount?.source ?? "CSV"
            let provider = AccountNaming.providerName(for: source)
            let accountName = targetAccount?.name
                ?? AccountNaming.displayName(provider: provider, nickname: nickname)
            importResult = try await model.importCSV(
                selectedFile.data,
                filename: selectedFile.filename,
                accountID: targetAccount?.accountID ?? newAccountID,
                accountName: accountName,
                source: source,
                replacingAccountsOnly: true
            )
        } catch {
            statusMessage = error.localizedDescription
        }
    }
}

private struct SelectedCSVFile {
    static let maximumBytes = 50 * 1024 * 1024

    let filename: String
    let data: Data
    let dataRowCount: Int
    let headers: [String]

    var detectedAccountNickname: String? {
        let stem = (filename as NSString).deletingPathExtension.lowercased()
        for (marker, nickname) in [
            ("stocks isa", "ISA"), ("_isa", "ISA"), ("-isa", "ISA"),
            ("invest", "Invest"), ("sipp", "SIPP"),
        ] where stem.contains(marker) {
            return nickname
        }
        return nil
    }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
    }

    init(url: URL, data: Data) throws {
        guard url.pathExtension.lowercased() == "csv" else {
            throw CSVSelectionError.invalidExtension
        }
        guard data.count <= Self.maximumBytes else {
            throw CSVSelectionError.fileTooLarge
        }
        guard var text = LocalCSVImporter.decodedText(from: data) else {
            throw CSVSelectionError.invalidEncoding
        }
        text = text.replacingOccurrences(of: "\u{feff}", with: "")
        let records = LocalCSVImporter.parseRecords(text)
        guard !records.isEmpty else {
            throw CSVSelectionError.emptyFile
        }
        guard let headerIndex = LocalCSVImporter.headerRowIndex(in: records) else {
            throw CSVSelectionError.missingColumns(["Date / Time", "Action", "Ticker", "Quantity", "Price"])
        }
        let headers = records[headerIndex]
        try Self.validate(headers: headers)
        filename = url.lastPathComponent
        self.data = data
        dataRowCount = max(0, records.count - headerIndex - 1)
        self.headers = Array(headers.prefix(8))
    }

    private static func validate(headers: [String]) throws {
        let displayNames = [
            "date": "Date / Time",
            "action": "Action",
            "ticker": "Ticker",
            "quantity": "Quantity",
            "price": "Price",
        ]
        let missing = LocalCSVImporter.missingRequiredColumns(in: headers).map {
            displayNames[$0] ?? $0
        }
        guard missing.isEmpty else {
            throw CSVSelectionError.missingColumns(missing)
        }
    }
}

private enum CSVSelectionError: LocalizedError {
    case invalidExtension
    case fileTooLarge
    case invalidEncoding
    case emptyFile
    case missingColumns([String])

    var errorDescription: String? {
        switch self {
        case .invalidExtension:
            "请选择扩展名为 .csv 的文件"
        case .fileTooLarge:
            "CSV 文件不能超过 50 MB"
        case .invalidEncoding:
            "CSV 必须使用 UTF-8、UTF-16 或常见 Windows 文本编码"
        case .emptyFile:
            "CSV 文件为空"
        case let .missingColumns(columns):
            "缺少必填列：\(columns.joined(separator: "、"))"
        }
    }
}
