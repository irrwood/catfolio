import SwiftUI

/// Two cards side by side when the page is wide enough, otherwise one above
/// the other. The Mac's Overview is built from these rows, so it reads as one
/// page rather than two halves.
struct MacDashboardRow: Layout {
    static let sideBySideWidth: CGFloat = 860
    var spacing: CGFloat = 10

    private func isSideBySide(_ width: CGFloat) -> Bool {
        width >= Self.sideBySideWidth
    }

    private func columnWidth(_ width: CGFloat, count: Int) -> CGFloat {
        guard count > 1 else { return width }
        return (width - spacing * CGFloat(count - 1)) / CGFloat(count)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? Self.sideBySideWidth
        if isSideBySide(width) {
            let column = columnWidth(width, count: subviews.count)
            let heights = subviews.map { $0.sizeThatFits(ProposedViewSize(width: column, height: nil)).height }
            return CGSize(width: width, height: heights.max() ?? 0)
        }
        let heights = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }
        let gaps = spacing * CGFloat(max(0, subviews.count - 1))
        return CGSize(width: width, height: heights.reduce(0, +) + gaps)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        if isSideBySide(bounds.width) {
            let column = columnWidth(bounds.width, count: subviews.count)
            for (index, subview) in subviews.enumerated() {
                let x = bounds.minX + CGFloat(index) * (column + spacing)
                subview.place(at: CGPoint(x: x, y: bounds.minY), anchor: .topLeading,
                              proposal: ProposedViewSize(width: column, height: nil))
            }
            return
        }
        var y = bounds.minY
        for subview in subviews {
            let proposal = ProposedViewSize(width: bounds.width, height: nil)
            subview.place(at: CGPoint(x: bounds.minX, y: y), anchor: .topLeading, proposal: proposal)
            y += subview.sizeThatFits(proposal).height + spacing
        }
    }
}

/// The returns page's Performance tiles, for the Mac's Overview: the gain,
/// loss and source cards, and the two comparison entries.
struct MacPerformanceSection: View {
    @Environment(AppModel.self) private var model
    @State private var sourcePreviews = ReturnsSourcePreviewStore()
    /// Bumped each time the page comes back into view, so the cards redraw
    /// from prices a chart page may have just refreshed.
    @State private var appearance = 0

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsTemplate.tileSpacing) {
            ReturnsSourceCards(store: sourcePreviews)
            HStack(spacing: SettingsTemplate.tileSpacing) {
                ReturnsNavigationCard(title: L10n.text("收益对比"), identifier: "comparison",
                                      returnPercent: ReturnsEntrySummary.allTimePercent(model.comparison)) {
                    ReturnsChartPage(chart: .comparison)
                }
                ReturnsNavigationCard(title: L10n.text("周期对比"), identifier: "cycle",
                                      returnPercent: ReturnsEntrySummary.yearToDatePercent(model.comparison)) {
                    CycleComparisonView()
                }
            }
        }
        .onAppear { appearance &+= 1 }
        .task(id: "\(scope)|\(model.portfolioChartRevision)|\(model.holdings.count)|\(model.selectedAccountKeys.count)|\(appearance)") {
            await sourcePreviews.load(
                scope: scope,
                revision: "\(model.portfolioChartRevision)",
                holdings: model.holdings,
                isPortfolioLoaded: !model.selectedAccountKeys.isEmpty || !model.holdings.isEmpty,
                fetch: { try await model.holdingValueHistory(cachedOnly: $0) }
            )
        }
        .task(id: "\(scope)|\(model.portfolioChartRevision)") {
            if !model.isReturnsLoading { await model.refreshReturns() }
        }
    }

    /// The accounts the cards describe, as on the returns page.
    private var scope: String {
        let accounts = model.selectedAccountKeys.sorted().joined(separator: ",")
        return "\(model.isFakeDataMode ? "demo" : "real")|\(accounts)"
    }
}
