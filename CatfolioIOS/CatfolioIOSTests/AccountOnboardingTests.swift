import XCTest
@testable import CatfolioIOS

final class AccountOnboardingTests: XCTestCase {
    func testTutorialStopsAtCredentialsUntilConnectionSucceeds() {
        var step = Trading212GuideStep.prepare
        for _ in 0..<10 { step = step.nextTutorialStep }
        XCTAssertEqual(step, .credentials)
        XCTAssertFalse(step.isTutorial)
        XCTAssertEqual(Trading212GuideStep.review.nextTutorialStep, .review)
    }

    func testReviewCanReturnToCredentialsButCompletionCannotGoBackAndCreateAgain() {
        XCTAssertEqual(Trading212GuideStep.review.previous, .credentials)
        XCTAssertEqual(Trading212GuideStep.credentials.previous, .permissions)
        XCTAssertNil(Trading212GuideStep.prepare.previous)
        XCTAssertNil(Trading212GuideStep.complete.previous)
    }
}
