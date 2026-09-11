import SwiftUI
import UIKit
import CoreText

/// The app's one type scale.
///
/// Every size in the app comes from here rather than from a literal at the
/// call site, so a change to the scale is a change in one file. The sizes
/// below are the ones the screens already used, deduplicated: sizes that sat
/// one point apart were doing the same job and now share a token.
///
/// Everything is SF Rounded. Figures additionally get fixed-width digits via
/// `appNumber`, which is what keeps a changing value from resizing its own
/// frame; the face itself no longer distinguishes text from values.
///
/// One consequence is deliberate: SF Rounded ships a single width, so there
/// is no compressed cut to fall back on when a row of labels is tight. Tokens
/// and layout have to make the room instead.
enum TypeScale: CaseIterable, Sendable {
    /// The oversized money headline on Home and on the returns card.
    case display
    /// The currency symbol or sign that sits beside `display`, baseline-aligned.
    case displayUnit
    case title
    case heading
    case subheading
    case body
    case callout
    case footnote
    /// Row labels and eyebrows. Usually set in caps via `appCaps`.
    case label
    case caption
    case micro
    /// Axis ticks and in-chart annotations, where space is genuinely scarce.
    case nano

    var size: CGFloat {
        switch self {
        case .display: 32
        case .displayUnit: 21
        case .title: 24
        case .heading: 19
        case .subheading: 17
        case .body: 16
        case .callout: 15
        case .footnote: 14
        case .label: 13
        case .caption: 12
        case .micro: 11
        case .nano: 10
        }
    }

    /// Which Dynamic Type ramp this token scales along. A token that scaled
    /// along `.body` everywhere would make the money headline grow faster
    /// than the layout can absorb.
    var textStyle: Font.TextStyle {
        switch self {
        case .display, .displayUnit: .largeTitle
        case .title: .title
        case .heading: .headline
        case .subheading, .body: .body
        case .callout: .callout
        case .footnote: .footnote
        case .label, .caption: .caption
        case .micro, .nano: .caption2
        }
    }

    var weight: Font.Weight {
        switch self {
        case .display, .displayUnit, .heading: .medium
        case .title: .semibold
        case .subheading, .body, .callout, .footnote, .caption: .regular
        case .label, .micro, .nano: .medium
        }
    }

    /// The weight a figure is set at, which is one step above the weight the
    /// same token gives prose.
    ///
    /// SF Rounded reads lighter than SF Pro at the same nominal weight — the
    /// rounded terminals take ink out of every stroke ending — and a figure
    /// has no word shape to help it hold together, so at small sizes a
    /// regular-weight number goes thin and washes out against the label
    /// beside it. Prose does not have that problem and is left alone.
    var numberWeight: Font.Weight {
        switch weight {
        case .ultraLight: .thin
        case .thin: .light
        case .light: .regular
        case .regular: .medium
        case .medium: .semibold
        default: weight
        }
    }

    /// Extra leading, on top of the face's own. Zero for anything that is a
    /// single line by construction: adding leading there only pads the frame.
    var lineSpacing: CGFloat {
        switch self {
        case .body, .callout: 3
        case .footnote, .caption: 2
        default: 0
        }
    }

    /// Letterspacing for text set in capitals.
    ///
    /// Capitals need it and lowercase does not — SF already carries Apple's
    /// optical tracking per size, so the only place a manual value is right
    /// is where that built-in tracking was designed for mixed case and the
    /// text is not. Roughly 6% of the size, which holds across the ramp.
    var capsTracking: CGFloat { (size * 0.06 * 100).rounded() / 100 }

    fileprivate var uiTextStyle: UIFont.TextStyle {
        switch textStyle {
        case .largeTitle: .largeTitle
        case .title: .title1
        case .title2: .title2
        case .title3: .title3
        case .headline: .headline
        case .subheadline: .subheadline
        case .body: .body
        case .callout: .callout
        case .footnote: .footnote
        case .caption: .caption1
        case .caption2: .caption2
        @unknown default: .body
        }
    }
}

