import ImageIO
import Observation
import SwiftUI
import UIKit

/// A slightly raised ground for app-owned modal pages in dark appearance.
/// Keep this separate from the security detail's designed presentation.
enum AppModalStyle {
    /// A sheet's night ground: `#141515`, the card's own hue (`#1D1E1E`) a
    /// step darker, so cards lift off it without a shift in colour.
    static let uiDarkBackground = UIColor(red: 0x14 / 255.0, green: 0x15 / 255.0, blue: 0x15 / 255.0, alpha: 1)
    static let darkBackground = Color(uiColor: uiDarkBackground)
    static let systemBackground = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? uiDarkBackground : .systemBackground
    })
}

/// One completion treatment across sheets and popovers, in both appearances.
struct AppModalDoneButton: View {
    var expands = false
    let action: () -> Void

    private static let label = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark ? .black : .white
    })

    var body: some View {
        Button(action: action) {
            Text(L10n.text("完成"))
                .appText(.callout, weight: .semibold)
                .foregroundStyle(Self.label)
                .frame(maxWidth: expands ? .infinity : nil, minHeight: expands ? 36 : nil)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        // The ink colour: a black pill by day, a white one at night, with the
        // label in the opposite colour, so it never sinks into a dark sheet.
        .tint(CatfolioTheme.primaryText)
    }
}

private struct AppModalEnvironmentKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var isAppModal: Bool {
        get { self[AppModalEnvironmentKey.self] }
        set { self[AppModalEnvironmentKey.self] = newValue }
    }
}

private struct AppPageBackgroundModifier: ViewModifier {
    @Environment(\.isAppModal) private var isModal
    @Environment(\.colorScheme) private var colorScheme
    let fallback: Color

    func body(content: Content) -> some View {
        content.background(isModal && colorScheme == .dark ? AppModalStyle.darkBackground : fallback)
    }
}

private struct AppModalSurfaceModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    @ViewBuilder func body(content: Content) -> some View {
        if colorScheme == .dark {
            content
                .scrollContentBackground(.hidden)
                .background(AppModalStyle.darkBackground.ignoresSafeArea())
                .presentationBackground(AppModalStyle.darkBackground)
                .toolbarBackground(AppModalStyle.darkBackground, for: .navigationBar)
        } else {
            content
        }
    }
}

extension View {
    /// Apply to the scrolling page inside a navigation stack, so its own
    /// opaque fill cannot cover the presentation's ground.
    func appPageBackground(_ fallback: Color = .clear) -> some View {
        modifier(AppPageBackgroundModifier(fallback: fallback))
    }

    func appModalSurface() -> some View {
        modifier(AppModalSurfaceModifier()).environment(\.isAppModal, true)
    }

    func appSheet<Sheet: View>(isPresented: Binding<Bool>, onDismiss: (() -> Void)? = nil,
                              @ViewBuilder content: @escaping () -> Sheet) -> some View {
        sheet(isPresented: isPresented, onDismiss: onDismiss) { content().appModalSurface() }
    }

    func appSheet<Item: Identifiable, Sheet: View>(item: Binding<Item?>, onDismiss: (() -> Void)? = nil,
                                                   @ViewBuilder content: @escaping (Item) -> Sheet) -> some View {
        sheet(item: item, onDismiss: onDismiss) { content($0).appModalSurface() }
    }

    func appFullScreenCover<Cover: View>(isPresented: Binding<Bool>, onDismiss: (() -> Void)? = nil,
                                        @ViewBuilder content: @escaping () -> Cover) -> some View {
        fullScreenCover(isPresented: isPresented, onDismiss: onDismiss) { content().appModalSurface() }
    }

    func appFullScreenCover<Item: Identifiable, Cover: View>(item: Binding<Item?>, onDismiss: (() -> Void)? = nil,
                                                           @ViewBuilder content: @escaping (Item) -> Cover) -> some View {
        fullScreenCover(item: item, onDismiss: onDismiss) { content($0).appModalSurface() }
    }
}

/// Shared treatment for the oversized financial values used as page and card
/// headlines: SF Rounded, with a smaller currency/sign prefix aligned to the
/// numeral baseline.
///
/// No manual tracking. The 5% letterspacing here was cut for Montserrat,
/// whose numerals are narrow; SF carries Apple's own optical tracking per
/// size, and adding to it at display sizes visibly loosens the figure.
struct CatfolioDisplayAmountText: View {
    @Environment(\.locale) private var appLocale
    let text: String
    var size: CGFloat = 32
    var symbolSize: CGFloat = 20.64
    var color: Color = .primary
    var isDirectional = false
    var signFollowsValue = false

