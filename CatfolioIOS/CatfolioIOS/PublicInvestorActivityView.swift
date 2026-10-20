import SwiftUI

struct PublicInvestorActivityView: View {
    @Environment(\.locale) private var appLocale
    @State private var investorID: String
    @State private var visibleCount = 40

    init(investorID: String = "") {
        _investorID = State(initialValue: investorID)
    }

    var body: some View {
        SettingsPage(title: L10n.text("持仓动态"), bottomInset: 32,
                     topInset: SettingsTemplate.pageInset, titleDisplayMode: .inline) {
            switch PublicInvestorCatalogState.shared.result {
            case .some(.success(let catalog)):
                content(catalog)
            case .some(.failure):
                SettingsFootnote(L10n.text("账户数据暂时无法读取。"))
            case .none:
                ProgressView()
            }
        }
        .task { PublicInvestorCatalogState.shared.loadIfNeeded() }
        .onChange(of: investorID) { _, _ in visibleCount = 40 }
    }

    @ViewBuilder
    private func content(_ catalog: PublicInvestorCatalog) -> some View {
        let records = catalog.recentActivities(investorID: investorID.isEmpty ? nil : investorID)
        SettingsCard {
            SettingsRowContainer {
                Picker(L10n.text("选择人物"), selection: $investorID) {
                    Text(L10n.text("全部人物")).tag("")
                    ForEach(catalog.investors) { investor in
                        Text(investor.title).tag(investor.id)
                    }
                }
                .pickerStyle(.menu)
                .appText(.subheading)
                .accessibilityIdentifier("investor-activity-filter")
            }
        }
        SettingsFootnote(L10n.text("记录更新至") + " " + catalog.asOf)
        if records.isEmpty {
            SettingsFootnote(L10n.text("暂无记录"))
        } else {
            LazyVStack(spacing: SettingsTemplate.sectionSpacing) {
                ForEach(records.prefix(visibleCount)) { record in
                    SettingsCard { PublicInvestorActivityRow(record: record) }
                }
            }
            if visibleCount < records.count {
                SettingsCard {
                    SettingsButtonRow(title: L10n.text("显示更多"), showsChevron: false) {
                        visibleCount += 40
                    }
                }
            }
        }
    }
}

struct PublicInvestorActivityRow: View {
    let record: PublicInvestorActivityItem
    private var activity: PublicInvestorActivity { record.activity }

    var body: some View {
        SettingsRowContainer {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: SettingsTemplate.iconSpacing) {
                    PublicInvestorAvatar(investorID: record.investor.id, size: 40)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(record.investor.title).appText(.subheading)
                        Text([activity.fund, activity.actionLabel].compactMap { $0 }.joined(separator: " · "))
                            .appText(.label).foregroundStyle(.secondary)
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(record.securityName).appText(.heading).fixedSize(horizontal: false, vertical: true)
                    if let ticker = activity.ticker {
                        Text(ticker).appText(.label).foregroundStyle(.secondary)
                    }
                    if let option = activity.option {
                        Text([option.putCall ?? "OPTION", option.expiry, option.strike.map { $0.formatted(.number) }]
                            .compactMap { $0 }.joined(separator: " · "))
                            .appNumber(.label).foregroundStyle(.secondary)
                    }
                    FinancialText(record.quantityLabel).appNumber(.body)
                        .fixedSize(horizontal: false, vertical: true)
                    if activity.owner == "SP" {
                        Text(L10n.text("持有人：配偶")).appText(.label).foregroundStyle(.secondary)
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.text(activity.exactDate == nil ? "申报期间" : "交易日期") + " · " + activity.dateLabel)
                    Text(L10n.text(activity.dateBasis == "TRADE_FILE_DATE" ? "交易文件日期" : "披露日期")
                         + " · " + activity.filedDate)
                }
                .appNumber(.label, weight: .regular)
                .foregroundStyle(.secondary)
                if let note = activity.note, !note.isEmpty {
                    Text(note).appText(.footnote).foregroundStyle(.secondary)
                }
                if activity.sourceType == "ARK_TRADE_NOTIFICATION" {
                    Text(L10n.text("ARK 基金交易通知未经对账，不含全部交易，不能据此还原当前完整持仓。"))
                        .appText(.caption).foregroundStyle(.secondary)
                } else if activity.exactDate == nil {
                    Text(L10n.text("季度持仓差额，不代表实际成交。"))
                        .appText(.caption).foregroundStyle(.secondary)
                }
                if let url = URL(string: activity.sourceURL), url.scheme == "https" {
                    Link(L10n.text(activity.sourceType == "ARK_TRADE_NOTIFICATION" ? "查看最新交易文件" : "查看原文"), destination: url)
                        .appText(.callout)
                        .frame(minHeight: 44, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("investor-activity-\(activity.id)")
    }
}
