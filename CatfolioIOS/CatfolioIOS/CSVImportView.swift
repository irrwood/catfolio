import SwiftUI
import UniformTypeIdentifiers

struct CSVImportView: View {
    @Environment(\.locale) private var appLocale
    @Environment(\.dismiss) private var dismissPage
    @Environment(\.accountFlowClose) private var accountFlowClose
    @Environment(AppModel.self) private var model

    let context: AccountConnectorContext
    private let isFirstLaunchSetup: Bool

    @State private var showsFileImporter = false
    @State private var showsImportConfirmation = false
    @State private var selectedFile: SelectedCSVFile?
    @State private var importResult: CSVImportResult?
    /// The file read and compared with the account; nothing written yet.
    @State private var preview: CSVImportPreview?
    @State private var isPreparing = false
    @State private var statusMessage: String?
    @State private var isImporting = false
    @State private var isReadingFile = false
    @State private var fileSelectionGeneration = UUID()
    @State private var nickname = ""
    @State private var newAccountID = UUID().uuidString.lowercased()
    @State private var importMode = CSVImportMode.merge
    @State private var conflictChoices: [String: CSVConflictChoice] = [:]
    @State private var lastImport: CSVImportInfo?
    @State private var availableUndo: UUID?

    init(context: AccountConnectorContext = .create, isFirstLaunchSetup: Bool = false) {
        self.context = context
        self.isFirstLaunchSetup = isFirstLaunchSetup
    }

    /// Inside 添加账户 this closes the whole flow; on its own, the page.
    private func dismiss() {
        if let accountFlowClose { accountFlowClose() } else { dismissPage() }
    }

    var body: some View {
        AccountFlowStack { page(1) }
            .accountFlowBrand(.csv)
    }

