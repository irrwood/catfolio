import ImageIO
import SwiftUI
import UIKit

/// Shared treatment for the oversized financial values used as page and card
/// headlines: SF Rounded, with a smaller currency/sign prefix aligned to the
/// numeral baseline.
///
/// No manual tracking. The 5% letterspacing here was cut for Montserrat,
/// whose numerals are narrow; SF carries Apple's own optical tracking per
/// size, and adding to it at display sizes visibly loosens the figure.
struct CatfolioDisplayAmountText: View {
    let text: String
    var size: CGFloat = 32
    var symbolSize: CGFloat = 20.64
    var color: Color = .primary

    private var splitText: (prefix: String, number: String) {
        guard let digitIndex = text.firstIndex(where: \.isNumber) else { return ("", text) }
        return (String(text[..<digitIndex]), String(text[digitIndex...]))
    }

    var body: some View {
        let parts = splitText
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(parts.prefix)
                .font(.system(size: symbolSize, weight: .medium, design: .rounded))
            Text(parts.number)
                .font(.system(size: size, weight: .medium, design: .rounded))
        }
        .monospacedDigit()
        .foregroundStyle(color)
        .lineLimit(1)
        .minimumScaleFactor(0.72)
    }
}

/// Defers expensive sheet content until UIKit reports that the system
/// presentation transition has completed. This keeps the interactive spring
/// free of chart preparation, decoding and network callbacks.
struct PresentationDidAppearReader: UIViewControllerRepresentable {
    let action: () -> Void

    func makeUIViewController(context: Context) -> ObserverViewController {
        ObserverViewController(action: action)
    }

    func updateUIViewController(_ controller: ObserverViewController, context: Context) {
        controller.action = action
    }

    final class ObserverViewController: UIViewController {
        var action: () -> Void
        private var hasReported = false

        init(action: @escaping () -> Void) {
            self.action = action
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        override func loadView() {
            let view = UIView(frame: .zero)
            view.backgroundColor = .clear
            view.isUserInteractionEnabled = false
            self.view = view
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard !hasReported else { return }
            hasReported = true
            let callback = action
            DispatchQueue.main.async(execute: callback)
        }
    }
}

enum CatfolioStyle {
    static let green = Color(red: 47 / 255, green: 138 / 255, blue: 62 / 255)
    static let red = Color(red: 228 / 255, green: 0, blue: 20 / 255)
    static let blue = Color(red: 112 / 255, green: 140 / 255, blue: 255 / 255)
    /// Shared page-edge alignment used by the home content regions.
    static let pageHorizontalInset: CGFloat = 20
    static let cardRadius: CGFloat = 20
    static let controlRadius: CGFloat = 12
}

/// The expanded Catfolio palette. Screens opt into these tokens explicitly so
/// a palette preview can be evaluated without silently recolouring the app.
enum CatfolioPalette {
    static let coral50 = color(0xFFECEB)
    static let coral200 = color(0xFFB3B1)
    static let coral500 = color(0xFF5D5B)
    static let coral700 = color(0xD32F2D)
    static let coral900 = color(0x7A1615)

    static let rose50 = color(0xFFE6EC)
    static let rose300 = color(0xD1526C)
    static let rose500 = color(0xE30045)
    static let rose700 = color(0xA80033)
    static let rose900 = color(0x5E001C)

    static let magenta50 = color(0xF9E5FD)
    static let magenta200 = color(0xE274F5)
    static let magenta500 = color(0xC702E8)
    static let magenta700 = color(0xB42B81)
    static let magenta900 = color(0x4E005B)

    static let violet50 = color(0xEBE4FF)
    static let violet200 = color(0xCAAEFA)
    static let violet500 = color(0x804DDE)
    static let violet700 = color(0x5A2CA8)
    static let violet900 = color(0x31165C)

    static let blue50 = color(0xE4F1FF)
    static let blue200 = color(0xA0CDFF)
    static let blue500 = color(0x027DFF)
    static let blue700 = color(0x2B47D1)
    static let blue900 = color(0x142A7A)

    static let sky50 = color(0xCAFDFF)
    static let sky200 = color(0x7FE8FF)
    static let sky300 = color(0x91D2FC)
    static let sky700 = color(0x016D97)
    static let sky900 = color(0x084A63)

    static let teal50 = color(0xDBFBF4)
    static let teal200 = color(0x70D7C2)
    static let teal400 = color(0x00E1B2)
    static let teal500 = color(0x00C6A3)
    static let teal900 = color(0x0A6B62)

    static let green50 = color(0xE4FBEE)
    static let green200 = color(0x84F4AD)
    static let green500 = color(0x05AE5B)
    static let green700 = color(0x027D50)
    static let green900 = color(0x006645)
    /// Exact Figma green used by the Today contribution bars.
    static let contributionGreen = color(0x00CC00)
    /// Holding-detail transaction markers from the shared chart language.
    static let tradeBuy = color(0x01B801)
    static let tradeSellLight = color(0xFF9500)
    static let tradeSellDark = yellow500
    static let securityPriceLine = color(0x3475FF)
    /// Figma Today-card negative series and its ambient dark-mode light source.
    static let contributionRed = color(0xD5312C)
    static let contributionRedGlow = color(0xE2433C)

