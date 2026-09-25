import Foundation
import XCTest
@testable import CatfolioIOS

final class HoldingListShareFormatTests: XCTestCase {
    private let locale = Locale(identifier: "en_US")

    func testCompactShareCountsUseTwoDecimalsAndPromoteRoundedUnits() {
        XCTAssertEqual(DisplayFormat.listShares(83.4078, locale: locale), "83.41")
        XCTAssertEqual(DisplayFormat.listShares(1_000, locale: locale), "1.00K")
        XCTAssertEqual(DisplayFormat.listShares(12_345.678, locale: locale), "12.35K")
        XCTAssertEqual(DisplayFormat.listShares(999_999.99, locale: locale), "1.00M")
        XCTAssertEqual(DisplayFormat.listShares(1_234_567, locale: locale), "1.23M")
        XCTAssertEqual(DisplayFormat.listShares(1_500_000_000, locale: locale), "1.50B")
        XCTAssertEqual(DisplayFormat.listShares(-12_500, locale: locale), "-12.50K")
    }

    func testAccessibleShareCountKeepsFullTwoDecimalValue() {
        XCTAssertEqual(DisplayFormat.listShares(1_234_567, compact: false, locale: locale), "1234567.00")
    }
}
