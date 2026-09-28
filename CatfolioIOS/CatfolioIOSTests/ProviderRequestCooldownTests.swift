import Foundation
import XCTest
@testable import CatfolioIOS

final class ProviderRequestCooldownTests: XCTestCase {
    func testRetryAfterHonorsLongWaitAndHTTPDate() {
        let now = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(ProviderRequestCooldown.delay(retryAfter: "120", now: now), 120)
        XCTAssertEqual(ProviderRequestCooldown.delay(retryAfter: "Thu, 01 Jan 1970 00:02:00 GMT", now: now), 120)
        for header: String? in [nil, "invalid", "nan", "inf", "-1"] {
            XCTAssertEqual(ProviderRequestCooldown.delay(retryAfter: header, now: now), 60)
        }
    }

    func testCooldownIsSharedByProviderAndExpiresWithoutBlockingOthers() async throws {
        let cooldown = ProviderRequestCooldown()
        let massive = try XCTUnwrap(DataSource.named("massive"))
        let fmp = try XCTUnwrap(DataSource.named("fmp"))
        let now = Date(timeIntervalSince1970: 100)
        let response = try XCTUnwrap(HTTPURLResponse(url: URL(string: "https://api.massive.com/test")!,
            statusCode: 429, httpVersion: nil, headerFields: ["Retry-After": "120"]))
        await cooldown.record(massive, response: response, now: now)
        do {
            try await cooldown.check(massive, now: now.addingTimeInterval(119))
            XCTFail("All Massive callers must respect the provider cooldown")
        } catch { XCTAssertTrue(error is ProviderRequestCooldown.CooldownError) }
        try await cooldown.check(fmp, now: now)
        try await cooldown.check(massive, now: now.addingTimeInterval(120))
    }

    @MainActor func testRepeatedIssuesAreNotRepeatedInStatusRows() throws {
        let health = DataSourceHealth()
        let source = try XCTUnwrap(DataSource.named("massive"))
        health.apply(.httpStatus(404), for: source, at: Date(timeIntervalSince1970: 1))
        for second in 2...5 {
            health.apply(.rateLimited, for: source, at: Date(timeIntervalSince1970: Double(second)))
        }
        let status = try XCTUnwrap(health.statuses[source])
        XCTAssertEqual(status.failureCount, 5)
        XCTAssertEqual(status.lastEvent?.outcome, .rateLimited)
        XCTAssertEqual(status.distinctEarlierFailures.map(\.outcome), [.httpStatus(404)])
    }
}
