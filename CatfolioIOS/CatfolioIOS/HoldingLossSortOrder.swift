import Foundation

enum HoldingLossSortOrder: String, CaseIterable, Sendable {
    case currentLoss
    case maximumLoss

    static let preferenceKey = "returns.losses.sortOrder"

    var title: String {
        switch self {
        case .currentLoss: L10n.text("当前亏损")
        case .maximumLoss: L10n.text("历史最大亏损")
        }
    }
}
