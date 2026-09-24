import XCTest
@testable import CatfolioIOS

final class AssetLogoStyleTests: XCTestCase {
    func testAutomaticFollowsAppearanceAndFixedStylesDoNot() {
        XCTAssertFalse(AssetLogoStyle.automatic.usesDarkLogo(darkAppearance: false))
        XCTAssertTrue(AssetLogoStyle.automatic.usesDarkLogo(darkAppearance: true))
        for dark in [false, true] {
            XCTAssertFalse(AssetLogoStyle.light.usesDarkLogo(darkAppearance: dark))
            XCTAssertTrue(AssetLogoStyle.dark.usesDarkLogo(darkAppearance: dark))
        }
    }

    func testUnknownStoredValueFallsBackToAutomatic() {
        XCTAssertNil(AssetLogoStyle(rawValue: "brand"))
        XCTAssertEqual(AssetLogoStyle.allCases.map(\.rawValue), ["automatic", "light", "dark"])
    }
}
