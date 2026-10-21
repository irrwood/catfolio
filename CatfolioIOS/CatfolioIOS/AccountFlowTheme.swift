import SwiftUI

/// A connector's logo color for filled actions, plus readable inline controls.
struct AccountFlowTheme {
    let accent: Color
    let controlTint: Color
    let onAccent: Color
}

extension AddAccountProvider {
    var flowTheme: AccountFlowTheme {
        switch self {
        case .trading212:
            .init(accent: CatfolioPalette.accountTrading212Accent,
                  controlTint: CatfolioPalette.accountTrading212Control,
                  onAccent: CatfolioPalette.accountTrading212Ink)
        case .ibkr:
            .init(accent: CatfolioPalette.accountIBKRBackground,
                  controlTint: CatfolioPalette.accountIBKRControl, onAccent: .white)
        case .moomoo:
            .init(accent: CatfolioPalette.accountMoomooAccent,
                  controlTint: CatfolioPalette.accountMoomooControl,
                  onAccent: CatfolioPalette.accountMoomooInk)
        case .robinhood:
            .init(accent: CatfolioPalette.accountRobinhoodBackground,
                  controlTint: CatfolioPalette.accountRobinhoodControl,
                  onAccent: CatfolioPalette.accountRobinhoodInk)
        case .snaptrade:
            .init(accent: CatfolioPalette.accountConnectBottom,
                  controlTint: CatfolioPalette.accountConnectControl,
                  onAccent: CatfolioPalette.accountConnectInk)
        case .csv:
            .init(accent: CatfolioPalette.accountImportTop,
                  controlTint: CatfolioPalette.accountImportControl, onAccent: .white)
        case .screenshot, .longbridge, .alpaca:
            .init(accent: CatfolioTheme.primaryText,
                  controlTint: CatfolioTheme.primaryText, onAccent: SettingsTemplate.pageBackground)
        }
    }
}

extension PortfolioAccount {
    /// Match the connector, not the editable account nickname.
    var brandProvider: AddAccountProvider? {
        switch source {
        case "Trading 212": .trading212
        case "IBKR Flex": .ibkr
        case "Moomoo": .moomoo
        case "Longbridge": .longbridge
        case "Alpaca": .alpaca
        case "Robinhood": .robinhood
        case "SnapTrade": .snaptrade
        case "CSV": .csv
        case "Screenshot": .screenshot
        default: nil
        }
    }
}

private struct AccountFlowThemeKey: EnvironmentKey {
    static let defaultValue: AccountFlowTheme? = nil
}

extension EnvironmentValues {
    var accountFlowTheme: AccountFlowTheme? {
        get { self[AccountFlowThemeKey.self] }
        set { self[AccountFlowThemeKey.self] = newValue }
    }
}

extension View {
    /// Scope a connector's brand to its account and creation/management pages.
    func accountFlowBrand(_ provider: AddAccountProvider?) -> some View {
        let theme = provider?.flowTheme
        return environment(\.accountFlowTheme, theme)
            .tint(theme?.controlTint ?? CatfolioTheme.accent)
    }
}
