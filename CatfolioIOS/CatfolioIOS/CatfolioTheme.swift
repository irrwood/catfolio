import ImageIO
import Observation
import SwiftUI
import UIKit

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
    /// The paywall's blue field and white plan cards keep their identity in both appearances.
    enum Paywall {
        static let top = CatfolioPalette.color(0x073BCE)
        static let middle = CatfolioPalette.color(0x236CEA)
        static let glow = CatfolioPalette.color(0x8AB9F7)
        static let bottom = CatfolioPalette.color(0xDEEDFF)
        static let action = CatfolioPalette.color(0x155BE5)
        static let ink = CatfolioPalette.color(0x142D58)
        static let secondaryInk = CatfolioPalette.color(0x52647F)
    }

    /// Close blue tones keep first-launch gradients and page changes subtle.
    enum FirstLaunch {
        static let top = CatfolioPalette.color(0x405A9D)
        static let middle = CatfolioPalette.color(0x536DB0)
        static let bottom = CatfolioPalette.color(0x7F93C9)
        static let violetTop = CatfolioPalette.color(0x4C589D)
        static let violetMiddle = CatfolioPalette.color(0x606CB0)
        static let violetBottom = CatfolioPalette.color(0x8C92C9)
    }

    /// Stable identity colours for the six public investors, independent of gains and losses.
    enum InvestorPortrait {
        static let pelosi = CatfolioPalette.dynamic(light: 0xF7DDE3, dark: 0x775563)
        static let hh = CatfolioPalette.dynamic(light: 0xDCE9D6, dark: 0x536753)
        static let berkshire = CatfolioPalette.dynamic(light: 0xF4E8C7, dark: 0x71664B)
        static let scion = CatfolioPalette.dynamic(light: 0xDDE4F5, dark: 0x52647B)
        static let ark = CatfolioPalette.dynamic(light: 0xE8DDF4, dark: 0x675779)
        static let musk = CatfolioPalette.dynamic(light: 0xF5DFCE, dark: 0x765D4C)

        static func background(for investorID: String) -> Color {
            switch investorID {
            case "pelosi": pelosi
            case "hh": hh
            case "berkshire": berkshire
            case "scion": scion
            case "ark": ark
            case "musk": musk
            default: Color(uiColor: .secondarySystemFill)
            }
        }
    }

    /// Existing chart swatches, shared without rounding their RGB components
    /// to nearby hex colours or changing their categorical assignments.
    enum ChartSeries {
        static let green = Color(red: 0.204, green: 0.780, blue: 0.349)
        static let orange = Color(red: 1.000, green: 0.584, blue: 0.000)
        static let blue = Color(red: 0.204, green: 0.459, blue: 1.000)
        static let rose = Color(red: 0.890, green: 0.000, blue: 0.271)
        static let magenta = Color(red: 0.780, green: 0.000, blue: 0.910)
        static let sky = Color(red: 0.627, green: 0.804, blue: 1.000)
        static let peach = Color(red: 1.000, green: 0.824, blue: 0.741)
        static let mint = Color(red: 0.000, green: 0.882, blue: 0.698)
        static let pink = Color(red: 1.000, green: 0.431, blue: 0.702)
        static let lavender = Color(red: 0.722, green: 0.600, blue: 1.000)
        static let teal = Color(red: 0.000, green: 0.620, blue: 0.540)
        static let neutral = Color(red: 0.400, green: 0.400, blue: 0.450)
    }

    /// Categorical colours for revenue lines, independent of gain/loss.
    static func revenueSegment(at index: Int) -> Color {
        let colors = [ChartSeries.blue, ChartSeries.orange, ChartSeries.magenta,
                      ChartSeries.teal, ChartSeries.rose, ChartSeries.lavender,
                      ChartSeries.mint, ChartSeries.pink, ChartSeries.sky, ChartSeries.peach]
        if colors.indices.contains(index) { return colors[index] }
        return Color(hue: (Double(index) * 0.61803398875).truncatingRemainder(dividingBy: 1),
                     saturation: 0.62, brightness: 0.78)
    }

    /// Grounds and fringe shared by the existing animated backgrounds.
    enum Ambient {
        static let night = Color(red: 0.012, green: 0.020, blue: 0.130)
        static let pinkFringe = Color(red: 1.000, green: 0.450, blue: 0.850)
        static let nightBright = Color(red: 0.012, green: 0.020, blue: 0.075)
        static let clearSkyDay = Color(red: 0.482, green: 0.820, blue: 1.000)
        static let clearSkyNight = Color(red: 0.020, green: 0.070, blue: 0.160)
        static let ringsNight = Color(red: 0.020, green: 0.050, blue: 0.100)
    }

    /// Exact fixed swatches used by existing surfaces and chart annotations.
    static let researchViolet = Color(red: 139 / 255, green: 92 / 255, blue: 246 / 255)
    static let fixedNeutralGray = Color(red: 142 / 255, green: 142 / 255, blue: 147 / 255)
    static let homeSky = Color(red: 154 / 255, green: 220 / 255, blue: 1)
    static let rangeNegative = Color(red: 1, green: 16 / 255, blue: 89 / 255)
    static let contributionSky = Color(red: 124 / 255, green: 212 / 255, blue: 1)
    static let stockMapBackground = Color(red: 0.045, green: 0.063, blue: 0.094)
    static let emptyStateGraphite = Color(white: 0x1E / 255)
    static let calendarMutedGreen = Color(red: 0.58, green: 0.66, blue: 0.27)

    /// Add-account action badges, Figma 630:23915.
    static let accountConnectTop = color(0x008F8C)
    static let accountConnectBottom = color(0x00DAD6)
    static let accountImportTop = color(0x0052FF)
    static let accountImportBottom = color(0x75A1FF)
    static let accountIBKRBackground = color(0xC71120)
    static let accountRobinhoodBackground = color(0xCCFF00)
    /// Connection canvas, Figma 745:7380. Broker colors come from their identities.
    static let accountConnectionBackground = dynamic(light: 0xFFFFFF, dark: 0x141515)
    // Keep the black cat readable without a bright white tile at night.
    static let connectionLogoBackground = dynamic(light: 0xFDFDFD, dark: 0xC8CDD2)
    // Composite over the live broker gradient, including while the form scrolls.
    static let accountCredentialBackground = dynamic(light: 0x000000, dark: 0xFFFFFF,
                                                     lightOpacity: 0.03, darkOpacity: 0.07)
    static let accountCredentialLabel = dynamic(light: 0x000000, dark: 0xFFFFFF,
                                                lightOpacity: 0.45, darkOpacity: 0.60)
    static let accountCredentialBorder = dynamic(light: 0x000000, dark: 0xFFFFFF,
                                                 lightOpacity: 0.06, darkOpacity: 0.08)
    static let accountCredentialShadow = Color.black.opacity(0.08)
    static let accountLongbridgeAccent = color(0x00B8B8)
    static let accountLongbridgeInk = color(0x003B3B)
    static let accountLongbridgeControl = dynamic(light: 0x007A7A, dark: 0x00B8B8)
    static let accountAlpacaAccent = color(0xFCD72B)
    static let accountAlpacaInk = color(0x3F3500)
    static let accountAlpacaControl = dynamic(light: 0x776000, dark: 0xFCD72B)
    static let accountTrading212Accent = color(0x00BAFC)
    static let accountTrading212Link = color(0x009BD2)
    /// First-launch template, Figma 750:2097.
    static let onboardingAccent = color(0x00BAFC)
    static let accountTrading212Ink = color(0x00364A)
    static let accountTrading212Control = dynamic(light: 0x006C94, dark: 0x00BAFC)
    static let accountIBKRControl = dynamic(light: 0xC71120, dark: 0xFF747E)
    static let accountMoomooAccent = color(0xFF6900)
    static let accountMoomooInk = color(0x4A1E00)
    static let accountMoomooControl = dynamic(light: 0xA64200, dark: 0xFFA064)
    static let accountRobinhoodInk = color(0x24290F)
    static let accountRobinhoodControl = dynamic(light: 0x536B00, dark: 0xCCFF00)
    static let accountConnectInk = color(0x003B39)
    static let accountConnectControl = dynamic(light: 0x007A77, dark: 0x00DAD6)
    static let accountImportControl = dynamic(light: 0x0052FF, dark: 0x8CAAFF)
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
    static let violet100 = color(0xE6D8FF)
    static let violet200 = color(0xCAAEFA)
    static let violet500 = color(0x804DDE)
    static let violet700 = color(0x5A2CA8)
    static let violet900 = color(0x31165C)

    /// Loss analysis keeps one purple field and ranked tonal bands in both appearances.
    static let lossChartBackground = Color(red: 0.360386, green: 0.194594, blue: 0.834078)
    static let lossChartBase = color(0xEFE2FF)
    static let lossChartLayers = [color(0x2A0D52), color(0x5724A3), color(0x8C49ED),
                                 color(0xB280F6), color(0xCCA7FB), color(0xE0CAFD)]

    static let blue50 = color(0xE4F1FF)
    static let blue100 = color(0xCCEBFF)
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
    /// Categorical segment colours from the dividend card, Figma 322:2262.
    static let dividendSeries: [Color] = [
        color(0x3475FF), color(0xA0CDFF), color(0xC8CD00), color(0xFF9500),
        color(0x13BA8E), color(0xEB74FE), color(0x00CC00)
    ]
    static let dividendSelection = dynamic(light: 0x1F46FF, dark: 0x8BA7FF)
    /// Holding-detail transaction markers from the shared chart language.
    static let tradeBuy = color(0x01B801)
    static let tradeSellLight = color(0xFF9500)
    static let tradeSellDark = yellow500
    static let securityPriceLine = color(0x3475FF)
    /// A statement's two directions, for the flow diagrams on the financials
    /// page. What a company earns, keeps or generates reads as one identity;
    /// what is subtracted from it — cost of revenue, operating expenses,
    /// liabilities, capital expenditure — reads as the other.
    ///
    /// Blue against amber. Violet was the second colour until it was judged
    /// unattractive; amber is blue's complement, so the two sides separate at
    /// a glance, and it is not the red a reader takes for a loss.
    ///
    /// The ribbons carry their own colour rather than a translucent copy of the
    /// bar. A tint chosen directly can be lighter than an opacity of the bar
    /// would ever be while keeping enough saturation to still read as the same
    /// identity.
    ///
    /// Each value has a dark counterpart. The light-mode ribbons are pale tints
    /// meant to sit on white; on a black page the same tints glared like lit
    /// bands, so dark mode draws deep tints of the same hues and lifts the
    /// bars a step so they still stand off the ribbons.
    ///
    /// Neither side is `gain` or `loss`: revenue is not a gain and a liability
    /// is not a loss, so borrowing either would tell the reader something
    /// untrue about a statement.
    static let statementInflow = dynamic(light: 0x027DFF, dark: 0x3D9BFF)
    static let statementInflowRibbon = dynamic(light: 0xCCEBFF, dark: 0x0F3257)
    static let statementOutflow = dynamic(light: 0xEF7A00, dark: 0xFFA238)
    static let statementOutflowRibbon = dynamic(light: 0xFFE4C7, dark: 0x4A2C0C)
    /// Figures printed in a flow diagram's colours: a step darker than the bar
    /// in light mode, where amber on white would be too faint to read.
    static let statementInflowText = dynamic(light: 0x0068D6, dark: 0x6CB4FF)
    static let statementOutflowText = dynamic(light: 0xB85C00, dark: 0xFFB366)
    /// Figma Today-card negative series and its ambient dark-mode light source.
    static let contributionRed = color(0xD5312C)
    static let contributionRedGlow = color(0xE2433C)

    /// Compact calendar card and date tile, Figma 610:14785.
    static let calendarMonth = dynamic(light: 0xD93835, dark: 0xFF736D)
    static let calendarTileTop = dynamic(light: 0xFFFFFF, dark: 0x303131)
    static let calendarTileBottom = dynamic(light: 0xEDEDED, dark: 0x1D1E1E)
    static let calendarSeparator = dynamic(light: 0xF2F2F2, dark: 0x282929)

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

    private static func uiColor(_ hex: UInt32) -> UIColor {
        UIColor(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }

    /// One swatch for each appearance.
    private static func dynamic(light: UInt32, dark: UInt32,
                                lightOpacity: CGFloat = 1, darkOpacity: CGFloat = 1) -> Color {
        let light = uiColor(light).withAlphaComponent(lightOpacity)
        let dark = uiColor(dark).withAlphaComponent(darkOpacity)
        return Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }
}

