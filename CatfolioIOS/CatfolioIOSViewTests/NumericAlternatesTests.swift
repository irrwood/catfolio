import UIKit
import CoreText
import SwiftUI
import XCTest
@testable import CatfolioIOS

/// SF's alternate digit forms — straight-sided six and nine, open four.
final class NumericAlternatesTests: XCTestCase {

    func testCurrencyVariantUsesTheShippedCurrencyAlternates() throws {
        for rounded in [true, false] {
            let standard = plain(size: 48, rounded: rounded)
            let alternate = CurrencySymbolAlternates.applying(to: standard)
            // Rounded's cv09 includes dollar and cent; SF Pro exposes it as
            // "Small dollar sign" and already uses the target cent form.
            for symbol in rounded ? ["$", "¢"] : ["$"] {
                XCTAssertNotEqual(
                    try XCTUnwrap(image(symbol, font: alternate)),
                    try XCTUnwrap(image(symbol, font: standard)),
                    "cv09 did not change \(symbol), rounded: \(rounded)"
                )
            }
            XCTAssertEqual(alternate.pointSize, standard.pointSize)
            XCTAssertEqual(alternate.fontName, standard.fontName)
        }
    }

    func testCurrencyVariantLeavesDigitsLettersAndOtherCurrenciesUnchanged() throws {
        let standard = plain(size: 32, rounded: true)
        let alternate = CurrencySymbolAlternates.applying(to: standard)
        for text in ["0123456789", "+−.,%", "Total", "€£¥"] {
            XCTAssertEqual(
                try XCTUnwrap(image(text, font: alternate)),
                try XCTUnwrap(image(text, font: standard)),
                "cv09 unexpectedly changed \(text)"
            )
        }
    }

    func testCurrencyFeaturePreservesExistingNumericAlternates() throws {
        let original = plain(size: 32, rounded: true)
        let descriptor = original.fontDescriptor.addingAttributes([
            .featureSettings: [NumericAlternates.straightSidedSixAndNine, NumericAlternates.openFour].map {
                [UIFontDescriptor.FeatureKey.type: kStylisticAlternativesType,
                 UIFontDescriptor.FeatureKey.selector: $0 * 2]
            },
        ])
        let digitsOnly = UIFont(descriptor: descriptor, size: 32)
        let combined = NumericAlternates.font(size: 32, weight: .medium, rounded: true)
        XCTAssertEqual(
            try XCTUnwrap(image("0123456789", font: combined)),
            try XCTUnwrap(image("0123456789", font: digitsOnly))
        )
        XCTAssertNotEqual(
            try XCTUnwrap(image("$¢", font: combined)),
            try XCTUnwrap(image("$¢", font: digitsOnly))
        )
    }

    func testCurrencyVariantFontsAreCached() {
        let standard = plain(size: 17, rounded: true)
        XCTAssertTrue(CurrencySymbolAlternates.applying(to: standard) === CurrencySymbolAlternates.applying(to: standard))
    }

    @MainActor
    func testSwiftUIMonospacingAndWeightPreserveCurrencyVariant() throws {
        let standard = plain(size: 32, rounded: true)
        let alternate = CurrencySymbolAlternates.applying(to: standard)
        func render(_ text: String, font: UIFont) throws -> Data {
            let renderer = ImageRenderer(content: Text(text)
                .font(Font(font)).monospacedDigit().fontWeight(.bold)
                .foregroundStyle(.black).padding(8).background(.white))
            return try XCTUnwrap(renderer.uiImage?.pngData())
        }
        XCTAssertNotEqual(try render("$¢", font: alternate), try render("$¢", font: standard))
        XCTAssertEqual(try render("0123456789", font: alternate), try render("0123456789", font: standard))
    }

    @MainActor
    func testSemanticCurrencyFontStillFollowsDynamicType() throws {
        func render(_ size: DynamicTypeSize) throws -> UIImage {
            let renderer = ImageRenderer(content: Text("$1,234.56")
                .currencyFont(.body).fixedSize()
                .environment(\.dynamicTypeSize, size))
            return try XCTUnwrap(renderer.uiImage)
        }
        let standard = try render(.large)
        let accessible = try render(.accessibility3)
        XCTAssertGreaterThan(accessible.size.height, standard.size.height)
        XCTAssertGreaterThan(accessible.size.width, standard.size.width)
    }

