import SwiftUI
import CoreText

/// Presentation only: the original signed string still feeds exports,
/// calculations and VoiceOver. Figma 617:15644 supplies the two 12 pt assets.
enum FinancialSign: String, Hashable {
    case increase, decrease

    static let sizeInEm: CGFloat = 0.75

    var assetName: String {
        self == .increase ? "FinancialIncrease" : "FinancialDecrease"
    }

    var text: Text {
        // A block provides a font-sized advance and the exact attributed
        // foreground ink. FinancialSignRenderer masks it with the original
        // Figma asset; the block itself is never visible or read by VoiceOver.
        Text(verbatim: "\u{2588}").customAttribute(FinancialSignAttribute(sign: self))
    }
}

enum FinancialTextPart: Equatable {
    case text(String)
    case sign(FinancialSign)
}

enum FinancialTextPresentation {
    // Rates use triangles by default. Monetary values opt in only when they
    // describe market movement or unrealised P&L; booked amounts keep +/−.
    private static let rateSigns = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}.%\p{Sc}])[+\-−](?=\d(?:[\d.,\x{00A0}\x{202F}]*\d)?\s*(?:[%％]|bps?\b))"#
    )
    // Explicitly directional values may include a currency prefix or render
    // their % in a separate view. Do not infer unrealised P&L from a currency.
    private static let directionalSigns = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}.%])[+\-−](?=(?:(?:[A-Z]{0,3}\p{Sc}|[A-Z]{3})\s*)?\d)"#
    )

    private static let signedValue = try! NSRegularExpression(
        pattern: #"^(?:(?:[A-Z]{0,3}\p{Sc}|[A-Z]{3})\s*)?\d[\d.,\x{00A0}\x{202F}]*(?:[KMB])?(?:\s*(?:[%％]|bps?\b))?"#
    )

    static func parts(in string: String, isDirectional: Bool = false, signFollowsValue: Bool = false) -> [FinancialTextPart] {
        let expression = isDirectional ? directionalSigns : rateSigns
        let matches = expression.matches(in: string, range: NSRange(string.startIndex..., in: string))
        guard !matches.isEmpty else { return [.text(string)] }
        var parts: [FinancialTextPart] = []
        var start = string.startIndex
        for match in matches {
            guard let range = Range(match.range, in: string) else { continue }
            if start < range.lowerBound { parts.append(.text(String(string[start..<range.lowerBound]))) }
            let sign: FinancialSign = string[range] == "+" ? .increase : .decrease
            let remainder = String(string[range.upperBound...])
            if signFollowsValue,
               let valueMatch = signedValue.firstMatch(in: remainder, range: NSRange(remainder.startIndex..., in: remainder)),
               let valueRange = Range(valueMatch.range, in: remainder) {
                parts.append(.text(String(remainder[valueRange])))
                parts.append(.sign(sign))
                start = string.index(range.upperBound, offsetBy: remainder[valueRange].count)
            } else {
                parts.append(.sign(sign))
                start = range.upperBound
            }
        }
        if start < string.endIndex { parts.append(.text(String(string[start...]))) }
        return parts
    }
}

private struct FinancialSignAttribute: TextAttribute {
    let sign: FinancialSign
}

/// Display amounts can shrink the currency prefix while keeping the triangle
/// aligned to, and sized with, the actual numerals.
struct FinancialNumberAttribute: TextAttribute {}

/// Retains native Text layout, wrapping and transitions while aligning each
/// inline sign to the visible height of the digits, independent of font size.
struct FinancialText: View {
    @Environment(\.font) private var font
    @Environment(\.fontResolutionContext) private var fontContext
    private let content: Text
    private let alignmentFont: Font?

    init(_ string: String, isDirectional: Bool = false, signFollowsValue: Bool = false) {
        content = Text(financial: string, isDirectional: isDirectional, signFollowsValue: signFollowsValue)
        alignmentFont = nil
    }

    init(alignmentFont: Font? = nil, @ViewBuilder content: () -> Text) {
        self.content = content()
        self.alignmentFont = alignmentFont
    }

    private var fontMetrics: (capHeightToAscent: CGFloat, pointSizeToAscent: CGFloat) {
        if #available(iOS 26.0, *) {
            let resolved = (alignmentFont ?? font ?? .body).resolve(in: fontContext).ctFont
            let ascent = CTFontGetAscent(resolved)
            return (CTFontGetCapHeight(resolved) / ascent, CTFontGetSize(resolved) / ascent)
        }
        // The app's SF Rounded figures share these proportions. Earlier OS
        // versions do not expose SwiftUI's resolved font; actual run ascent
        // still supplies the text size, including Dynamic Type and shrinking.
        let fallback = NumericAlternates.font(size: 17, weight: .regular, rounded: true)
        return (fallback.capHeight / fallback.ascender, fallback.pointSize / fallback.ascender)
    }

    var body: some View {
        let metrics = fontMetrics
        content.textRenderer(FinancialSignRenderer(capHeightToAscent: metrics.capHeightToAscent,
                                                   pointSizeToAscent: metrics.pointSizeToAscent))
    }
}

private struct FinancialSignRenderer: TextRenderer {
    let capHeightToAscent: CGFloat
    let pointSizeToAscent: CGFloat

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        for line in layout {
            let runs = Array(line)
            for (index, run) in runs.enumerated() {
                guard let attribute = run[FinancialSignAttribute.self] else {
                    context.draw(run)
                    continue
                }
                let following = runs.dropFirst(index + 1).prefix { $0[FinancialSignAttribute.self] == nil }
                let reference = following.first { $0[FinancialNumberAttribute.self] != nil }
                    ?? following.first
                    ?? runs.prefix(index).last { $0[FinancialSignAttribute.self] == nil }
                let bounds = (reference ?? run).typographicBounds
                let digitCenter = bounds.origin.y - bounds.ascent * capHeightToAscent / 2
                let imageBounds = run.typographicBounds.rect
                let edge = bounds.ascent * pointSizeToAscent * FinancialSign.sizeInEm
                var aligned = context
                // Only the asset's alpha is used. Drawing the attributed run
                // through this mask keeps semantic colours and opacity intact.
                aligned.clipToLayer { mask in
                    mask.draw(Image(attribute.sign.assetName).renderingMode(.original),
                        in: CGRect(x: imageBounds.midX - edge / 2, y: digitCenter - edge / 2,
                                   width: edge, height: edge))
                }
                aligned.draw(run)
            }
        }
    }
}

extension LabeledContent where Label == Text, Content == FinancialText {
    init(_ title: String, financialValue value: String) {
        self.init { FinancialText(value) } label: { Text(title) }
    }
}

extension Text {
    /// Use inside FinancialText for rich text concatenation. The renderer
    /// aligns tagged assets after SwiftUI resolves the caller's typography.
    init(financial string: String, isDirectional: Bool = false, signFollowsValue: Bool = false) {
        let parts = FinancialTextPresentation.parts(in: string, isDirectional: isDirectional, signFollowsValue: signFollowsValue)
        self = parts.reduce(Text(verbatim: "")) { result, part in
            switch part {
            case .text(let text): result + Text(verbatim: text)
            case .sign(let sign): result + sign.text
            }
        }.accessibilityLabel(Text(verbatim: string))
    }
}
