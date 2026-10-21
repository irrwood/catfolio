import SwiftUI

struct CSVUpdateOptionsSection: View {
    @Binding var mode: CSVImportMode
    let info: CSVImportInfo?

    var body: some View {
        SettingsSection(L10n.text("更新方式")) {
            SettingsRowContainer {
                Picker(L10n.text("更新方式"), selection: $mode) {
                    Text(L10n.text("合并更新")).tag(CSVImportMode.merge)
                    Text(L10n.text("完整重建")).tag(CSVImportMode.rebuild)
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("csv-update-mode")
            }
            SettingsRowContainer {
                Text(mode == .merge
                     ? L10n.text("追加新交易，保留旧记录和手动补录；重复与修改会在预览中列出。")
                     : L10n.text("仅用于完整交易历史：替换此账户原有导入记录，保留手动补录。"))
                    .appText(.label)
                    .foregroundStyle(SettingsTemplate.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        if let info {
            SettingsSection(L10n.text("上次 CSV 更新")) {
                SettingsValueRow(title: L10n.text("导入时间"),
                    value: info.importedAt.formatted(date: .abbreviated, time: .shortened), valueIsNumeric: false)
                SettingsValueRow(title: L10n.text("文件"), value: info.filename, valueIsNumeric: false)
                SettingsValueRow(title: L10n.text("格式"), value: L10n.label(info.format), valueIsNumeric: false)
                if let first = info.firstDate, let last = info.lastDate {
                    SettingsValueRow(title: L10n.text("已保存的交易日期"), value: "\(first) – \(last)", valueIsNumeric: false)
                }
            }
        }
    }
}

struct CSVImportCountsSection: View {
    let counts: CSVImportCounts

    var body: some View {
        SettingsSection(L10n.text("交易更新")) {
            SettingsValueRow(title: L10n.text("新增交易"), value: "\(counts.added)")
            SettingsValueRow(title: L10n.text("重复，自动跳过"), value: "\(counts.duplicate)")
            SettingsValueRow(title: L10n.text("确认修改"), value: "\(counts.updated)")
            if counts.retained > 0 {
                SettingsValueRow(title: L10n.text("保留原记录"), value: "\(counts.retained)")
            }
        }
    }
}

struct CSVConflictSection: View {
    let conflicts: [CSVTransactionConflict]
    var onResolve: ((String, CSVConflictChoice) -> Void)?
    var onKeepAll: (() -> Void)? = nil

    var body: some View {
        SettingsSection(L10n.text("待确认的交易")) {
            if conflicts.filter({ $0.choice == nil }).count > 1, let onKeepAll {
                SettingsButtonRow(title: L10n.text("全部保留原记录，跳过对应 CSV 行"), showsChevron: false, action: onKeepAll)
                    .accessibilityIdentifier("csv-keep-all")
            }
            ForEach(conflicts) { conflict in
                SettingsRowContainer {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("\(conflict.incoming.ticker) · \(conflict.incoming.date)")
                            .appText(.subheading, weight: .semibold)
                        Text(conflict.ambiguous
                             ? L10n.text("缺少可匹配的交易编号，可能是重复记录，也可能是另一笔成交。")
                             : L10n.text("相同交易编号的内容发生了变化。"))
                            .appText(.label)
                            .foregroundStyle(SettingsTemplate.secondaryText)
                        ForEach(Array(conflict.existing.enumerated()), id: \.offset) { _, row in
                            Text(L10n.text("原记录：\(summary(row))"))
                                .appText(.label)
                        }
                        Text(L10n.text("CSV：\(summary(conflict.incoming))"))
                            .appText(.label)
                        Picker(L10n.text("处理方式"), selection: Binding<CSVConflictChoice?>(
                            get: { conflict.choice }, set: { value in
                                if let value { onResolve?(conflict.id, value) }
                            })) {
                            Text(L10n.text("请选择")).tag(Optional<CSVConflictChoice>.none)
                            Text(L10n.text("保留原记录，跳过此行")).tag(Optional(CSVConflictChoice.keepExisting))
                            if conflict.allowsReplacement {
                                Text(L10n.text("用 CSV 修正原记录")).tag(Optional(CSVConflictChoice.useIncoming))
                            }
                            if conflict.ambiguous {
                                Text(L10n.text("这是另一笔交易，新增")).tag(Optional(CSVConflictChoice.addBoth))
                            }
                        }
                        .pickerStyle(.menu)
                        .accessibilityIdentifier("csv-conflict-\(conflict.id)")
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func summary(_ row: LocalTransactionRecord) -> String {
        var parts = [row.action, DisplayFormat.shares(row.quantity) + " × " + String(row.price), row.currency]
        if let timestamp = row.executedAt { parts.append(timestamp) }
        if let rate = row.brokerFXRate { parts.append("FX \(rate)") }
        if let cash = row.cashPostings {
            parts.append(cash.map { "\($0.amount) \($0.currency)" }.joined(separator: ", "))
        }
        if let realised = row.realisedProfitLoss {
            parts.append("\(realised) \(row.realisedProfitLossCurrency ?? "")")
        }
        return parts.joined(separator: " · ")
    }
}
