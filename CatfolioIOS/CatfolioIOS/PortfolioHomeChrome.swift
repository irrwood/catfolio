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
            Group {
                if colorScheme == .dark {
                    PortfolioNightGlow(cardTop: scrollState.restingSheetTop, scrollState: scrollState)
                } else {
                    PortfolioHomeTopBackground(colorScheme: colorScheme)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .opacity(1 - scrollState.backdropProgress)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
    }
}

/// Figma 398:3114's night page. There is no gradient and no coloured light:
/// the canvas is a pale blue, and black shapes blurred over it take the light
/// away. What survives between them is the glow — a band behind the card's
/// top edge, brighter on the left because a second, narrower shape shades
/// the right.
///
/// The shapes are placed against the card's resting top rather than the
/// screen, so the band sits behind the card whatever height the hero above
/// it takes (Figma has the card at 398pt with no chart; here it rests lower).
struct PortfolioNightGlow: View {
    /// The sheet's top in the backdrop's space with the page at rest.
    let cardTop: CGFloat?
    let scrollState: PortfolioHomeScrollState

    static let canvas = Color(red: 0x7D / 255, green: 0xA7 / 255, blue: 0xEC / 255)
    /// Figma's card top in its 402pt frame; every shape is placed from it.
    private static let figmaCardTop: CGFloat = 398
    private static let blur: CGFloat = 100
    /// Room for the blur on every side of a pre-rendered shape (3σ).
    private static let bleed: CGFloat = 300

