import SwiftUI
import UIKit
import XCTest
@testable import CatfolioIOS

@MainActor
final class FinancialSignTextTests: XCTestCase {
    func testTrailingSignsStayWithEachAmountAndRate() {
        XCTAssertEqual(FinancialTextPresentation.parts(in: "-$1.30", isDirectional: true, signFollowsValue: true),
                       [.text("$1.30"), .sign(.decrease)])
        XCTAssertEqual(FinancialTextPresentation.parts(in: "-0.0% · SPY +0.6%", signFollowsValue: true),
                       [.text("0.0%"), .sign(.decrease), .text(" · SPY "), .text("0.6%"), .sign(.increase)])
        XCTAssertEqual(FinancialTextPresentation.parts(in: "+£1,234.56 · -12 bp", isDirectional: true, signFollowsValue: true),
                       [.text("£1,234.56"), .sign(.increase), .text(" · "), .text("12 bp"), .sign(.decrease)])
        XCTAssertEqual(FinancialTextPresentation.parts(in: "—", signFollowsValue: true), [.text("—")])
    }

    func testTrailingTriangleHasCompactVisibleGap() throws {
        for size: CGFloat in [20, 26] {
            let image = try render(CatfolioDisplayAmountText(text: "-$88.88", size: size,
                symbolSize: size, isDirectional: true, signFollowsValue: true))
            let columns = Set(try pixelInk(image).map(\.x)).sorted()
            let gap = try XCTUnwrap(Array(zip(columns, columns.dropFirst())).last {
                $1 - $0 > 1 / image.scale + 0.01
            })
            XCTAssertGreaterThan(gap.1 - gap.0, 1 / image.scale)
            XCTAssertLessThanOrEqual(gap.1 - gap.0, size * 0.4,
                                     "The trailing triangle should stay close to the final digit")
        }
    }

    func testTrailingHeadlineSignRendersAtRightOfNumber() throws {
        let image = try render(CatfolioDisplayAmountText(text: "-$88.88", size: 26, symbolSize: 16,
            isDirectional: true, signFollowsValue: true))
        XCTAssertGreaterThan(image.size.width, 70)
        let attachment = XCTAttachment(image: image)
        attachment.name = "trailing-headline-sign"
        attachment.lifetime = .keepAlways
        add(attachment)
        try image.pngData()?.write(to: URL(fileURLWithPath: "/tmp/trailing-headline-sign.png"))
    }

    func testDefaultSignsReplaceRatesAndLeaveBookedMoneyAndArithmeticLiteral() {
        let examples: [(String, [FinancialTextPart])] = [
            ("SPY +1.2% · -3.4%", [.text("SPY "), .sign(.increase), .text("1.2% · "), .sign(.decrease), .text("3.4%")]),
            ("≈-0.4%", [.text("≈"), .sign(.decrease), .text("0.4%")]),
            ("+0.0%", [.sign(.increase), .text("0.0%")]),
            ("-25 bp", [.sign(.decrease), .text("25 bp")]),
            ("+12.5 bps", [.sign(.increase), .text("12.5 bps")]),
            ("+1,2 %", [.sign(.increase), .text("1,2 %")]),
            ("+1.2％", [.sign(.increase), .text("1.2％")]),
            ("+$42.50 (+3.2%)", [.text("+$42.50 ("), .sign(.increase), .text("3.2%)")]),
            ("-$42.50 · -3.2%", [.text("-$42.50 · "), .sign(.decrease), .text("3.2%")]),
            ("+1.2% (+£15.00)", [.sign(.increase), .text("1.2% (+£15.00)")]),
        ]
        for (string, expected) in examples {
            XCTAssertEqual(FinancialTextPresentation.parts(in: string), expected, string)
        }
        for string in ["2026-10-09", "BRK-B", "10–20%", "1%-2%", "1 - 2", "+", "−", "—", "12.3%", "$0.00", "1e-3",
                       "+$1,234.56", "−£98.70", "+US$200", "-CHF\u{00A0}200", "¥-1,500", "≈-£", "+$", "-88.88",
                       "+$1.2M", "−2,704 EUR", "+2704", "+€2,704 + -£1,500 + +$420", "$100-$20=$80"] {
            XCTAssertEqual(FinancialTextPresentation.parts(in: string), [.text(string)], string)
        }
        XCTAssertEqual(FinancialTextPresentation.parts(in: "+16.4", isDirectional: true),
                       [.sign(.increase), .text("16.4")])
    }

