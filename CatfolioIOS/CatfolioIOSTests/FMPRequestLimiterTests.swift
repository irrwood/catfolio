import Foundation
import XCTest
@testable import CatfolioIOS

final class FMPRequestLimiterTests: XCTestCase {
    func testExhaustedQuotaFailsPromptlyInsteadOfHoldingUpFallback() async throws {
        let limiter = FMPRequestLimiter(spacing: 0)
        await limiter.backOff(retryAfter: "120")
        let completed = expectation(description: "Caller can continue to fallback")
        let request = Task {
            do {
                try await limiter.waitForTurn()
                XCTFail("An exhausted provider must not receive another request")
            } catch FMPFailure.rateLimited(let seconds) {
                XCTAssertGreaterThan(seconds, 0)
                XCTAssertLessThanOrEqual(seconds, 120)
                completed.fulfill()
            } catch {
                // Cancellation below releases the task if the old blocking
                // implementation regresses, without leaving a long sleeper.
                if !(error is CancellationError) { XCTFail("Unexpected error: \(error)") }
            }
        }
        await fulfillment(of: [completed], timeout: 0.5)
        request.cancel()
        await request.value
    }

    func testRequestsResumeWhenCooldownExpires() async throws {
        let limiter = FMPRequestLimiter(spacing: 0)
        await limiter.backOff(retryAfter: "1")
        do {
            try await limiter.waitForTurn()
            XCTFail("The quota is still cooling down")
        } catch FMPFailure.rateLimited { }
        try await Task.sleep(for: .milliseconds(1_050))
        try await limiter.waitForTurn()
    }

    func testShorterBackoffDoesNotReopenExhaustedQuota() async {
        let limiter = FMPRequestLimiter(spacing: 0)
        await limiter.backOff(retryAfter: "120")
        await limiter.backOff(retryAfter: "1")
        let remaining = await limiter.secondsUntilFreeSlot
        XCTAssertGreaterThan(remaining, 110)
    }

    func testNormalRequestsStayPaced() async throws {
        let limiter = FMPRequestLimiter(spacing: 0.08)
        try await limiter.waitForTurn()
        let first = Date()
        try await limiter.waitForTurn()
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(first), 0.06)
    }

    func testCancellationIsNotReportedAsQuotaFailure() async {
        let limiter = FMPRequestLimiter(spacing: 0)
        await limiter.backOff(retryAfter: "120")
        let request = Task { () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                try await limiter.waitForTurn()
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }
        let cancelled = await request.value
        XCTAssertTrue(cancelled)
    }
}
