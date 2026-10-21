import UIKit
import XCTest
@testable import CatfolioIOS

@MainActor
final class MacPlatformTests: XCTestCase {
    func testWideWindowGivesThePageItsWidthAndKeepsRoomBesideIt() {
        // 1678 wide: the subpage column keeps 40%, the Overview takes the rest.
        XCTAssertEqual(MacSplitColumns.pageWidth(available: 1678, maximum: MacPageWidth.overview), 1007)
        // Wider still, a page never grows past its own width.
        XCTAssertEqual(MacSplitColumns.pageWidth(available: 2600, maximum: MacPageWidth.standard),
                       MacPageWidth.standard)
    }

    func testNarrowWindowKeepsThePageAtItsMinimum() {
        XCTAssertEqual(MacSplitColumns.pageWidth(available: 700, maximum: MacPageWidth.overview),
                       MacSplitColumns.minimumPageWidth)
    }

    func testSplitPagePinsTheDividerToThePageWidth() {
        let split = UISplitViewController(style: .doubleColumn)
        split.view.frame = CGRect(x: 0, y: 0, width: 1678, height: 900)
        let widths = MacSplitWidths(pageWidth: MacPageWidth.overview)
        widths.split = split
        widths.apply()
        XCTAssertEqual(split.minimumPrimaryColumnWidth, 1007)
        XCTAssertEqual(split.maximumPrimaryColumnWidth, 1007)
        XCTAssertEqual(split.preferredPrimaryColumnWidth, 1007)
        XCTAssertEqual(split.preferredSplitBehavior, .tile)
    }

    func testSplitPageWidthsComeBackAfterTheSplitViewResetsThem() {
        let split = UISplitViewController(style: .doubleColumn)
        split.view.frame = CGRect(x: 0, y: 0, width: 1678, height: 900)
        let widths = MacSplitWidths(pageWidth: MacPageWidth.standard)
        widths.split = split
        widths.apply()
        split.preferredPrimaryColumnWidth = UISplitViewController.automaticDimension
        widths.apply()
        XCTAssertEqual(split.preferredPrimaryColumnWidth, MacPageWidth.standard)
    }

    func testEachMenuRequestIsDeliveredEvenForTheSamePage() {
        let requests = RootNavigationRequests()
        requests.open(.returns)
        let first = requests.serial
        requests.open(.returns)
        XCTAssertEqual(requests.requested, .returns)
        XCTAssertEqual(requests.serial, first + 1)
    }

    func testGoMenuShortcutsAreDistinctAndInSidebarOrder() {
        let shortcuts = RootDestination.sidebarCases.map { String($0.shortcut.character) }
        XCTAssertEqual(shortcuts, (1...RootDestination.sidebarCases.count).map(String.init))
    }

    func testIOSKeepsReturnsAsItsOwnTabAndSettingsOnTheAccountPage() {
        // These tests run on iOS, where nothing is merged.
        XCTAssertEqual(RootDestination.returns.resolved, .returns)
        XCTAssertEqual(RootDestination.preferences.resolved, .settings)
        XCTAssertFalse(RootDestination.sidebarCases.contains(.preferences))
    }
}
