import SwiftUI
import XCTest
@testable import CatfolioIOS

@MainActor
final class HomeLoadingPresentationTests: XCTestCase {
    func testPendingQuotesNeverPresentUnavailableOrEmptyDirection() {
        for hasContributions in [false, true] {
            XCTAssertEqual(TodayContributionCard.ContentState.resolve(isLoading: true,
                hasContributions: hasContributions, hasVisibleContributions: false), .loading)
        }
    }

    func testCachedVisibleQuotesStayVisibleDuringRefresh() {
        XCTAssertEqual(TodayContributionCard.ContentState.resolve(isLoading: true,
            hasContributions: true, hasVisibleContributions: true), .bars)
    }

    func testEmptyMessagesAppearOnlyAfterLoadingSettles() {
        XCTAssertEqual(TodayContributionCard.ContentState.resolve(isLoading: false,
            hasContributions: false, hasVisibleContributions: false), .unavailable)
        XCTAssertEqual(TodayContributionCard.ContentState.resolve(isLoading: false,
            hasContributions: true, hasVisibleContributions: false), .emptyDirection)
    }
}