    private var amountText: Text {
        FinancialTextPresentation.parts(in: text, isDirectional: isDirectional, signFollowsValue: signFollowsValue)
            .reduce(Text(verbatim: "")) { result, part in
                switch part {
                case .sign(let sign):
                    result + sign.text.font(Typography.number(size: size))
                case .text(let value):
                    if let digitIndex = value.firstIndex(where: \.isNumber) {
                        result
                            + Text(verbatim: String(value[..<digitIndex]))
                                .font(Typography.number(size: symbolSize))
                            + Text(verbatim: String(value[digitIndex...]))
                                .font(Typography.number(size: size))
                                .customAttribute(FinancialNumberAttribute())
                    } else {
                        result + Text(verbatim: value).font(Typography.number(size: size))
                    }
                }
            }
    }

    var body: some View {
        FinancialText(alignmentFont: Typography.number(size: size)) { amountText }
        .monospacedDigit()
        .foregroundStyle(color)
        .lineLimit(1)
        .minimumScaleFactor(0.72)
        .accessibilityLabel(Text(verbatim: text))
    }
}

/// Content scrolling under a top bar fades out through a progressive blur
/// instead of meeting it at a hard line.
///
/// Set explicitly rather than left to `.automatic`, which on some screens
/// resolves to the hard edge — a visible boundary under the bar exactly where
/// the page should dissolve into it. Top edge only: the bottom edge and the
/// tab bar keep whatever the system gives them.
///
/// Applied per page, next to the page's navigation title, not once at the
/// root: the modifier reaches every scroll view below it, and the root stack
/// also holds the portfolio home, which has no top bar to blur under.
extension View {
    @ViewBuilder
    func softTopScrollEdge() -> some View {
        if #available(iOS 26.0, *) {
            scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            self
        }
    }

    @ViewBuilder
    func hardTopScrollEdge() -> some View {
        if #available(iOS 26.0, *) {
            scrollEdgeEffectStyle(.hard, for: .top)
        } else {
            self
        }
    }
}

extension UIScrollView {
    /// The same decision for a scroll view SwiftUI does not reach — one owned
    /// by a UIKit container, such as the History pager's pages.
    func applySoftTopScrollEdge() {
        if #available(iOS 26.0, *) {
            topEdgeEffect.style = .soft
        }
    }
}

/// Binds this page's scroll view before its large title first appears. Only
/// the page directly owned by the nearest navigation controller is changed;
/// never nominate a scroll view on a shared tab or outer navigation container.
struct NavigationBarScrollAnchor: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.nominateIfVisible()
    }
    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) {
        controller.releaseRegistration()
    }

    final class Controller: UIViewController {
        private weak var registeredOwner: UIViewController?
        private weak var registeredScrollView: UIScrollView?

        override func loadView() {
            let view = UIView(frame: .zero)
            view.backgroundColor = .clear
            view.isUserInteractionEnabled = false
            self.view = view
        }

        override func viewIsAppearing(_ animated: Bool) {
            super.viewIsAppearing(animated)
            nominateIfVisible()
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            nominateIfVisible()
        }

        func nominateIfVisible() {
            guard isViewLoaded, view.window != nil else { return }
            var candidate = view.superview
            while let current = candidate, !(current is UIScrollView) {
                candidate = current.superview
            }
            guard let scrollView = candidate as? UIScrollView else { return }
            var owner: UIViewController = self
            while let parent = owner.parent {
                if let navigation = parent as? UINavigationController {
                    guard navigation.topViewController === owner else { return }
                    if registeredOwner !== owner || registeredScrollView !== scrollView {
                        releaseRegistration()
                    }
                    if owner.contentScrollView(for: .top) !== scrollView {
                        owner.setContentScrollView(scrollView, for: .top)
                    }
                    registeredOwner = owner
                    registeredScrollView = scrollView
                    return
                }
                guard !(parent is UITabBarController) else { return }
                owner = parent
            }
        }

        func releaseRegistration() {
            if let owner = registeredOwner, let scrollView = registeredScrollView,
               owner.contentScrollView(for: .top) === scrollView {
                owner.setContentScrollView(nil, for: .top)
            }
            registeredOwner = nil
            registeredScrollView = nil
        }
    }
}

struct ContentCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(20)
            .settingsCardSurface()
    }
}

struct StatusNotice: View {
    @Environment(\.locale) private var appLocale
    enum Kind {
        case error
        case success
        case info
    }

    let text: String
    var kind: Kind = .error

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: iconName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(accentColor)
                .frame(width: 20)

