import SwiftUI

/// Figma 761:2899: the original mark sits inside a 64pt, 18pt-radius tile.
struct CatfolioConnectionLogo: View {
    var body: some View {
        Image("CatfolioConnectionMark")
            .renderingMode(.original)
            .resizable().scaledToFit()
            .frame(width: 41.7034, height: 51.7916)
            .frame(width: 64, height: 64)
            .background(CatfolioPalette.connectionLogoBackground,
                        in: RoundedRectangle(cornerRadius: 18))
            .accessibilityHidden(true)
    }
}

/// The pushed connection page in Figma 750:1593.
struct AccountConnectionHeader: View {
    let provider: AddAccountProvider
    let title: String
    var subtitle: String? = nil
    @ScaledMetric(relativeTo: .headline) private var titleSize = 22

    var body: some View {
        VStack(spacing: 16) {
            AccountFlowSharedElement(id: "\(provider.rawValue).logos") {
                HStack(spacing: 8) {
                    CatfolioConnectionLogo()
                    Image("AccountConnectionLink")
                        .frame(width: 24, height: 24)
                        .foregroundStyle(provider.flowTheme.iconTint)
                    if provider == .trading212 {
                        Image("AccountConnectionTrading212").frame(width: 64, height: 64)
                    } else {
                        AddAccountProviderIcon(provider: provider, size: 64)
                    }
                }
                .accessibilityHidden(true)
            }
            .frame(height: 64)
            VStack(spacing: 6) {
                AccountFlowSharedElement(id: "\(provider.rawValue).title.\(title)") {
                    Text(title).font(Typography.text(size: titleSize, weight: .bold))
                        .accessibilityAddTraits(.isHeader)
                }
                if let subtitle {
                    AccountFlowSharedElement(id: "\(provider.rawValue).subtitle.\(subtitle)") {
                        Text(subtitle).appText(.callout, weight: .medium)
                            .foregroundStyle(CatfolioTheme.primaryText.opacity(0.5))
                            .padding(.vertical, 1.5)
                            .frame(maxWidth: 262)
                    }
                }
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 30)
        // The page supplies the remaining 16pt before the input card.
        .padding(.bottom, 14)
        .accessibilityIdentifier("account-connection-header")
        .preference(key: WorkspacePageTitleKey.self, value: title)
    }
}

/// Broker explanations share the intro's plain symbols and compact benefit layout.
struct AccountPreparationFeature: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        OnboardingBenefitRow(symbol: symbol, title: title, detail: detail, isAccountPreparation: true)
            .padding(.vertical, 16)
            .frame(minHeight: 86)
            .padding(.horizontal, 16)
    }
}

struct AccountPreparationList<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: -4) { content }
    }
}

struct AccountPreparationNextButton: View {
    var labelColor: Color? = nil
    let action: () -> Void

    var body: some View {
        OnboardingPrimaryButton(title: L10n.text("下一步"), usesGlass: true,
                                labelColor: labelColor, action: action)
            .accessibilityIdentifier("account-guide-next")
    }
}

struct AccountCredentialRow: View {
    let title: String
    @Binding var text: String
    var accessibilityIdentifier: String
    var placeholder: String?
    @State private var revealsKey = false
    @Environment(\.usesPaywallOnboardingStyle) private var paywallStyle
    @ScaledMetric(relativeTo: .subheadline) private var labelSize = 16

    init(title: String, text: Binding<String>, accessibilityIdentifier: String, isSecret: Bool = true, placeholder: String? = nil) {
        self.title = title
        self._text = text
        self.accessibilityIdentifier = accessibilityIdentifier
        self.placeholder = placeholder
        self._revealsKey = State(initialValue: !isSecret)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(Typography.text(size: labelSize, weight: .medium))
                .foregroundStyle(paywallStyle ? .white.opacity(0.65) : CatfolioPalette.accountCredentialLabel)
                .padding(.horizontal, 20)
            ServiceAPIKeyInput(placeholder: placeholder ?? title, text: $text,
                               revealsKey: $revealsKey,
                               accessibilityIdentifier: accessibilityIdentifier,
                               isAccountCredential: true)
                .padding(.leading, 20)
                .padding(.trailing, 14)
                .padding(.vertical, 16)
                .frame(minHeight: 64)
                .background(paywallStyle ? .white.opacity(0.10) : CatfolioPalette.accountCredentialBackground, in: RoundedRectangle(cornerRadius: 24))
                .overlay {
                    RoundedRectangle(cornerRadius: 24)
                        .strokeBorder(paywallStyle ? .white.opacity(0.16) : CatfolioPalette.accountCredentialBorder, lineWidth: 1)
                        .allowsHitTesting(false)
                }
        }
    }
}

struct AccountCredentialFootnote: View {
    var body: some View {
        Text(L10n.text("保存在钥匙串；可在设置中开启跨设备密钥同步。"))
            .appText(.caption)
            .foregroundStyle(SettingsTemplate.secondaryText)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, SettingsTemplate.rowHorizontalPadding)
    }
}

/// The brand wash reaches white at 37.586% of the viewport, as in the design.
/// Night mode keeps a subdued wash over the existing dark account surface.
struct AccountConnectionBackground: View {
    let theme: AccountFlowTheme
    var isPreparation = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            CatfolioPalette.accountConnectionBackground
            // Figma's transform starts the preparation gradient above the viewport.
            LinearGradient(colors: [
                theme.accent.opacity(colorScheme == .dark ? 0.28 : 1),
                theme.accent.opacity(0)
            ], startPoint: UnitPoint(x: 0.5, y: isPreparation ? -0.13673 : 0),
               endPoint: UnitPoint(x: 0.5, y: isPreparation ? 0.38616 : 0.37586))
        }
        .accessibilityHidden(true)
    }
}
