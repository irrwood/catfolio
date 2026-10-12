import SwiftUI

/// Selected and unselected artwork for the tab bar.
enum RootTabArtwork: String, CaseIterable {
    case portfolio = "TabPerformance"
    case returns = "TabPortfolio"
    case research = "TabResearch"
    case settings = "TabSettings"
    case assistant = "TabAI"

    var selected: String { rawValue + "Selected" }
    var unselected: String { rawValue + "Unselected" }
}

/// A large title for pages whose heading scrolls with their content.
struct RootTabTitle: View {
    let title: String
    @ScaledMetric(relativeTo: .largeTitle) private var fontSize: CGFloat = 34

    var body: some View {
        Text(title)
            .font(Typography.text(size: fontSize, weight: .bold))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .accessibilityAddTraits(.isHeader)
    }
}
