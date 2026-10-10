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
                if closed { HomeMoonGlyph() }
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

/// The closed-market moon. It comes in full and wanes to the crescent.
struct HomeMoonGlyph: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = 0

    var body: some View {
        HomeMoonShape(phase: reduceMotion ? 1 : phase)
            .fill(.secondary)
            .frame(width: 10, height: 10)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.9).delay(0.15)) { phase = 1 }
            }
            .accessibilityLabel(L10n.text("休市"))
    }
}

/// A disc with a second disc cut from its upper right: clear of the moon at
/// phase 0, a full moon, and biting in to the crescent at phase 1.
struct HomeMoonShape: Shape {
    var phase: CGFloat
    var animatableData: CGFloat {
        get { phase }
        set { phase = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let radius = min(rect.width, rect.height) / 2
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let moon = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                                          width: radius * 2, height: radius * 2))
        // Offsets in radii, from well clear of the disc to the crescent's bite.
        let start = CGPoint(x: 2.3, y: -1.7), end = CGPoint(x: 0.55, y: -0.42)
        let cutCenter = CGPoint(x: center.x + (start.x + (end.x - start.x) * phase) * radius,
                                y: center.y + (start.y + (end.y - start.y) * phase) * radius)
        let cutRadius = radius * 0.88
        let cut = Path(ellipseIn: CGRect(x: cutCenter.x - cutRadius, y: cutCenter.y - cutRadius,
                                         width: cutRadius * 2, height: cutRadius * 2))
        return moon.subtracting(cut)
    }
}