    static let yellow50 = color(0xFFFACC)
    static let yellow300 = color(0xFFF904)
    static let yellow500 = color(0xF7D700)
    static let yellow700 = color(0xC8CD01)
    static let yellow900 = color(0x5E5100)

    static let orange50 = color(0xFFEEE1)
    static let orange200 = color(0xFFD2BD)
    static let orange400 = color(0xFF6B43)
    static let orange500 = color(0xEF7A00)
    static let orange900 = color(0x6B3200)

    static let clay50 = color(0xF6EBE3)
    static let clay200 = color(0xFFAB7D)
    static let clay500 = color(0xB57347)
    static let clay700 = color(0x8A5231)
    static let clay900 = color(0x4A2A17)

    static let neutral50 = color(0xF8FAFA)
    static let neutral100 = color(0xEFF2F2)
    static let neutral200 = color(0xE2E7E7)
    static let neutral300 = color(0xCBD2D3)
    static let neutral400 = color(0xA7B0B1)
    static let neutral500 = color(0x7F8A8B)
    static let neutral600 = color(0x5F6A6B)
    static let neutral700 = color(0x454E4F)
    static let neutral800 = color(0x2C3334)
    static let neutral900 = color(0x1A1F20)

    static let white = color(0xFFFFFF)
    static let paper = color(0xF1FDFE)
    static let black = color(0x000000)

    static let muted100 = color(0xE7F1F2)
    static let muted200 = color(0xC1E1E4)
    static let muted300 = color(0xB4D0D2)
    static let muted500 = color(0x80B9BB)

    static let berryGradient = LinearGradient(
        colors: [rose500, violet500],
        startPoint: .topTrailing,
        endPoint: .bottomLeading
    )
    static let mistGradient = LinearGradient(
        colors: [color(0xB5DCF0), paper],
        startPoint: .topTrailing,
        endPoint: .bottomLeading
    )
    static let jadeGradient = LinearGradient(
        colors: [teal500, green50],
        startPoint: .topTrailing,
        endPoint: .bottomLeading
    )
    static let emberGradient = LinearGradient(
        stops: [
            .init(color: yellow500, location: 0),
            .init(color: orange400, location: 0.55),
            .init(color: clay500, location: 1),
        ],
        startPoint: .topTrailing,
        endPoint: .bottomLeading
    )

    private static func color(_ hex: UInt32) -> Color {
        Color(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

/// Semantic application colors. Views should depend on these roles instead of
/// palette swatches so changing one token updates every related screen.
enum CatfolioTheme {
    static let accent = CatfolioPalette.blue500
    static let positive = CatfolioPalette.green500
    static let danger = CatfolioPalette.rose500
    static let warning = CatfolioPalette.orange500

    static let trading212 = accent
    static let moomoo = CatfolioPalette.orange400
    static let interactiveBrokers = danger
    static let csvImport = positive
    static let services = CatfolioPalette.violet500
    static let preference = CatfolioPalette.teal500
    static let localData = CatfolioPalette.sky700
    static let neutralIcon = CatfolioPalette.neutral600

    static let disclosure = accent.opacity(0.68)

    static func pageBackground(for colorScheme: ColorScheme) -> Color {
        colorScheme == .light ? CatfolioPalette.neutral50 : CatfolioPalette.neutral900
    }

    static func surface(for colorScheme: ColorScheme) -> Color {
        colorScheme == .light ? CatfolioPalette.white : CatfolioPalette.neutral800
    }
}

enum DisplayCurrency: String, CaseIterable, Identifiable {
    case usd = "USD"
    case gbp = "GBP"
    case eur = "EUR"
    case cny = "CNY"
    case hkd = "HKD"
    case cad = "CAD"
    case aud = "AUD"
    case sgd = "SGD"
    case jpy = "JPY"

    static let preferenceKey = "catfolio.displayCurrency"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .usd: "USD · 美元"
        case .gbp: "GBP · 英镑"
        case .eur: "EUR · 欧元"
        case .cny: "CNY · 人民币"
        case .hkd: "HKD · 港币"
        case .cad: "CAD · 加元"
        case .aud: "AUD · 澳元"
        case .sgd: "SGD · 新加坡元"
        case .jpy: "JPY · 日元"
        }
    }

    static var current: DisplayCurrency {
        let saved = UserDefaults.standard.string(forKey: preferenceKey)
        return saved.flatMap(DisplayCurrency.init(rawValue:)) ?? .usd
    }

    func fromUSD(_ value: Double) -> Double {
        guard let usdPerUnit = LocalPortfolioEngine.usdRate(for: rawValue), usdPerUnit > 0 else {
            return value
        }
        return value / usdPerUnit
    }
}

enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    static let preferenceKey = "catfolio.appearance"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "跟随系统"
        case .light: "浅色"
        case .dark: "深色"
        }
    }

    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

