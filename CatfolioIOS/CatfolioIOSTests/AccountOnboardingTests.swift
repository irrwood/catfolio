import XCTest
@testable import CatfolioIOS

final class AccountOnboardingTests: XCTestCase {
    func testTutorialStopsAtCredentialsUntilConnectionSucceeds() {
        var step = Trading212GuideStep.prepare
        step = step.nextTutorialStep
        XCTAssertEqual(step, .credentials, "One preparation screen must lead straight to input")
        for _ in 0..<10 { step = step.nextTutorialStep }
        XCTAssertEqual(step, .credentials)
        XCTAssertFalse(step.isTutorial)
        XCTAssertEqual(Trading212GuideStep.review.nextTutorialStep, .review)
    }

    func testLegacyTutorialStepsJoinTheThreeStepFlow() {
        for step in [Trading212GuideStep.prepare, .settings, .permissions] {
            XCTAssertEqual(step.progressStep, 1)
            XCTAssertEqual(step.nextTutorialStep, .credentials)
        }
        XCTAssertEqual(Trading212GuideStep.credentials.progressStep, 2)
        XCTAssertEqual(Trading212GuideStep.review.progressStep, 3)
        XCTAssertEqual(Trading212GuideStep.complete.progressStep, 3)
    }

    func testReviewCanReturnToCredentialsButCompletionCannotGoBackAndCreateAgain() {
        XCTAssertEqual(Trading212GuideStep.review.previous, .credentials)
        XCTAssertEqual(Trading212GuideStep.credentials.previous, .prepare)
        XCTAssertNil(Trading212GuideStep.prepare.previous)
        XCTAssertNil(Trading212GuideStep.complete.previous)
    }
}
