import SwiftUI

/// Tutorial navigation cannot advance into review or success without a broker response.
enum Trading212GuideStep: Int, CaseIterable {
    case prepare, settings, permissions, credentials, review, complete

    var isTutorial: Bool { rawValue < Self.credentials.rawValue }
    var nextTutorialStep: Self {
        guard isTutorial else { return self }
        return Self(rawValue: rawValue + 1) ?? self
    }
    var previous: Self? {
        guard self != .prepare, self != .complete else { return nil }
        return Self(rawValue: rawValue - 1)
    }
    var title: String {
        switch self {
        case .prepare: L10n.text("准备连接账户")
        case .settings: L10n.text("找到 API 设置")
        case .permissions: L10n.text("创建只读凭证")
        case .credentials: L10n.text("填写连接凭证")
        case .review: L10n.text("确认账户与持仓")
        case .complete: L10n.text("账户已添加")
        }
    }
}

struct Trading212GuideProgress: View {
    let step: Trading212GuideStep

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Trading 212").appText(.subheading, weight: .semibold)
                Spacer()
                Text(L10n.text("第 \(min(step.rawValue + 1, 5)) 步，共 5 步"))
                    .appText(.label)
                    .foregroundStyle(SettingsTemplate.secondaryText)
            }
            ProgressView(value: Double(min(step.rawValue + 1, 5)), total: 5)
                .tint(CatfolioTheme.accent)
                .accessibilityLabel(L10n.text("添加账户进度"))
            Text(step.title)
                .font(.title2.weight(.bold))
                .accessibilityAddTraits(.isHeader)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("account-guide-\(step)")
    }
}

struct Trading212GuideLesson: View {
    let step: Trading212GuideStep
    let next: () -> Void
    let skip: () -> Void
    static let helpURL = URL(string: "https://helpcentre.trading212.com/hc/en-us/articles/14584770928157-Trading-212-API-key")!

    var body: some View {
        SettingsCard {
            switch step {
            case .prepare:
                instruction("person.crop.rectangle", L10n.text("选择要添加的账户"),
                            L10n.text("先在 Trading 212 切换到目标 Invest 或 Stocks & Shares ISA 账户。每个账户分别添加；SIPP 暂不支持 API 连接。"))
                instruction("arrow.triangle.2.circlepath", L10n.text("连接后可以导入什么"),
                            L10n.text("读取持仓、现金与可用的历史记录。先预览，再确认添加到 Catfolio。"))
                instruction("lock", L10n.text("使用只读 API 连接"),
                            L10n.text("无需填写券商登录密码。API Key 与 Secret 仅保存在此 iPhone 的钥匙串中。"))
            case .settings:
                instruction("1.circle", L10n.text("打开 Trading 212 菜单"),
                            L10n.text("在 Trading 212 App 中点击 ☰，确认当前是要导入的账户。"))
                instruction("2.circle", L10n.text("进入 Settings → API (Beta)"),
                            L10n.text("打开设置，找到 API (Beta)。如果没有此入口，请检查账户类型。"))
                instruction("3.circle", L10n.text("选择 Generate API key"),
                            L10n.text("首次使用需阅读并接受 Trading 212 的风险提示，然后创建新密钥，可命名为 Catfolio。"))
            case .permissions:
                instruction("checklist", L10n.text("勾选读取权限"),
                            L10n.text("开启 Portfolio、Account data 和 History 的读取权限，包括历史订单、股息与交易记录。不要开启下单或修改订单权限。"))
                instruction("key", L10n.text("保存 Key 与 Secret"),
                            L10n.text("生成后会显示 API Key 和 API Secret。Secret 只显示一次，请安全保存，再返回 Catfolio 填写。"))
            default:
                EmptyView()
            }
        }
        SettingsCard {
            SettingsRowContainer {
                GlassPrimaryButton(title: step == .permissions ? L10n.text("已准备好，填写凭证") : L10n.text("下一步"),
                                   systemImage: "arrow.right", action: next)
                    .accessibilityIdentifier("account-guide-next")
            }
            if step == .prepare {
                SettingsButtonRow(icon: .symbol("key"), title: L10n.text("已有 Key 和 Secret，直接填写"),
                                  showsChevron: false, action: skip)
            }
            Link(destination: Self.helpURL) {
                SettingsRowContainer {
                    Label(L10n.text("查看官方图文教程"), systemImage: "arrow.up.right.square")
                        .appText(.subheading)
                }
            }
            .buttonStyle(SettingsRowButtonStyle())
        }
    }

    private func instruction(_ symbol: String, _ title: String, _ detail: String) -> some View {
        SettingsRowContainer {
            HStack(alignment: .top, spacing: SettingsTemplate.iconSpacing) {
                Image(systemName: symbol)
                    .font(.title3)
                    .frame(width: SettingsTemplate.iconSize)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 8) {
                    Text(title).appText(.subheading, weight: .semibold)
                    Text(detail).appText(.label)
                        .foregroundStyle(SettingsTemplate.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
