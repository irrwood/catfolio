import XCTest
@testable import CatfolioIOS

final class UnifiedSecuritySearchTests: XCTestCase {
    private func result(_ ticker: String, name: String = "Test", fund: Bool = false) -> MarketSecurityResult {
        .init(ticker: ticker, name: name, market: "US", exchange: "NASDAQ",
              currency: "USD", sector: nil, isFund: fund)
    }

    private func position(_ ticker: String, name: String) -> Holding {
        Holding(ticker: ticker, logoSymbol: nil, displayName: name, sector: nil, source: nil,
                shares: 12, averageCost: 80, costCurrency: "USD", quotePrice: 100, quoteCurrency: "USD",
                todayChangePercent: nil, marketValue: 1200, weight: 0.2, unrealized: 240,
                unrealizedPercent: 25, fxPnl: nil, fxPnlPercent: nil, fxPnlStatus: nil, fxPnlSource: nil)
    }

    func testHoldingKeepsDirectoryOrderAndPreservesPosition() throws {
        let holding = position("AAPL", name: "Apple")
        let matches = MarketSecurityResult.includingHoldings(
            [result("APLE"), result("aapl"), result("AAPL")], holdings: [holding], query: "apple")
        XCTAssertEqual(matches.map(\.ticker), ["APLE", "aapl"])
        XCTAssertEqual(matches[1].resolvedHolding(in: [holding]), holding)
    }

    func testExactUnheldMatchStaysAheadOfHeldPrefixAndCompanyNameMatches() throws {
        let catalog = try CompanyReferenceCatalog.bundled.get()
        let directory = MarketSecurityResult.search("NIO", in: catalog)
        let holdings = [position("NIOX.L", name: "NIOX Group"), position("OTHER", name: "NIO Fund")]
        let matches = MarketSecurityResult.includingHoldings(directory, holdings: holdings, query: "NIO")
        XCTAssertEqual(matches.first?.ticker, "NIO")
        let directoryIDs = Set(directory.map(\.ticker))
        XCTAssertEqual(matches.filter { directoryIDs.contains($0.ticker) }.map(\.ticker), directory.map(\.ticker))
        XCTAssertTrue(matches.contains { $0.ticker == "OTHER" })
    }

    func testBrokerOnlyExactMatchUsesRelevanceInsteadOfHoldingOrder() {
        let holdings = [position("OTHER", name: "Private Fund"), position("PRIVATE", name: "My security")]
        let matches = MarketSecurityResult.includingHoldings(
            [result("PRIVATEA"), result("ZZ", name: "Private Company")], holdings: holdings, query: "private")
        XCTAssertEqual(matches.map(\.ticker), ["PRIVATE", "PRIVATEA", "ZZ", "OTHER"])
    }

    func testHeldNameMatchCannotJumpAheadOfTickerMatchesAndAliases() {
        let directory = [result("ALIAS"), result("NIO"), result("NIOX.L")]
        let matches = MarketSecurityResult.includingHoldings(directory,
            holdings: [position("HOLDING", name: "NIO Fund")], query: "NIO")
        XCTAssertEqual(matches.map(\.ticker), ["ALIAS", "NIO", "NIOX.L", "HOLDING"])
    }

    func testBrokerOnlyHoldingsMatchNamesAndTrimmedCodes() {
        let holding = position("PRIVATE", name: "我的证券")
        for query in ["  private ", "我的"] {
            XCTAssertEqual(MarketSecurityResult.includingHoldings([], holdings: [holding], query: query)
                .map(\.ticker), ["PRIVATE"])
        }
        XCTAssertTrue(MarketSecurityResult.includingHoldings([], holdings: [holding], query: "other").isEmpty)
        XCTAssertTrue(MarketSecurityResult.includingHoldings([], holdings: [holding], query: "  ").isEmpty)
    }

    func testDirectoryAliasResolvesToRealHolding() throws {
        let holding = position("0700.HK", name: "Tencent")
        let matches = MarketSecurityResult.includingHoldings([result("0700.HK")],
                                                             holdings: [holding], query: "腾讯")
        XCTAssertEqual(try XCTUnwrap(matches.first).resolvedHolding(in: [holding]), holding)
    }

    func testUnheldStockAndETFOpenWithoutInventingAPosition() throws {
        let catalog = try CompanyReferenceCatalog.bundled.get()
        for ticker in ["AAPL", "QQQ"] {
            let match = try XCTUnwrap(MarketSecurityResult.search(ticker, in: catalog).first { $0.ticker == ticker })
            XCTAssertEqual(match.isFund, ticker == "QQQ")
            let holding = match.resolvedHolding(in: [])
            XCTAssertEqual(holding.ticker, ticker)
            XCTAssertEqual(holding.shares, 0)
            XCTAssertEqual(holding.marketValue, 0)
            XCTAssertEqual(holding.quoteCurrency, match.currency)
        }
    }
}