    func testUnrealisedAmountsExplicitlyUseTrianglesAcrossCurrencies() {
        for currency in ["USD", "GBP", "EUR", "CNY", "JPY", "HKD", "AUD", "CAD", "CHF", "SEK"] {
            for value in [1234.56, -1234.56, 0] {
                let money = DisplayFormat.money(value, currency: currency, signed: true, fractionDigits: 2)
                XCTAssertEqual(FinancialTextPresentation.parts(in: money, isDirectional: true),
                               [.sign(value >= 0 ? .increase : .decrease), .text(String(money.dropFirst()))], currency)
                XCTAssertEqual(FinancialTextPresentation.parts(in: money), [.text(money)],
                               "The same amount in a realised P&L or cash-flow row must retain +/−")
            }
        }
        XCTAssertEqual(FinancialTextPresentation.parts(in: "−£98.70", isDirectional: true),
                       [.sign(.decrease), .text("£98.70")])
        for unavailable in ["—", "暂无数据"] {
            XCTAssertEqual(FinancialTextPresentation.parts(in: unavailable, isDirectional: true), [.text(unavailable)])
        }
    }

    func testUnrealisedHeadlineTrianglesFollowNumeralsWithSmallerCurrencyPrefixes() throws {
        for string in ["+$88.88", "-£88.88"] {
            for size: CGFloat in [16, 26, 40] {
                let smallCurrency = try render(CatfolioDisplayAmountText(text: string,
                    size: size, symbolSize: size * 0.645, isDirectional: true))
                let fullCurrency = try render(CatfolioDisplayAmountText(text: string,
                    size: size, symbolSize: size, isDirectional: true))
                try assertCentered(smallCurrency, digitsStart: smallCurrency.size.width / 2,
                                   label: "Unrealised \(string) at \(size)")
                let smallArrow = try inkBounds(splitInk(pixelInk(smallCurrency), scale: smallCurrency.scale).arrow)
                let fullArrow = try inkBounds(splitInk(pixelInk(fullCurrency), scale: fullCurrency.scale).arrow)
                XCTAssertEqual(smallArrow.width, fullArrow.width, accuracy: 0.5)
                XCTAssertEqual(smallArrow.height, fullArrow.height, accuracy: 0.5,
                               "Shrinking the currency must not shrink the triangle")
            }
        }
    }

    func testOriginalVectorAssetsHaveTheDesignSizeAndVisibleInk() throws {
        for sign in [FinancialSign.increase, .decrease] {
            let image = try XCTUnwrap(UIImage(named: sign.assetName))
            XCTAssertEqual(image.size.width, 12, accuracy: 0.01)
            XCTAssertEqual(image.size.height, 12, accuracy: 0.01)
            let rendered = try render(FinancialText { sign.text }.foregroundStyle(.green).padding(8))
            XCTAssertGreaterThan(try coloredPixelCount(rendered), 5)
        }
    }