/// Fonts built from the scale, for the places that need a `Font` rather than
/// a view modifier — chart axis labels, `Text` concatenation, `UIKit` bridges.
///
/// Prefer the `appText` / `appNumber` / `appCaps` modifiers in views: those
/// scale through `@ScaledMetric`, which SwiftUI re-evaluates on its own when
/// the reader changes their text size.
enum Typography {
    static func text(_ scale: TypeScale, weight: Font.Weight? = nil) -> Font {
        text(size: scaled(scale), weight: weight ?? scale.weight)
    }

    /// SF Rounded with fixed-width digits, so a changing value never changes
    /// the width of its own frame.
    static func number(_ scale: TypeScale, weight: Font.Weight? = nil) -> Font {
        text(size: scaled(scale), weight: weight ?? scale.numberWeight)
            .monospacedDigit()
    }

    /// A figure at a size the scale does not name — the oversized headline,
    /// a label sized to a Figma frame.
    ///
    /// Still goes through the alternates and fixed-width digits, because a
    /// number set outside the scale is still a number: the display amount was
    /// built straight from `Font.system` and so was the only figure in the
    /// app without the straight-sided six and nine.
    static func number(size: CGFloat, weight: Font.Weight = .medium) -> Font {
        Font(NumericAlternates.font(
            size: size,
            weight: NumericAlternates.uiWeight(weight),
            rounded: true
        )).monospacedDigit()
    }

    /// Prose at a size the scale does not name.
    static func text(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        Font(CurrencySymbolAlternates.font(size: size, weight: NumericAlternates.uiWeight(weight), rounded: true))
    }

    /// Native semantic sizes used by form rows and financial tables. Only
    /// currency glyphs change; the existing size, weight and digits stay intact.
    static func currency(
        _ style: UIFont.TextStyle,
        weight: UIFont.Weight? = nil,
        contentSizeCategory: UIContentSizeCategory? = nil
    ) -> Font {
        let traits = contentSizeCategory.map { UITraitCollection(preferredContentSizeCategory: $0) }
        let base = UIFont.preferredFont(forTextStyle: style, compatibleWith: traits)
        var descriptor = base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor
        if let weight {
            descriptor = descriptor.addingAttributes([.traits: [UIFontDescriptor.TraitKey.weight: weight.rawValue]])
        }
        return Font(CurrencySymbolAlternates.applying(to: UIFont(descriptor: descriptor, size: base.pointSize)))
    }

    private static func scaled(_ scale: TypeScale) -> CGFloat {
        UIFontMetrics(forTextStyle: scale.uiTextStyle).scaledValue(for: scale.size)
    }
}

private struct CurrencySemanticFont: ViewModifier {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let style: UIFont.TextStyle
    let weight: UIFont.Weight?

    private var contentSizeCategory: UIContentSizeCategory {
        switch dynamicTypeSize {
        case .xSmall: .extraSmall
        case .small: .small
        case .medium: .medium
        case .large: .large
        case .xLarge: .extraLarge
        case .xxLarge: .extraExtraLarge
        case .xxxLarge: .extraExtraExtraLarge
        case .accessibility1: .accessibilityMedium
        case .accessibility2: .accessibilityLarge
        case .accessibility3: .accessibilityExtraLarge
        case .accessibility4: .accessibilityExtraExtraLarge
        case .accessibility5: .accessibilityExtraExtraExtraLarge
        @unknown default: .large
        }
    }

    func body(content: Content) -> some View {
        content.font(Typography.currency(style, weight: weight, contentSizeCategory: contentSizeCategory))
    }
}