enum CompanyNameDisplay: String, CaseIterable, Identifiable {
    case original = "原始名称"
    case chineseShort = "中文简称"

    static let preferenceKey = "catfolio.companyNameDisplay"

    var id: String { rawValue }

    static var current: CompanyNameDisplay {
        let saved = UserDefaults.standard.string(forKey: preferenceKey)
        return saved.flatMap(CompanyNameDisplay.init(rawValue:)) ?? .original
    }
}

enum CompanyNameCatalog {
    static func displayName(ticker: String, fallback: String) -> String {
        guard CompanyNameDisplay.current == .chineseShort else { return fallback }

        let ticker = ticker.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if let name = chineseShortNames[ticker] { return name }

        let suffixes = [".L", ".SW", ".AS", ".DE", ".PA", ".MI", ".HK", ".TO"]
        if let suffix = suffixes.first(where: ticker.hasSuffix) {
            let baseTicker = String(ticker.dropLast(suffix.count))
            if let name = chineseShortNames[baseTicker] { return name }
        }

        return fallback
    }

    // Only include established everyday names. An unknown symbol keeps the broker name
    // instead of receiving an unreliable machine-translated corporate name.
    private static let chineseShortNames: [String: String] = [
        "AAPL": "苹果",
        "ABBV": "艾伯维",
        "ADBE": "奥多比",
        "AMD": "超威半导体",
        "AMZN": "亚马逊",
        "ARM": "Arm",
        "ASML": "阿斯麦",
        "ASMLA": "阿斯麦",
        "AVGO": "博通",
        "BABA": "阿里巴巴",
        "BAC": "美国银行",
        "BIDU": "百度",
        "BMO": "蒙特利尔银行",
        "BMY": "百时美施贵宝",
        "BRK-B": "伯克希尔",
        "BRK.B": "伯克希尔",
        "CSCO": "思科",
        "COST": "好市多",
        "CVX": "雪佛龙",
        "DIA": "道琼斯30",
        "DIS": "迪士尼",
        "EQQQ": "纳斯达克100",
        "GLD": "黄金ETF",
        "GOOG": "谷歌",
        "GOOGL": "谷歌",
        "GS": "高盛",
        "IBM": "IBM",
        "INTC": "英特尔",
        "IUSA": "iShares 标普500",
        "IWM": "罗素2000",
        "JD": "京东",
        "JNJ": "强生",
        "JPM": "摩根大通",
        "KO": "可口可乐",
        "LLY": "礼来",
        "LI": "理想汽车",
        "MA": "万事达",
        "MCD": "麦当劳",
        "META": "Meta",
        "MRK": "默沙东",
        "MS": "摩根士丹利",
        "MSFT": "微软",
        "MU": "美光",
        "NFLX": "奈飞",
        "NIO": "蔚来",
        "NKE": "耐克",
        "NTDOY": "任天堂",
        "NVDA": "英伟达",
        "ORCL": "甲骨文",
        "PDD": "拼多多",
        "PEP": "百事",
        "PFE": "辉瑞",
        "PLTR": "帕兰提尔",
        "QCOM": "高通",
        "QQQ": "纳斯达克100",
        "RR": "劳斯莱斯",
        "SBUX": "星巴克",
        "SPY": "SPDR 标普500",
        "TD": "多伦多道明银行",
        "TCEHY": "腾讯",
        "TSLA": "特斯拉",
        "TSM": "台积电",
        "UBER": "优步",
        "UNH": "联合健康",
        "V": "Visa",
        "VEU": "美国以外市场",
        "VHVG": "Vanguard 发达市场",
        "VOO": "Vanguard 标普500",
        "VUSA": "Vanguard 标普500",
        "VUAG": "Vanguard 标普500",
        "VTI": "美国全市场",
        "VWCE": "Vanguard 全球市场",
        "VWRL": "Vanguard 全球市场",
        "VWRP": "Vanguard 全球市场",
        "WMT": "沃尔玛",
        "XPEV": "小鹏汽车"
    ]
}

struct ChartDateRange: Equatable {
    let start: Date
    let end: Date

    init(_ first: Date, _ second: Date) {
        start = min(first, second)
        end = max(first, second)
    }
}

struct ChartRangeSummary: View {
    let dateText: String
    let primaryValue: String
    let secondaryValue: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(dateText)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)

            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Spacer(minLength: 0)
                Text(primaryValue)
                    .appNumber(.callout, weight: .bold)
                    .foregroundStyle(color)
                    .lineLimit(1)

                Text(secondaryValue)
                    .appNumber(.callout, weight: .bold)
                    .foregroundStyle(color)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("区间 \(dateText)，变化 \(primaryValue)，\(secondaryValue)")
    }
}

struct ChartLegendItem: View {
    let title: String
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Shared interaction and visual constants for every chart in the app.
enum ChartInteractionStyle {
    static let activationDuration: TimeInterval = 0.23
    static let preActivationMovementTolerance: CGFloat = 10
    static let dimmedSeriesOpacity = 0.30
    static let selectionHapticMinimumInterval: TimeInterval = 0.035
    static let hapticsPreferenceKey = "catfolio.haptics"
}

struct ChartInteractionValue {
    let primaryLocation: CGPoint
    let secondaryLocation: CGPoint?

