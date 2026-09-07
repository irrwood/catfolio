import SwiftUI
import UIKit

/// Legacy call-site shape, now served by the shared scale.
///
/// The screens were built against a four-weight Montserrat helper that each
/// of three files declared for itself. Rather than touch several hundred call
/// sites at once, the helper stays and its body moved: sizes still arrive as
/// points, but the face is now SF Pro and the nearest scale token supplies
/// the Dynamic Type ramp. New code should call `appText` / `appNumber`.
enum LegacyType {
    static func regular(_ size: CGFloat, relativeTo style: Font.TextStyle = .body) -> Font {
        .system(size: scaled(size, style), weight: .regular)
    }

    static func medium(_ size: CGFloat, relativeTo style: Font.TextStyle = .body) -> Font {
        .system(size: scaled(size, style), weight: .medium)
    }

    static func semibold(_ size: CGFloat, relativeTo style: Font.TextStyle = .body) -> Font {
        .system(size: scaled(size, style), weight: .semibold)
    }

    static func italic(_ size: CGFloat, relativeTo style: Font.TextStyle = .body) -> Font {
        .system(size: scaled(size, style), weight: .regular).italic()
    }

    private static func scaled(_ size: CGFloat, _ style: Font.TextStyle) -> CGFloat {
        let metrics: UIFont.TextStyle
        switch style {
        case .largeTitle: metrics = .largeTitle
        case .title: metrics = .title1
        case .title2: metrics = .title2
        case .title3: metrics = .title3
        case .headline: metrics = .headline
        case .subheadline: metrics = .subheadline
        case .callout: metrics = .callout
        case .footnote: metrics = .footnote
        case .caption: metrics = .caption1
        case .caption2: metrics = .caption2
        default: metrics = .body
        }
        return UIFontMetrics(forTextStyle: metrics).scaledValue(for: size)
    }
}
