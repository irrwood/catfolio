import UIKit
import XCTest
@testable import CatfolioIOS

@MainActor
final class MacPlatformTests: XCTestCase {
    func testSplitPageKeepsItsWidthAndLeavesRoomBesideIt() {
        let split = UISplitViewController(style: .doubleColumn)
        let widths = MacSplitWidths(pageWidth: MacPageWidth.overview)
        widths.split = split
        widths.apply()
        XCTAssertEqual(split.preferredPrimaryColumnWidth, MacPageWidth.overview)
        XCTAssertEqual(split.maximumPrimaryColumnWidth, MacPageWidth.overview)
        XCTAssertEqual(split.minimumPrimaryColumnWidth, MacSplitColumns.minimumPageWidth)
        XCTAssertEqual(split.preferredSplitBehavior, .tile)
        XCTAssertEqual(split.preferredDisplayMode, .oneBesideSecondary)
    }

    func testSplitPageWidthsComeBackAfterTheSplitViewResetsThem() {
        let split = UISplitViewController(style: .doubleColumn)
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