    var touchCount: Int { secondaryLocation == nil ? 1 : 2 }

    var horizontalSelectionLocations: [CGPoint] {
        [primaryLocation, secondaryLocation]
            .compactMap { $0 }
            .sorted { $0.x < $1.x }
    }
}

/// The single interaction entry point for charts. SwiftUI gestures expose one
/// pointer location, so this UIKit bridge owns the true multi-touch state and
/// lets every chart share the same ScrollView-safe activation policy.
struct ChartInteractionOverlay: UIViewRepresentable {
    let onValueChanged: (ChartInteractionValue) -> Void
    let onInteractionEnded: (Int) -> Void

    init(
        onValueChanged: @escaping (ChartInteractionValue) -> Void,
        onInteractionEnded: @escaping (Int) -> Void
    ) {
        self.onValueChanged = onValueChanged
        self.onInteractionEnded = onInteractionEnded
    }

    func makeUIView(context: Context) -> TouchCaptureView {
        let view = TouchCaptureView()
        view.onValueChanged = onValueChanged
        view.onInteractionEnded = onInteractionEnded
        return view
    }

    func updateUIView(_ uiView: TouchCaptureView, context: Context) {
        uiView.onValueChanged = onValueChanged
        uiView.onInteractionEnded = onInteractionEnded
    }

    final class TouchCaptureView: UIView {
        var onValueChanged: (ChartInteractionValue) -> Void = { _ in }
        var onInteractionEnded: (Int) -> Void = { _ in }
        private var activePressTouchCount = 0

        private lazy var inspectionPress: ChartDetailGestureRecognizer = {
            let recognizer = ChartDetailGestureRecognizer(
                target: self,
                action: #selector(handleInspectionPress(_:))
            )
            recognizer.minimumPressDuration = ChartInteractionStyle.activationDuration
            recognizer.allowableMovement = ChartInteractionStyle.preActivationMovementTolerance
            recognizer.cancelsTouchesInView = false
            recognizer.delaysTouchesBegan = false
            recognizer.delaysTouchesEnded = false
            return recognizer
        }()

        override init(frame: CGRect) {
            super.init(frame: frame)
            isMultipleTouchEnabled = true
            isExclusiveTouch = false
            backgroundColor = .clear
            isAccessibilityElement = false
            // A normal swipe exceeds `allowableMovement` before the hold
            // completes, so the ancestor ScrollView keeps vertical gestures.
            // After the hold succeeds, the first finger owns the interaction.
            // A second finger can join or leave without restarting it.
            addGestureRecognizer(inspectionPress)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        @objc
        private func handleInspectionPress(_ recognizer: ChartDetailGestureRecognizer) {
            switch recognizer.state {
            case .began, .changed:
                guard let value = recognizer.currentValue else { return }
                if recognizer.state == .began {
                    playActivationHapticIfEnabled()
                }
                activePressTouchCount = value.touchCount
                onValueChanged(value)
            case .ended, .cancelled:
                if activePressTouchCount > 0 {
                    onInteractionEnded(activePressTouchCount)
                }
                activePressTouchCount = 0
            case .failed:
                // A pre-activation scroll should not clear an existing chart
                // value or emit an interaction-ended callback.
                activePressTouchCount = 0
            default:
                break
            }
        }

        private func playActivationHapticIfEnabled() {
            let defaults = UserDefaults.standard
            let isEnabled = defaults.object(forKey: ChartInteractionStyle.hapticsPreferenceKey) as? Bool ?? true
            guard isEnabled else { return }
            UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.55)
        }

    }

    /// One recognizer owns the complete interaction so adding a second finger
    /// never competes with, cancels, or restarts the active one-finger hover.
    final class ChartDetailGestureRecognizer: UIGestureRecognizer {
        var minimumPressDuration = ChartInteractionStyle.activationDuration
        var allowableMovement = ChartInteractionStyle.preActivationMovementTolerance

        private weak var primaryTouch: UITouch?
        private var trackedTouches: [UITouch] = []
        private var primaryStartLocation = CGPoint.zero
        private var activationWorkItem: DispatchWorkItem?

