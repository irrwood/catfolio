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
    /// Add-account action badges, Figma 630:23915.
    static let accountConnectTop = color(0x008F8C)
    static let accountConnectBottom = color(0x00DAD6)
    static let accountImportTop = color(0x0052FF)
    static let accountImportBottom = color(0x75A1FF)
    static let accountIBKRBackground = color(0xC71120)
    static let accountRobinhoodBackground = color(0xCCFF00)
    static let accountTrading212Accent = color(0x00BAFC)
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
    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        let light = uiColor(light)
        let dark = uiColor(dark)
        return Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }
}

/// Semantic application colors. Views should depend on these roles instead of
/// palette swatches so changing one token updates every related screen.
enum CatfolioTheme {
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
            : Color(red: 0.204, green: 0.780, blue: 0.349)
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
    static let gainDefault = Color(red: 0.204, green: 0.780, blue: 0.349)
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
