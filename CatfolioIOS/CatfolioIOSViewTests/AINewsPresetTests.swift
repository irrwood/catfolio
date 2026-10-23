import SwiftUI
import XCTest
@testable import CatfolioIOS

final class AINewsPresetTests: XCTestCase {
    func testCompanyPresetsPassTheSelectedListingDirectlyToNewsSearch() throws {
        let security = AIQuestionSecurity(result: .init(ticker: "AAPL", name: "Apple", market: "US",
            exchange: "NASDAQ", currency: "USD", sector: "Technology", isFund: false))
        for preset in AIQuestionPreset.allCases where preset.requiresSecurity {
            let request = try XCTUnwrap(preset.request(security: security))
            XCTAssertEqual(request.newsQueries.count, 1)
            XCTAssertEqual(request.newsQueries[0].ticker, "AAPL")
            XCTAssertEqual(request.newsQueries[0].name, "Apple")
        }
    }

    func testMarketPresetSearchesAPublicTopicWithoutInventingATicker() throws {
        let request = try XCTUnwrap(AIQuestionPreset.market.request())
        XCTAssertEqual(request.newsQueries.count, 1)
        XCTAssertEqual(request.newsQueries[0].ticker, "")
        XCTAssertEqual(request.newsQueries[0].name, "US stock market")
    }
}
