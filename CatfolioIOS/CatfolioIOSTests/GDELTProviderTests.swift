import Foundation
import XCTest
@testable import CatfolioIOS

final class GDELTProviderTests: XCTestCase {
    func testEmptyArticleListIsDistinctFromMissingOrUnreadableData() {
        XCTAssertEqual(GDELTProvider.articles(in: Data(#"{"articles":[]}"#.utf8))?.count, 0)
        XCTAssertNil(GDELTProvider.articles(in: Data(#"{"message":"temporarily unavailable"}"#.utf8)))
        XCTAssertNil(GDELTProvider.articles(in: Data("not json".utf8)))
    }
}