        var currentValue: ChartInteractionValue? {
            guard let view, let primaryTouch = trackedTouches.first else { return nil }
            return ChartInteractionValue(
                primaryLocation: primaryTouch.location(in: view),
                secondaryLocation: trackedTouches.dropFirst().first?.location(in: view)
            )
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            guard state == .possible || state == .began || state == .changed else { return }

            let newTouches = touches
                .filter { touch in !trackedTouches.contains(where: { $0 === touch }) }
                .sorted { lhs, rhs in
                    lhs.timestamp == rhs.timestamp
                        ? lhs.location(in: view).x < rhs.location(in: view).x
                        : lhs.timestamp < rhs.timestamp
                }

            for touch in newTouches where trackedTouches.count < 2 {
                trackedTouches.append(touch)
            }

            if primaryTouch == nil, let firstTouch = trackedTouches.first, let view {
                primaryTouch = firstTouch
                primaryStartLocation = firstTouch.location(in: view)
                scheduleActivation()
            } else if state == .began || state == .changed {
                // The second finger upgrades the active hover in place.
                state = .changed
            }
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
            guard let primaryTouch, let view else { return }

            if state == .possible {
                let location = primaryTouch.location(in: view)
                let distance = hypot(
                    location.x - primaryStartLocation.x,
                    location.y - primaryStartLocation.y
                )
                if distance > allowableMovement {
                    cancelActivation()
                    state = .failed
                }
            } else if state == .began || state == .changed {
                state = .changed
            }
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
            finishTouches(touches, cancelled: false)
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
            finishTouches(touches, cancelled: true)
        }

        override func reset() {
            cancelActivation()
            primaryTouch = nil
            trackedTouches.removeAll(keepingCapacity: true)
            primaryStartLocation = .zero
            super.reset()
        }

        private func scheduleActivation() {
            cancelActivation()
            let workItem = DispatchWorkItem { [weak self] in
                guard let self, self.state == .possible, self.primaryTouch != nil else { return }
                self.state = .began
            }
            activationWorkItem = workItem
            DispatchQueue.main.asyncAfter(
                deadline: .now() + minimumPressDuration,
                execute: workItem
            )
        }

        private func cancelActivation() {
            activationWorkItem?.cancel()
            activationWorkItem = nil
        }

        private func finishTouches(_ touches: Set<UITouch>, cancelled: Bool) {
            let primaryEnded = touches.contains { touch in touch === primaryTouch }
            trackedTouches.removeAll { trackedTouch in
                touches.contains { touch in touch === trackedTouch }
            }

            guard primaryEnded else {
                // Removing only the second finger downgrades to one-finger
                // hover and keeps the selected point/tooltip alive.
                if state == .began || state == .changed {
                    state = .changed
                }
                return
            }

            cancelActivation()
            if state == .began || state == .changed {
                state = cancelled ? .cancelled : .ended
            } else if state == .possible {
                state = .failed
            }
        }
    }
}

/// Convenience adapter for charts that inspect only one point. It still uses
/// the shared interaction state machine, so scroll arbitration, timing,
/// haptics and cleanup cannot drift from time-series charts.
struct ChartPointInteractionOverlay: View {
    let onLocationChanged: (CGPoint) -> Void
    let onInteractionEnded: () -> Void

    var body: some View {
        ChartInteractionOverlay(
            onValueChanged: { value in
                onLocationChanged(value.primaryLocation)
            },
            onInteractionEnded: { _ in
                onInteractionEnded()
            }
        )
    }
}

/// Applies one hard-edged alpha mask to the complete visual series container.
/// Line, fill, markers, endpoints and future effects therefore cannot drift
/// into separate dimming implementations.
private struct ChartSeriesInteractionMask: ViewModifier {
    let selectedRange: ClosedRange<CGFloat>?
    let selectedX: CGFloat?
    let dimsAfterSingleSelection: Bool

    func body(content: Content) -> some View {
        content.mask {
            GeometryReader { geometry in
                let width = geometry.size.width
                ZStack(alignment: .topLeading) {
                    if let selectedRange {
                        let lower = min(width, max(0, selectedRange.lowerBound))
                        let upper = min(width, max(lower, selectedRange.upperBound))

                        Rectangle()
                            .fill(Color.white.opacity(ChartInteractionStyle.dimmedSeriesOpacity))

                        Rectangle()
                            .fill(Color.white)
                            .frame(width: upper - lower)
                            .offset(x: lower)
                    } else if dimsAfterSingleSelection, let selectedX {
                        let boundary = min(width, max(0, selectedX))

                        Rectangle()
                            .fill(Color.white.opacity(ChartInteractionStyle.dimmedSeriesOpacity))

                        Rectangle()
                            .fill(Color.white)
                            .frame(width: boundary)
                    } else {
                        Rectangle().fill(Color.white)
                    }
                }
            }
        }
    }
}

extension View {
    func chartSeriesInteractionMask(
        selectedRange: ClosedRange<CGFloat>?,
        selectedX: CGFloat?,
        dimsAfterSingleSelection: Bool
    ) -> some View {
        modifier(ChartSeriesInteractionMask(
            selectedRange: selectedRange,
            selectedX: selectedX,
            dimsAfterSingleSelection: dimsAfterSingleSelection
        ))
    }
}

struct ContentCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(20)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: CatfolioStyle.cardRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: CatfolioStyle.cardRadius, style: .continuous)
                    .stroke(Color.primary.opacity(0.055), lineWidth: 1)
            }
    }
}

struct StatusNotice: View {
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

            Text(text)
                .font(.footnote)
                .foregroundStyle(.primary)
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

    @ViewBuilder
    func catfolioTabBarBehavior() -> some View {
        if #available(iOS 26.0, *) {
            self.tabBarMinimizeBehavior(.onScrollDown)
        } else {
            self
        }
    }
}

