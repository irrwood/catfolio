import XCTest
@testable import CatfolioIOS

/// Where a sale's exact Result enters the app. Trading 212 omits walletImpact
/// on some historical fills, so the optionality here is load-bearing: reading
/// an absent Result as zero would report a real profit as break-even.
final class Trading212FillDecodingTests: XCTestCase {

    private let payload = #"{"order":{"status":"FILLED","side":"SELL","currency":"GBP","ticker":"TEST_US_EQ","instrument":{"currency":"USD","ticker":"TEST_US_EQ"}},"fill":{"id":123,"filledAt":"2026-01-02T10:00:00Z","price":200,"quantity":-2,"walletImpact":{"currency":"GBP","fxRate":0.75,"realisedProfitLoss":-12.34}}}"#

    private func decode(_ json: String) throws -> Trading212Client.HistoricalOrder {
        try JSONDecoder().decode(
            Trading212Client.HistoricalOrder.self, from: Data(json.utf8))
    }

    func testFillCarriesResultCurrencyAndFXRate() throws {
        let order = try decode(payload)

        XCTAssertEqual(order.fill?.walletImpact?.realisedProfitLoss, -12.34)
        XCTAssertEqual(order.fill?.walletImpact?.currency, "GBP")
        XCTAssertEqual(order.fill?.walletImpact?.fxRate, 0.75)
        XCTAssertEqual(order.fill?.id, 123)
    }

    /// The instrument trades in USD while the wallet settles in GBP; conflating
    /// the two is what produces a realised figure in the wrong currency.
    func testInstrumentCurrencyIsDistinctFromWalletCurrency() throws {
        let order = try decode(payload)

        XCTAssertEqual(order.order?.instrument?.currency, "USD")
        XCTAssertEqual(order.fill?.walletImpact?.currency, "GBP")
    }

    /// Break-even is a reported Result, not a missing one.
    func testZeroResultDecodesAsZeroNotNil() throws {
        let order = try decode(payload.replacingOccurrences(of: "-12.34", with: "0"))

        XCTAssertEqual(order.fill?.walletImpact?.realisedProfitLoss, 0)
    }

    func testAbsentWalletImpactDecodesAsNilRatherThanFailing() throws {
        let order = try decode(#"{"fill":{"quantity":-2,"price":200},"order":{"side":"SELL"}}"#)

        XCTAssertNil(order.fill?.walletImpact)
        XCTAssertEqual(order.fill?.quantity, -2)
    }
}
