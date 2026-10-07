import XCTest
@testable import CatfolioIOS

/// London listings quote in pence or pounds depending on the line, and a
/// provider's own unit can disagree with the broker's. A wrong scale is a
/// hundredfold error in a holding's value.
final class InstrumentCurrencyRulesTests: XCTestCase {
    func testMarketPricesAreScaledOnlyForKnownPenceAndPoundLines() {
        XCTAssertEqual(InstrumentCurrencyRules.marketPriceScale(symbol: "AAPL", targetCurrency: "GBP"), 1)
        XCTAssertEqual(InstrumentCurrencyRules.marketPriceScale(symbol: "UNKNOWN.L", targetCurrency: "GBP"), 1)
        XCTAssertEqual(InstrumentCurrencyRules.marketPriceScale(symbol: "EQQU.L", targetCurrency: "GBP"), 1)
        XCTAssertEqual(InstrumentCurrencyRules.marketPriceScale(symbol: "EQQQ.L", targetCurrency: "GBP"), 0.01, accuracy: 1e-12)
        XCTAssertEqual(InstrumentCurrencyRules.marketPriceScale(symbol: "EQQQ.L", targetCurrency: "GBX"), 1)
        XCTAssertEqual(InstrumentCurrencyRules.marketPriceScale(symbol: "VUAG.L", targetCurrency: "GBX"), 100)
    }

    func testProviderPricesFollowTheProvidersOwnUnitOrAreRefused() {
        XCTAssertEqual(InstrumentCurrencyRules.providerPriceScale(symbol: "VUAG.L", sourceCurrency: "GBp")!, 0.01, accuracy: 1e-12)
        XCTAssertEqual(InstrumentCurrencyRules.providerPriceScale(symbol: "VUAG.L", sourceCurrency: "GBP"), 1)
        XCTAssertEqual(InstrumentCurrencyRules.providerPriceScale(symbol: "EQQQ.L", sourceCurrency: "GBP"), 100)
        XCTAssertNil(InstrumentCurrencyRules.providerPriceScale(symbol: "EQQQ.L", sourceCurrency: nil),
                     "An unknown unit is not guessed")
        XCTAssertNil(InstrumentCurrencyRules.providerPriceScale(symbol: "EQQU.L", sourceCurrency: "GBP"))
    }
}