    func testInlineSignsMatchWidthsAndSurviveCapHeightTrimming() throws {
        for size in [DynamicTypeSize.large, .accessibility2] {
            for scale in [TypeScale.nano, .body, .heading] {
                let plus = try render(FinancialText("+16.4%").appNumber(scale).foregroundStyle(.green), size: size)
                let minus = try render(FinancialText("-16.4%").appNumber(scale).foregroundStyle(.green), size: size)
                XCTAssertEqual(plus.size.width, minus.size.width, accuracy: 0.5,
                               "A sign change must not shift the digits")
                let trimmed = try render(FinancialText("-16.4%")
                    .appNumber(scale, trimsLeading: true).foregroundStyle(.green), size: size)
                XCTAssertEqual(try coloredPixelCount(trimmed), try coloredPixelCount(minus), accuracy: 5,
                               "The complete icon must survive the bare-height text layout")
            }
        }
    }

    func testSignsCenterOnDigitInkAcrossFontSizesAndDynamicType() throws {
        for sign in ["+", "-"] {
            for size in [DynamicTypeSize.large, .accessibility2] {
                for scale in [TypeScale.nano, .caption, .body, .heading, .display] {
                    for trimmed in [false, true] {
                        let image = try render(FinancialText(sign + "88.88", isDirectional: true)
                            .appNumber(scale, trimsLeading: trimmed), size: size)
                        try assertCentered(image, label: "\(sign) \(scale) \(size) trimmed=\(trimmed)")
                    }
                }
                let native = try render(FinancialText(sign + "88.88", isDirectional: true).font(.title), size: size)
                try assertCentered(native, label: "native title \(size)")
            }
        }
    }

    func testSignsInheritTheSameForegroundAsDigits() throws {
        for scheme in [ColorScheme.light, .dark] {
            for color in [Color.primary, .secondary, .green, .red, .gray] {
                for sign in ["+", "-"] {
                    let image = try render(FinancialText(sign + "88.88", isDirectional: true)
                        .appNumber(.heading).foregroundStyle(color), scheme: scheme)
                    let ink = try pixelInk(image, scheme: scheme)
                    let parts = try splitInk(ink, scale: image.scale)
                    let arrow = try XCTUnwrap(parts.arrow.max { $0.contrast < $1.contrast })
                    let digits = try XCTUnwrap(parts.digits.max { $0.contrast < $1.contrast })
                    for channel in 0..<3 {
                        XCTAssertEqual(arrow.rgb[channel], digits.rgb[channel], accuracy: 3,
                                       "\(sign) must inherit \(color) in \(scheme)")
                    }
                }
            }
        }
    }

    func testSignSizeAndAdvanceScaleWithTheFont() throws {
        for sign in ["+", "-"] {
            var previous: (font: CGFloat, ink: CGRect, advance: CGFloat)?
            for size: CGFloat in [10, 16, 24, 32, 48] {
                let signed = try render(FinancialText(sign + "88.88", isDirectional: true).font(Typography.number(size: size)))
                let unsigned = try render(FinancialText("88.88").font(Typography.number(size: size)))
                let advance = signed.size.width - unsigned.size.width
                XCTAssertGreaterThan(advance, size * 0.5)
                XCTAssertLessThan(advance, size,
                    "The sign must reserve a compact font-relative advance")
                let parts = try splitInk(pixelInk(signed), scale: signed.scale)
                let arrow = try inkBounds(parts.arrow)
                if let previous {
                    XCTAssertEqual(arrow.width / previous.ink.width, size / previous.font, accuracy: 0.2)
                    XCTAssertEqual(arrow.height / previous.ink.height, size / previous.font, accuracy: 0.2)
                    XCTAssertEqual(advance / previous.advance, size / previous.font, accuracy: 0.15)
                }
                previous = (size, arrow, advance)
            }
        }
    }

    func testSignScalesWithDynamicType() throws {
        var ratios: [CGFloat] = []
        for size in [DynamicTypeSize.large, .accessibility2] {
            let image = try render(FinancialText("+88.88", isDirectional: true).appNumber(.body), size: size)
            let parts = try splitInk(pixelInk(image), scale: image.scale)
            ratios.append(try inkBounds(parts.arrow).height / inkBounds(parts.digits).height)
        }
        XCTAssertEqual(ratios[0], ratios[1], accuracy: 0.05)
    }

