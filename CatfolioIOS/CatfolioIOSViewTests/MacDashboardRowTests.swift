import SwiftUI
import XCTest
@testable import CatfolioIOS

@MainActor
final class MacDashboardRowTests: XCTestCase {
    private func height(atWidth width: CGFloat) -> CGFloat {
        let row = MacDashboardRow(spacing: 10) {
            Color.red.frame(height: 100)
            Color.blue.frame(height: 60)
        }
        return UIHostingController(rootView: row)
            .sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
            .height
    }

    func testWideRowPutsTheCardsSideBySide() {
        XCTAssertEqual(height(atWidth: MacDashboardRow.sideBySideWidth + 200), 100, accuracy: 0.5)
    }

    func testNarrowRowStacksTheCards() {
        XCTAssertEqual(height(atWidth: MacDashboardRow.sideBySideWidth - 200), 170, accuracy: 0.5)
    }
}