/// SF's OpenType Character Variant 9: the alternate dollar/cent glyphs.
/// Keep the real Unicode currency characters for formatting, copying and
/// VoiceOver. This is a font feature, not an SF Symbol or a replacement image.
enum CurrencySymbolAlternates {
    static let openTypeTag = "cv09"
    private static let cache = NSCache<UIFont, UIFont>()

    static func font(size: CGFloat, weight: UIFont.Weight, rounded: Bool) -> UIFont {
        var descriptor = UIFont.systemFont(ofSize: size, weight: weight).fontDescriptor
        if rounded, let round = descriptor.withDesign(.rounded) { descriptor = round }
        return applying(to: UIFont(descriptor: descriptor, size: size))
    }

    static func applying(to font: UIFont) -> UIFont {
        if let cached = cache.object(forKey: font) { return cached }
        // Append rather than replace: numeric fonts already carry the open
        // four and straight-sided six/nine, and may have tabular figures too.
        let existing = font.fontDescriptor.object(forKey: .featureSettings) as? [[String: Any]] ?? []
        let descriptor = font.fontDescriptor.addingAttributes([
            .featureSettings: existing + [[
                kCTFontOpenTypeFeatureTag as String: openTypeTag,
                kCTFontOpenTypeFeatureValue as String: 1,
            ]],
        ])
        let alternate = UIFont(descriptor: descriptor, size: font.pointSize)
        cache.setObject(alternate, forKey: font)
        return alternate
    }
}

/// SF's alternate digit forms.
///
/// The default six and nine curl their terminals back toward the bowl and the
/// four is closed, which at small sizes and in a dense column makes 6/8, 9/8
/// and 4/9 harder to tell apart than they need to be. SF ships straight-sided
/// and open alternates for exactly this, and a portfolio is a screen full of
/// digits people are comparing.
///
/// Applied through a font descriptor because SwiftUI has no API for stylistic
/// sets on the system font. `Font(_: UIFont)` keeps the size that
/// `@ScaledMetric` already resolved, so Dynamic Type still works.
enum NumericAlternates {
    /// Stylistic set numbers, not raw selectors. Selector is `2n` for set n,
    /// per the `kStylisticAlternativesType` convention.
    ///
    /// Verified by rendering, not assumed: the mapping of set number to glyph
    /// is a property of the shipped font, and Apple has changed which set
    /// carries which alternate between releases.
    static let straightSidedSixAndNine = 1
    static let openFour = 2

    private static let cache = NSCache<NSString, UIFont>()

    static func font(size: CGFloat, weight: UIFont.Weight, rounded: Bool) -> UIFont {
        let key = "\(size)-\(weight.rawValue)-\(rounded)" as NSString
        if let cached = cache.object(forKey: key) { return cached }

        var descriptor = UIFont.systemFont(ofSize: size, weight: weight).fontDescriptor
        if rounded, let round = descriptor.withDesign(.rounded) { descriptor = round }
        descriptor = descriptor.addingAttributes([
            .featureSettings: [straightSidedSixAndNine, openFour].map { set in
                [
                    UIFontDescriptor.FeatureKey.type: kStylisticAlternativesType,
                    UIFontDescriptor.FeatureKey.selector: set * 2,
                ]
            },
        ])
        let font = CurrencySymbolAlternates.applying(to: UIFont(descriptor: descriptor, size: size))
        cache.setObject(font, forKey: key)
        return font
    }

    static func uiWeight(_ weight: Font.Weight) -> UIFont.Weight {
        switch weight {
        case .ultraLight: .ultraLight
        case .thin: .thin
        case .light: .light
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        case .heavy: .heavy
        case .black: .black
        default: .regular
        }
    }
}

private struct ScaledFont: ViewModifier {
    let weight: Font.Weight
    let design: Font.Design
    let monospacedDigit: Bool
    /// Only figures get the alternates; prose has no 6/8 confusion to solve
    /// and the straight-sided forms read as a different typeface in running
    /// text.
    let usesAlternateDigits: Bool
    let lineSpacing: CGFloat
    let tracking: CGFloat
    @ScaledMetric private var size: CGFloat