    private func page(_ page: Int) -> some View {
        let selectedFile = !context.isCreating || page == 2 ? self.selectedFile : nil
        let preview = !context.isCreating || page == 2 ? self.preview : nil
        return AccountFlowPage(showsNext: Binding(
            get: { context.isCreating && flowStep > page },
            set: { shown in
                guard !shown, flowStep > page else { return }
                fileSelectionGeneration = UUID()
                self.selectedFile = nil
                self.preview = nil
                conflictChoices = [:]
                statusMessage = nil
                isReadingFile = false
                isPreparing = false
            })) {
            OnboardingPage(scrollReset: page, isAccountPreparation: selectedFile == nil && !isReadingFile) {
                AccountConnectionHeader(provider: .csv, title: importResult != nil ? L10n.text("导入完成")
                    : (selectedFile != nil ? L10n.text("确认交易记录") : (context.isCreating ? L10n.text("导入 CSV") : L10n.text("更新 CSV"))),
                    subtitle: importResult != nil ? nil : L10n.text("选择交易记录文件，预览后确认导入。"))
                if selectedFile == nil && !isReadingFile {
                    VStack(spacing: 0) {
                        AccountPreparationFeature(symbol: "doc.text.fill", title: L10n.text("选择交易记录"),
                            detail: L10n.text("从券商导出 CSV 文件，再从这里选择。"))
                        AccountPreparationFeature(symbol: "checkmark.seal.fill", title: L10n.text("先预览，再导入"),
                            detail: L10n.text("本机处理，不上传；最大 50 MB。"))
                    }
                }
                if context.isCreating, selectedFile != nil, importResult == nil {
                    SettingsSectionHeader(L10n.text("账户昵称"))
                    SettingsCard {
                        SettingsFieldRow(L10n.text("账户昵称"), text: $nickname)
                            .textInputAutocapitalization(.words)
                            .autocorrectionDisabled()
                    }
                }

                if !context.isCreating, importResult == nil {
                    CSVUpdateOptionsSection(mode: $importMode, info: lastImport)
                        .disabled(isImporting || isPreparing || isReadingFile)
                }
                if selectedFile != nil || isReadingFile {
                    SettingsSectionHeader(L10n.text("交易记录"))
                    SettingsCard {
                        if selectedFile != nil {
                            SettingsButtonRow(
                                icon: .symbol("folder"),
                                title: selectedFile == nil ? L10n.text("选择 CSV 文件") : L10n.text("重新选择文件"),
                                showsChevron: false
                            ) {
                                showsFileImporter = true
                            }
                            .disabled(isImporting)
                        }

                        if isReadingFile { ProgressView().padding() }
                        if let selectedFile {
                            SettingsValueRow(title: L10n.text("文件"), value: selectedFile.filename, valueIsNumeric: false)
                            SettingsValueRow(title: L10n.text("大小"), value: selectedFile.formattedSize)
                            SettingsValueRow(title: L10n.text("数据行"), value: selectedFile.dataRowCount.map(String.init) ?? L10n.text("导入时统计"))
                            SettingsValueRow(title: L10n.text("识别列"), value: selectedFile.headers.joined(separator: " · "), valueIsNumeric: false)
                        }
                    }
                }
                if let selectedFile, selectedFile.dataRowCount == 0 {
                    SettingsCard {
                        SettingsRowContainer {
                            StatusNotice(text: L10n.text("CSV 没有可导入的数据行。"))
                        }
                    }
                }

                if let importResult {
                    CSVImportResultSection(result: importResult)
                } else if let preview {
                    CSVImportPreviewSection(preview: preview, onResolve: { id, choice in
                        conflictChoices[id] = choice
                        rebuildPreview()
                    }, onKeepAll: {
                        for conflict in preview.conflicts where conflict.choice == nil {
                            conflictChoices[conflict.id] = .keepExisting
                        }
                        rebuildPreview()
                    })
                    .disabled(isImporting || isPreparing)
                } else if isPreparing {
                    SettingsCard {
                        SettingsRowContainer {
                            HStack(spacing: SettingsTemplate.iconSpacing) {
                                ProgressView()
                                Text(L10n.text("正在检查 CSV…"))
                                    .appText(.subheading)
                                    .foregroundStyle(SettingsTemplate.secondaryText)
                            }
                        }
                    }
                }
                if let statusMessage {
                    SettingsCard {
                        SettingsRowContainer {
                            StatusNotice(text: statusMessage)
                        }
                    }
                }
                if let availableUndo {
                    SettingsCard {
                        SettingsButtonRow(title: L10n.text("撤销上次 CSV 导入"), showsChevron: false) {
                            Task { await undoImport(availableUndo) }
                        }
                        .disabled(isImporting || isPreparing || isReadingFile)
                        .accessibilityIdentifier("csv-undo")
                    }
                }
                if importResult == nil {
                    DisclosureGroup(L10n.text("查看 CSV 格式要求")) {
                        SettingsSection(L10n.text("格式")) {
                            requiredColumn("Date / Time", detail: L10n.text("支持 Time (UTC) 和带时分秒日期"))
                            requiredColumn("Action", detail: L10n.text("BUY / SELL / DIVIDEND 及 212 交易类型"))
                            requiredColumn("Ticker", detail: L10n.text("例如 AAPL、LLOY.L"))
                            requiredColumn("Quantity", detail: L10n.text("交易股数"))
                            requiredColumn("Price", detail: L10n.text("每股成交价"))
                            SettingsValueRow(title: L10n.text("可选"), value: "Currency · Name", valueIsNumeric: false)
                        }
                    }
                }
            } actions: { flowActions(page) }
            .toolbar {
                if !context.isCreating || importResult != nil {
                    ToolbarItem(placement: .confirmationAction) {
                        AppModalDoneButton { dismiss() }
                    }
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
                await loadImportJournal()
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
            .onChange(of: importMode) { _, _ in
                conflictChoices = [:]
                rebuildPreview()
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
                Text(confirmationMessage)
            }
        } next: { AnyView(self.page(page + 1)) }
    }

    /// What confirming will do, including what the preview found missing.
    private var confirmationMessage: String {
        var lines = [context.isCreating
            ? L10n.text("导入将创建新账户并重算成本。")
            : (importMode == .merge
                ? L10n.text("新增交易将合并到账户，旧记录和手动补录会保留；按预览中的选择处理冲突。")
                : L10n.text("完整重建将替换此账户原有的导入记录，保留手动补录，并重算持仓和成本。请确认文件包含完整历史。"))]
        if let preview {
            if preview.result.skippedRowCount > 0 {
                lines.append(L10n.text("有 \(preview.result.skippedRowCount) 行无法读取，不会导入。"))
            }
            if preview.removedCount > 0 {
                lines.append(L10n.text("\(preview.removedCount) 个现有持仓将被移除。"))
            }
        }
        lines.append(L10n.text("导入前会自动备份当前组合。"))
        return lines.joined(separator: "\n")
    }

    private var flowStep: Int { selectedFile != nil || importResult != nil ? 2 : 1 }

    @ViewBuilder
    private func flowActions(_ page: Int) -> some View {
        let selectedFile = !context.isCreating || page == 2 ? self.selectedFile : nil
        if importResult != nil {
            OnboardingPrimaryButton(title: L10n.text("完成")) { dismiss() }
        } else if let selectedFile {
            OnboardingPrimaryButton(
                title: isImporting
                    ? L10n.text("正在导入")
                    : (context.isCreating ? L10n.text("创建 CSV 账户") : L10n.text("导入并更新账户")),
                isDisabled: !selectedFile.hasDataRows || isReadingFile || preview == nil
                    || preview?.canCommit != true || isPreparing
                    || (context.isCreating && nickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty),
                isBusy: isImporting || isPreparing
            ) {
                showsImportConfirmation = true
            }
        } else {
            OnboardingPrimaryButton(title: L10n.text("选择 CSV 文件"),
                isBusy: isReadingFile) { showsFileImporter = true }
        }
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
        isPreparing = false
        selectedFile = nil
        importResult = nil
        preview = nil
        conflictChoices = [:]
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
                if file.hasDataRows { Task { await prepare(file, generation: generation) } }
            } catch {
                guard fileSelectionGeneration == generation else { return }
                statusMessage = error.localizedDescription
            }
        }
    }