    @MainActor
    func testCurrencyPreviewRendersAcrossSharedFontEntrypoints() throws {
        let renderer = ImageRenderer(content: VStack(alignment: .leading, spacing: 12) {
            Text("$ ¢ 1,234.56").font(Typography.number(size: 32))
            Text("$ ¢ 1,234.56").appNumber(.heading)
            Text("$ ¢ 1,234.56").font(LegacyType.medium(19))
            Text("$ ¢ 1,234.56").currencyFont(.body)
        }.foregroundStyle(.black).padding(20).background(.white))
        renderer.scale = 2
        let preview = try XCTUnwrap(renderer.uiImage)
        let attachment = XCTAttachment(image: preview)
        attachment.name = "SF-cv09-currency-preview"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func image(_ text: String, font: UIFont) -> Data? {
        let size = CGSize(width: 260, height: 60)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            (text as NSString).draw(
                at: .zero,
                withAttributes: [.font: font, .foregroundColor: UIColor.black]
            )
        }.pngData()
    }

    private func plain(size: CGFloat, rounded: Bool) -> UIFont {
        var descriptor = UIFont.systemFont(ofSize: size, weight: .medium).fontDescriptor
        if rounded, let round = descriptor.withDesign(.rounded) { descriptor = round }
        return UIFont(descriptor: descriptor, size: size)
    }

    /// The whole point. If the shipped font does not carry these stylistic
    /// sets, or the selector convention is wrong, the descriptor is accepted
    /// silently and the glyphs are unchanged — so the only honest check is
    /// whether the drawn pixels actually differ.
    func testAlternateDigitsChangeTheGlyphs() throws {
        for rounded in [true, false] {
            let alternate = NumericAlternates.font(size: 48, weight: .medium, rounded: rounded)
            let standard = plain(size: 48, rounded: rounded)
            let withAlternates = try XCTUnwrap(image("469", font: alternate))
            let without = try XCTUnwrap(image("469", font: standard))
            XCTAssertNotEqual(
                withAlternates, without,
                "stylistic sets had no effect on 4/6/9 (rounded: \(rounded)) — "
                    + "the set numbers are wrong or this font does not ship them"
            )
        }
    }

    /// Digits without an alternate must be untouched, or the feature is doing
    /// more than it claims and the change is a different typeface rather than
    /// three glyph swaps.
    func testDigitsWithoutAlternatesAreUnchanged() throws {
        let alternate = NumericAlternates.font(size: 48, weight: .medium, rounded: true)
        let standard = plain(size: 48, rounded: true)
        XCTAssertEqual(
            try XCTUnwrap(image("012357", font: alternate)),
            try XCTUnwrap(image("012357", font: standard)),
            "a digit with no alternate changed shape"
        )
    }

    /// Letters are not affected. This is applied to figures, and prose that
    /// picked it up would read as a second typeface.
    func testLettersAreUnchanged() throws {
        XCTAssertEqual(
            try XCTUnwrap(image("Total", font: NumericAlternates.font(size: 48, weight: .medium, rounded: true))),
            try XCTUnwrap(image("Total", font: plain(size: 48, rounded: true)))
        )
    }

    /// Built once per size and weight; a font is rebuilt on every row
    /// otherwise, and rows are what this app is made of.
    func testFontsAreCached() {
        let first = NumericAlternates.font(size: 17, weight: .semibold, rounded: true)
        let second = NumericAlternates.font(size: 17, weight: .semibold, rounded: true)
        XCTAssertTrue(first === second)
    }

    /// The rounded request has to survive the feature settings — asking for
    /// alternates must not quietly drop back to SF Pro.
    func testRoundedDesignSurvives() {
        let rounded = NumericAlternates.font(size: 24, weight: .medium, rounded: true)
        let pro = NumericAlternates.font(size: 24, weight: .medium, rounded: false)
        XCTAssertNotEqual(rounded.fontName, pro.fontName)
        XCTAssertTrue(
            rounded.fontName.lowercased().contains("round"),
            "expected a rounded face, got \(rounded.fontName)"
        )
    }
}