struct GlassChoiceBar: View {
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

/// A compact chart range selector with a single floating selected capsule.
/// Unselected choices remain plain text so the control does not read as a
/// traditional segmented bar.
private enum ChartTimeRangePickerMetrics {
    static let horizontalInset: CGFloat = 16
    static let itemWidth: CGFloat = 44
    static let itemHeight: CGFloat = 30
    static let cornerRadius: CGFloat = 10
}

struct ChartTimeRangePicker<Value: Hashable>: View {

    let choices: [Value]
    @Binding var selection: Value
    var isDisabled = false
    var usesBrightSelectedBackground = false
    let title: (Value) -> String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 0) {
            ForEach(choices, id: \.self) { choice in
                Button {
                    selection = choice
                } label: {
                    Text(title(choice))
                        .appText(.footnote, weight: selection == choice ? .semibold : .medium, width: .compressed)
                        .foregroundStyle(textColor(for: choice))
                        .lineLimit(1)
                        .frame(
                            width: ChartTimeRangePickerMetrics.itemWidth,
                            height: ChartTimeRangePickerMetrics.itemHeight
                        )
                        .background {
                            if selection == choice {
                                RoundedRectangle(
                                    cornerRadius: ChartTimeRangePickerMetrics.cornerRadius,
                                    style: .continuous
                                )
                                    .fill(selectedBackgroundColor)
                            }
                        }
                        .contentShape(RoundedRectangle(
                            cornerRadius: ChartTimeRangePickerMetrics.cornerRadius,
                            style: .continuous
                        ))
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .accessibilityAddTraits(selection == choice ? .isSelected : [])
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, ChartTimeRangePickerMetrics.horizontalInset)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.55 : 1)
    }

    private func textColor(for choice: Value) -> Color {
        if selection == choice {
            return colorScheme == .light ? .black : .white
        }
        return colorScheme == .light ? Color.black.opacity(0.40) : Color.white.opacity(0.40)
    }

    private var selectedBackgroundColor: Color {
        if usesBrightSelectedBackground, colorScheme == .light {
            return .white
        }
        return colorScheme == .light
            ? Color.black.opacity(0.045)
            : Color.white.opacity(0.075)
    }
}

/// Geometry-matched loading state for the shared time-range picker. Keeping
/// this beside `ChartTimeRangePicker` prevents each chart screen from
/// inventing a different set of placeholder widths and selected-pill bounds.
struct ChartTimeRangePickerSkeleton: View {
    @Environment(\.colorScheme) private var colorScheme

    var itemCount = 7
    var selectedIndex = 3

    private var skeletonColor: Color {
        colorScheme == .dark ? .white.opacity(0.09) : Color(white: 0.957)
    }

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<max(1, itemCount), id: \.self) { index in
                ZStack {
                    if index == selectedIndex {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(skeletonColor.opacity(1.18))
                            .frame(width: 44, height: 30)
                    }

                    Capsule()
                        .fill(skeletonColor)
                        .frame(width: index == itemCount - 1 ? 23 : 14, height: 9)
                }
                .frame(maxWidth: .infinity, minHeight: 44)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct ToolbarIconButton: View {
    let systemImage: String
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(accessibilityLabel, systemImage: systemImage)
                .labelStyle(.iconOnly)
        }
        .accessibilityLabel(accessibilityLabel)
    }
}

struct GlassPrimaryButton: View {
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
        .tint(CatfolioTheme.accent)
    }
}

private final class AssetLogoImageCache: @unchecked Sendable {
    static let shared = AssetLogoImageCache()

    private let images = NSCache<NSURL, UIImage>()

    private init() {
        // Asset logos are bundled at 96 px and decoded only when visible.
        // Keeping roughly two long scrolling screens avoids churn without
        // allowing the full logo library to become resident at once.
        images.countLimit = 120
        images.totalCostLimit = 6 * 1_024 * 1_024
    }

    func image(for url: URL) -> UIImage? {
        images.object(forKey: url as NSURL)
    }

    func insert(_ image: UIImage, for url: URL) {
        let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
        images.setObject(image, forKey: url as NSURL, cost: cost)
    }
}

