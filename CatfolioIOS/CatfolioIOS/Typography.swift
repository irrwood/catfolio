import SwiftUI
import UIKit

/// The app's one type scale.
///
/// Every size in the app comes from here rather than from a literal at the
/// call site, so a change to the scale is a change in one file. The sizes
/// below are the ones the screens already used, deduplicated: sizes that sat
/// one point apart were doing the same job and now share a token.
///
/// Text is SF Pro and numbers are SF Rounded. That split is deliberate — the
/// rounded face reads as the "value" voice throughout the app, and it is the
/// face Apple ships with the tallest, most even numerals, so a column of
/// figures aligns optically as well as metrically.
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
        .system(size: scaled(scale), weight: weight ?? scale.weight)
    }

    /// SF Rounded with fixed-width digits, so a changing value never changes
    /// the width of its own frame.
    static func number(_ scale: TypeScale, weight: Font.Weight? = nil) -> Font {
        .system(size: scaled(scale), weight: weight ?? scale.weight, design: .rounded)
            .monospacedDigit()
    }

    private static func scaled(_ scale: TypeScale) -> CGFloat {
        UIFontMetrics(forTextStyle: scale.uiTextStyle).scaledValue(for: scale.size)
    }
}

private struct ScaledFont: ViewModifier {
    let weight: Font.Weight
    let design: Font.Design
    let width: Font.Width
    let monospacedDigit: Bool
    let lineSpacing: CGFloat
    let tracking: CGFloat
    @ScaledMetric private var size: CGFloat

    init(
        scale: TypeScale,
        weight: Font.Weight?,
        design: Font.Design,
        width: Font.Width,
        monospacedDigit: Bool,
        tracking: CGFloat
    ) {
        self.weight = weight ?? scale.weight
        self.design = design
        self.width = width
        self.monospacedDigit = monospacedDigit
        self.lineSpacing = scale.lineSpacing
        self.tracking = tracking
        _size = ScaledMetric(wrappedValue: scale.size, relativeTo: scale.textStyle)
    }

    func body(content: Content) -> some View {
        var font = Font.system(size: size, weight: weight, design: design).width(width)
        if monospacedDigit { font = font.monospacedDigit() }
        return content
            .font(font)
            .tracking(tracking)
            .lineSpacing(lineSpacing)
    }
}

extension View {
    /// Body copy, labels, names — SF Pro at a token size.
    ///
    /// `width` is for a run of options that has to fit a fixed rail — a
    /// segmented range picker, say. It narrows the letterforms rather than
    /// shrinking them, so the labels stay the same height as everything
    /// around them instead of quietly becoming a size smaller. The width axis
    /// belongs to SF Pro, which is why this is on `appText` and not on
    /// `appNumber`: SF Rounded ships one width and asking it to compress does
    /// nothing.
    func appText(
        _ scale: TypeScale,
        weight: Font.Weight? = nil,
        width: Font.Width = .standard
    ) -> some View {
        modifier(ScaledFont(
            scale: scale, weight: weight, design: .default, width: width,
            monospacedDigit: false, tracking: 0
        ))
    }

    /// Any figure the reader might compare against another figure — money,
    /// percentages, share counts, dates, axis ticks.
    ///
    /// SF Rounded with fixed-width digits. The fixed width is what stops a
    /// live value from shifting its neighbours as it ticks; pair it with
    /// `numericTransition` where the value animates.
    func appNumber(_ scale: TypeScale, weight: Font.Weight? = nil) -> some View {
        modifier(ScaledFont(
            scale: scale, weight: weight, design: .rounded, width: .standard,
            monospacedDigit: true, tracking: 0
        ))
    }

    /// Text set in capitals, with the letterspacing capitals need.
    func appCaps(_ scale: TypeScale, weight: Font.Weight? = nil) -> some View {
        modifier(ScaledFont(
            scale: scale, weight: weight ?? .medium, design: .default, width: .standard,
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
