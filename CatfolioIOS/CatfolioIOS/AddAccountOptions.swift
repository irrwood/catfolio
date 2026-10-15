import SwiftUI

enum AddAccountProvider: String, CaseIterable, Identifiable, Codable {
    case trading212, ibkr, moomoo, robinhood, snaptrade, csv

    var id: String { rawValue }

    var connectionSummary: String {
        switch self {
        case .trading212: "API Key + Secret"
        case .ibkr: "Flex Token + Query ID"
        case .moomoo, .robinhood: L10n.text("授权连接")
        case .snaptrade: "Client ID + Consumer Key"
        case .csv: L10n.text("导入交易记录")
        }
    }

    var title: String {
        switch self {
        case .trading212: "Trading 212"
        case .ibkr: "Interactive Brokers"
        case .moomoo: "Moomoo"
        case .robinhood: "Robinhood"
        case .snaptrade: L10n.text("连接其他 2000+ 券商")
        case .csv: "CSV"
        }
    }

    var iconAsset: String {
        switch self {
        case .trading212: "AddAccountTrading212"
        case .ibkr: "BrokerIBKR"
        case .moomoo: "AddAccountMoomoo"
        case .robinhood: "BrokerRobinhood"
        case .snaptrade: "AddAccountConnection"
        case .csv: "AddAccountCSV"
        }
    }
}

/// Figma 630:23915: large provider badges, with import in its own card.
struct AddAccountOptions: View {
    let onSelect: (AddAccountProvider) -> Void

    var body: some View {
        VStack(spacing: SettingsTemplate.tileSpacing) {
            SettingsCard {
                ForEach(AddAccountProvider.allCases.filter { $0 != .csv }) { provider in
                    AddAccountProviderRow(provider: provider) { onSelect(provider) }
                }
            }
            SettingsCard {
                AddAccountProviderRow(provider: .csv) { onSelect(.csv) }
            }
        }
    }
}

struct AddAccountProviderRow: View {
    let provider: AddAccountProvider
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            SettingsRowContainer(minHeight: SettingsTemplate.accountProviderRowHeight) {
                HStack(spacing: SettingsTemplate.iconSpacing) {
                    AddAccountProviderIcon(provider: provider)
                    Text(provider.title)
                        .appText(.subheading, weight: .medium)
                        .foregroundStyle(CatfolioTheme.primaryText)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    SettingsChevron()
                }
            }
        }
        .buttonStyle(SettingsRowButtonStyle())
        .accessibilityLabel(provider == .csv ? L10n.text("CSV 导入") : provider.title)
        .accessibilityIdentifier("add-account-\(provider.rawValue)")
    }
}

struct AddAccountProviderIcon: View {
    @Environment(\.colorScheme) private var colorScheme
    let provider: AddAccountProvider

    var body: some View {
        Group {
            if provider == .snaptrade || provider == .csv {
                badgeShape
                    .fill(provider == .csv
                        ? AnyShapeStyle(SettingsTemplate.accountImportGradient)
                        : AnyShapeStyle(SettingsTemplate.accountConnectGradient))
                    .overlay {
                        Image(provider.iconAsset)
                            .renderingMode(.original)
                            .resizable()
                            .scaledToFit()
                            .frame(width: SettingsTemplate.accountActionGlyphSize,
                                   height: SettingsTemplate.accountActionGlyphSize)
                            .offset(y: provider == .snaptrade ? SettingsTemplate.accountConnectGlyphOffsetY : 0)
                    }
                    .overlay {
                        badgeShape
                            .strokeBorder(SettingsTemplate.cardBorder,
                                          lineWidth: SettingsTemplate.accountActionIconBorderWidth)
                    }
            } else if provider == .ibkr || provider == .robinhood {
                badgeShape
                    .fill(provider == .ibkr
                        ? CatfolioPalette.accountIBKRBackground
                        : CatfolioPalette.accountRobinhoodBackground)
                    .overlay {
                        Image(provider.iconAsset)
                            .renderingMode(.original)
                            .resizable()
                            .scaledToFit()
                            .frame(width: SettingsTemplate.accountBrokerArtworkSize,
                                   height: SettingsTemplate.accountBrokerArtworkSize)
                            .offset(y: provider == .ibkr
                                ? SettingsTemplate.accountIBKRArtworkOffsetY
                                : SettingsTemplate.accountRobinhoodArtworkOffsetY)
                    }
                    .clipShape(badgeShape)
            } else {
                Image(provider.iconAsset)
                    .renderingMode(.original)
                    .resizable()
                    .scaledToFit()
                    .frame(width: SettingsTemplate.accountProviderIconSize,
                           height: SettingsTemplate.accountProviderIconSize)
            }
        }
        .frame(width: SettingsTemplate.accountProviderIconSize, height: SettingsTemplate.accountProviderIconSize)
        .environment(\.colorScheme, provider == .ibkr || provider == .robinhood ? .dark : colorScheme)
        .drawingGroup()
        .accessibilityHidden(true)
    }

    private var badgeShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: SettingsTemplate.accountProviderIconRadius, style: .circular)
    }
}
