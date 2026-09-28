import SwiftUI

/// Settings › 数据源状态: every source the app has asked this launch, and
/// what it last said. The page a reader opens when something shows no data,
/// to learn whether a source refused, timed out, or answered with nothing
/// usable — instead of an empty chart and a guess.
@MainActor struct DataSourceStatusView: View {
    @Environment(\.locale) private var appLocale
    let health: DataSourceHealth

    init() {
        self.health = DataSourceHealth.shared
    }

    init(health: DataSourceHealth) {
        self.health = health
    }

    var body: some View {
        SettingsPage {
            let rows = health.ordered
            if rows.isEmpty {
                SettingsFootnote(L10n.text("这次启动后还没有请求过任何数据源。"))
            } else {
                SettingsFootnote(L10n.text("以下是本次启动的请求记录。单个证券或接口失败，不代表整个数据源不可用。"))
                ForEach(DataSource.Kind.allCases, id: \.self) { kind in
                    let members = rows.filter { $0.source.kind == kind }
                    if !members.isEmpty {
                        SettingsSection(kind.title) {
                            ForEach(members, id: \.source) { entry in
                                DataSourceStatusRow(source: entry.source, status: entry.status)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(L10n.text("数据源状态"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct DataSourceStatusRow: View {
    let source: DataSource
    let status: DataSourceStatus

    var body: some View {
        SettingsRowContainer {
            HStack(alignment: .top, spacing: SettingsTemplate.iconSpacing) {
                Circle()
                    .fill(status.isFailing ? CatfolioTheme.danger : CatfolioTheme.positive)
                    .frame(width: 8, height: 8)
                    .padding(.top, 8)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: SettingsTemplate.subtitleSpacing) {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(source.title).appText(.body)
                            Spacer(minLength: 0)
                            countLabel.fixedSize()
                        }
                        VStack(alignment: .leading, spacing: SettingsTemplate.subtitleSpacing) {
                            Text(source.title).appText(.body)
                            countLabel
                        }
                    }
                    Text(summary)
                        .appText(.footnote)
                        .foregroundStyle(status.isFailing ? CatfolioTheme.danger : SettingsTemplate.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    // Distinct earlier issues; repeated requests still count above.
                    ForEach(status.distinctEarlierFailures.prefix(2)) { event in
                        Text(Self.line(for: event))
                            .appText(.caption)
                            .foregroundStyle(SettingsTemplate.secondaryText)
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var countLabel: some View {
        Text(L10n.text("连接成功 \(status.successCount) · 问题 \(status.failureCount)"))
            .appNumber(.caption)
            .foregroundStyle(SettingsTemplate.secondaryText)
    }

    private var summary: String {
        guard let event = status.lastEvent else { return "" }
        if event.outcome.isFailure { return Self.line(for: event) }
        return L10n.text("正常 · \(Self.timestamp(event.date))")
    }

    static func line(for event: DataSourceEvent) -> String {
        let what = event.outcome.readerDescription
        return what + " · " + timestamp(event.date)
    }

    static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: AppLanguage.currentIdentifier)
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

extension DataSource.Kind {
    var title: String {
        switch self {
        case .marketData: L10n.text("行情数据")
        case .filings: L10n.text("公司申报")
        case .news: L10n.text("新闻")
        case .ai: L10n.text("AI")
        case .broker: L10n.text("券商")
        case .other: L10n.text("其他")
        }
    }
}

extension DataSourceOutcome {
    /// What happened, as the reader can act on it.
    var readerDescription: String {
        switch self {
        case .success: L10n.text("正常")
        case .rateLimited: L10n.text("请求过于频繁（429），稍后重试")
        case .offline: L10n.text("网络未连接")
        case .timedOut: L10n.text("请求超时")
        case let .transport(detail): L10n.text("连接失败（\(L10n.message(detail))）")
        case let .unusable(reason): L10n.text("返回了数据但无法使用：\(L10n.message(reason))")
        case let .httpStatus(status):
            switch status {
            case 401: L10n.text("未授权（401），检查密钥")
            case 403: L10n.text("拒绝访问（403）")
            case 404: L10n.text("没有找到（404）")
            case 500...599: L10n.text("服务器错误（\(status)）")
            default: L10n.text("HTTP \(status)")
            }
        }
    }
}