    var body: some View {
        GeometryReader { geometry in
            // Horizontal geometry follows the width; vertical, the card.
            let scale = geometry.size.width / 402
            let shift = (cardTop ?? Self.figmaCardTop) - Self.figmaCardTop
            ZStack(alignment: .topLeading) {
                Self.canvas
                PortfolioNightShades(scale: scale, shift: shift, width: geometry.size.width,
                                     scrollState: scrollState)
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            .clipped()
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// A blurred black ellipse, rendered once and then only moved. Blurring
    /// two screen-sized shapes by 100pt on every scroll frame would cost the
    /// GPU far more than the motion is worth; translating a finished texture
    /// costs nothing.
    static func shape(width: CGFloat, height: CGFloat) -> some View {
        Image(uiImage: Self.blurredEllipse(width: width, height: height))
            .resizable()
            .frame(width: width + 2 * Self.bleed, height: height + 2 * Self.bleed)
            .offset(x: -Self.bleed, y: -Self.bleed)
    }

    @MainActor private static var cache: [String: UIImage] = [:]

    /// Rendered at a quarter of the point size: a 100pt blur has no detail a
    /// finer texture would keep, and the image stays a few hundred KB.
    @MainActor private static func blurredEllipse(width: CGFloat, height: CGFloat) -> UIImage {
        let key = "\(Int(width.rounded()))x\(Int(height.rounded()))"
        if let image = cache[key] { return image }
        let renderer = ImageRenderer(content:
            Ellipse()
                .fill(.black)
                .frame(width: width, height: height)
                .blur(radius: blur)
                .frame(width: width + 2 * bleed, height: height + 2 * bleed)
        )
        renderer.scale = 0.25
        let image = renderer.uiImage ?? UIImage()
        cache[key] = image
        return image
    }
}

/// The two black shapes over the blue, which rise as the page scrolls up —
/// each at its own rate, so the light opens unevenly rather than as one
/// sliding sheet. Its own view, so a scroll sample moves these and redraws
/// nothing else.
private struct PortfolioNightShades: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let scale: CGFloat
    let shift: CGFloat
    let width: CGFloat
    let scrollState: PortfolioHomeScrollState

    private static let topRate: CGFloat = 0.8
    private static let rightRate: CGFloat = 1.4

    var body: some View {
        let scroll = reduceMotion ? 0 : scrollState.heroOffset
        ZStack(alignment: .topLeading) {
            // Figma's top shape starts 275pt above the screen. Moved down to
            // this card it would let blue in at the status bar, so everything
            // above its centre is held black; it rises with the top shape.
            Rectangle()
                .fill(.black)
                .frame(width: width + 400, height: 400 + (-275 + 365.5 + shift))
                .blur(radius: 100)
                .drawingGroup()
                .offset(x: -200, y: -400 - scroll * Self.topRate)
            // The top of the page goes black.
            PortfolioNightGlow.shape(width: 736 * scale, height: 731)
                .offset(x: -159 * scale, y: -275 + shift - scroll * Self.topRate)
            // The right side stays dark longer, so the glow leans left.
            PortfolioNightGlow.shape(width: 246 * scale, height: 709)
                .offset(x: 235 * scale, y: -278 + shift - scroll * Self.rightRate)
        }
    }
}

/// The black slab under the night card, Figma's `Rectangle 34625532`. It
/// starts one corner radius below the card's top, so the glass's top edge
/// still has the blue behind it and the body below has black. Drawn behind
/// the sheet and not clipped to it: its blur is what shades the gutters
/// either side of the card.
struct PortfolioCardSlab: View {
    static let inset: CGFloat = 53
    static let cornerRadius: CGFloat = 53
    /// How far the sheet has opened towards the full width, 0…1.
    let widthProgress: CGFloat
    var fill: Color = .black

    var body: some View {
        RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
            .fill(fill)
            .padding(.top, Self.inset)
            // At rest the blurred sides are Figma's blue gutters. Once the
            // sheet reaches the screen edges there are no gutters, and a blur
            // centred on the edge left a half-blue strip down both sides; the
            // slab widens past the screen as the sheet does.
            .padding(.horizontal, -60 * widthProgress)
            // Figma's runs 1,116pt, well past the screen. A short portfolio
            // ends its sheet mid-screen, and the blue canvas showed under it.
            .padding(.bottom, -1200)
            // Figma's layer blur 30 matched the render as a Gaussian of about
            // 20pt; it is also what spreads into the side gutters.
            .blur(radius: 20)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
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
        // The night gradient stays translucent through width expansion, then settles
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
    /// Where the sheet's top sits on screen with the page at rest. The night
    /// glow is placed behind it; it changes with layout, never with scrolling.
    private(set) var restingSheetTop: CGFloat?

    @ObservationIgnored private var offset: CGFloat = 0
    @ObservationIgnored private var pull: CGFloat = 0
    @ObservationIgnored private var lastSheetTop: CGFloat?
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
        updateRestingSheetTop()
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

    /// `top` is the sheet's current top on screen.
    func sheetMoved(to top: CGFloat) {
        lastSheetTop = top
        updateRestingSheetTop()
    }

    // Read only with the page at rest. Mid-scroll, the offset and the sheet's
    // frame reach here a frame apart, and the difference would move the
    // glow — re-blurring a screen of backdrop — on every frame. Checked from
    // both callbacks, since either can be the last to arrive at rest.
    private func updateRestingSheetTop() {
        guard abs(offset) < 0.5, pull == 0, let lastSheetTop else { return }
        let resting = lastSheetTop.rounded()
        guard restingSheetTop.map({ abs($0 - resting) > 0.5 }) ?? true else { return }
        restingSheetTop = resting
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
            // Behind the glass and outside its clip, so the glass takes its
            // colour from it and its blur reaches the gutters.
            .background {
                // Both appearances: a black slab at night, a white one by
                // day, so the light card has the night card's solid body and
                // lit rim instead of dissolving into the blue page.
                PortfolioCardSlab(widthProgress: widthProgress,
                                       fill: colorScheme == .dark ? .black : .white)
            }
            .padding(.horizontal, horizontalInset)
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { _, top in
                scrollState.sheetMoved(to: top)
            }
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

    /// iOS's clear glass adds a grey haze of its own at night — black behind
    /// it read back as #131313 where Figma's glass stays #000 — and doubled
    /// the blue at the card's top. A black tint takes the haze back out while
    /// the glass still refracts: measured against Figma 398:3114, 0.5 left the
    /// top at #1A2437 for Figma's #172131 and 0.7 went past it.
    private static let nightTint = 0.55

    @ViewBuilder
    private var liquidGlassLayer: some View {
        if #available(iOS 26.0, *) {
            Color.clear
                .glassEffect(colorScheme == .dark ? .clear.tint(.black.opacity(Self.nightTint)) : .clear, in: sheetShape)
        } else {
            Rectangle()
                .fill(.ultraThinMaterial)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                // Keep native refraction in both appearances. A light surface
                // wash leaves the top clear; the lower gradient protects text.
                if !reduceTransparency, settlingProgress < 1 {
                    liquidGlassLayer
                }

                // Night paints nothing over most of the glass (Figma
                // 398:3114): the black slab behind it gives the body its black
                // and the page's blue gives the top edge its light. Only its
                // last stretch fades to black — the glass ends here, above the
                // solid sheet, and its rim read as a rule between the Today
                // card and the holdings.
                if colorScheme == .dark {
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .clear, location: 0.72),
                            .init(color: .black, location: 1),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                } else {
                    // The white slab behind gives the body its white, as the
                    // black one does at night; only the end fades to solid.
                    LinearGradient(
                        stops: [
                            .init(color: .white.opacity(0), location: 0),
                            .init(color: .white.opacity(0), location: 0.72),
                            .init(color: .white, location: 1),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }

                // Settle into the page surface independently of width expansion.
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
