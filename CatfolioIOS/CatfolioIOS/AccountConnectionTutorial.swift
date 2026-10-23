import SwiftUI

/// Every connector uses the same trailing tutorial entry and a pushed help page.
struct AccountConnectionTutorial: ViewModifier {
    let provider: AddAccountProvider

    func body(content: Content) -> some View {
        content.toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink(L10n.text("教程")) {
                    if provider == .ibkr {
                        IBKRGuideHelpView().accountFlowBrand(provider)
                    } else {
                        if let url = provider.tutorialURL {
                            OfficialBrokerTutorialPage(url: url)
                        }
                    }
                }
                .tint(CatfolioTheme.primaryText)
                .accessibilityIdentifier("\(provider.rawValue)-open-setup-guide")
            }
        }
    }
}

extension View {
    func accountConnectionTutorial(_ provider: AddAccountProvider) -> some View {
        modifier(AccountConnectionTutorial(provider: provider))
    }
}

struct BrokerPreparationInstructions: View {
    let provider: AddAccountProvider

    var body: some View {
        AccountPreparationList {
            switch provider {
            case .longbridge:
                AccountPreparationFeature(symbol: "key.fill", title: L10n.text("获取 OpenAPI 凭证"),
                    detail: L10n.text("填写开发者中心的 App Key、App Secret 和 Access Token；此处使用 API Key 凭证。"))
                readOnly
                AccountPreparationFeature(symbol: "doc.on.doc.fill", title: L10n.text("复制连接凭证"),
                    detail: L10n.text("复制凭证后回到 Catfolio，下一步粘贴并预览持仓。"))
            case .alpaca:
                AccountPreparationFeature(symbol: "key.fill", title: L10n.text("创建 API Key"),
                    detail: L10n.text("在 Alpaca Dashboard 创建 API Key，并保存 Secret Key。"))
                AccountPreparationFeature(symbol: "square.stack.fill", title: L10n.text("选择账户环境"),
                    detail: L10n.text("实盘和模拟盘使用不同凭证，账户与持仓分别保存。"))
                AccountPreparationFeature(symbol: "doc.on.doc.fill", title: L10n.text("复制连接凭证"),
                    detail: L10n.text("复制凭证后回到 Catfolio，下一步粘贴并预览持仓。"))
            case .snaptrade:
                AccountPreparationFeature(symbol: "key.fill", title: L10n.text("创建个人 API Key"),
                    detail: L10n.text("在 Dashboard 开启双重验证并创建个人 API Key；凭证仅存于此 iPhone。"))
                AccountPreparationFeature(symbol: "link.circle.fill", title: L10n.text("关联券商账户"),
                    detail: L10n.text("先在 SnapTrade Dashboard 关联券商账户，再复制 Client ID 和 Consumer Key。"))
                AccountPreparationFeature(symbol: "checkmark.rectangle.fill", title: L10n.text("预览与同步"),
                    detail: L10n.text("选择账户，预览后同步持仓。"))
            case .moomoo:
                AccountPreparationFeature(symbol: "person.fill", title: L10n.text("登录 Moomoo"),
                    detail: L10n.text("在授权页面登录，完成后回到这里继续。"))
                AccountPreparationFeature(symbol: "lock.shield.fill", title: L10n.text("只读连接"),
                    detail: L10n.text("授权时仅允许 trade:read；令牌仅存于此 iPhone。"))
            case .robinhood:
                AccountPreparationFeature(symbol: "person.crop.rectangle.fill", title: L10n.text("在电脑上授权"),
                    detail: L10n.text("生成登录链接，发送到电脑并打开。"))
                AccountPreparationFeature(symbol: "arrow.uturn.backward.circle.fill", title: L10n.text("返回这里完成连接"),
                    detail: L10n.text("授权后复制浏览器的完整回调链接，粘贴到这里。"))
                AccountPreparationFeature(symbol: "lock.shield.fill", title: L10n.text("只读连接"),
                    detail: L10n.text("令牌仅存于此 iPhone 的 Keychain。Catfolio 仅调用读取工具；Robinhood 授权页可能包含交易权限。"))
            default:
                EmptyView()
            }
        }
    }

    private var readOnly: some View {
        AccountPreparationFeature(symbol: "lock.shield.fill", title: L10n.text("只读连接"),
            detail: L10n.text("仅同步股票和 ETF 多头持仓，不含现金、场外基金和交易流水。Catfolio 不发送交易指令。"))
    }
}

extension AddAccountProvider {
    var tutorialURL: URL? {
        let address: String
        switch self {
        case .trading212: return Trading212GuideLesson.helpURL
        case .longbridge: address = "https://open.longbridge.com/docs/getting-started"
        case .alpaca: address = "https://alpaca.markets/learn/connect-to-alpaca-api"
        case .snaptrade: address = "https://docs.snaptrade.com/docs/getting-started"
        case .moomoo:
            address = AppLanguage.currentIdentifier == "zh-Hans"
                ? "https://open.moomoo.com/zh-cn/api/overview/getting-started"
                : "https://open.moomoo.com/api/overview/getting-started"
        case .robinhood: address = "https://robinhood.com/us/en/support/articles/agentic-trading-overview/"
        default: return nil
        }
        return URL(string: address)
    }
}