private actor AssetLogoRepository {
    struct DecodedImage: @unchecked Sendable {
        let value: UIImage
    }

    static let shared = AssetLogoRepository()

    private let session: URLSession
    private var requests: [URL: Task<Data, Error>] = [:]

    private init() {
        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.urlCache = URLCache(
            memoryCapacity: 4 * 1_024 * 1_024,
            diskCapacity: 32 * 1_024 * 1_024
        )
        session = URLSession(configuration: configuration)
    }

    func data(for url: URL) async throws -> Data {
        if url.isFileURL {
            return try Data(contentsOf: url, options: [.mappedIfSafe])
        }
        if let request = requests[url] {
            return try await request.value
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.timeoutInterval = 15
        let session = session
        let request = Task<Data, Error> {
            let (data, response) = try await session.data(for: urlRequest)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  !data.isEmpty else {
                throw URLError(.badServerResponse)
            }
            return data
        }
        requests[url] = request
        defer { requests[url] = nil }
        return try await request.value
    }

    func image(for url: URL) async throws -> DecodedImage {
        if let cached = AssetLogoImageCache.shared.image(for: url) {
            return DecodedImage(value: cached)
        }
        let data = try await data(for: url)
        if let cached = AssetLogoImageCache.shared.image(for: url) {
            return DecodedImage(value: cached)
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(
                  source,
                  0,
                  [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                      kCGImageSourceThumbnailMaxPixelSize: 96,
                      kCGImageSourceShouldCacheImmediately: true,
                  ] as CFDictionary
              ) else {
            throw URLError(.cannotDecodeContentData)
        }
        let image = UIImage(cgImage: cgImage)
        AssetLogoImageCache.shared.insert(image, for: url)
        return DecodedImage(value: image)
    }
}

struct AssetLogo: View {
    let ticker: String
    let logoSymbol: String?
    var size: CGFloat = 28
    var onBrandColorResolved: ((Color) -> Void)? = nil
    @State private var loadedImage: UIImage?

    var body: some View {
        Group {
            if let image = displayedImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
            } else {
                fallback
            }
        }
        .frame(width: size, height: size)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: size * 2 / 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: size * 2 / 7, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
        }
        .clipShape(RoundedRectangle(cornerRadius: size * 2 / 7, style: .continuous))
        .accessibilityHidden(true)
        .task(id: logoURL) {
            // SwiftUI may reuse this view when a ranked chart slot changes
            // ticker. Clear the old decoded image before resolving the new URL.
            loadedImage = nil
            await loadLogo()
        }
    }

    private var displayedImage: UIImage? {
        loadedImage ?? logoURL.flatMap { AssetLogoImageCache.shared.image(for: $0) }
    }

    @MainActor
    private func loadLogo() async {
        guard loadedImage == nil, let logoURL else {
            onBrandColorResolved?(AssetBrandColor.fallback(for: logoSymbol ?? ticker))
            return
        }
        if let cached = AssetLogoImageCache.shared.image(for: logoURL) {
            loadedImage = cached
            onBrandColorResolved?(AssetBrandColor.resolved(from: cached, fallbackKey: logoSymbol ?? ticker))
            return
        }
        guard let decoded = try? await AssetLogoRepository.shared.image(for: logoURL),
              !Task.isCancelled else {
            onBrandColorResolved?(AssetBrandColor.fallback(for: logoSymbol ?? ticker))
            return
        }
        loadedImage = decoded.value
        onBrandColorResolved?(AssetBrandColor.resolved(from: decoded.value, fallbackKey: logoSymbol ?? ticker))
    }

    private var fallback: some View {
        ZStack {
            fallbackColor
            Text(String(ticker.prefix(1)).uppercased())
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
        }
    }

    private var fallbackColor: Color {
        AssetBrandColor.fallback(for: logoSymbol ?? ticker)
    }

    private var logoURL: URL? {
        let symbol = (logoSymbol ?? ticker).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !symbol.isEmpty, symbol != "ETF 其他" else { return nil }
        if let bundled = Bundle.main.url(
            forResource: symbol.uppercased(),
            withExtension: "png",
            subdirectory: "AssetLogos"
        ) {
            return bundled
        }
        return URL(string: "https://financialmodelingprep.com")?
            .appendingPathComponent("image-stock")
            .appendingPathComponent("\(symbol).png")
    }
}

/// Resolves a usable brand accent from the actual logo while ignoring the
/// transparent/white canvas common in market-data logo assets.
enum AssetBrandColor {
    private struct Bucket {
        var red = 0.0
        var green = 0.0
        var blue = 0.0
        var weight = 0.0
    }

    static func resolved(from image: UIImage, fallbackKey: String) -> Color {
        guard let color = dominantColor(from: image) else {
            return fallback(for: fallbackKey)
        }
        return Color(uiColor: vivid(color))
    }

    static func fallback(for key: String) -> Color {
        let normalized = key.uppercased()

        if normalized.contains("NVDA") { return Color(red: 0.45, green: 0.72, blue: 0.10) }
        if normalized.contains("VUSA") || normalized.contains("VUAG") || normalized.contains("VTI") {
            return Color(red: 0.67, green: 0.08, blue: 0.12)
        }
        if normalized.contains("DWS") || normalized.contains("XS2D") {
            return Color(red: 0.05, green: 0.58, blue: 0.66)
        }
        if normalized.contains("QQQ") || normalized.contains("EQGB") || normalized.contains("OKTA") {
            return Color(red: 0.12, green: 0.37, blue: 0.90)
        }

        let colors = [
            Color(red: 0.26, green: 0.47, blue: 0.96),
            Color(red: 0.20, green: 0.62, blue: 0.36),
            Color(red: 0.92, green: 0.47, blue: 0.16),
            Color(red: 0.55, green: 0.36, blue: 0.86),
            Color(red: 0.12, green: 0.60, blue: 0.62),
            Color(red: 0.82, green: 0.32, blue: 0.56),
            Color(red: 0.34, green: 0.37, blue: 0.78),
            Color(red: 0.62, green: 0.43, blue: 0.28),
        ]
        let hash = normalized.unicodeScalars.reduce(UInt64(14_695_981_039_346_656_037)) {
            ($0 ^ UInt64($1.value)) &* 1_099_511_628_211
        }
        return colors[Int(hash % UInt64(colors.count))]
    }

