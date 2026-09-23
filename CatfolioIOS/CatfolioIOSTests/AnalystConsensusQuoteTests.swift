import XCTest
@testable import CatfolioIOS

final class AnalystConsensusQuoteTests: XCTestCase {
    private var snapshot: AnalystConsensusData {
        AnalystConsensusData(ratings: nil, consensus: "Buy", low: 90, mean: 120, high: 150,
                             current: 100, source: "FMP", fetchedAt: Date(timeIntervalSince1970: 1_700_000_000),
                             warnings: ["Saved provider warning"])
    }

    func testChangingHoldingQuoteUpdatesCurrentMarkerWithoutChangingResearch() throws {
        let original = snapshot
        let first = original.withCurrentQuote(110, currency: "USD")
        let updated = first.withCurrentQuote(140, currency: "usd")

        XCTAssertEqual(first.current, 110)
        XCTAssertEqual(updated.current, 140)
        XCTAssertEqual(original.current, 100, "Presentation must not mutate the saved snapshot")
        XCTAssertEqual(updated.low, original.low)
        XCTAssertEqual(updated.mean, original.mean)
        XCTAssertEqual(updated.high, original.high)
        XCTAssertEqual(updated.consensus, original.consensus)
        XCTAssertEqual(updated.source, original.source)
        XCTAssertEqual(updated.fetchedAt, original.fetchedAt)
        XCTAssertEqual(updated.warnings, original.warnings)
        XCTAssertEqual(AnalystConsensusData.position(try XCTUnwrap(updated.current), low: 90, high: 150),
                       5.0 / 6.0, accuracy: 1e-12)
    }

    func testMissingInvalidOrNonDollarQuoteDoesNotFallBackToSavedPrice() {
        for quote: Double? in [nil, 0, -1, .nan, .infinity, -.infinity] {
            XCTAssertNil(snapshot.withCurrentQuote(quote, currency: "USD").current)
        }
        for currency: String? in [nil, "GBP", "GBX", "HKD", ""] {
            XCTAssertNil(snapshot.withCurrentQuote(110, currency: currency).current)
        }
    }

    func testPersistedCacheHitUsesEachRequestedQuoteAndKeepsOriginalResearchDate() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("analyst-quote-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let original = snapshot
        try JSONEncoder().encode(["TEST": original]).write(to: url)
        let client = AnalystConsensusClient(cacheURL: url)

        let first = try await client.load(symbol: "TEST", currency: "USD", price: 110)
        let second = try await client.load(symbol: "TEST", currency: "USD", price: 140)
        let unavailable = try await client.load(symbol: "TEST", currency: "USD", price: nil)

        XCTAssertEqual(first.current, 110)
        XCTAssertEqual(second.current, 140)
        XCTAssertNil(unavailable.current)
        XCTAssertEqual(first.fetchedAt, original.fetchedAt)
        XCTAssertEqual(second.fetchedAt, original.fetchedAt)
        XCTAssertEqual(unavailable.mean, original.mean)
        let saved = try JSONDecoder().decode([String: AnalystConsensusData].self,
                                            from: Data(contentsOf: url))
        XCTAssertEqual(saved["TEST"]?.current, 100, "Reusing research must not rewrite its cache")
    }
}
