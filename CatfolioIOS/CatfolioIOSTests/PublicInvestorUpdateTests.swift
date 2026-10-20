import XCTest
@testable import CatfolioIOS

final class PublicInvestorUpdateTests: XCTestCase {
    func testPelosiPrivateInvestmentPreservesRangeAndSourceDates() throws {
        let catalog = try PublicInvestorCatalog.loaded.get()
        let record = try XCTUnwrap(catalog.recentActivities(investorID: "pelosi").first)
        let activity = record.activity
        XCTAssertEqual(activity.id, "house-20035553-row-1")
        XCTAssertEqual(activity.exactDate, "2026-09-08")
        XCTAssertEqual(activity.filedDate, "2026-10-02")
        XCTAssertEqual(activity.dateBasis, "FILING_DATE")
        XCTAssertEqual(activity.amountLow, 500_001)
        XCTAssertEqual(activity.amountHigh, 1_000_000)
        XCTAssertNil(activity.amount)
        XCTAssertNil(activity.shares)
        XCTAssertNil(activity.ticker)
        XCTAssertEqual(activity.owner, "SP")
        XCTAssertTrue(record.securityName.contains("REOF XXX"))
        XCTAssertFalse(record.securityName.contains("[AB]"))
        XCTAssertTrue(activity.sourceURL.hasSuffix("/20035553.pdf"))
    }

    func testARKDailyTradesKeepFundsAndDoNotReplaceQuarterlyHoldings() throws {
        let catalog = try PublicInvestorCatalog.loaded.get()
        let ark = try XCTUnwrap(catalog.investors.first { $0.id == "ark" })
        let trades = ark.activities.filter { $0.sourceType == "ARK_TRADE_NOTIFICATION" }
        XCTAssertEqual(trades.count, 12)
        XCTAssertEqual(Set(trades.compactMap(\.fund)), ["ARKF", "ARKG", "ARKK", "ARKW"])
        XCTAssertTrue(trades.allSatisfy { $0.exactDate == "2026-10-19" && $0.dateBasis == "TRADE_FILE_DATE" })
        XCTAssertEqual(trades.filter { $0.ticker == "CRWV" }.compactMap(\.shares).reduce(0, +), 132_498)
        XCTAssertEqual(trades.filter { $0.ticker == "PLTR" }.compactMap(\.shares).reduce(0, +), 18_349)
        XCTAssertEqual(trades.filter { $0.ticker == "SHOP" }.compactMap(\.shares).reduce(0, +), 20_755)
        XCTAssertTrue(trades.allSatisfy { $0.amount == nil })
        XCTAssertEqual(ark.snapshot?.effectiveDate, "2026-06-30")
        XCTAssertEqual(ark.history?.count, 11)
        let snapshotSymbols = Set((ark.history ?? []).flatMap(\.positions)
            .filter { $0.option == nil }.compactMap(\.ticker))
        XCTAssertEqual(Set(PublicInvestorLedger.symbols(catalog: catalog, selection: "ark")), snapshotSymbols)
    }

    func testFeedSortsByDisclosureDateAndFiltersWithoutInventingMuskRecords() throws {
        let catalog = try PublicInvestorCatalog.loaded.get()
        let records = catalog.recentActivities()
        XCTAssertEqual(catalog.asOf, "2026-10-20")
        XCTAssertEqual(Set(records.map(\.id)).count, records.count)
        XCTAssertTrue(records.prefix(12).allSatisfy { $0.investor.id == "ark" })
        XCTAssertEqual(records[12].activity.id, "house-20035553-row-1")
        XCTAssertTrue(zip(records, records.dropFirst()).allSatisfy { $0.activity.filedDate >= $1.activity.filedDate })
        XCTAssertTrue(catalog.recentActivities(investorID: "musk").isEmpty)
        XCTAssertTrue(catalog.recentActivities(investorID: "hh").allSatisfy { $0.investor.id == "hh" })
    }
}