    private var targetSource: String { context.account?.source ?? "CSV" }
    private var targetAccountID: String? { context.isCreating ? newAccountID : context.account?.accountID }
    private var targetAccountKey: String {
        "\(targetSource)|\(targetAccountID.flatMap { $0.isEmpty ? nil : $0 } ?? "default")"
    }

    /// Reads the whole file and compares it with the account. Writes nothing.
    private func prepare(_ file: SelectedCSVFile, generation: UUID) async {
        isPreparing = true
        defer { if fileSelectionGeneration == generation { isPreparing = false } }
        do {
            let prepared = try await model.prepareCSVImport(file.data, accountID: targetAccountID,
                source: targetSource, filename: file.filename, mode: importMode)
            guard fileSelectionGeneration == generation else { return }
            preview = prepared
        } catch {
            guard fileSelectionGeneration == generation else { return }
            statusMessage = error.localizedDescription
        }
    }

    private func importSelectedFile() async {
        guard !isImporting, !isReadingFile, !isPreparing, let preview, preview.canCommit else { return }
        isImporting = true
        statusMessage = nil
        importResult = nil
        defer { isImporting = false }
        do {
            let provider = AccountNaming.providerName(for: targetSource)
            let accountName = context.account?.name
                ?? AccountNaming.displayName(provider: provider, nickname: nickname)
            importResult = try await model.commitCSVImport(
                preview,
                accountID: targetAccountID,
                accountName: accountName,
                source: targetSource,
                replacingAccountsOnly: true
            )
            await loadImportJournal()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func rebuildPreview() {
        guard var plan = preview?.updatePlan else { return }
        plan.mode = importMode
        let choices = conflictChoices
        let generation = UUID()
        fileSelectionGeneration = generation
        isPreparing = true
        Task {
            let updated = await Task.detached(priority: .userInitiated) { plan.preview(choices: choices) }.value
            guard generation == fileSelectionGeneration else { return }
            preview = updated
            isPreparing = false
        }
    }

    private func loadImportJournal() async {
        guard let journal = try? await LocalPortfolioStore.shared.csvImportJournal(accountKey: targetAccountKey) else { return }
        lastImport = journal.info
        availableUndo = journal.undo?.id
    }

    private func undoImport(_ id: UUID) async {
        isImporting = true
        defer { isImporting = false }
        do {
            try await model.undoCSVImport(accountKey: targetAccountKey, id: id)
            importResult = nil
            preview = nil
            selectedFile = nil
            availableUndo = nil
            statusMessage = L10n.text("已撤销 CSV 导入。")
            await loadImportJournal()
        } catch { statusMessage = error.localizedDescription }
    }
}

/// Before anything is written: the trades read, every row left out and why,
/// and each holding the import would add, remove or change.
struct CSVImportPreviewSection: View {
    let preview: CSVImportPreview
    var onResolve: ((String, CSVConflictChoice) -> Void)? = nil
    var onKeepAll: (() -> Void)? = nil

    var body: some View {
        let result = preview.result
        if let counts = preview.counts {
            CSVImportCountsSection(counts: counts)
        }
        if !preview.conflicts.isEmpty {
            CSVConflictSection(conflicts: preview.conflicts, onResolve: onResolve, onKeepAll: onKeepAll)
        }
        if let problem = preview.problem {
            SettingsCard {
                SettingsRowContainer { StatusNotice(text: problem) }
            }
        }
        SettingsSection(result.skippedRowCount > 0 || preview.removedCount > 0
                ? L10n.text("导入前请检查") : L10n.text("导入预览")) {
            SettingsValueRow(title: L10n.text("有效交易"), value: L10n.text("\(result.transactionsCount ?? 0) 条"))
            if preview.canCommit {
                SettingsValueRow(title: L10n.text("导入后持仓"), value: L10n.text("\(result.holdingsCount) 个持仓"))
            }
            if result.skippedRowCount > 0 {
                SettingsValueRow(title: L10n.text("无法读取，将跳过"), value: L10n.text("\(result.skippedRowCount) 行"))
            }
            ForEach(Array(result.warnings.enumerated()), id: \.offset) { index, warning in
                SettingsRowContainer {
                    StatusNotice(text: warning)
                        .accessibilityIdentifier("csv-preview-warning-\(index)")
                }
            }
        }
        if !preview.changes.isEmpty || preview.unchangedCount > 0 {
            SettingsSection(L10n.text("持仓变化")) {
                ForEach(preview.changes) { change in
                    SettingsRowContainer {
                        HStack {
                            VStack(alignment: .leading, spacing: SettingsTemplate.subtitleSpacing) {
                                Text(change.ticker)
                                    .appText(.subheading, weight: .semibold)
                                Text(title(for: change.kind))
                                    .appText(.label, weight: .regular)
                                    .foregroundStyle(SettingsTemplate.secondaryText)
                            }
                            Spacer()
                            FinancialText(sharesText(change))
                                .appNumber(.subheading)
                                .foregroundStyle(change.kind == .removed ? SettingsTemplate.secondaryText : CatfolioTheme.primaryText)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("csv-preview-change-\(change.ticker)")
                }
                if preview.unchangedCount > 0 {
                    SettingsValueRow(title: L10n.text("不变"), value: L10n.text("\(preview.unchangedCount) 个持仓"))
                }
            }
        }
        SettingsFootnote(L10n.text("确认导入前不会改动账户；导入时会先自动备份当前组合。"))
    }

    private func title(for kind: CSVImportPreview.Change.Kind) -> String {
        switch kind {
        case .added: L10n.text("新增")
        case .removed: L10n.text("将移除")
        case .changed: L10n.text("股数变化")
        }
    }

    private func sharesText(_ change: CSVImportPreview.Change) -> String {
        switch change.kind {
        case .added: DisplayFormat.shares(change.sharesAfter ?? 0)
        case .removed: DisplayFormat.shares(change.sharesBefore ?? 0) + " → 0"
        case .changed: "\(DisplayFormat.shares(change.sharesBefore ?? 0)) → \(DisplayFormat.shares(change.sharesAfter ?? 0))"
        }
    }
}

/// The saved result includes parser warnings: skipped rows must remain visible
/// even when the valid rows were successfully imported.
struct CSVImportResultSection: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let result: CSVImportResult

    var body: some View {
        if let counts = result.importCounts {
            CSVImportCountsSection(counts: counts)
        }
        SettingsSection(result.warnings.isEmpty
                ? L10n.text("导入完成") : L10n.text("导入完成，请检查提示")) {
            SettingsRowContainer {
                Label(L10n.text("已导入 \(result.holdingsCount) 个持仓"), systemImage: "checkmark.circle")
                    .appText(.subheading)
                    .foregroundStyle(CatfolioTheme.positive)
            }
            if result.backupCreated == true {
                SettingsRowContainer {
                    Label(L10n.text("已在导入前备份原组合"), systemImage: "externaldrive.badge.checkmark")
                        .appText(.subheading)
                        .foregroundStyle(SettingsTemplate.secondaryText)
                }
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
                            FinancialText(DisplayFormat.shares(holding.shares))
                                .appNumber(.subheading)
                            FinancialText(L10n.text("均价 \(DisplayFormat.money(holding.averageCost, currency: holding.currency))"))
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