    func testMoneyRendersNativePlusAndMinusInRowsAndDisplayHeadlines() throws {
        for string in ["+$88.88", "-$88.88", "−£98.70"] {
            for size: CGFloat in [16, 26, 32] {
                let native = try render(Text(verbatim: string).font(Typography.number(size: size)).monospacedDigit())
                let row = try render(FinancialText(string).font(Typography.number(size: size)).monospacedDigit())
                let headline = try render(CatfolioDisplayAmountText(text: string, size: size, symbolSize: size))
                XCTAssertEqual(row.pngData(), native.pngData(), "Money in a row must keep its native sign: \(string)")
                XCTAssertEqual(headline.pngData(), native.pngData(), "Money in a headline must keep its native sign: \(string)")
            }
        }
    }

    func testSignsStayCenteredWhenTextShrinksToFit() throws {
        for sign in [FinancialSign.increase, .decrease] {
            let image = try render(FinancialText {
                sign.text.foregroundStyle(.red) + Text("88.88")
            }
            .font(Typography.number(size: 40))
            .lineLimit(1).minimumScaleFactor(0.5).frame(width: 100, alignment: .leading))
            let ink = try pixelInk(image)
            let arrow = ink.filter { $0.rgb[0] - $0.rgb[1] > 70 }.map(\.y)
            let digits = ink.filter { abs($0.rgb[0] - $0.rgb[1]) < 5 }.map(\.y)
            let arrowCenter = (try XCTUnwrap(arrow.min()) + XCTUnwrap(arrow.max())) / 2
            let digitCenter = (try XCTUnwrap(digits.min()) + XCTUnwrap(digits.max())) / 2
            XCTAssertEqual(arrowCenter, digitCenter, accuracy: 0.75)
            let arrowRight = try XCTUnwrap(ink.filter { $0.rgb[0] - $0.rgb[1] > 70 }.map(\.x).max())
            let digitLeft = try XCTUnwrap(ink.filter { abs($0.rgb[0] - $0.rgb[1]) < 5 }.map(\.x).min())
            XCTAssertGreaterThan(digitLeft, arrowRight, "Scaling down must retain a visible sign-to-digit gap")
        }
    }

