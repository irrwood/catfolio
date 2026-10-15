import SwiftUI

/// Tutorial navigation cannot advance into review or success without a broker response.
enum Trading212GuideStep: Int, CaseIterable, Codable {
    case prepare, settings, permissions, credentials, review, complete

    var isTutorial: Bool { rawValue < Self.credentials.rawValue }
    var nextTutorialStep: Self { isTutorial ? .credentials : self }
    var previous: Self? {
        switch self {
        case .credentials: .prepare
        case .review: .credentials
        default: nil
        }
    }
    // Preserve the original Codable values so existing Keychain drafts still decode.
    // The three old tutorial pages now share one preparation screen.
    var progressStep: Int {
        switch self {
        case .prepare, .settings, .permissions: 1
        case .credentials: 2
        case .review, .complete: 3
        }
    }
    var title: String {
        switch self {
        case .prepare, .settings, .permissions: L10n.text("获取只读 Key")
        case .credentials: L10n.text("粘贴 Key 和 Secret")
        case .review: L10n.text("确认持仓")
        case .complete: L10n.text("账户已添加")
        }
    }
    var subtitle: String {
        switch self {
        case .prepare, .settings, .permissions: L10n.text("在 Trading 212 创建密钥，然后回来粘贴。")
        case .credentials: L10n.text("连接 Trading 212，下一步预览持仓。")
        case .review: L10n.text("检查账户和持仓，确认后再添加。")
        case .complete: "Trading 212"
        }
    }
}

struct Trading212GuideProgress: View {
    let step: Trading212GuideStep

    var body: some View {
        OnboardingHeader(title: step.title, subtitle: step.subtitle)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("account-guide-\(step)")
    }
}

struct Trading212GuideLesson: View {
    let step: Trading212GuideStep
    let next: () -> Void
    static let helpURL = URL(string: "https://helpcentre.trading212.com/hc/en-us/articles/14584770928157-Trading-212-API-key")!

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            OnboardingFeature(symbol: "person.crop.rectangle", title: L10n.text("创建 API Key"),
                detail: L10n.text("在目标 Invest / ISA 账户，打开 Settings → API (Beta) → Generate API key。"))
            OnboardingFeature(symbol: "checklist", title: L10n.text("只开启读取权限"),
                detail: L10n.text("Portfolio、Account data、History。不启用交易权限。"))
            OnboardingFeature(symbol: "key.horizontal", title: L10n.text("保存 Key 和 Secret"),
                detail: L10n.text("Secret 只显示一次，复制后回到这里。"))
        }
        Link(destination: Self.helpURL) {
            Label(L10n.text("查看详细教程"), systemImage: "arrow.up.right.square")
                .appText(.callout, weight: .medium).padding(.vertical, 8)
        }
    }

    var actions: some View {
        OnboardingPrimaryButton(title: L10n.text("填写 Key 和 Secret"), action: next)
            .accessibilityIdentifier("account-guide-next")
    }
}
