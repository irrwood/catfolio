import XCTest
@testable import CatfolioIOS

final class DelistedPriceArchiveTests: XCTestCase {
    func testArchiveHasRealFiniteTradingCoverage() throws {
        let archive = try XCTUnwrap(DelistedPriceArchive.entry(for: "CYBR"))
        XCTAssertEqual(archive.currency, "USD")
        XCTAssertEqual(archive.firstDay, "2016-01-04")
        XCTAssertEqual(archive.lastTradingDay, "2026-02-10")
        XCTAssertEqual(archive.count, 2541)
        XCTAssertEqual(archive.closes(from: "2025-06-24", to: "2025-06-24"), ["2025-06-24": 397.13])
        XCTAssertTrue(archive.closes(from: "2026-02-11", to: "2026-10-19").isEmpty)
        XCTAssertNil(DelistedPriceArchive.entry(for: "PANW"))
        XCTAssertNil(DelistedPriceArchive.entry(for: "CYBR.L"))
    }

    func testDailyHistoryAndDetailWorkOfflineWithoutExtendingPastDelisting() async throws {
        let client = LocalMarketDataClient()
        for adjusted in [true, false] {
            let closes = try await client.historicalCloses(symbol: "CYBR", from: "2025-06-20", to: "2026-10-19",
                dividendAdjusted: adjusted, cachedOnly: true)
            XCTAssertEqual(closes.count, 162)
            XCTAssertEqual(closes.keys.max(), "2026-02-10")
            XCTAssertEqual(closes["2026-02-10"], 408.85)
        }
        let history = try await client.securityPriceHistory(ticker: "CYBR", currency: "USD",
            document: .empty, cachedOnly: true)
        XCTAssertEqual(history.points.count, 2541)
        XCTAssertEqual(history.points.last?.dateText, "2026-02-10")
        XCTAssertTrue(history.intradayPoints.isEmpty)
        XCTAssertNil(history.extendedHoursQuote())
        do {
            _ = try await client.historicalCloses(symbol: "CYBR", from: "2026-02-11", to: "2026-10-19", cachedOnly: true)
            XCTFail("A retired price must not become a quote for a later day")
        } catch LocalServiceError.noHistoricalPrices {} catch { XCTFail("Unexpected error: \(error)") }
    }

    func testArchiveValidationRejectsWrongUnitsAndDuplicateOrPostDelistingBars() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "cybr_delisted_daily_history", withExtension: "json"))
        let data = try Data(contentsOf: url)
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for (key, value) in [("currency", "EUR"), ("priceBasis", "unknown"), ("lastTradingDay", "2026-10-19")] {
            var mutated = original
            mutated[key] = value
            XCTAssertThrowsError(try DelistedPriceArchive.decode(JSONSerialization.data(withJSONObject: mutated)))
        }
        var mutated = original
        var bars = try XCTUnwrap(original["bars"] as? [[String: Any]])
        bars[1] = bars[0]
        mutated["bars"] = bars
        XCTAssertThrowsError(try DelistedPriceArchive.decode(JSONSerialization.data(withJSONObject: mutated)))
    }

    func testAccountLedgerUsesTheArchivedSecuritysOwnDollarPricesOffline() async throws {
        var document = LocalPortfolioDocument.empty
        document.positions = [LocalPositionRecord(ticker: "CYBR", name: "CyberArk", shares: 1,
            averageCost: 397.13, currency: "USD", quotePrice: 399.44, quoteCurrency: "USD",
            source: "CSV", openedDate: "2025-06-24")]
        document.transactions = [
            LocalTransactionRecord(date: "2025-06-24", action: "DEPOSIT", ticker: "CASH",
                quantity: 0, price: 0, currency: "USD", source: "CSV", accountID: nil, accountName: nil,
                cashPostings: [.init(currency: "USD", amount: 1000)]),
            LocalTransactionRecord(date: "2025-06-24", action: "BUY", ticker: "CYBR",
                quantity: 1, price: 397.13, currency: "USD", source: "CSV", accountID: nil, accountName: nil,
                cashPostings: [.init(currency: "USD", amount: Decimal(string: "-397.13")!)])
        ]
        let result = try await LocalMarketDataClient().tolerantAccountSeries(document: document,
            to: "2025-06-25", cachedOnly: true, includeBenchmarks: false)
        let ledger = try XCTUnwrap(result.ledger)
        XCTAssertEqual(try XCTUnwrap(ledger.values.last ?? nil), 1002.31, accuracy: 0.00001)
        XCTAssertTrue(result.assumptions.isEmpty)
    }
}