            Text(L10n.message(text))
                .font(.footnote)
                .foregroundStyle(CatfolioTheme.primaryText)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            accentColor.opacity(0.08),
            in: RoundedRectangle(cornerRadius: CatfolioStyle.controlRadius, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: CatfolioStyle.controlRadius, style: .continuous)
                .stroke(accentColor.opacity(0.14), lineWidth: 0.5)
        }
        .accessibilityElement(children: .combine)
    }

    private var accentColor: Color {
        switch kind {
        case .error:
            return CatfolioTheme.warning
        case .success:
            return CatfolioTheme.positive
        case .info:
            return CatfolioTheme.accent
        }
    }

    private var iconName: String {
        switch kind {
        case .error:
            return "exclamationmark.circle.fill"
        case .success:
            return "checkmark.circle.fill"
        case .info:
            return "info.circle.fill"
        }
    }
}

extension View {
    func contentCard() -> some View {
        modifier(ContentCard())
    }
}

struct GlassChoiceBar: View {
    @Environment(\.locale) private var appLocale
    let choices: [String]
    @Binding var selection: String

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: 6) {
                HStack(spacing: 6) {
                    ForEach(choices, id: \.self) { choice in
                        Button(choice) { selection = choice }
                            .buttonStyle(.glass(glass(for: choice)))
                            .font(.caption.weight(.bold))
                            .accessibilityAddTraits(selection == choice ? .isSelected : [])
                    }
                }
            }
        } else {
            HStack(spacing: 4) {
                ForEach(choices, id: \.self) { choice in
                    Button(choice) { selection = choice }
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(selection == choice ? CatfolioTheme.accent.opacity(0.18) : .clear, in: Capsule())
                }
            }
            .padding(4)
            .background(.thinMaterial, in: Capsule())
        }
    }

    @available(iOS 26.0, *)
    private func glass(for choice: String) -> Glass {
        selection == choice
            ? .regular.tint(CatfolioTheme.accent.opacity(0.28)).interactive()
            : .regular.interactive()
    }
}

struct GlassPrimaryButton: View {
    @Environment(\.locale) private var appLocale
    @Environment(\.accountFlowTheme) private var accountTheme
    let title: String
    var systemImage: String? = nil
    /// Not ready to be tapped — an incomplete form, say. Renders as a plain
    /// disabled button.
    var isDisabled = false
    /// Work actually in flight. Renders the spinner.
    ///
    /// Separate from `isDisabled` because a form that is merely incomplete is
    /// not loading anything: every connector screen passed its "nickname is
    /// empty" check here and so showed a permanent spinner before the user had
    /// typed a thing, which reads as a hang.
    var isBusy = false
    let action: () -> Void

    var body: some View {
        Group {
            if #available(iOS 26.0, *) {
                button
                    .buttonStyle(.glassProminent)
            } else {
                button
                    .buttonStyle(.borderedProminent)
            }
        }
        .disabled(isDisabled || isBusy)
    }

    private var button: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .tint(accountTheme?.onAccent)
                } else if let systemImage {
                    Image(systemName: systemImage)
                        .font(.body.weight(.semibold))
                }
                Text(title)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .font(.body.weight(.semibold))
        .controlSize(.large)
        .tint(accountTheme?.accent ?? CatfolioTheme.accent)
        .foregroundColor(accountTheme?.onAccent)
    }
}

struct ContributionStripePattern: View {
    @Environment(\.locale) private var appLocale
    let color: Color

    var body: some View {
        Canvas { context, size in
            var stripes = Path()
            // Match the exported Figma stripe asset: 13pt strokes on a
            // 35.5pt cadence. The previous 18pt bands covered almost half of
            // each bar and made the whole gradient read much darker.
            let bandWidth: CGFloat = 13
            let spacing: CGFloat = 35.5
            // Start and end every diagonal band outside the rendered bounds.
            // If a stroke begins at y = 0 its cap remains visible just inside
            // the rounded mask, which reads as a short line head at the top.
            let overscan = bandWidth * 2
            var x = -size.height - overscan
            while x < size.width + size.height {
                stripes.move(to: CGPoint(x: x - overscan, y: -overscan))
                stripes.addLine(to: CGPoint(
                    x: x + size.height + overscan,
                    y: size.height + overscan
                ))
                x += spacing
            }
            context.stroke(stripes, with: .color(color), lineWidth: bandWidth)
        }
        .allowsHitTesting(false)
    }
}

/// Figma 487:5331 and 641:25494: the comparison-card identities in day and night.
enum ReturnsEntryStyle {
    static let returnFill = Color(red: 198 / 255, green: 155 / 255, blue: 0)
    static let cycleFill = Color(red: 227 / 255, green: 0, blue: 69 / 255)
    static let returnDayInk = Color(red: 56 / 255, green: 46 / 255, blue: 7 / 255)
    static let lossDayIconInk = Color(red: 123 / 255, green: 37 / 255, blue: 255 / 255)
}

