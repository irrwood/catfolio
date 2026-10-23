import SwiftUI

/// Optional services share the account picker's card and row geometry.
struct FirstLaunchServiceOptions: View {
    @Binding var isExpanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsTemplate.sectionSpacing) {
            SettingsCard {
                Button { isExpanded.toggle() } label: {
                    row(symbol: "sparkles", title: L10n.text("行情与 AI（可选）"),
                        isDisclosure: true)
                }
                .buttonStyle(SettingsRowButtonStyle())
                .accessibilityIdentifier("service-onboarding-services")
                .accessibilityValue(isExpanded ? L10n.text("已展开") : L10n.text("已收起"))
            }
            if isExpanded {
                group(L10n.text("行情与估值"), providers: [.massive, .fmp])
                group("AI", providers: [.openRouter, .claude, .deepSeek, .jev])
                group(L10n.text("新闻"), providers: [.finnhub])
                Text(L10n.text("服务商的额度、功能和费用以其账户方案为准。"))
                    .appText(.footnote).foregroundStyle(.white.opacity(0.82))
            }
        }
    }

    private func group(_ title: String, providers: [LocalServiceProvider]) -> some View {
        VStack(alignment: .leading, spacing: SettingsTemplate.tileSpacing) {
            Text(title).appText(.label).foregroundStyle(.white.opacity(0.82))
            SettingsCard {
                ForEach(providers) { provider in
                    NavigationLink(value: ServiceAPISetupState.Step.key(provider)) {
                        row(symbol: provider.iconName, title: provider.title, subtitle: provider.purpose)
                    }
                    .buttonStyle(SettingsRowButtonStyle())
                    .accessibilityIdentifier("service-onboarding-provider-\(provider.rawValue)")
                }
            }
        }
    }

    private func row(symbol: String, title: String, subtitle: String? = nil,
                     isDisclosure: Bool = false) -> some View {
        SettingsRowContainer(minHeight: SettingsTemplate.accountProviderRowHeight) {
            HStack(spacing: SettingsTemplate.iconSpacing) {
                Image(systemName: symbol)
                    .appText(.title)
                    .foregroundStyle(CatfolioTheme.primaryText)
                    .frame(width: SettingsTemplate.accountProviderIconSize,
                           height: SettingsTemplate.accountProviderIconSize)
                    .background(CatfolioTheme.neutralFill,
                                in: RoundedRectangle(cornerRadius: SettingsTemplate.accountProviderIconRadius))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: SettingsTemplate.subtitleSpacing) {
                    Text(title).appText(.subheading, weight: .medium)
                        .foregroundStyle(CatfolioTheme.primaryText)
                    if let subtitle {
                        Text(subtitle).appText(.footnote)
                            .foregroundStyle(SettingsTemplate.secondaryText)
                    }
                }
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                SettingsChevron()
                    .rotationEffect(isDisclosure ? .degrees(isExpanded ? -90 : 90) : .zero)
            }
        }
    }
}
