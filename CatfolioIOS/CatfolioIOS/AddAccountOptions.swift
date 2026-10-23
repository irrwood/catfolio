import SwiftUI

enum AddAccountProvider: String, CaseIterable, Identifiable, Codable {
    case trading212, ibkr, moomoo, longbridge, alpaca, robinhood, snaptrade, csv, screenshot

    var id: String { rawValue }

    var connectionSummary: String {
        switch self {
        case .trading212: "API Key + Secret"
        case .ibkr: "Flex Token + Query ID"
        case .moomoo, .robinhood: L10n.text("授权连接")
        case .snaptrade: "Client ID + Consumer Key"
        case .longbridge: "App Key + Secret + Token"
        case .alpaca: "API Key + Secret"
        case .csv: L10n.text("导入交易记录")
        case .screenshot: L10n.text("从截图识别持仓")
        }
    }

    var title: String {
        switch self {
        case .trading212: "Trading 212"
        case .ibkr: "Interactive Brokers"
        case .moomoo: "Moomoo"
        case .robinhood: "Robinhood Agents"
        case .longbridge: "Longbridge"
        case .alpaca: "Alpaca"
        case .snaptrade: L10n.text("连接其他 2000+ 券商")
        case .csv: "CSV"
        case .screenshot: L10n.text("截图导入")
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
        case .screenshot: "AddAccountCSV"
        case .longbridge: "BrokerLongbridge"
        case .alpaca: "BrokerAlpaca"
        }
    }
}

/// Figma 630:23915: large provider badges, with import in its own card.
struct AddAccountOptions: View {
    let onSelect: (AddAccountProvider) -> Void

    var body: some View {
        VStack(spacing: SettingsTemplate.tileSpacing) {
            SettingsCard {
                ForEach(AddAccountProvider.allCases.filter { $0 != .csv && $0 != .screenshot }) { provider in
                    AddAccountProviderRow(provider: provider) { onSelect(provider) }
                }
            }
            SettingsCard {
                AddAccountProviderRow(provider: .csv) { onSelect(.csv) }
                AddAccountProviderRow(provider: .screenshot) { onSelect(.screenshot) }
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
    var size: CGFloat = SettingsTemplate.accountProviderIconSize

    var body: some View {
        Group {
            if provider == .screenshot {
                badgeShape.fill(CatfolioTheme.neutralFill)
                    .overlay {
                        Image(systemName: "photo.badge.plus")
                            .appText(.title).foregroundStyle(CatfolioTheme.primaryText)
                    }
            } else if provider == .snaptrade || provider == .csv {
                badgeShape
                    .fill(provider == .csv
                        ? AnyShapeStyle(SettingsTemplate.accountImportGradient)
                        : AnyShapeStyle(SettingsTemplate.accountConnectGradient))
                    .overlay {
                        Image(provider.iconAsset)
                            .renderingMode(.original)
                            .resizable()
                            .scaledToFit()
                            .frame(width: SettingsTemplate.accountActionGlyphSize * scale,
                                   height: SettingsTemplate.accountActionGlyphSize * scale)
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
                            .frame(width: SettingsTemplate.accountBrokerArtworkSize * scale,
                                   height: SettingsTemplate.accountBrokerArtworkSize * scale)
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
                    .frame(width: size,
                           height: size)
                    // Match the tall Longbridge mark's visual height to the other brokers.
                    .scaleEffect(provider == .longbridge ? 0.9 : 1)
                    .background {
                        if provider == .longbridge { badgeShape.fill(CatfolioPalette.black) }
                    }
                    .clipShape(badgeShape)
            }
        }
        .frame(width: size, height: size)
        .environment(\.colorScheme, provider == .ibkr || provider == .robinhood ? .dark : colorScheme)
        .drawingGroup()
        .accessibilityHidden(true)
    }

    private var scale: CGFloat { size / SettingsTemplate.accountProviderIconSize }

    private var badgeShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: SettingsTemplate.accountProviderIconRadius * scale, style: .circular)
    }
}
