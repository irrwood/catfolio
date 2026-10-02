import SwiftUI
import UniformTypeIdentifiers

struct CSVImportView: View {
    @Environment(\.locale) private var appLocale
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model

    let context: AccountConnectorContext

    @State private var showsFileImporter = false
    @State private var showsImportConfirmation = false
    @State private var selectedFile: SelectedCSVFile?
    @State private var importResult: CSVImportResult?
    @State private var statusMessage: String?
    @State private var isImporting = false
    @State private var isReadingFile = false
    @State private var fileSelectionGeneration = UUID()
    @State private var nickname = ""
    @State private var newAccountID = UUID().uuidString.lowercased()

    init(context: AccountConnectorContext = .create) {
        self.context = context
    }

    var body: some View {
        NavigationStack {
            SettingsPage(bottomInset: 32) {
                if context.isCreating {
                    SettingsSectionHeader(L10n.text("账户昵称"))
                    SettingsCard {
                        SettingsFieldRow(L10n.text("账户昵称"), text: $nickname)
                            .textInputAutocapitalization(.words)
                            .autocorrectionDisabled()
                    }
                }

                SettingsSectionHeader(L10n.text("交易记录"))
                SettingsCard {
                    SettingsButtonRow(
                        icon: .symbol("folder"),
                        title: selectedFile == nil ? L10n.text("选择 CSV 文件") : L10n.text("重新选择文件"),
                        showsChevron: false
                    ) {
                        showsFileImporter = true
                    }
                    .disabled(isImporting)

                    if isReadingFile { ProgressView().padding() }
                    if let selectedFile {
                        SettingsValueRow(title: L10n.text("文件"), value: selectedFile.filename, valueIsNumeric: false)
                        SettingsValueRow(title: L10n.text("大小"), value: selectedFile.formattedSize)
                        SettingsValueRow(title: L10n.text("数据行"), value: selectedFile.dataRowCount.map(String.init) ?? L10n.text("导入时统计"))
                        SettingsValueRow(title: L10n.text("识别列"), value: selectedFile.headers.joined(separator: " · "), valueIsNumeric: false)
                    }
                }
                SettingsFootnote(L10n.text("本机处理，不上传；最大 50 MB。"))

                SettingsSection(L10n.text("格式")) {
                    requiredColumn("Date / Time", detail: L10n.text("支持 Time (UTC) 和带时分秒日期"))
                    requiredColumn("Action", detail: L10n.text("BUY / SELL / DIVIDEND 及 212 交易类型"))
                    requiredColumn("Ticker", detail: L10n.text("例如 AAPL、LLOY.L"))
                    requiredColumn("Quantity", detail: L10n.text("交易股数"))
                    requiredColumn("Price", detail: L10n.text("每股成交价"))
                    SettingsValueRow(title: L10n.text("可选"), value: "Currency · Name", valueIsNumeric: false)
                }

                if let selectedFile {
                    SettingsCard {
                        SettingsRowContainer {
                            GlassPrimaryButton(
                                title: isImporting
                                    ? L10n.text("正在导入")
                                    : (context.isCreating ? L10n.text("创建 CSV 账户") : L10n.text("导入并更新账户")),
                                systemImage: "arrow.down.doc",
                                isDisabled: !selectedFile.hasDataRows || isReadingFile
                                    || (context.isCreating && nickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty),
                                isBusy: isImporting
                            ) {
                                showsImportConfirmation = true
                            }
                        }

                        if selectedFile.dataRowCount == 0 {
                            SettingsRowContainer {
                                StatusNotice(text: L10n.text("CSV 没有可导入的数据行。"))
                            }
                        }
                    }
                }

                if let importResult {
                    CSVImportResultSection(result: importResult)
                } else if let statusMessage {
                    SettingsCard {
                        SettingsRowContainer {
                            StatusNotice(text: statusMessage)
                        }
                    }
                }
            }
            .softTopScrollEdge()
            .navigationTitle(context.isCreating ? L10n.text("新建 CSV 账户") : L10n.text("CSV 导入"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if context.isCreating {
                    ToolbarItem(placement: .cancellationAction) { AccountProviderBackButton() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    AppModalDoneButton { dismiss() }
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
                context.isCreating ? L10n.text("创建 CSV 账户？") : L10n.text("更新当前账户？"),
                isPresented: $showsImportConfirmation,
                titleVisibility: .visible
            ) {
                Button(context.isCreating ? L10n.text("导入并创建") : L10n.text("导入并更新")) {
                    Task { await importSelectedFile() }
                }
                Button(L10n.text("取消"), role: .cancel) {}
            } message: {
                Text(context.isCreating
                    ? L10n.text("请确认 CSV 包含完整交易记录。导入将创建新账户并重算成本。")
                    : L10n.text("请确认 CSV 包含完整交易记录。导入将更新当前账户并重算成本；其他账户不受影响。"))
            }
        }
        .tint(CatfolioTheme.accent)
    }

    /// A column the file has to carry, and what goes in it. The name is set
    /// fixed-width because it is a literal header string, not prose.
    private func requiredColumn(_ name: String, detail: String) -> some View {
        SettingsRowContainer {
            HStack(spacing: SettingsTemplate.valueSpacing) {
                Text(name)
                    .font(.body.monospaced())
                Spacer(minLength: 8)
                Text(detail)
                    .appText(.subheading)
                    .foregroundStyle(SettingsTemplate.readOnlyValue)
                    .multilineTextAlignment(.trailing)
            }
        }
    }

    private func handleFileSelection(_ result: Result<[URL], Error>) {
        let generation = UUID()
        fileSelectionGeneration = generation
        isReadingFile = true
        selectedFile = nil
        importResult = nil
        statusMessage = nil
        Task {
            defer { if fileSelectionGeneration == generation { isReadingFile = false } }
            do {
                guard let url = try result.get().first else { return }
                let file = try await Task.detached(priority: .userInitiated) {
                    let hasAccess = url.startAccessingSecurityScopedResource()
                    defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
                    if let size, size > SelectedCSVFile.maximumBytes { throw CSVSelectionError.fileTooLarge }
                    let data = try Data(contentsOf: url, options: .mappedIfSafe)
                    return try SelectedCSVFile(url: url, data: data)
                }.value
                guard fileSelectionGeneration == generation, !Task.isCancelled else { return }
                selectedFile = file
                if context.isCreating, AccountNaming.generatedNicknames.contains(nickname),
                   let detectedName = file.detectedAccountNickname {
                    nickname = model.suggestedAccountNickname(detectedName: detectedName)
                }
            } catch {
                guard fileSelectionGeneration == generation else { return }
                statusMessage = error.localizedDescription
            }
        }
    }

    private func importSelectedFile() async {
        guard !isImporting, !isReadingFile, let selectedFile, selectedFile.hasDataRows else { return }
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

/// The saved result includes parser warnings: skipped rows must remain visible
/// even when the valid rows were successfully imported.
struct CSVImportResultSection: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let result: CSVImportResult

    var body: some View {
        SettingsSection(result.warnings.isEmpty
                ? L10n.text("导入完成") : L10n.text("导入完成，请检查提示")) {
            SettingsRowContainer {
                Label(L10n.text("已导入 \(result.holdingsCount) 个持仓"), systemImage: "checkmark.circle")
                    .appText(.subheading)
                    .foregroundStyle(CatfolioTheme.positive)
            }
            if let count = result.transactionsCount {
                if dynamicTypeSize.isAccessibilitySize {
                    SettingsRowContainer {
                        VStack(alignment: .leading, spacing: SettingsTemplate.subtitleSpacing) {
                            Text(L10n.text("有效交易")).appText(.subheading)
                            Text(L10n.text("\(count) 条"))
                                .appNumber(.subheading)
                                .foregroundStyle(SettingsTemplate.secondaryText)
                        }
                    }
                } else {
                    SettingsValueRow(title: L10n.text("有效交易"), value: L10n.text("\(count) 条"))
                }
            }
            ForEach(Array(result.warnings.enumerated()), id: \.offset) { index, warning in
                SettingsRowContainer {
                    StatusNotice(text: warning)
                        .accessibilityIdentifier("csv-import-warning-\(index)")
                }
            }
            ForEach((result.holdings ?? []).prefix(8)) { holding in
                SettingsRowContainer {
                    HStack {
                        VStack(alignment: .leading, spacing: SettingsTemplate.subtitleSpacing) {
                            Text(holding.ticker)
                                .appText(.subheading, weight: .semibold)
                            if !holding.name.isEmpty {
                                Text(holding.name)
                                    .appText(.label, weight: .regular)
                                    .foregroundStyle(SettingsTemplate.secondaryText)
                            }
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: SettingsTemplate.subtitleSpacing) {
                            Text(DisplayFormat.shares(holding.shares))
                                .appNumber(.subheading)
                            Text(L10n.text("均价 \(DisplayFormat.money(holding.averageCost, currency: holding.currency))"))
                                .appNumber(.label, weight: .regular, monospaced: false)
                                .foregroundStyle(SettingsTemplate.secondaryText)
                        }
                    }
                }
            }
        }
    }
}

struct SelectedCSVFile: Sendable {
    static let maximumBytes = 50 * 1024 * 1024

    let filename: String
    let data: Data
    let dataRowCount: Int?
    let hasDataRows: Bool
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
        // Preview at most 27 records; full parsing happens once, on import.
        let records = LocalCSVImporter.parseRecords(text, maximumRecords: 27)
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
        let previewRows = max(0, records.count - headerIndex - 1)
        hasDataRows = previewRows > 0
        dataRowCount = records.count < 27 ? previewRows : nil
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
            L10n.text("请选择扩展名为 .csv 的文件")
        case .fileTooLarge:
            L10n.text("CSV 文件不能超过 50 MB")
        case .invalidEncoding:
            L10n.text("CSV 必须使用 UTF-8、UTF-16 或常见 Windows 文本编码")
        case .emptyFile:
            L10n.text("CSV 文件为空")
        case let .missingColumns(columns):
            L10n.text("缺少必填列：\(columns.joined(separator: L10n.listSeparator))")
        }
    }
}
