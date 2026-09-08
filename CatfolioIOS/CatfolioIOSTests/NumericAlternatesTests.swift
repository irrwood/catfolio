import UIKit
import XCTest
@testable import CatfolioIOS

/// SF's alternate digit forms — straight-sided six and nine, open four.
final class NumericAlternatesTests: XCTestCase {

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
