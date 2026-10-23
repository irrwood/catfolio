import SwiftUI

extension AccountFlowTheme {
    static let firstLaunch = AccountFlowTheme(accent: .white,
                                             controlTint: .white,
                                             onAccent: CatfolioPalette.Paywall.action)
}

/// Large, left-aligned white type shares the paywall's hierarchy.
struct FirstLaunchIntroHeader: View {
    let title: String
    var subtitle: String? = nil
    var showsAppIcon = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if showsAppIcon {
                CatfolioConnectionLogo()
            }
            VStack(alignment: .leading, spacing: 12) {
                Text(title).appText(.display, weight: .bold)
                    .foregroundStyle(.white)
                    .accessibilityAddTraits(.isHeader)
                if let subtitle {
                    Text(subtitle).appText(.footnote)
                        .foregroundStyle(.white.opacity(0.86))
                }
            }
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 16)
        .padding(.bottom, 10)
    }
}

struct FirstLaunchIntroFeatures: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            OnboardingBenefitRow(symbol: "chart.pie", title: L10n.text("连接账户"),
                                      detail: L10n.text("导入券商持仓，也可以手动添加。"))
            OnboardingBenefitRow(symbol: "key.horizontal", title: L10n.text("按需连接服务"),
                                      detail: L10n.text("行情、新闻和 AI，选你需要的就好。"))
            OnboardingBenefitRow(symbol: "lock", title: L10n.text("密钥由你掌握"),
                                      detail: L10n.text("保存在钥匙串，可选择跨设备同步。"))
        }
        .padding(.horizontal, 0)
    }
}
