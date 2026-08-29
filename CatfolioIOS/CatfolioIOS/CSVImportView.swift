import SwiftUI
import UniformTypeIdentifiers

struct CSVImportView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel

    @State private var showsFileImporter = false
    @State private var showsImportConfirmation = false
    @State private var selectedFile: SelectedCSVFile?
    @State private var importResult: CSVImportResult?
    @State private var statusMessage: String?
    @State private var isImporting = false

    var body: some View {
        NavigationStack {
            Form {
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
                    Text("文件只在此 iPhone 内解析和保存，不会上传。最大 5 MB。")
                }

                Section("格式") {
                    requiredColumn("Date", detail: "YYYY-MM-DD 或常见日期格式")
                    requiredColumn("Action", detail: "BUY / SELL / DIVIDEND")
                    requiredColumn("Ticker", detail: "例如 AAPL、LLOY.L")
                    requiredColumn("Quantity", detail: "交易股数")
                    requiredColumn("Price", detail: "每股成交价")
                    LabeledContent("可选", value: "Currency · Name")
                }

                if let selectedFile {
                    Section {
                        GlassPrimaryButton(
                            title: isImporting ? "正在导入" : "导入并替换持仓",
                            systemImage: "arrow.down.doc",
                            isDisabled: isImporting
                        ) {
                            showsImportConfirmation = true
                        }

                        if selectedFile.dataRowCount == 0 {
                            Text("CSV 没有可导入的数据行。")
                                .font(.footnote)
                                .foregroundStyle(CatfolioStyle.red)
                        }
                    } footer: {
                        Text("导入会按交易日期重新计算加权平均成本，并替换当前持仓数据。")
                    }
                }

                if let importResult {
                    Section("导入完成") {
                        Label("已导入 \(importResult.holdingsCount) 个持仓", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(CatfolioStyle.green)
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
                                    Text(holding.shares.formatted(.number.precision(.fractionLength(0...4))))
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
                        Label(statusMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(CatfolioStyle.red)
                    }
                }
            }
            .navigationTitle("CSV 导入")
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
            .confirmationDialog(
                "导入后将替换当前持仓",
                isPresented: $showsImportConfirmation,
                titleVisibility: .visible
            ) {
                Button("导入并替换", role: .destructive) {
                    Task { await importSelectedFile() }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("请确认 CSV 包含完整交易记录。导入会替换本机当前持仓；已平仓持仓不会显示。")
            }
        }
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
            selectedFile = try SelectedCSVFile(url: url, data: data)
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
            importResult = try await model.importCSV(selectedFile.data, filename: selectedFile.filename)
        } catch {
            statusMessage = error.localizedDescription
        }
    }
}

private struct SelectedCSVFile {
    static let maximumBytes = 5 * 1024 * 1024

    let filename: String
    let data: Data
    let dataRowCount: Int
    let headers: [String]

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
        guard var text = String(data: data, encoding: .utf8) else {
            throw CSVSelectionError.invalidEncoding
        }
        text = text.replacingOccurrences(of: "\u{feff}", with: "")
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: true)
        guard let headerLine = lines.first else {
            throw CSVSelectionError.emptyFile
        }
        let headers = Self.parseHeader(String(headerLine))
        try Self.validate(headers: headers)
        filename = url.lastPathComponent
        self.data = data
        dataRowCount = max(0, lines.count - 1)
        self.headers = Array(headers.prefix(8))
    }

    private static func validate(headers: [String]) throws {
        let normalized = Set(headers.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        let requiredAliases: [(String, Set<String>)] = [
            ("Date", ["date", "trade date", "transaction date", "time"]),
            ("Action", ["action", "type", "transaction type", "side", "direction"]),
            ("Ticker", ["ticker", "symbol", "instrument", "stock", "isin", "code"]),
            ("Quantity", ["quantity", "qty", "shares", "units", "amount", "no. of shares"]),
            ("Price", ["price", "price / share", "trade price", "unit price", "execution price"]),
        ]
        let missing = requiredAliases.compactMap { name, aliases in
            normalized.isDisjoint(with: aliases) ? name : nil
        }
        guard missing.isEmpty else {
            throw CSVSelectionError.missingColumns(missing)
        }
    }

    private static func parseHeader(_ line: String) -> [String] {
        var fields: [String] = []
        var field = ""
        var insideQuotes = false
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            if character == "\"" {
                let next = line.index(after: index)
                if insideQuotes, next < line.endIndex, line[next] == "\"" {
                    field.append("\"")
                    index = next
                } else {
                    insideQuotes.toggle()
                }
            } else if character == ",", !insideQuotes {
                fields.append(field)
                field = ""
            } else {
                field.append(character)
            }
            index = line.index(after: index)
        }
        fields.append(field)
        return fields
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
            "CSV 文件不能超过 5 MB"
        case .invalidEncoding:
            "CSV 必须使用 UTF-8 编码"
        case .emptyFile:
            "CSV 文件为空"
        case let .missingColumns(columns):
            "缺少必填列：\(columns.joined(separator: "、"))"
        }
    }
}
