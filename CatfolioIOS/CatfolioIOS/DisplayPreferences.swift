import ImageIO
import Observation
import SwiftUI
import UIKit

enum DisplayCurrency: String, CaseIterable, Identifiable {
    case usd = "USD"
    case gbp = "GBP"
    case eur = "EUR"
    case cny = "CNY"
    case hkd = "HKD"
    case cad = "CAD"
    case aud = "AUD"
    case sgd = "SGD"
    case jpy = "JPY"

    static let preferenceKey = "catfolio.displayCurrency"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .usd: L10n.text("USD · 美元")
        case .gbp: L10n.text("GBP · 英镑")
        case .eur: L10n.text("EUR · 欧元")
        case .cny: L10n.text("CNY · 人民币")
        case .hkd: L10n.text("HKD · 港币")
        case .cad: L10n.text("CAD · 加元")
        case .aud: L10n.text("AUD · 澳元")
        case .sgd: L10n.text("SGD · 新加坡元")
        case .jpy: L10n.text("JPY · 日元")
        }
    }

    static var current: DisplayCurrency {
        let saved = UserDefaults.standard.string(forKey: preferenceKey)
        return saved.flatMap(DisplayCurrency.init(rawValue:)) ?? .usd
    }

    func fromUSD(_ value: Double) -> Double {
        guard let usdPerUnit = LocalPortfolioEngine.usdRate(for: rawValue), usdPerUnit > 0 else {
            return value
        }
        return value / usdPerUnit
    }
}

enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    static let preferenceKey = "catfolio.appearance"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: L10n.text("跟随系统")
        case .light: L10n.text("浅色")
        case .dark: L10n.text("深色")
        }
    }

    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

enum CompanyNameDisplay: String, CaseIterable, Identifiable {
    case original = "原始名称"
    case chineseShort = "中文简称"

    static let preferenceKey = "catfolio.companyNameDisplay"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .original: L10n.text("原文简称")
        case .chineseShort: L10n.text("中文简称")
        }
    }

    static var current: CompanyNameDisplay {
        let saved = UserDefaults.standard.string(forKey: preferenceKey)
        return saved.flatMap(CompanyNameDisplay.init(rawValue:)) ?? .original
    }
}