    init(
        scale: TypeScale,
        weight: Font.Weight?,
        design: Font.Design,
        monospacedDigit: Bool,
        usesAlternateDigits: Bool = false,
        tracking: CGFloat
    ) {
        self.weight = weight ?? scale.weight
        self.design = design
        self.monospacedDigit = monospacedDigit
        self.usesAlternateDigits = usesAlternateDigits
        self.lineSpacing = scale.lineSpacing
        self.tracking = tracking
        _size = ScaledMetric(wrappedValue: scale.size, relativeTo: scale.textStyle)
    }

    func body(content: Content) -> some View {
        var font: Font
        if usesAlternateDigits {
            font = Font(NumericAlternates.font(
                size: size,
                weight: NumericAlternates.uiWeight(weight),
                rounded: design == .rounded
            ))
        } else {
            font = Font(CurrencySymbolAlternates.font(
                size: size, weight: NumericAlternates.uiWeight(weight), rounded: design == .rounded
            ))
        }
        if monospacedDigit { font = font.monospacedDigit() }
        return content
            .font(font)
            .tracking(tracking)
            .lineSpacing(lineSpacing)
    }
}

extension View {
    /// Currency variants at the existing native semantic size, including
    /// live Dynamic Type changes. No numeric alternates or weight bump.
    func currencyFont(_ style: UIFont.TextStyle, weight: UIFont.Weight? = nil) -> some View {
        modifier(CurrencySemanticFont(style: style, weight: weight))
    }

    /// Body copy, labels, names.
    ///
    /// There is no `width` parameter. SF Rounded has a single width, so a
    /// request to compress would be accepted and silently ignored — which is
    /// exactly how the two range pickers came to look different from each
    /// other while their code read the same.
    func appText(_ scale: TypeScale, weight: Font.Weight? = nil) -> some View {
        modifier(ScaledFont(
            scale: scale, weight: weight, design: .rounded,
            monospacedDigit: false, tracking: 0
        ))
    }

    /// Any figure the reader might compare against another figure — money,
    /// percentages, share counts, dates, axis ticks.
    ///
    /// Digits are fixed-width by default, which is what stops a live value
    /// from resizing its own frame as it ticks and shoving its neighbours
    /// around; pair it with `numericTransition` where the value animates.
    ///
    /// That width is not free. A fixed-width `1` is padded out to the width
    /// of an `8`, so a figure with several 1s in it — `11.834`, `$1,141.70` —
    /// carries visible gaps its neighbours do not. Pass `monospaced: false`
    /// for a figure that never changes and sits in no column: a share count,
    /// a settled date. It keeps the face and the weight, and loses only the
    /// padding it had no use for.
    func appNumber(
        _ scale: TypeScale,
        weight: Font.Weight? = nil,
        monospaced: Bool = true
    ) -> some View {
        modifier(ScaledFont(
            scale: scale, weight: weight ?? scale.numberWeight, design: .rounded,
            monospacedDigit: monospaced, usesAlternateDigits: true, tracking: 0
        ))
    }

    /// Text set in capitals, with the letterspacing capitals need.
    func appCaps(_ scale: TypeScale, weight: Font.Weight? = nil) -> some View {
        modifier(ScaledFont(
            scale: scale, weight: weight ?? .medium, design: .rounded,
            monospacedDigit: false, tracking: scale.capsTracking
        ))
    }

    /// Rolls each digit to its new value instead of swapping the whole string.
    ///
    /// Only the digits that actually changed move, and because the font is
    /// already fixed-width the frame does not resize mid-flight — which is
    /// what made live prices jitter and drag their neighbours around.
    func numericTransition(_ value: Double) -> some View {
        contentTransition(.numericText(value: value))
            .animation(.snappy(duration: 0.28), value: value)
    }
}