    private static func vivid(_ color: UIColor) -> UIColor {
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        guard color.getHue(
            &hue,
            saturation: &saturation,
            brightness: &brightness,
            alpha: &alpha
        ) else { return color }

        return UIColor(
            hue: hue,
            saturation: min(max(saturation, 0.58), 0.92),
            brightness: min(max(brightness, 0.72), 0.94),
            alpha: 1
        )
    }

    private static func dominantColor(from image: UIImage) -> UIColor? {
        guard let cgImage = image.cgImage else { return nil }

        let width = 24
        let height = 24
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var buckets = Array(repeating: Bucket(), count: 18)
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Double(pixels[offset + 3]) / 255
            guard alpha > 0.18 else { continue }

            let red = Double(pixels[offset]) / 255
            let green = Double(pixels[offset + 1]) / 255
            let blue = Double(pixels[offset + 2]) / 255
            let maximum = max(red, green, blue)
            let minimum = min(red, green, blue)
            let delta = maximum - minimum
            let saturation = maximum == 0 ? 0 : delta / maximum

            // White/grey image canvases are not brand colours. Very dark marks
            // fall back to a stable accessible accent instead of muddying glass.
            guard saturation > 0.18, maximum > 0.12 else { continue }

            let hue: Double
            if delta == 0 {
                hue = 0
            } else if maximum == red {
                hue = ((green - blue) / delta).truncatingRemainder(dividingBy: 6) / 6
            } else if maximum == green {
                hue = (((blue - red) / delta) + 2) / 6
            } else {
                hue = (((red - green) / delta) + 4) / 6
            }
            let normalizedHue = hue < 0 ? hue + 1 : hue
            let index = min(Int(normalizedHue * Double(buckets.count)), buckets.count - 1)
            let weight = saturation * saturation * (0.35 + min(maximum, 0.9)) * alpha
            buckets[index].red += red * weight
            buckets[index].green += green * weight
            buckets[index].blue += blue * weight
            buckets[index].weight += weight
        }

        guard let winner = buckets.max(by: { $0.weight < $1.weight }), winner.weight > 0.10 else {
            return nil
        }
        return UIColor(
            red: winner.red / winner.weight,
            green: winner.green / winner.weight,
            blue: winner.blue / winner.weight,
            alpha: 1
        )
    }
}

enum DisplayFormat {
    static func shares(_ value: Double) -> String {
        value.formatted(
            .number
                .grouping(.never)
                .precision(.fractionLength(0...4))
        )
    }

    static func money(
        _ value: Double,
        currency: String? = nil,
        signed: Bool = false,
        fractionDigits: Int? = nil
    ) -> String {
        guard value.isFinite else { return "—" }
        let targetCurrency: String
        let adjusted: Double
        if let currency {
            let normalizedCurrency = currency.uppercased()
            targetCurrency = normalizedCurrency == "GBX" ? "GBP" : normalizedCurrency
            adjusted = normalizedCurrency == "GBX" ? value / 100 : value
        } else {
            let displayCurrency = DisplayCurrency.current
            targetCurrency = displayCurrency.rawValue
            adjusted = displayCurrency.fromUSD(value)
        }

        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = targetCurrency
        if targetCurrency == "USD" {
            formatter.currencySymbol = "$"
        }
        formatter.minimumFractionDigits = fractionDigits ?? 0
        formatter.maximumFractionDigits = fractionDigits ?? (abs(adjusted) >= 1_000 ? 0 : 2)
        let text = formatter.string(from: NSNumber(value: abs(adjusted))) ?? "\(adjusted)"
        guard signed else { return text }
        return "\(adjusted >= 0 ? "+" : "-")\(text)"
    }

    static func compactMoney(_ usdValue: Double) -> String {
        let displayCurrency = DisplayCurrency.current
        let converted = displayCurrency.fromUSD(usdValue)
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = displayCurrency.rawValue
        if displayCurrency == .usd {
            formatter.currencySymbol = "$"
        }
        let symbol = formatter.currencySymbol ?? "\(displayCurrency.rawValue) "
        let compact = abs(converted).formatted(
            .number
                .notation(.compactName)
                .precision(.fractionLength(0...1))
        )
        return "\(converted < 0 ? "-" : "")\(symbol)\(compact)"
    }

    static func percent(_ value: Double, signed: Bool = true) -> String {
        "\(signed && value >= 0 ? "+" : "")\(value.formatted(.number.precision(.fractionLength(1))))%"
    }

    static func ratioPercent(_ value: Double?) -> String {
        guard let value else { return "暂无" }
        return percent(value * 100)
    }
}
