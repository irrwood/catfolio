import XCTest
@testable import CatfolioIOS

final class PublicInvestorHistoryTests: XCTestCase {
    func testAllHistoryUsesSelectedInvestorsAndIncludesNonEquityDisclosures() throws {
        let catalog = try PublicInvestorCatalog.loaded.get()
        let history = PublicInvestorHistory(records: catalog.recentActivities())
        let accounts: Set<String> = ["公开披露|pelosi", "公开披露|ark"]
        let rows = history.scoped(accountIDs: accounts)
        XCTAssertEqual(Set(rows.map(\.investor.id)), ["pelosi", "ark"])
        XCTAssertTrue(rows.contains { $0.activity.id == "house-20035553-row-1" && $0.activity.ticker == nil })
        XCTAssertTrue(rows.contains { $0.activity.option != nil })
        XCTAssertTrue(zip(rows, rows.dropFirst()).allSatisfy { $0.activity.filedDate >= $1.activity.filedDate })
        XCTAssertTrue(history.scoped(accountIDs: []).isEmpty)
        XCTAssertTrue(history.scoped(accountIDs: ["公开披露|musk"]).isEmpty)
        XCTAssertTrue(history.scoped(accountIDs: ["SnapTrade|pelosi"]).isEmpty)
    }

    func testAccountTickerAndHistoryYearFiltersCompose() throws {
        let history = PublicInvestorHistory(records: try PublicInvestorCatalog.loaded.get().recentActivities())
        let accounts: Set<String> = ["公开披露|ark"]
        let rows = history.scoped(accountIDs: accounts, ticker: " crwv ", basis: .calendar, year: "2026")
        XCTAssertFalse(rows.isEmpty)
        XCTAssertTrue(rows.allSatisfy { $0.investor.id == "ark" && $0.historyTicker == "CRWV"
            && $0.historyDate.hasPrefix("2026") })
        let years = history.years(accountIDs: accounts, ticker: "CRWV", basis: .uk)
        XCTAssertFalse(years.isEmpty)
        for year in years {
            let scoped = history.scoped(accountIDs: accounts, ticker: "CRWV", basis: .uk, year: year)
            XCTAssertFalse(scoped.isEmpty)
            XCTAssertTrue(scoped.allSatisfy { TaxYearBasis.uk.label(for: $0.historyDate) == year })
        }
        XCTAssertTrue(history.years(accountIDs: [], basis: .calendar).isEmpty)
    }

    func testExportPreservesReportedRangesDatesAndSourceWithoutInventingPrice() throws {
        let record = try XCTUnwrap(PublicInvestorCatalog.loaded.get()
            .recentActivities(investorID: "pelosi").first { $0.activity.id == "house-20035553-row-1" })
        let row = PublicInvestorHistory.exportRow(record)
        XCTAssertEqual(row.count, PublicInvestorHistory.exportHeader.count)
        let fields = Dictionary(uniqueKeysWithValues: zip(PublicInvestorHistory.exportHeader, row))
        XCTAssertEqual(fields["Disclosure Date"], "2026-10-02")
        XCTAssertEqual(fields["Date"], "2026-09-08")
        XCTAssertEqual(fields["Quantity"], "")
        XCTAssertEqual(fields["Amount"], "")
        XCTAssertEqual(fields["Amount Low"], "500001.0")
        XCTAssertEqual(fields["Amount High"], "1000000.0")
        XCTAssertEqual(fields["Source"], record.activity.sourceURL)
        XCTAssertEqual(fields["Price"], "")
    }

    func testSupplementalRecordsDoNotDuplicateExistingFillsOrDropOptions() throws {
        let records = try PublicInvestorCatalog.loaded.get().recentActivities(investorID: "pelosi")
        let equity = try XCTUnwrap(records.first { !$0.isOption && $0.activity.ticker != nil })
        let option = try XCTUnwrap(records.first { $0.isOption && $0.activity.ticker != nil })
        let fills = [equity, option].map { record in
            LocalTransactionRecord(date: record.historyDate, action: "BUY", ticker: record.activity.ticker!,
                quantity: 10, price: 100, currency: "USD", source: PublicInvestorAccountAdapter.source,
                accountID: "pelosi", accountName: "Pelosi", tradeID: "investor-ledger-v1:\(record.activity.id):\(record.activity.ticker!)")
        }
        let supplemental = PublicInvestorHistory(records: records).supplemental(to: fills)
        XCTAssertFalse(supplemental.records.contains { $0.id == equity.id })
        XCTAssertTrue(supplemental.records.contains { $0.id == option.id }, "An underlying equity fill cannot stand in for an option")
        XCTAssertTrue(option.historySubtitle.contains(L10n.text("期权")))
        let activities = fills.map { PortfolioActivity(transaction: $0, securityName: $0.ticker) }
        let timeline = HistoryTimeline(activities: activities, disclosures: supplemental.records)
        let groups = timeline.groups(basis: .calendar, year: nil)
        let originalIDs = groups.flatMap(\.entries).compactMap { entry -> String? in
            if case .transaction(let activity) = entry { return activity.id }
            return nil
        }
        XCTAssertEqual(Set(originalIDs), Set(fills.map(\.id)), "Keep every pre-existing history row")
        XCTAssertEqual(groups.flatMap(\.entries).count, fills.count + supplemental.records.count)
        XCTAssertTrue(zip(groups, groups.dropFirst()).allSatisfy { $0.id > $1.id })
        for year in timeline.yearLabels(basis: .uk) {
            XCTAssertTrue(timeline.groups(basis: .uk, year: year).allSatisfy { TaxYearBasis.uk.label(for: $0.id) == year })
        }
    }

    func testQuarterlyChangesMatchTheirExistingSnapshotRowsByCUSIP() throws {
        let catalog = try PublicInvestorCatalog.loaded.get()
        let record = try XCTUnwrap(catalog.recentActivities(investorID: "ark").first { record in
            !record.isOption && record.activity.exactDate == nil && record.historyTicker != nil
                && (record.investor.history ?? []).contains { $0.filedDate == record.activity.filedDate }
        })
        let snapshot = try XCTUnwrap(record.investor.history?.first { $0.filedDate == record.activity.filedDate })
        let ticker = try XCTUnwrap(record.historyTicker)
        let fill = LocalTransactionRecord(date: snapshot.filedDate, action: "BUY", ticker: ticker,
            quantity: 10, price: 100, currency: "USD", source: PublicInvestorAccountAdapter.source,
            accountID: "ark", accountName: "ARK", tradeID: "investor-ledger-v1:\(snapshot.snapshotId ?? snapshot.filedDate):\(ticker)")
        XCTAssertTrue(PublicInvestorHistory(records: [record]).supplemental(to: [fill]).records.isEmpty)
    }
}