/// Semantic application colors. Views should depend on these roles instead of
/// palette swatches so changing one token updates every related screen.
enum CatfolioTheme {
    /// Two opaque tones from the sector chart's colour families. Reverse the
    /// tones at night so small glyphs remain distinct on their solid circles.
    static func sectorIconColors(for sector: PortfolioSector?, scheme: ColorScheme)
        -> (foreground: Color, background: Color) {
        let tones: (ink: Color, fill: Color) = switch sector {
        case .technology: (CatfolioPalette.violet900, CatfolioPalette.violet50)
        case .healthcare: (CatfolioPalette.yellow900, CatfolioPalette.yellow50)
        case .financials: (CatfolioPalette.green900, CatfolioPalette.green50)
        case .consumerCyclical: (CatfolioPalette.sky900, CatfolioPalette.blue50)
        case .consumerDefensive: (CatfolioPalette.coral900, CatfolioPalette.coral50)
        case .industrials: (CatfolioPalette.rose900, CatfolioPalette.rose50)
        case .energy: (CatfolioPalette.magenta900, CatfolioPalette.magenta50)
        case .materials: (CatfolioPalette.teal900, CatfolioPalette.teal50)
        case .realEstate: (CatfolioPalette.magenta700, CatfolioPalette.magenta50)
        case .utilities: (CatfolioPalette.blue900, CatfolioPalette.blue50)
        case .communication: (CatfolioPalette.sky900, CatfolioPalette.sky50)
        case nil: (CatfolioPalette.neutral700, CatfolioPalette.neutral200)
        }
        return scheme == .dark ? (tones.fill, tones.ink) : (tones.ink, tones.fill)
    }