    func testSignedValuesRenderAtSmallAndDisplaySizesInBothSchemes() throws {
        for scheme in [ColorScheme.light, .dark] {
            for size in [DynamicTypeSize.large, .accessibility2] {
                let image = try render(VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 6) {
                        FinancialText { FinancialSign.increase.text }
                        FinancialText { FinancialSign.decrease.text }
                    }
                    CatfolioDisplayAmountText(text: "+£1,234.56")
                    CatfolioDisplayAmountText(text: "-$98.70")
                    CatfolioDisplayAmountText(text: "+£1,234.56", isDirectional: true)
                    CatfolioDisplayAmountText(text: "-$98.70", isDirectional: true)
                    FinancialText("+$42.50 · +3.2%", isDirectional: true).appNumber(.body)
                    FinancialText("+16.4%").appNumber(.body, weight: .medium, trimsLeading: true)
                    FinancialText("≈-2.3%").appNumber(.subheading)
                    FinancialText("SPY +1.2%").appNumber(.footnote)
                    FinancialText("+3.2% · -6.1% · +0.0%").appNumber(.caption)
                    FinancialText("+$42.50 · +3.2%").appNumber(.body)
                    FinancialText("+€2,704 - £1,500 + $420").appNumber(.caption)
                    FinancialText("-10%").appNumber(.nano)
                    FinancialText("—").appNumber(.body)
                }.padding(20), size: size, scheme: scheme)
                let attachment = XCTAttachment(image: image)
                attachment.name = "financial-signs-\(scheme)-\(size)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }

    private func render<V: View>(_ content: V, size: DynamicTypeSize = .large,
                                 scheme: ColorScheme = .light) throws -> UIImage {
        let renderer = ImageRenderer(content: content.fixedSize()
            .foregroundStyle(scheme == .light ? .black : .white)
            .padding(4).background(scheme == .light ? .white : .black)
            .environment(\.colorScheme, scheme).environment(\.dynamicTypeSize, size))
        renderer.scale = 3
        return try XCTUnwrap(renderer.uiImage)
    }

    private func coloredPixelCount(_ image: UIImage) throws -> Int {
        let source = try XCTUnwrap(image.cgImage)
        let width = source.width, height = source.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(data: &pixels, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        return stride(from: 0, to: pixels.count, by: 4).filter { index in
            let components = pixels[index..<(index + 3)]
            return Int(components.max()!) - Int(components.min()!) > 70
        }.count
    }

    private func assertCentered(_ image: UIImage, digitsStart: CGFloat? = nil, label: String,
                                file: StaticString = #filePath, line: UInt = #line) throws {
        let ink = try pixelInk(image)
        let parts = try splitInk(ink, scale: image.scale)
        let arrow = parts.arrow.map(\.y)
        let digits = parts.digits.filter { $0.x >= (digitsStart ?? 0) }.map(\.y)
        let arrowCenter = (try XCTUnwrap(arrow.min()) + XCTUnwrap(arrow.max())) / 2
        let digitCenter = (try XCTUnwrap(digits.min()) + XCTUnwrap(digits.max())) / 2
        if abs(arrowCenter - digitCenter) > 0.75 {
            let attachment = XCTAttachment(image: image)
            attachment.name = label
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        XCTAssertEqual(arrowCenter, digitCenter, accuracy: 0.75, label, file: file, line: line)
    }

    private struct InkPixel {
        let x: CGFloat
        let y: CGFloat
        let rgb: [Double]
        let contrast: Double
    }

    private func splitInk(_ ink: [InkPixel], scale: CGFloat) throws -> (arrow: [InkPixel], digits: [InkPixel]) {
        let columns = Set(ink.map(\.x)).sorted()
        let boundary = try XCTUnwrap(zip(columns, columns.dropFirst()).first {
            $1 - $0 > 1 / scale + 0.01
        }?.1, "The triangle and digits must have a visible gap")
        return (ink.filter { $0.x < boundary }, ink.filter { $0.x >= boundary })
    }

    private func inkBounds(_ ink: [InkPixel]) throws -> CGRect {
        let minX = try XCTUnwrap(ink.map(\.x).min()), maxX = try XCTUnwrap(ink.map(\.x).max())
        let minY = try XCTUnwrap(ink.map(\.y).min()), maxY = try XCTUnwrap(ink.map(\.y).max())
        return CGRect(x: minX, y: minY, width: maxX - minX + 1 / 3, height: maxY - minY + 1 / 3)
    }

    private func pixelInk(_ image: UIImage, scheme: ColorScheme = .light) throws -> [InkPixel] {
        let source = try XCTUnwrap(image.cgImage)
        let width = source.width, height = source.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(data: &pixels, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        // Fractional cap-height frames can leave a transparent edge pixel.
        // Composite it onto the intended background rather than reading its
        // zero RGB channels as black ink.
        context.setFillColor((scheme == .light ? UIColor.white : UIColor.black).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        var result: [InkPixel] = []
        for y in 0..<height {
            for x in 0..<width {
                let index = (y * width + x) * 4
                let rgb = pixels[index..<(index + 3)].map(Double.init)
                let contrast = rgb.map { abs($0 - (scheme == .light ? 255 : 0)) }.max()!
                if contrast > 70 {
                    result.append(InkPixel(x: CGFloat(x) / image.scale, y: CGFloat(y) / image.scale,
                                           rgb: rgb, contrast: contrast))
                }
            }
        }
        return result
    }
}
