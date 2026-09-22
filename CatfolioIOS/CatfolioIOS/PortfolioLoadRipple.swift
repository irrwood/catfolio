import SwiftUI

/// The plot finishes preparing after the model has published its chart data.
struct PortfolioHeroReadyPreference: PreferenceKey {
    static var defaultValue: Bool { false }
    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}