/// The paints of Figma 487:5331 / 641:25494, per chart and scheme.
struct ReturnsSourcePalette {
    struct Glow {
        let asset: String
        /// Offset from the card's top-left corner, and size, before the blur.
        let frame: CGRect
        let abovePlot: Bool
    }

    /// The design's colour wash, composited over the card's opaque base.
    let fill: LinearGradient
    /// The title over the amount: the chart's tint, blended over the illustrated background.
    let title: Color
    let amount: Color
    let solidLayerColors: [Color]?
    let glows: [Glow]
    /// Each layer: this colour at the curve, fading to `curveFade` at its base.
    let curve: Color
    let curveFade: Color
    let stroke: Color
    /// The whole layer — fill and edge — is set at this opacity.
    let layerOpacity: Double
    let backLayerOpacity: Double
    let frontLayerOpacity: Double
    let backLayerColor: Color?
    let strokeOpacity: Double
    let strokeWidth: CGFloat

    private static func rgb(_ hex: UInt32, _ alpha: Double = 1) -> Color {
        Color(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
              blue: Double(hex & 0xFF) / 255).opacity(alpha)
    }

    init(isLosses: Bool, scheme: ColorScheme) {
        amount = scheme == .light ? (isLosses ? .white : Self.rgb(0x005CA7)) : .white
        // Front (bottom) to back (top): daylight blue layers lighten toward the back.
        solidLayerColors = isLosses ? (scheme == .light ? [.white, .white, .white] : nil) : scheme == .light
            ? [Self.rgb(0x70BCF9), Self.rgb(0xA7D7FF), .white]
            : [Self.rgb(0x0489F7), Self.rgb(0x0062B4), Self.rgb(0x078AF7)]
        backLayerOpacity = scheme == .dark ? (isLosses ? 0.3 : 0.4) : (isLosses ? 1 : 0.8)
        frontLayerOpacity = isLosses && scheme == .light ? 0.5 : 1
        backLayerColor = nil
        strokeOpacity = scheme == .dark ? 0.3 : 0.7
        strokeWidth = scheme == .dark ? 1 : 1.5
        switch (isLosses, scheme == .dark) {
        case (false, true):
            fill = LinearGradient(stops: [
                .init(color: Self.rgb(0x004F74), location: 0.04445),
                .init(color: Color.black, location: 0.67584)
            ], startPoint: UnitPoint(x: 0.217, y: -0.101), endPoint: UnitPoint(x: 0.783, y: 1.101))
            title = .white
            glows = [Glow(asset: "EntryGainGlow", frame: CGRect(x: -163.8, y: 28.2, width: 355.6, height: 279.6), abovePlot: false)]
            curve = Self.rgb(0x0189F8); curveFade = Self.rgb(0x0189F8, 0)
            stroke = .clear; layerOpacity = 1
        case (false, false):
            fill = LinearGradient(stops: [
                .init(color: Self.rgb(0x008DFF), location: 0.04445),
                .init(color: Self.rgb(0x008EFF), location: 0.67584)
            ], startPoint: UnitPoint(x: 0.217, y: -0.101), endPoint: UnitPoint(x: 0.783, y: 1.101))
            title = Self.rgb(0x2FA2FF)
            glows = [Glow(asset: "EntryGainGlow", frame: CGRect(x: -163.8, y: 28.2, width: 355.6, height: 279.6), abovePlot: true)]
            curve = .white; curveFade = .white
            stroke = .clear; layerOpacity = 1
        case (true, true):
            fill = LinearGradient(stops: [
                .init(color: Self.rgb(0x2B006B), location: 0.07168),
                .init(color: Color.black, location: 0.605)
            ], startPoint: UnitPoint(x: 0.692, y: 1.099), endPoint: UnitPoint(x: 0.308, y: -0.099))
            title = Self.rgb(0xB355FF)
            glows = [Glow(asset: "EntryLossGlow", frame: CGRect(x: -183.8, y: -138.8, width: 395.6, height: 296.6), abovePlot: false)]
            curve = Self.rgb(0x7D25FF); curveFade = Self.rgb(0xAC74FF, 0)
            stroke = .clear; layerOpacity = 1
        case (true, false):
            fill = LinearGradient(stops: [
                .init(color: Self.rgb(0xA66CFF), location: 0.32659),
                .init(color: Self.rgb(0x9047FF), location: 1)
            ], startPoint: .top, endPoint: .bottom)
            title = Self.rgb(0xB355FF)
            glows = [Glow(asset: "EntryLossDayGlow", frame: CGRect(x: -165.8, y: -156.8, width: 353.6, height: 296.6), abovePlot: false)]
            curve = Self.rgb(0x7D25FF); curveFade = Self.rgb(0xAC74FF)
            stroke = .clear; layerOpacity = 0.4
        }
    }
}
