import XCTest
@testable import CatfolioIOS

/// A Trading 212 fill keeps the currency its security is quoted in. An
/// unlisted London line used to be taken for pence, so a SILG.L fill at
/// £25 read as 25p and its profit came out a hundredfold too large.
final class LondonFillCurrencyTests: XCTestCase {
    private func position(_ ticker: String, currency: String) -> LocalPositionRecord {
        LocalPositionRecord(ticker: ticker, name: ticker, shares: 10, averageCost: 25, currency: currency,
                            quotePrice: 31, quoteCurrency: currency, source: "Trading 212", openedDate: "2026-01-05",
                            accountID: "A", accountName: "A", accountCurrency: "GBP", brokerPnl: nil,
                            brokerPnlCurrency: nil, brokerFxPnl: nil, brokerFxPnlCurrency: nil, fxPnl: nil,
                            fxPnlCurrency: nil, fxPnlStatus: nil, fxPnlSource: nil)
    }

    private func fill(_ ticker: String, currency: String) -> LocalTransactionRecord {
        LocalTransactionRecord(date: "2026-01-05", action: "BUY", ticker: ticker, quantity: 10, price: 25,
                               currency: currency, source: "Trading 212", accountID: "A", accountName: "A",
                               tradeID: "\(ticker)-1")
    }

    private func roundTrip(_ document: LocalPortfolioDocument) async throws -> LocalPortfolioDocument {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("london-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(document).write(to: url)
        return try await LocalPortfolioStore(fileURL: url).load()
    }

    func testAHeldLondonLineKeepsItsBrokersQuoteCurrency() async throws {
        var document = LocalPortfolioDocument.empty
        document.source = "Trading 212"
        // KRUZ.L stands in for any London line the app has no entry for.
        document.positions = [position("KRUZ.L", currency: "GBP")]
        document.transactions = [fill("KRUZ.L", currency: "GBP")]
        let loaded = try await roundTrip(document)
        XCTAssertEqual(loaded.transactions?.first?.currency, "GBP")
    }

    func testSILGIsQuotedInPoundsEvenOnceSold() async throws {
        XCTAssertEqual(InstrumentCurrencyRules.knownPriceCurrency(for: "SILG.L"), "GBP")
        var document = LocalPortfolioDocument.empty
        document.source = "Trading 212"
        document.transactions = [fill("SILG.L", currency: "GBP")]
        let loaded = try await roundTrip(document)
        XCTAssertEqual(loaded.transactions?.first?.currency, "GBP")
    }

    func testAnOldPenceFillWithNoPositionIsStillRepaired() async throws {
        var document = LocalPortfolioDocument.empty
        document.source = "Trading 212"
        document.transactions = [fill("BARC.L", currency: "GBP")]
        let loaded = try await roundTrip(document)
        XCTAssertEqual(loaded.transactions?.first?.currency, "GBX")
    }
}
