import SwiftUI

struct IBKRAccountGuide: View {
    let step: Int
    let next: () -> Void
    let skip: () -> Void

    private var title: String {
        switch step {
        case 0: L10n.text("打开 Flex Queries")
        case 1: L10n.text("创建账户报表")
        default: L10n.text("获取 Token 和 Query ID")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Interactive Brokers").appText(.subheading, weight: .semibold)
            Text(L10n.text("第 \(step + 1) 步，共 4 步"))
                .appText(.label).foregroundStyle(SettingsTemplate.secondaryText)
            ProgressView(value: Double(step + 1), total: 4).tint(CatfolioTheme.accent)
            Text(title).font(.title2.weight(.bold)).accessibilityAddTraits(.isHeader)
        }
        SettingsCard {
            SettingsRowContainer {
                VStack(alignment: .leading, spacing: 16) {
                    if step == 0 {
                        Text(L10n.text("登录 Interactive Brokers 网页端，进入 Performance & Reports → Flex Queries。也可以从菜单 Reporting → Flex Queries 进入。"))
                        Text(L10n.text("Catfolio 使用自定义 Activity Flex Query，请在这里创建自己的报表。"))
                    } else if step == 1 {
                        Text(L10n.text("在 Activity Flex Query 区域点击 +，将查询命名为 Catfolio，选择 XML 格式。"))
                        Text(L10n.text("包含 Account Information、Open Positions、Trades、Cash Transactions 的全部字段。Trades 使用逐笔 Execution，Open Positions 使用 Summary。"))
                        Text(L10n.text("初次可选择最近 365 天。保存查询，并记下查询名称旁的 Query ID。"))
                    } else {
                        Text(L10n.text("回到 Flex Queries，打开 Flex Web Service 的设置，启用服务并生成 Token，检查有效期和 IP 限制。"))
                        Text(L10n.text("复制 Token 和刚保存的 Query ID，下一步填入 Catfolio。凭证仅保存在此 iPhone 的钥匙串中。"))
                        Text(L10n.text("可以先保存并创建账户，稍后同步；也可以立即读取持仓，预览后再确认。IBKR 生成报表可能需要几分钟。"))
                    }
                }
                .appText(.subheading)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        SettingsCard {
            SettingsRowContainer {
                GlassPrimaryButton(title: step == 2 ? L10n.text("已准备好，填写凭证") : L10n.text("下一步"),
                                   systemImage: "arrow.right", action: next)
            }
            if step == 0 {
                SettingsButtonRow(icon: .symbol("key"), title: L10n.text("已有 Token 和 Query ID，直接填写"),
                                  showsChevron: false, action: skip)
            }
            Link(destination: URL(string: step == 2
                ? "https://www.ibkrguides.com/clientportal/performanceandstatements/flex-web-service.htm"
                : "https://www.ibkrguides.com/clientportal/performanceandstatements/activityflex.htm")!) {
                SettingsRowContainer {
                    Label(L10n.text("查看官方图文教程"), systemImage: "arrow.up.right.square")
                        .appText(.subheading)
                }
            }
            .buttonStyle(SettingsRowButtonStyle())
        }
    }
}

/// Reopening help leaves the connection draft and its preview in the parent view.
struct IBKRGuideHelpView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var step = 0

    var body: some View {
        NavigationStack {
            SettingsPage(bottomInset: 32) {
                IBKRAccountGuide(step: step) {
                    if step < 2 { step += 1 } else { dismiss() }
                } skip: { dismiss() }
            }
            .navigationTitle(L10n.text("分步连接教程"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if step > 0 {
                    ToolbarItem(placement: .cancellationAction) {
                        Button { step -= 1 } label: {
                            Label(L10n.text("上一步"), systemImage: "chevron.left")
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    AppModalDoneButton { dismiss() }
                }
            }
        }
        .tint(CatfolioTheme.accent)
    }
}

struct IBKRConnectionIntro: View {
    let showGuide: () -> Void

    var body: some View {
        SettingsCard {
            SettingsRowContainer {
                HStack(spacing: 12) {
                    AssetLogo(ticker: "IBKR", logoSymbol: nil, size: 44)
                        .accessibilityHidden(true)
                    Text("Interactive Brokers")
                        .appText(.subheading, weight: .semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            SettingsRowContainer {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.text("连接账户"))
                        .font(.title2.weight(.bold))
                        .accessibilityAddTraits(.isHeader)
                    Text(L10n.text("输入从 Interactive Brokers 获取的 Token 和 Query ID，即可连接账户。"))
                        .appText(.subheading)
                        .foregroundStyle(SettingsTemplate.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            SettingsButtonRow(icon: .symbol("list.number"), title: L10n.text("查看分步教程"), action: showGuide)
                .accessibilityIdentifier("ibkr-open-setup-guide")
        }
    }
}
