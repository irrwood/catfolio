import SwiftUI

/// The main connection flow has one preparation screen; the longer guide is optional.
struct IBKRSetupIntro: View {
    var body: some View {
        AccountConnectionHeader(provider: .ibkr, title: L10n.text("准备 IBKR 凭证"),
                                subtitle: L10n.text("需要一个 Flex 报表，以及 Token 和 Query ID。"))
        AccountPreparationList {
            AccountPreparationFeature(symbol: "doc.text.fill", title: L10n.text("创建 Flex 报表"),
                detail: L10n.text("在 IBKR 网页端打开 Reporting → Flex Queries，新建 XML 报表。"))
            AccountPreparationFeature(symbol: "square.stack.3d.up.fill", title: L10n.text("包含四项数据"),
                detail: "Account Information · Open Positions · Trades · Cash Transactions")
            AccountPreparationFeature(symbol: "doc.on.doc.fill", title: L10n.text("复制两项凭证"),
                detail: L10n.text("记下报表的 Query ID，再启用 Flex Web Service 生成 Token。"))
        }
    }
}

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
        OnboardingHeader(title: title, subtitle: "Interactive Brokers")
        AccountPreparationList {
            if step == 0 {
                AccountPreparationFeature(symbol: "person.crop.rectangle.fill", title: L10n.text("打开 Flex Queries"),
                    detail: L10n.text("登录 Interactive Brokers 网页端，进入 Performance & Reports → Flex Queries。也可以从菜单 Reporting → Flex Queries 进入。"))
                AccountPreparationFeature(symbol: "doc.text.fill", title: L10n.text("创建账户报表"),
                    detail: L10n.text("Catfolio 使用自定义 Activity Flex Query，请在这里创建自己的报表。"))
            } else if step == 1 {
                AccountPreparationFeature(symbol: "doc.fill.badge.plus", title: "Activity Flex Query",
                    detail: L10n.text("在 Activity Flex Query 区域点击 +，将查询命名为 Catfolio，选择 XML 格式。"))
                AccountPreparationFeature(symbol: "checkmark.rectangle.fill", title: L10n.text("持仓与交易"),
                    detail: L10n.text("包含 Account Information、Open Positions、Trades、Cash Transactions 的全部字段。Trades 使用逐笔 Execution，Open Positions 使用 Summary。"))
                AccountPreparationFeature(symbol: "calendar.circle.fill", title: "Query ID",
                    detail: L10n.text("初次可选择最近 365 天。保存查询，并记下查询名称旁的 Query ID。"))
            } else {
                AccountPreparationFeature(symbol: "key.fill", title: "Flex Web Service",
                    detail: L10n.text("回到 Flex Queries，打开 Flex Web Service 的设置，启用服务并生成 Token，检查有效期和 IP 限制。"))
                AccountPreparationFeature(symbol: "pencil.circle.fill", title: L10n.text("填写连接凭证"),
                    detail: L10n.text("复制 Token 和刚保存的 Query ID，下一步填入 Catfolio。凭证保存在钥匙串，可在设置中开启跨设备同步。"))
                AccountPreparationFeature(symbol: "arrow.triangle.2.circlepath.circle.fill", title: L10n.text("预览与同步"),
                    detail: L10n.text("可以先保存并创建账户，稍后同步；也可以立即读取持仓，预览后再确认。IBKR 生成报表可能需要几分钟。"))
            }
        }
    }

    var documentationURL: URL {
        URL(string: step == 2
            ? "https://www.ibkrguides.com/clientportal/performanceandstatements/flex-web-service.htm"
            : "https://www.ibkrguides.com/clientportal/performanceandstatements/activityflex.htm")!
    }

    var actions: some View {
        VStack(spacing: 12) {
            OnboardingPrimaryButton(title: step == 2 ? L10n.text("返回") : L10n.text("下一步"),
                                    action: next)
        }
    }

}

/// Reopening help leaves the connection draft and its preview in the parent view.
struct IBKRGuideHelpView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.isWorkspaceDetail) private var isWorkspaceDetail
    @State private var step: Int
    @State private var showsNextStep = false
    @State private var didCopyBrief = false
    private var onFinish: (() -> Void)?

    init(initialStep: Int = 0, onFinish: (() -> Void)? = nil) {
        _step = State(initialValue: initialStep)
        self.onFinish = onFinish
    }

    private func finish() {
        if let onFinish { onFinish() } else { dismiss() }
    }

    private func next() {
        if step >= 2 { finish() }
        else if isWorkspaceDetail { showsNextStep = true }
        else { step += 1 }
    }

    var body: some View {
        OnboardingPage(scrollReset: step, isAccountPreparation: true) {
            IBKRAccountGuide(step: step, next: next, skip: finish)
            if step == 1 {
                Button(didCopyBrief ? L10n.text("已复制，去 IBKR 粘贴给它的助手") : L10n.text("复制配置提示词")) {
                    UIPasteboard.general.string = IBKRFlexQueryBrief.prompt
                    didCopyBrief = true
                }
                .appText(.callout, weight: .medium)
                .frame(minHeight: 44)
            }
        } actions: {
            IBKRAccountGuide(step: step, next: next, skip: finish).actions
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(!isWorkspaceDetail && step > 0)
        .navigationDestination(isPresented: $showsNextStep) {
            AnyView(IBKRGuideHelpView(initialStep: step + 1, onFinish: onFinish ?? { dismiss() }))
                .workspaceNavigationChrome()
        }
        .toolbar {
            if step > 0 && !isWorkspaceDetail {
                ToolbarItem(placement: .cancellationAction) {
                    Button { step -= 1 } label: {
                        Label(L10n.text("上一步"), systemImage: "chevron.left")
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink(L10n.text("官方教程")) {
                    OfficialBrokerTutorialPage(url: IBKRAccountGuide(step: step, next: {}, skip: {}).documentationURL)
                }
                .accessibilityIdentifier("ibkr-open-official-guide")
            }
        }
        .tint(CatfolioTheme.primaryText)
    }
}

struct IBKRConnectionIntro: View {
    var body: some View {
        OnboardingHeader(title: L10n.text("填写 IBKR 凭证"),
                         subtitle: L10n.text("粘贴 Token 和 Query ID，保存后即可同步。"))
    }
}
