import XCTest
@testable import CatfolioIOS

/// Nasdaq answers HTTP 200 for everything, including "no such symbol". The
/// outcome lives in the envelope, so these pin the decision that keeps a
/// lookup failure from being reported as a successful empty result.
final class NasdaqAnalystStatusTests: XCTestCase {
    private typealias Status = NasdaqAnalystClient.Status

    func testSuccessPasses() {
        XCTAssertNoThrow(try NasdaqAnalystClient.validate(Status(rCode: 200, bCodeMessage: nil)))
    }

    func testMissingStatusIsNotTreatedAsFailure() {
        XCTAssertNoThrow(try NasdaqAnalystClient.validate(nil))
    }

    /// A non-US ticker such as AZN.L comes back this way.
    func testUnknownSymbolIsRejected() {
        let status = Status(rCode: 400, bCodeMessage: [.init(code: 1001, errorMessage: "Symbol not exists.")])

        XCTAssertThrowsError(try NasdaqAnalystClient.validate(status)) { error in
            XCTAssertEqual(error as? NasdaqAnalystError, .unknownSymbol)
        }
    }

    /// An ETF such as VOO: real symbol, rCode 200, but no analyst coverage.
    /// This must not read as success with empty data.
    func testNoCoverageIsDistinguishedFromSuccess() {
        let status = Status(rCode: 200, bCodeMessage: [.init(code: 1002, errorMessage: "No record found.")])

        XCTAssertThrowsError(try NasdaqAnalystClient.validate(status)) { error in
            XCTAssertEqual(error as? NasdaqAnalystError, .noCoverage)
        }
    }

    func testOtherServerCodesSurfaceTheirMessage() {
        let status = Status(rCode: 500, bCodeMessage: [.init(code: 9, errorMessage: "boom")])

        XCTAssertThrowsError(try NasdaqAnalystClient.validate(status))
    }
}

/// FMP reports five rating buckets and Nasdaq three. The card has only ever
/// drawn three, so the collapse is the contract both providers meet.
final class RatingSpreadTests: XCTestCase {

    func testFiveBucketsCollapseIntoThree() throws {
        // strongSell, sell, hold, buy, strongBuy
        let spread = try XCTUnwrap(RatingSpread(fiveBucket: [1, 2, 3, 4, 5]))

        XCTAssertEqual(spread.bearish, 3, "strongSell + sell")
        XCTAssertEqual(spread.neutral, 3, "hold")
        XCTAssertEqual(spread.bullish, 9, "buy + strongBuy")
        XCTAssertEqual(spread.total, 15)
    }

    func testWrongBucketCountIsRejected() {
        XCTAssertNil(RatingSpread(fiveBucket: [1, 2, 3]))
        XCTAssertNil(RatingSpread(fiveBucket: []))
    }

    /// An all-zero distribution carries no information and must not render as
    /// a bar chart divided by zero.
    func testAnEmptyDistributionIsRejected() {
        XCTAssertNil(RatingSpread(fiveBucket: [0, 0, 0, 0, 0]))
        XCTAssertNil(RatingSpread(bearish: 0, neutral: 0, bullish: 0))
    }

    func testNegativeCountsAreRejected() {
        XCTAssertNil(RatingSpread(bearish: -1, neutral: 0, bullish: 1))
        XCTAssertNil(RatingSpread(fiveBucket: [0, -2, 0, 0, 1]))
    }

    /// Nasdaq's shape, straight through: sell/hold/buy with no strong split.
    func testThreeBucketConstructionKeepsItsCounts() throws {
        let spread = try XCTUnwrap(RatingSpread(bearish: 0, neutral: 2, bullish: 16))

        XCTAssertEqual(spread.bearish, 0)
        XCTAssertEqual(spread.neutral, 2)
        XCTAssertEqual(spread.bullish, 16)
        XCTAssertEqual(spread.total, 18)
    }
}
