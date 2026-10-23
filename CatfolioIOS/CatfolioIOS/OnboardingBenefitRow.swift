import SwiftUI

/// Shared paywall-style explanation row for onboarding and broker connection pages.
struct OnboardingBenefitRow: View {
    let symbol: String
    let title: String
    let detail: String
    var isAccountPreparation = false
    @Environment(\.usesPaywallOnboardingStyle) private var paywallStyle
    @Environment(\.accountFlowTheme) private var theme
    @ScaledMetric(relativeTo: .body) private var symbolSize = 18
    @ScaledMetric(relativeTo: .body) private var tileSize = 38

    var body: some View {
        HStack(alignment: isAccountPreparation ? .center : .top, spacing: 12) {
            Image(systemName: symbol)
                .symbolRenderingMode(.monochrome)
                .font(.system(size: isAccountPreparation ? symbolSize * 17 / 18 : symbolSize,
                              weight: isAccountPreparation ? .regular : .medium))
                .frame(width: isAccountPreparation ? tileSize * 52 / 38 : tileSize,
                       height: isAccountPreparation ? tileSize * 52 / 38 : tileSize)
                .foregroundStyle(isAccountPreparation ? (theme?.iconTint ?? CatfolioTheme.primaryText) : (paywallStyle ? .white : CatfolioTheme.primaryText))
                .background { symbolBackground }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: isAccountPreparation ? 4 : 3) {
                Text(title).appText(.callout, weight: isAccountPreparation ? .medium : .semibold)
                Text(detail).appText(isAccountPreparation ? .footnote : .caption)
                    .foregroundStyle(isAccountPreparation ? CatfolioTheme.primaryText.opacity(0.4) : (paywallStyle ? .white.opacity(0.82) : SettingsTemplate.secondaryText))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(paywallStyle ? .white : CatfolioTheme.primaryText)
        .accessibilityElement(children: .combine)
    }
    @ViewBuilder private var symbolBackground: some View {
        let shape = RoundedRectangle(cornerRadius: 12)
        if isAccountPreparation {
            shape.fill(CatfolioPalette.accountConnectionBackground)
                .overlay {
                    shape.fill((theme?.accent ?? CatfolioTheme.primaryText).opacity(0.0784))
                }
        } else {
            shape.fill(paywallStyle ? .white.opacity(0.14) : CatfolioTheme.primaryText.opacity(0.06))
        }
    }

}