    /// White glass suggestions over the assistant's shared home backdrop.
    static func assistantSuggestionFill(for scheme: ColorScheme) -> Color {
        .white.opacity(scheme == .dark ? 0.06 : 0.38)
    }

    static func assistantSuggestionBorder(for scheme: ColorScheme) -> Color {
        .white.opacity(scheme == .dark ? 0.06 : 0.50)
    }

    // Figma 241:45228: white stationery on a black backdrop. At night the
    // same note is graphite with pale ink, and a light hairline keeps its
    // edge against the black.
    static let paper = Color(uiColor: UIColor {
        $0.userInterfaceStyle == .dark ? UIColor(white: 0.13, alpha: 1) : .white
    })
    static let paperFold = Color(uiColor: UIColor {
        $0.userInterfaceStyle == .dark ? UIColor(white: 0.19, alpha: 1) : UIColor(white: 239.0 / 255.0, alpha: 1)
    })
    static let paperInk = Color(uiColor: UIColor {
        $0.userInterfaceStyle == .dark ? UIColor(white: 0.93, alpha: 1) : .black
    })
    static let paperEdge = Color(uiColor: UIColor {
        $0.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.10) : UIColor(white: 0, alpha: 0.10)
    })
    /// The shade a fold casts on the page below it.
    static let paperFoldShade = Color(uiColor: UIColor {
        $0.userInterfaceStyle == .dark ? UIColor(white: 0, alpha: 0.35) : UIColor(white: 0, alpha: 0.08)
    })
    /// Laid over the blurred page behind the note. Darker at night, so the
    /// graphite paper stands off a backdrop of nearly its own grey.
    static let paperBackdropDim = Color(uiColor: UIColor {
        $0.userInterfaceStyle == .dark ? UIColor(white: 0, alpha: 0.55) : UIColor(white: 0, alpha: 0.12)
    })
    /// The light that runs across "正在思考" while the note is written.
    static let paperShine = Color(uiColor: UIColor {
        $0.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.6) : UIColor(white: 1, alpha: 0.95)
    })
    static let accent = CatfolioPalette.blue500
    /// Apply to primary lettering at the text site; a root foreground style also recolors tinted buttons.
    static let primaryTextUIColor = UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor.label.resolvedColor(with: trait)
            : UIColor(red: 30 / 255, green: 30 / 255, blue: 32 / 255, alpha: 1)
    }
    static let primaryText = Color(uiColor: primaryTextUIColor)
    /// Neutral labels use adaptive ink; returns keep their financial colors.
    /// Alpha preserves hierarchy over the heatmap's translucent tiles.
    static let heatmapIdentifier = Color.primary.opacity(0.92)
    static let heatmapDetail = Color.primary.opacity(0.68)

    static func heatmapPerformance(for change: Double?, scheme: ColorScheme) -> Color {
        guard let change, change.isFinite, abs(change) >= 0.005 else {
            return Color.primary.opacity(0.86)
        }
        let ink = change > 0
            ? (scheme == .light ? CatfolioPalette.green700 : CatfolioPalette.green200)
            : (scheme == .light ? CatfolioPalette.rose700 : CatfolioPalette.rose300)
        return ink.opacity(0.86)
    }
    /// Black lettering on bright colored surfaces stays black in dark mode.
    static let blackTextOnColor = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark ? .black : primaryTextUIColor.resolvedColor(with: trait)
    })
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
    static let neutralIcon = Color(uiColor: .secondaryLabel)
    static let neutralFill = Color(uiColor: .secondarySystemFill)
    static let subtleFill = Color(uiColor: .quaternarySystemFill)
    static let skeletonFill = Color(uiColor: .tertiarySystemFill)
    static let skeletonEmphasis = Color(uiColor: .systemFill)

    static let disclosure = accent.opacity(0.68)

    /// A rise and a fall. One definition each, resolved per appearance here
    /// rather than at the call sites.
    ///
    /// There were nine different greens and five different reds in the app
    /// all meaning these two things, because every screen picked its own. A
    /// reader comparing two rows cannot tell a deliberate shade from an
    /// accidental one, so there is exactly one of each and the light and dark
    /// variants live together where they can be compared.
    static func gain(for scheme: ColorScheme) -> Color {
        scheme == .light
            ? Color(red: 0, green: 0.53, blue: 0.14)
            : CatfolioPalette.ChartSeries.green
    }

    static func loss(for scheme: ColorScheme) -> Color {
        scheme == .light
            ? CatfolioPalette.rose500
            : Color(red: 1.000, green: 0.271, blue: 0.404)
    }

    /// Readable performance text over Home's blue hero background.
    static func heroPerformance(for value: Double, scheme: ColorScheme) -> Color {
        if scheme == .dark {
            return value >= 0 ? gain(for: scheme) : loss(for: scheme)
        }
        return value >= 0
            ? Color(red: 13 / 255, green: 125 / 255, blue: 41 / 255)
            : loss(for: scheme).mix(with: .black, by: 0.12)
    }

    /// For contexts with no `ColorScheme` to hand — a `Canvas` closure, a
    /// value computed off the view tree. Prefer the scheme-aware pair.
    static let gainDefault = CatfolioPalette.ChartSeries.green
    static let lossDefault = CatfolioPalette.rose500
    /// Points at the settings template so a screen that has not been moved
    /// over yet still sits on the same ground as one that has.
    static let settingsBackground = SettingsTemplate.pageBackground
    /// The grey the night thin material adds over black; content panels
    /// subtract it with plus-darker so black stays black under their fill.
    static let nightMaterialLift = Color(white: 0.88)

    static func pageBackground(for colorScheme: ColorScheme) -> Color {
        Color(uiColor: .systemGroupedBackground)
    }

    static func surface(for colorScheme: ColorScheme) -> Color {
        SettingsTemplate.card
    }
}
