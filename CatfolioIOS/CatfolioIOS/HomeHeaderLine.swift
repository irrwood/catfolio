import SwiftUI
import UIKit

/// Canvas keeps a range switch to one draw pass instead of rebuilding hundreds
/// of Swift Charts marks. Filtering and domains are cached once; every range
/// keeps the original daily vertices so viewport zooms preserve the same curve.
/// The line above the home total: its title, or what the page is saying.
enum HomeHeaderLine: Equatable {
    case title(String, holdingsValueOnly: Bool, closed: Bool)
    case refreshing
    case status(String, isError: Bool)

    /// A title that follows the chart's selection changes at once; only a
    /// status coming or going sweeps.
    static func sweeps(_ old: HomeHeaderLine, _ new: HomeHeaderLine) -> Bool {
        if case .title = old, case .title = new { return false }
        return true
    }

    @ViewBuilder var view: some View {
        switch self {
        case let .title(text, holdingsValueOnly, closed):
            HStack(spacing: 5) {
                if closed { HomeMarketStatusGlyph() }
                Text(text)
                    .appCaps(.caption, weight: .semibold)
                if holdingsValueOnly {
                    Text(L10n.text("持仓市值"))
                        .appCaps(.caption, weight: .semibold)
                        .foregroundStyle(.secondary)
                }
            }
        case .refreshing:
            HStack(spacing: 6) {
                // UIKit's own spinner: a repeating SwiftUI animation here
                // would leak into the page's other layout changes.
                ProgressView()
                    .controlSize(.mini)
                    .tint(CatfolioTheme.primaryText)
                Text(L10n.text("正在刷新…"))
                    .appCaps(.caption, weight: .semibold)
            }
        case let .status(text, isError):
            Text(text)
                .appCaps(.caption, weight: .semibold)
                .foregroundStyle(isError ? CatfolioTheme.danger : CatfolioTheme.primaryText)
        }
    }
}

/// Reuse the extended-session artwork while preserving the home's existing
/// closed-market meaning and caption-sized visual weight.
struct HomeMarketStatusGlyph: View {
    @ScaledMetric(relativeTo: .caption) private var iconSize: CGFloat = 16

    var body: some View {
        ZStack {
            RotatingSunriseIcon(size: iconSize)
                .foregroundStyle(.secondary)
        }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L10n.text("休市"))
    }
}
