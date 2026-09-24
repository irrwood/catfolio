import XCTest
import SwiftUI
@testable import CatfolioIOS

final class AssetLogoExportCatalogTests: XCTestCase {
    func testReviewedStockAndEtfAliasesLoadBothAppearances() throws {
        let stockLight = try XCTUnwrap(AssetLogoExportCatalog.imageURL(for: "GOOGL", dark: false))
        let stockDark = try XCTUnwrap(AssetLogoExportCatalog.imageURL(for: "GOOGL", dark: true))
        XCTAssertEqual(stockLight.lastPathComponent, "GOOG.light.png")
        XCTAssertEqual(stockDark.lastPathComponent, "GOOG.dark.png")
        XCTAssertNotNil(UIImage(contentsOfFile: stockLight.path))
        XCTAssertNotNil(UIImage(contentsOfFile: stockDark.path))

        let etfLight = try XCTUnwrap(AssetLogoExportCatalog.imageURL(for: "VUAG.L", dark: false))
        let etfDark = try XCTUnwrap(AssetLogoExportCatalog.imageURL(for: "VUAG.L", dark: true))
        XCTAssertEqual(etfLight.lastPathComponent, "VOO.light.png")
        XCTAssertEqual(etfDark.lastPathComponent, "VOO.dark.png")
        XCTAssertNotNil(UIImage(contentsOfFile: etfLight.path))
        XCTAssertNotNil(UIImage(contentsOfFile: etfDark.path))
    }

    func testVerifiedReuseAliasesResolveExistingLogoPairs() throws {
        let reused: [(code: String, stem: String)] = [
            ("AGNCL", "AGNC"), ("BP.L", "BP"), ("NTDOY", "7974.T"),
            ("SQ", "XYZ"), ("SPLG", "SPY"), ("VUSA.L", "VOO")
        ]
        for (code, stem) in reused {
            for dark in [false, true] {
                let url = try XCTUnwrap(AssetLogoExportCatalog.imageURL(for: code, dark: dark), code)
                XCTAssertEqual(url.lastPathComponent, "\(stem).\(dark ? "dark" : "light").png", code)
                XCTAssertNotNil(UIImage(contentsOfFile: url.path), code)
            }
        }
    }
}
