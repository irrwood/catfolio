import SwiftUI
import XCTest
@testable import CatfolioIOS

/// The type scale, pinned. These are cheap tests for a reason: the scale is
/// the kind of thing that drifts one point at a time until nothing lines up.
final class TypographyTests: XCTestCase {

    /// `displayUnit` is excluded: it is not a rung on the ramp but the small
    /// companion to `display`, and it is declared next to the token it pairs
    /// with rather than at its own size's position.
    func testScaleIsDescending() {
        let ramp = TypeScale.allCases.filter { $0 != .displayUnit }
        for (index, scale) in ramp.enumerated() where index > 0 {
            XCTAssertLessThanOrEqual(
                scale.size, ramp[index - 1].size,
                "\(scale) is larger than the token above it"
            )
        }
    }

    /// Two tokens the same size are two names for one thing, and call sites
    /// will pick between them at random.
    func testNoTwoTokensShareASize() {
        let sizes = TypeScale.allCases.map(\.size)
        XCTAssertEqual(Set(sizes).count, sizes.count, "duplicate sizes: \(sizes)")
    }

    /// Below about 10pt text stops being readable at arm's length, and above
    /// the display size the money headline stops fitting its line.
    func testEverySizeIsWithinTheUsableRange() {
        for scale in TypeScale.allCases {
            XCTAssertGreaterThanOrEqual(scale.size, 10, "\(scale)")
            XCTAssertLessThanOrEqual(scale.size, 32, "\(scale)")
        }
    }

    /// Caps tracking is proportional, so it holds at every size rather than
    /// looking right at 13pt and wrong at 24pt.
    func testCapsTrackingScalesWithSize() {
        for scale in TypeScale.allCases {
            let ratio = scale.capsTracking / scale.size
            XCTAssertEqual(ratio, 0.06, accuracy: 0.005, "\(scale)")
        }
    }

    /// Leading belongs on text that wraps. Adding it to a single-line figure
    /// only pads the row.
    func testOnlyWrappingTokensCarryExtraLeading() {
        for scale in [TypeScale.display, .displayUnit, .title, .heading, .label, .micro, .nano] {
            XCTAssertEqual(scale.lineSpacing, 0, "\(scale) should not add leading")
        }
        for scale in [TypeScale.body, .callout, .footnote, .caption] {
            XCTAssertGreaterThan(scale.lineSpacing, 0, "\(scale) should add leading")
        }
    }

    /// The money headline must not scale along `.body`, or it grows faster
    /// than the layout can absorb at accessibility sizes.
    func testDisplayTokensScaleAlongLargeTitle() {
        XCTAssertEqual(TypeScale.display.textStyle, .largeTitle)
        XCTAssertEqual(TypeScale.displayUnit.textStyle, .largeTitle)
    }

    /// The unit that sits beside the headline has to be smaller than it, and
    /// close enough to read as the same object.
    func testDisplayUnitSitsBelowTheDisplaySize() {
        XCTAssertLessThan(TypeScale.displayUnit.size, TypeScale.display.size)
        XCTAssertGreaterThan(TypeScale.displayUnit.size / TypeScale.display.size, 0.55)
    }

    /// The bundle carried four Montserrat faces for a headline treatment that
    /// is now SF Rounded. If a face comes back, so does a 400 KB payload and
    /// a second set of metrics to keep aligned.
    func testNoBundledFontFilesRemain() throws {
        let bundle = Bundle(for: Self.self)
        let app = try XCTUnwrap(Bundle(identifier: "com.catfolio.CatfolioIOS") ?? Bundle.main as Bundle?)
        for bundle in [bundle, app] {
            XCTAssertTrue(
                bundle.paths(forResourcesOfType: "ttf", inDirectory: nil).isEmpty,
                "a font file is being bundled again"
            )
            XCTAssertNil(
                bundle.object(forInfoDictionaryKey: "UIAppFonts"),
                "UIAppFonts is registered again"
            )
        }
    }
}
