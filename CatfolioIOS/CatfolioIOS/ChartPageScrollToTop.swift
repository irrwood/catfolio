import SwiftUI

/// Scrolls the chart page back to its top, where the picker and chart are.
struct ChartPageScrollToTop {
    let action: () -> Void
    init(_ action: @escaping () -> Void = {}) { self.action = action }
    func callAsFunction() { action() }
}

extension EnvironmentValues {
    @Entry var scrollChartPageToTop = ChartPageScrollToTop()
}
