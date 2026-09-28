import XCTest
@testable import CatfolioIOS

final class ServiceAPIOnboardingTests: XCTestCase {
    func testFirstLaunchWithNoCredentialsShowsGuide() {
        XCTAssertTrue(ServiceAPIOnboardingPolicy.shouldPresent(hasSeen: false, hasAnyAPIKey: false, hasConnectedAI: false))
    }

    func testExistingCredentialsAndConnectedAIKeepCurrentFlow() {
        XCTAssertFalse(ServiceAPIOnboardingPolicy.shouldPresent(hasSeen: false, hasAnyAPIKey: true, hasConnectedAI: false))
        XCTAssertFalse(ServiceAPIOnboardingPolicy.shouldPresent(hasSeen: false, hasAnyAPIKey: false, hasConnectedAI: true))
    }

    func testSkippingOrCompletingDoesNotPromptAgainEvenWithoutKeys() {
        for hasKey in [false, true] {
            XCTAssertFalse(ServiceAPIOnboardingPolicy.shouldPresent(hasSeen: true, hasAnyAPIKey: hasKey, hasConnectedAI: false))
        }
    }
}
