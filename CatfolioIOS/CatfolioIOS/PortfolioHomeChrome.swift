import SwiftUI
import UIKit

struct PortfolioHomeTopBackground: View {
    @Environment(\.locale) private var appLocale
    let colorScheme: ColorScheme

    var body: some View {
        LinearGradient(
            stops: colorScheme == .light
                ? [
                    // Figma 223:31122: #9ADCFF.
                    .init(color: Color(red: 154 / 255, green: 220 / 255, blue: 1), location: 0),
                    .init(color: .white, location: 1),
                ]
                : [
                    .init(color: .black, location: 0),
                    .init(color: Color(red: 0.192, green: 0.208, blue: 0.235), location: 1),
                ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

struct PortfolioHomePageBackdrop: View {
    @Environment(\.locale) private var appLocale
    let colorScheme: ColorScheme
    let scrollState: PortfolioHomeScrollState

    var body: some View {
        ZStack(alignment: .top) {
            (colorScheme == .light ? Color.white : Color.black)

            // Figma 223:31122 uses one uninterrupted viewport gradient from
            // #9ADCFF to the terminal page surface. Keeping it fixed behind
            // the native ScrollView also makes rubber-banding reveal the same
            // background instead of a separate pale-blue extension band.
            PortfolioHomeTopBackground(colorScheme: colorScheme)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .opacity(1 - scrollState.backdropProgress)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
    }
}

enum PortfolioContentSheetLayout {
    // Figma 165:6775 starts as a 378pt sheet inside a 402pt canvas.
    static let initialHorizontalInset: CGFloat = 12
    // By the halfway reference (223:29979) the sheet has travelled 263pt
    // and opened to the full canvas width.
    static let widthExpansionDistance: CGFloat = 263
    static let transitionHeight: CGFloat = 326
    // TODAY sits 30pt from the card top and is 17pt tall. Once it has left the
    // screen, use the card's remaining travel to finish the colour transition.
    static let backdropFadeDistance: CGFloat = transitionHeight - 47
    // Leaves the sheet at the screenshot's resting position: the account
    // summary remains visible while the chart is covered by Today.
    static let firstScrollDetent = PortfolioHeroChartLayout.sectionHeight - PortfolioHeroChartLayout.plotTop
    static let topRadius: CGFloat = 38

    static func settlingProgress(offset: CGFloat, colorScheme: ColorScheme) -> CGFloat {
        // Night glass stays clear through the width expansion, then settles
        // over another card-height of travel. Scrolling back reverses it.
        let start = colorScheme == .dark ? widthExpansionDistance : 0
        let distance = colorScheme == .dark ? transitionHeight : widthExpansionDistance
        return min(max((offset - start) / distance, 0), 1)
    }

    static var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: topRadius,
            bottomLeadingRadius: 0,
            bottomTrailingRadius: 0,
            topTrailingRadius: topRadius,
            style: .continuous
        )
    }
}

/// Only the small visual layers observe scroll samples. PortfolioView keeps
/// this reference without reading its properties while building financial
/// content, so a pixel of travel does not reconstruct the holdings or charts.
@MainActor @Observable
final class PortfolioHomeScrollState {
    private(set) var heroOffset: CGFloat = 0
    private(set) var sheetProgress: CGFloat = 0
    private(set) var backdropProgress: CGFloat = 0
    private(set) var indicatorTopInset: CGFloat = 0
    private(set) var hasVisibleIndicatorTrack = false

    @ObservationIgnored private var offset: CGFloat = 0
    @ObservationIgnored private var pull: CGFloat = 0
    @ObservationIgnored private var titleExitOffset: CGFloat?
    @ObservationIgnored private var holdingsTop: CGFloat?
    @ObservationIgnored private var viewportHeight: CGFloat = 0

    func update(offset: CGFloat, pull: CGFloat) {
        self.offset = offset
        self.pull = pull
        if heroOffset != offset { heroOffset = offset }
        let progress = min(max(offset / PortfolioContentSheetLayout.widthExpansionDistance, 0), 1)
        if sheetProgress != progress { sheetProgress = progress }
        updateBackdrop()
        updateIndicator()
    }

    func titleMoved(to bottom: CGFloat) {
        guard pull < 0.5 else { return }
        let exit = offset + bottom
        guard titleExitOffset.map({ abs($0 - exit) > 0.5 }) ?? true else { return }
        titleExitOffset = exit
        updateBackdrop()
    }

    func holdingsMoved(to top: CGFloat) {
        holdingsTop = top
        updateIndicator()
    }

    func viewportChanged(to height: CGFloat) {
        viewportHeight = height
        updateIndicator()
    }

    private func updateBackdrop() {
        guard let start = titleExitOffset else { return }
        let linear = min(max((offset - start) / PortfolioContentSheetLayout.backdropFadeDistance, 0), 1)
        let progress = linear * linear * (3 - 2 * linear)
        if backdropProgress != progress { backdropProgress = progress }
    }

    private func updateIndicator() {
        let inset = max(0, (holdingsTop ?? 0) - offset)
        if indicatorTopInset != inset { indicatorTopInset = inset }
        let visible = holdingsTop != nil && viewportHeight - inset > 32
        if hasVisibleIndicatorTrack != visible { hasVisibleIndicatorTrack = visible }
    }
}

struct PortfolioPinnedHero: ViewModifier {
    let scrollState: PortfolioHomeScrollState

    func body(content: Content) -> some View {
        content.offset(y: scrollState.heroOffset)
    }
}

struct PortfolioHomeScrollIndicators: ViewModifier {
    let scrollState: PortfolioHomeScrollState
    let enabled: Bool

    func body(content: Content) -> some View {
        content
            .contentMargins(.top, scrollState.indicatorTopInset, for: .scrollIndicators)
            .scrollIndicators(enabled && scrollState.hasVisibleIndicatorTrack ? .automatic : .hidden, axes: .vertical)
            .onGeometryChange(for: CGFloat.self) { geometry in
                max(0, geometry.size.height - geometry.safeAreaInsets.top - geometry.safeAreaInsets.bottom)
            } action: { _, height in
                scrollState.viewportChanged(to: height)
            }
    }
}

struct PortfolioContentSheet<Content: View>: View {
    @Environment(\.locale) private var appLocale
    let scrollState: PortfolioHomeScrollState
    let content: Content
    @Environment(\.colorScheme) private var colorScheme

    init(scrollState: PortfolioHomeScrollState, @ViewBuilder content: () -> Content) {
        self.scrollState = scrollState
        self.content = content()
    }

    private var widthProgress: CGFloat {
        scrollState.sheetProgress
    }

    private var horizontalInset: CGFloat {
        PortfolioContentSheetLayout.initialHorizontalInset * (1 - widthProgress)
    }

    private var settlingProgress: CGFloat {
        PortfolioContentSheetLayout.settlingProgress(
            offset: scrollState.heroOffset, colorScheme: colorScheme
        )
    }

    private var sheetShape: UnevenRoundedRectangle {
        PortfolioContentSheetLayout.shape
    }

    var body: some View {
        content
            .background {
                PortfolioContentSheetBackground(
                    colorScheme: colorScheme,
                    settlingProgress: settlingProgress
                )
                .allowsHitTesting(false)
            }
            .clipShape(sheetShape)
            .padding(.horizontal, horizontalInset)
            .accessibilityElement(children: .contain)
    }
}

struct PortfolioContentSheetBackground: View {
    @Environment(\.locale) private var appLocale
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let colorScheme: ColorScheme
    let settlingProgress: CGFloat

    private var terminalColor: Color {
        colorScheme == .light ? .white : .black
    }

    private var sheetShape: UnevenRoundedRectangle {
        PortfolioContentSheetLayout.shape
    }

    @ViewBuilder
    private var liquidGlassLayer: some View {
        if #available(iOS 26.0, *) {
            Color.clear
                .glassEffect(.clear, in: sheetShape)
        } else {
            Rectangle()
                .fill(.ultraThinMaterial)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                // The card retains its own glass surface. No separate blur
                // band extends beyond its rounded edge.
                if !reduceTransparency, settlingProgress < 1 {
                    liquidGlassLayer
                }

                // The top of the card is the glass itself — `.clear`, the
                // variant that barely frosts, so the page shows through and
                // only its rim and highlight draw the card, like the
                // assistant's header buttons. The wash comes in lower down,
                // where the list needs an even ground to be read on.
                LinearGradient(
                    stops: [
                        .init(color: terminalColor.opacity(0), location: 0),
                        .init(color: terminalColor.opacity(colorScheme == .dark ? 0.02 : 0.06),
                              location: colorScheme == .dark ? 0.40 : 0.28),
                        .init(color: terminalColor.opacity(colorScheme == .dark ? 0.18 : 0.55),
                              location: colorScheme == .dark ? 0.72 : 0.62),
                        .init(color: terminalColor, location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )

                // Passive glass avoids a full-card press highlight. Night
                // opacity is delayed independently of the width expansion.
                terminalColor.opacity(reduceTransparency ? 1 : pow(settlingProgress, 3))
            }
            .frame(height: PortfolioContentSheetLayout.transitionHeight)

            terminalColor
        }
    }
}

struct PortfolioRefreshTimestamp: View {
    @Environment(\.locale) private var appLocale
    let date: Date?
    let cachedAt: Date?
    let isRefreshing: Bool

    var body: some View {
        Group {
            if let cachedAt {
                Text(L10n.text("上次显示于 \(cachedAt.formatted(.dateTime.month().day().hour().minute().locale(appLocale)))"))
                    .appNumber(.micro)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if let date {
                Text(L10n.text("更新于 \(date.formatted(.dateTime.hour().minute()))"))
                    .appNumber(.micro)
                    .foregroundStyle(Color.primary.opacity(0.44))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: cachedAt != nil ? 20 : 0)
        .offset(y: cachedAt != nil ? 0 : -16)
        .opacity(isRefreshing || cachedAt != nil ? 1 : 0)
        .animation(.easeOut(duration: 0.18), value: isRefreshing)
        .accessibilityHidden(!isRefreshing && cachedAt == nil)
        .accessibilityLabel(cachedAt.map { L10n.text("上次显示于 \($0.formatted(.dateTime.month().day().hour().minute().locale(appLocale)))") }
            ?? date.map { L10n.text("数据更新于 \($0.formatted(.dateTime.hour().minute()))") } ?? "")
    }
}

enum HomeSkeletonStyle {
    static func color(for scheme: ColorScheme) -> Color {
        CatfolioTheme.skeletonFill
    }
}

struct HomeSkeletonBlock: View {
    @Environment(\.locale) private var appLocale
    let width: CGFloat
    let height: CGFloat
    let color: Color

    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(color)
            .frame(width: width, height: height)
    }
}

struct PortfolioLoadingView: View {
    @Environment(\.locale) private var appLocale
    @Environment(\.colorScheme) private var colorScheme
    var isAnimating = true
    let scrollState: PortfolioHomeScrollState

    var body: some View {
        let color = HomeSkeletonStyle.color(for: colorScheme)
        VStack(spacing: 0) {
            PortfolioChartLoadingPlaceholder(isAnimating: isAnimating)
                .frame(height: PortfolioHeroChartLayout.sectionHeight)
                .modifier(PortfolioPinnedHero(scrollState: scrollState))

            PortfolioContentSheet(scrollState: scrollState) {
            VStack(spacing: 0) {
            ZStack(alignment: .top) {
                TodayLoadingHeader(isAnimating: isAnimating)
                    .padding(.horizontal, CatfolioStyle.pageHorizontalInset)
                    .padding(.top, 30)
                TodayContributionLoadingBars(isAnimating: isAnimating)
                    .padding(.horizontal, CatfolioStyle.pageHorizontalInset)
                    .frame(height: 167, alignment: .top)
                    .offset(y: 139)
            }
            .frame(height: 326, alignment: .top)

            VStack(spacing: 18) {
                HStack {
                    HomeSkeletonBlock(width: 118, height: 22, color: color)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.primary.opacity(0.10))
                    Spacer()
                    Image(systemName: "line.3.horizontal.decrease")
                        .font(.system(size: 20))
                        .foregroundStyle(Color.primary.opacity(0.10))
                        .frame(width: 58, height: 44)
                        .background(color, in: Capsule())
                }
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(color).frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: 10) {
                        HomeSkeletonBlock(width: 63, height: 14, color: color)
                        HStack(spacing: 8) {
                            HomeSkeletonBlock(width: 59, height: 10, color: color)
                            HomeSkeletonBlock(width: 40, height: 10, color: color)
                        }
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 10) {
                        HomeSkeletonBlock(width: 94, height: 14, color: color)
                        HStack(spacing: 4) {
                            HomeSkeletonBlock(width: 79, height: 10, color: color)
                            HomeSkeletonBlock(width: 45, height: 10, color: color)
                        }
                    }
                }
                .frame(height: 64)
            }
            .padding(.horizontal, CatfolioStyle.pageHorizontalInset)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, minHeight: 240, alignment: .top)
            }
            }
            .zIndex(1)
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isAnimating ? L10n.text("正在读取投资组合") : L10n.text("暂无持仓数据"))
    }
}
